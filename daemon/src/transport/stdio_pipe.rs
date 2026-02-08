//! Stdin/stdout pipe transport for jailed agent processes.
//!
//! Owns a child process, communicates via length-prefixed JSON on
//! the child's stdin (requests) and stdout (responses).
//! Mutex-guarded for safe concurrent access from multiple MCP calls.

use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::sync::Mutex;
use tracing::{debug, warn};

use super::protocol::{AgentRequest, AgentResponse};
use super::{recv_message, send_message, Transport};

/// Transport that communicates with a jailed agent via stdin/stdout pipes.
///
/// The agent process is spawned once and kept alive for the session lifetime.
/// Each `request()` call acquires both stdin and stdout mutexes to ensure
/// atomic send/receive (no interleaving from concurrent callers).
pub struct StdioPipeTransport {
    child: Mutex<Child>,
    stdin: Mutex<ChildStdin>,
    stdout: Mutex<ChildStdout>,
    alive: AtomicBool,
}

impl StdioPipeTransport {
    /// Spawn a jailed agent process and wait for its `Ready` message.
    ///
    /// `exec_path` is the path to the session jail wrapper (which runs the agent).
    /// `ready_timeout` is how long to wait for the agent's Ready message.
    pub async fn spawn(exec_path: &str, ready_timeout: Duration) -> Result<Self> {
        debug!(exec = %exec_path, "Spawning agent process");

        let mut child = tokio::process::Command::new(exec_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to spawn agent: {exec_path}"))?;

        let stdin = child.stdin.take().context("Failed to take agent stdin")?;
        let mut stdout = child.stdout.take().context("Failed to take agent stdout")?;

        // Wait for the agent's Ready message
        let ready_result =
            tokio::time::timeout(ready_timeout, recv_message(&mut stdout)).await;

        let ready_bytes = ready_result
            .map_err(|_| anyhow::anyhow!("Agent did not send Ready within {ready_timeout:?}"))?
            .context("Failed to read agent Ready message")?;

        let ready_msg: AgentResponse = serde_json::from_slice(&ready_bytes)
            .context("Failed to parse agent Ready message")?;

        match ready_msg {
            AgentResponse::Ready => {
                debug!("Agent is ready");
            }
            other => {
                anyhow::bail!("Expected Ready message, got: {other:?}");
            }
        }

        Ok(Self {
            child: Mutex::new(child),
            stdin: Mutex::new(stdin),
            stdout: Mutex::new(stdout),
            alive: AtomicBool::new(true),
        })
    }
}

#[async_trait]
impl Transport for StdioPipeTransport {
    async fn request(&self, req: &AgentRequest) -> Result<AgentResponse> {
        if !self.alive.load(Ordering::Relaxed) {
            anyhow::bail!("Agent process is not alive");
        }

        // Acquire both locks for atomic send/receive
        let mut stdin = self.stdin.lock().await;
        let mut stdout = self.stdout.lock().await;

        let req_bytes = serde_json::to_vec(req).context("Failed to serialize request")?;
        send_message(&mut *stdin, &req_bytes)
            .await
            .context("Failed to send request to agent")?;

        let resp_bytes = recv_message(&mut *stdout)
            .await
            .context("Failed to read response from agent")?;

        let resp: AgentResponse =
            serde_json::from_slice(&resp_bytes).context("Failed to parse agent response")?;

        Ok(resp)
    }

    async fn shutdown(&self) -> Result<()> {
        if !self.alive.load(Ordering::Relaxed) {
            return Ok(());
        }

        // Try graceful shutdown first
        let shutdown_result = self
            .request(&AgentRequest::Shutdown)
            .await;

        if let Err(e) = shutdown_result {
            warn!(error = %e, "Graceful shutdown failed, killing agent");
        }

        self.alive.store(false, Ordering::Relaxed);

        // Kill the process to ensure cleanup
        let mut child = self.child.lock().await;
        let _ = child.kill().await;
        let _ = child.wait().await;

        debug!("Agent process shut down");
        Ok(())
    }

    fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }
}
