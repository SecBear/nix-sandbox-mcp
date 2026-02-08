//! Isolation backend trait and implementations.
//!
//! Backends are responsible for executing code in sandboxed environments.
//! The Nix layer builds the sandbox wrappers; the backend just executes them.

mod jail;

pub use jail::JailBackend;

use std::path::Path;

use anyhow::Result;
use async_trait::async_trait;

use crate::config::EnvironmentMeta;

/// Result of executing code in a sandbox.
#[derive(Debug, Clone)]
pub struct ExecutionResult {
    /// Exit code of the process (0 = success).
    pub exit_code: i32,
    /// Captured stdout.
    pub stdout: String,
    /// Captured stderr.
    pub stderr: String,
}

/// Trait for isolation backends.
///
/// Each backend knows how to execute code in a sandboxed environment.
/// The actual sandboxing is done by Nix-built wrappers; the backend
/// just handles process management and I/O.
#[async_trait]
pub trait IsolationBackend: Send + Sync {
    /// Execute code in the given environment.
    ///
    /// # Arguments
    /// * `env` - Environment metadata (exec path, timeout, etc.)
    /// * `code` - The code to execute
    /// * `project_dir` - Optional absolute path to mount as project directory
    /// * `project_mount` - Mount point inside sandbox (e.g., "/project")
    ///
    /// # Returns
    /// Execution result with stdout, stderr, and exit code.
    async fn execute(
        &self,
        env: &EnvironmentMeta,
        code: &str,
        project_dir: Option<&Path>,
        project_mount: &str,
    ) -> Result<ExecutionResult>;
}
