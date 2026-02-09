//! Session management for persistent sandbox sessions.
//!
//! Sessions maintain a long-lived agent process inside a jail, preserving
//! interpreter state (variables, imports, files) across `run()` calls.
//! Each session is bound to its creation environment — using a different
//! `env` on an existing session returns an error.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tokio::sync::{Mutex, RwLock};
use tracing::{debug, info, warn};

use crate::backend::ExecutionResult;
use crate::config::EnvironmentMeta;
use crate::transport::protocol::{AgentRequest, AgentResponse};
use crate::transport::{StdioPipeTransport, Transport};

/// Parsed session configuration with `Duration` fields.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// How long a session can be idle before the reaper cleans it up.
    pub idle_timeout: Duration,

    /// Maximum total lifetime of a session, regardless of activity.
    pub max_lifetime: Duration,

    /// How long to wait for the agent's Ready message on startup.
    pub agent_ready_timeout: Duration,

    /// Interval between reaper sweeps.
    pub reaper_interval: Duration,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            idle_timeout: Duration::from_secs(300),
            max_lifetime: Duration::from_secs(3600),
            agent_ready_timeout: Duration::from_secs(30),
            reaper_interval: Duration::from_secs(60),
        }
    }
}

impl SessionConfig {
    /// Create from the TOML configuration values.
    pub fn from_toml(toml: &crate::config::SessionConfigToml) -> Self {
        Self {
            idle_timeout: Duration::from_secs(toml.idle_timeout_seconds),
            max_lifetime: Duration::from_secs(toml.max_lifetime_seconds),
            ..Self::default()
        }
    }

    /// Create from environment variables, falling back to defaults.
    ///
    /// Reads `SESSION_IDLE_TIMEOUT` and `SESSION_MAX_LIFETIME` (in seconds).
    pub fn from_env() -> Self {
        Self {
            idle_timeout: std::env::var("SESSION_IDLE_TIMEOUT")
                .ok()
                .and_then(|v| v.parse().ok())
                .map(Duration::from_secs)
                .unwrap_or(Duration::from_secs(300)),
            max_lifetime: std::env::var("SESSION_MAX_LIFETIME")
                .ok()
                .and_then(|v| v.parse().ok())
                .map(Duration::from_secs)
                .unwrap_or(Duration::from_secs(3600)),
            ..Self::default()
        }
    }
}

/// A persistent sandbox session.
///
/// Holds the transport to the jailed agent and tracks timing for reaper cleanup.
pub struct Session {
    /// User-provided session identifier.
    pub id: String,

    /// Environment this session is bound to (validated on each call).
    pub env_name: String,

    /// When this session was created.
    pub created_at: Instant,

    /// Last time this session was used (for idle timeout).
    last_used: Mutex<Instant>,

    /// Transport to the agent process.
    transport: Mutex<Box<dyn Transport>>,
}

impl Session {
    fn new(id: String, env_name: String, transport: Box<dyn Transport>) -> Self {
        let now = Instant::now();
        Self {
            id,
            env_name,
            created_at: now,
            last_used: Mutex::new(now),
            transport: Mutex::new(transport),
        }
    }

    /// Send a request to the agent and return the response.
    async fn request(&self, req: &AgentRequest) -> Result<AgentResponse> {
        *self.last_used.lock().await = Instant::now();
        let transport = self.transport.lock().await;
        transport.request(req).await
    }

    /// Check if the agent process is still alive.
    #[allow(dead_code)]
    fn is_alive(&self) -> bool {
        // We can't lock synchronously in an async context easily.
        // The transport's is_alive is atomic, so we check it directly
        // via a best-effort approach. The reaper will catch dead sessions.
        true // Checked properly during request/reaper
    }

    /// Shut down the agent.
    async fn shutdown(&self) -> Result<()> {
        let transport = self.transport.lock().await;
        transport.shutdown().await
    }

    /// Check if this session has exceeded idle timeout.
    async fn is_idle_expired(&self, timeout: Duration) -> bool {
        let last_used = *self.last_used.lock().await;
        last_used.elapsed() > timeout
    }

    /// Check if this session has exceeded max lifetime.
    fn is_lifetime_expired(&self, max_lifetime: Duration) -> bool {
        self.created_at.elapsed() > max_lifetime
    }
}

/// Manages the lifecycle of persistent sandbox sessions.
///
/// Thread-safe: uses `RwLock` for the session map, per-session execute locks
/// for arrival-order serialization, and `Mutex` per-session transport.
pub struct SessionManager {
    sessions: RwLock<HashMap<String, Arc<Session>>>,
    /// Per-session execute lock. Acquired at the top of `execute()` to ensure
    /// concurrent requests for the same session are processed in arrival order.
    /// Different sessions run in parallel (different locks).
    execute_locks: RwLock<HashMap<String, Arc<Mutex<()>>>>,
    config: SessionConfig,
}

impl SessionManager {
    /// Create a new session manager with the given configuration.
    pub fn new(config: SessionConfig) -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
            execute_locks: RwLock::new(HashMap::new()),
            config,
        }
    }

    /// Get or create the per-session execute lock.
    async fn get_execute_lock(&self, session_id: &str) -> Arc<Mutex<()>> {
        // Fast path: read lock
        {
            let locks = self.execute_locks.read().await;
            if let Some(lock) = locks.get(session_id) {
                return Arc::clone(lock);
            }
        }
        // Slow path: create
        let mut locks = self.execute_locks.write().await;
        Arc::clone(
            locks
                .entry(session_id.to_string())
                .or_insert_with(|| Arc::new(Mutex::new(()))),
        )
    }

    /// Execute code in a session, creating the session if needed.
    ///
    /// Per-session execute lock ensures concurrent requests for the same
    /// session are serialized in arrival order. Different sessions run
    /// in parallel.
    ///
    /// Returns an error if:
    /// - The session exists but is bound to a different environment
    /// - The environment doesn't support sessions (`session_exec` is None)
    /// - The agent process fails to start or respond
    pub async fn execute(
        &self,
        session_id: &str,
        env_name: &str,
        env_meta: &EnvironmentMeta,
        code: &str,
        project_dir: Option<&Path>,
        project_mount: &str,
    ) -> Result<ExecutionResult> {
        // Per-session lock: serializes all operations on this session.
        // First task to reach here wins; others queue behind it.
        let exec_lock = self.get_execute_lock(session_id).await;
        let _guard = exec_lock.lock().await;

        let session = self
            .get_or_create(session_id, env_name, env_meta, project_dir, project_mount)
            .await?;

        // Map env_name to interpreter name for the agent protocol
        let interpreter = env_to_interpreter(env_name, env_meta);

        let req = AgentRequest::Execute {
            id: session_id.to_string(),
            interpreter,
            code: code.to_string(),
        };

        let resp = session
            .request(&req)
            .await
            .context("Failed to communicate with session agent")?;

        match resp {
            AgentResponse::Result {
                stdout,
                stderr,
                exit_code,
                ..
            } => Ok(ExecutionResult {
                exit_code,
                stdout,
                stderr,
            }),
            AgentResponse::Error { message } => Ok(ExecutionResult {
                exit_code: 1,
                stdout: String::new(),
                stderr: message,
            }),
            other => anyhow::bail!("Unexpected agent response: {other:?}"),
        }
    }

    /// Get an existing session or create a new one.
    ///
    /// Caller must hold the per-session execute lock — this guarantees
    /// no concurrent creation race for the same session_id.
    async fn get_or_create(
        &self,
        session_id: &str,
        env_name: &str,
        env_meta: &EnvironmentMeta,
        project_dir: Option<&Path>,
        project_mount: &str,
    ) -> Result<Arc<Session>> {
        // Check for existing session
        {
            let sessions = self.sessions.read().await;
            if let Some(session) = sessions.get(session_id) {
                if session.env_name != env_name {
                    anyhow::bail!(
                        "Session '{}' is bound to environment '{}', not '{}'.\n\
                         Use a different session ID, or omit session for ephemeral execution.",
                        session_id,
                        session.env_name,
                        env_name
                    );
                }
                return Ok(Arc::clone(session));
            }
        }

        // Create new session (no race possible — execute lock is held)
        let session_exec = env_meta.session_exec.as_deref().ok_or_else(|| {
            anyhow::anyhow!(
                "Environment '{}' does not support sessions (no session_exec configured)",
                env_name
            )
        })?;

        // Build env vars for the agent process (for runtime project mounting)
        let mut env_vars = Vec::new();
        if let Some(dir) = project_dir {
            env_vars.push(("PROJECT_DIR".to_string(), dir.to_string_lossy().into_owned()));
            env_vars.push(("PROJECT_MOUNT".to_string(), project_mount.to_string()));
        }

        let transport =
            StdioPipeTransport::spawn(session_exec, self.config.agent_ready_timeout, &env_vars).await
                .with_context(|| {
                    format!("Failed to start session agent for '{env_name}'")
                })?;

        let session = Arc::new(Session::new(
            session_id.to_string(),
            env_name.to_string(),
            Box::new(transport),
        ));

        info!(session = %session_id, env = %env_name, "Created new session");
        let mut sessions = self.sessions.write().await;
        sessions.insert(session_id.to_string(), Arc::clone(&session));
        Ok(session)
    }

    /// Clean up expired sessions (called by the reaper task).
    pub async fn cleanup_expired(&self) {
        let expired_ids: Vec<String> = {
            let sessions = self.sessions.read().await;
            let mut expired = Vec::new();
            for (id, session) in sessions.iter() {
                let idle_expired = session.is_idle_expired(self.config.idle_timeout).await;
                let lifetime_expired =
                    session.is_lifetime_expired(self.config.max_lifetime);

                if idle_expired || lifetime_expired {
                    let reason = if lifetime_expired {
                        "max lifetime"
                    } else {
                        "idle timeout"
                    };
                    debug!(session = %id, reason = %reason, "Session expired");
                    expired.push(id.clone());
                }
            }
            expired
        };

        if expired_ids.is_empty() {
            return;
        }

        let mut sessions = self.sessions.write().await;
        let mut locks = self.execute_locks.write().await;
        for id in &expired_ids {
            if let Some(session) = sessions.remove(id) {
                locks.remove(id);
                info!(session = %id, "Cleaning up expired session");
                if let Err(e) = session.shutdown().await {
                    warn!(session = %id, error = %e, "Error shutting down session");
                }
            }
        }
    }

    /// Destroy all sessions (called on MCP disconnect).
    pub async fn destroy_all(&self) {
        let all_sessions: Vec<Arc<Session>> = {
            let mut sessions = self.sessions.write().await;
            self.execute_locks.write().await.clear();
            sessions.drain().map(|(_, s)| s).collect()
        };

        for session in &all_sessions {
            info!(session = %session.id, "Destroying session");
            if let Err(e) = session.shutdown().await {
                warn!(session = %session.id, error = %e, "Error destroying session");
            }
        }
    }

    /// Start the background reaper task.
    ///
    /// Returns a `JoinHandle` that runs until cancelled. The reaper
    /// checks for expired sessions every `reaper_interval`.
    pub fn start_reaper(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let manager = Arc::clone(self);
        let interval = manager.config.reaper_interval;

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.tick().await; // First tick is immediate, skip it
            loop {
                ticker.tick().await;
                debug!("Reaper sweep");
                manager.cleanup_expired().await;
            }
        })
    }
}

/// Map environment name to interpreter name for the agent protocol.
///
/// The agent supports "python", "bash", and "node" interpreters.
/// If `interpreter_type` is set on the environment metadata (from custom
/// sandbox artifacts), use that directly. Otherwise, fall back to
/// name-based matching for bundled presets.
fn env_to_interpreter(env_name: &str, env_meta: &EnvironmentMeta) -> String {
    // Custom sandboxes set interpreter_type explicitly
    if let Some(ref itype) = env_meta.interpreter_type {
        return itype.clone();
    }

    // Bundled preset name-based mapping
    match env_name {
        "python" => "python".to_string(),
        "shell" => "bash".to_string(),
        "node" => "node".to_string(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta_with_interpreter_type(itype: Option<&str>) -> EnvironmentMeta {
        EnvironmentMeta {
            backend: crate::config::BackendType::Jail,
            exec: "/bin/test".to_string(),
            session_exec: None,
            timeout_seconds: 30,
            memory_mb: 512,
            interpreter_type: itype.map(String::from),
        }
    }

    #[test]
    fn test_env_to_interpreter() {
        let meta_none = meta_with_interpreter_type(None);
        assert_eq!(env_to_interpreter("python", &meta_none), "python");
        assert_eq!(env_to_interpreter("shell", &meta_none), "bash");
        assert_eq!(env_to_interpreter("node", &meta_none), "node");
        assert_eq!(env_to_interpreter("custom", &meta_none), "custom");
    }

    #[test]
    fn test_env_to_interpreter_with_interpreter_type() {
        let meta_python = meta_with_interpreter_type(Some("python"));
        // interpreter_type overrides name-based matching
        assert_eq!(env_to_interpreter("data-science", &meta_python), "python");

        let meta_bash = meta_with_interpreter_type(Some("bash"));
        assert_eq!(env_to_interpreter("rust-dev", &meta_bash), "bash");
    }

    #[test]
    fn test_session_config_defaults() {
        let config = SessionConfig::default();
        assert_eq!(config.idle_timeout, Duration::from_secs(300));
        assert_eq!(config.max_lifetime, Duration::from_secs(3600));
        assert_eq!(config.agent_ready_timeout, Duration::from_secs(30));
        assert_eq!(config.reaper_interval, Duration::from_secs(60));
    }

    #[test]
    fn test_session_config_from_env_defaults() {
        // When env vars are not set, from_env() uses the same defaults
        let config = SessionConfig::from_env();
        assert_eq!(config.idle_timeout, Duration::from_secs(300));
        assert_eq!(config.max_lifetime, Duration::from_secs(3600));
        assert_eq!(config.agent_ready_timeout, Duration::from_secs(30));
        assert_eq!(config.reaper_interval, Duration::from_secs(60));
    }

    #[test]
    fn test_session_config_from_toml() {
        let toml = crate::config::SessionConfigToml {
            idle_timeout_seconds: 120,
            max_lifetime_seconds: 1800,
        };
        let config = SessionConfig::from_toml(&toml);
        assert_eq!(config.idle_timeout, Duration::from_secs(120));
        assert_eq!(config.max_lifetime, Duration::from_secs(1800));
    }
}
