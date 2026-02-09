//! jail.nix backend implementation.
//!
//! Executes code by forking and running the Nix-built jail wrapper.
//! The wrapper handles all sandboxing via bubblewrap.

use std::path::Path;
use std::process::Stdio;

use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tracing::{debug, instrument};

use super::{ExecutionResult, IsolationBackend};
use crate::config::EnvironmentMeta;

/// Backend that uses jail.nix (bubblewrap) for isolation.
#[derive(Debug, Default, Clone)]
pub struct JailBackend {
    // Future: could hold pre-warmed sandbox pool
}

impl JailBackend {
    /// Create a new jail backend.
    #[must_use]
    pub const fn new() -> Self {
        Self {}
    }
}

#[async_trait]
impl IsolationBackend for JailBackend {
    #[instrument(skip(self, code), fields(exec = %env.exec, timeout = env.timeout_seconds))]
    async fn execute(
        &self,
        env: &EnvironmentMeta,
        code: &str,
        project_dir: Option<&Path>,
        project_mount: &str,
    ) -> Result<ExecutionResult> {
        debug!(code_len = code.len(), "Executing code in jail");

        // Spawn the jail wrapper process
        let mut cmd = Command::new(&env.exec);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        // Pass project dir as env vars for runtime mounting (mkSandbox artifacts)
        if let Some(dir) = project_dir {
            cmd.env("PROJECT_DIR", dir);
            cmd.env("PROJECT_MOUNT", project_mount);
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("Failed to spawn jail wrapper: {}", env.exec))?;

        // Write code to stdin
        let mut stdin = child.stdin.take().context("Failed to open stdin")?;
        stdin
            .write_all(code.as_bytes())
            .await
            .context("Failed to write code to stdin")?;
        drop(stdin); // Close stdin to signal EOF

        // Take pipe handles out so `child` stays in scope for kill-on-timeout
        let mut child_stdout = child.stdout.take().context("Failed to open stdout")?;
        let mut child_stderr = child.stderr.take().context("Failed to open stderr")?;

        // Read stdout+stderr concurrently, under the timeout.
        // `child` is NOT moved into this future, so we can kill it on timeout.
        let timeout_duration = std::time::Duration::from_secs(env.timeout_seconds);
        let read_all = async {
            let mut stdout_buf = Vec::new();
            let mut stderr_buf = Vec::new();
            let (r1, r2) = tokio::join!(
                child_stdout.read_to_end(&mut stdout_buf),
                child_stderr.read_to_end(&mut stderr_buf),
            );
            r1.context("Failed to read stdout")?;
            r2.context("Failed to read stderr")?;
            Ok::<_, anyhow::Error>((stdout_buf, stderr_buf))
        };

        let (stdout_buf, stderr_buf) =
            if let Ok(result) = tokio::time::timeout(timeout_duration, read_all).await {
                result?
            } else {
                let _ = child.kill().await;
                anyhow::bail!("Command timed out after {}s", env.timeout_seconds);
            };

        let status = child.wait().await.context("Failed to wait for process")?;

        let result = ExecutionResult {
            exit_code: status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&stdout_buf).into_owned(),
            stderr: String::from_utf8_lossy(&stderr_buf).into_owned(),
        };

        debug!(exit_code = result.exit_code, "Execution completed");

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::BackendType;

    #[tokio::test]
    async fn test_execute_echo() {
        // This test requires a working jail wrapper, skip in CI
        if std::env::var("NIX_SANDBOX_TEST").is_err() {
            return;
        }

        let backend = JailBackend::new();
        let env = EnvironmentMeta {
            backend: BackendType::Jail,
            exec: "/bin/sh".to_string(), // Use sh for testing without jail
            session_exec: None,
            timeout_seconds: 5,
            memory_mb: 512,
            interpreter_type: None,
        };

        let result = backend.execute(&env, "echo hello", None, "/project").await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("hello"));
    }
}
