//! MCP server implementation using rmcp.
//!
//! Exposes sandboxed execution environments as MCP tools.
//! Routes to either ephemeral execution (`IsolationBackend`) or
//! persistent sessions (`SessionManager`) based on the `session` parameter.

use std::sync::Arc;

use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, Content, Implementation, ServerCapabilities, ServerInfo};
use rmcp::schemars;
use rmcp::transport::stdio;
use rmcp::{tool, tool_handler, tool_router, ErrorData as McpError, ServerHandler, ServiceExt};
use schemars::JsonSchema;
use serde::Deserialize;
use tracing::{error, info};

use crate::backend::IsolationBackend;
use crate::config::Config;
use crate::session::SessionManager;

/// MCP server for sandboxed code execution.
#[derive(Clone)]
pub struct SandboxServer<B: Clone> {
    config: Arc<Config>,
    backend: Arc<B>,
    session_manager: Arc<SessionManager>,
    tool_router: ToolRouter<Self>,
}

/// Parameters for the run tool.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct RunParams {
    /// The code to run in the sandbox.
    #[schemars(description = "The code to run in the sandbox")]
    pub code: String,

    /// Execution environment (required): python, node, shell, or custom.
    #[schemars(description = "Execution environment (required): python, node, shell, or custom")]
    pub env: String,

    /// Optional session ID for persistent state across calls.
    /// When provided, interpreter state (variables, imports, files in /workspace)
    /// persists between calls with the same session ID.
    /// Sessions are bound to their creation environment.
    #[serde(default)]
    #[schemars(
        description = "Optional session ID for persistent state across calls. When provided, variables and /workspace files persist between calls with the same session ID. Each session is bound to its creation environment."
    )]
    pub session: Option<String>,
}

/// Maximum output size returned to the MCP client (1 MB).
const MAX_OUTPUT_SIZE: usize = 1024 * 1024;

/// Truncate a string to a byte-safe limit, appending a marker if truncated.
fn truncate_output(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    // Find a char boundary at or before max_bytes
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n\n[truncated — output exceeded 1MB]", &s[..end])
}

/// Format an execution result into an MCP `CallToolResult`.
fn format_result(exit_code: i32, stdout: String, stderr: String) -> CallToolResult {
    let is_error = exit_code != 0;

    let output = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{stdout}\n--- stderr ---\n{stderr}")
    };

    let output = truncate_output(&output, MAX_OUTPUT_SIZE);

    if is_error {
        CallToolResult::error(vec![Content::text(output)])
    } else {
        CallToolResult::success(vec![Content::text(output)])
    }
}

#[tool_router]
impl<B: IsolationBackend + Clone + Send + Sync + 'static> SandboxServer<B> {
    /// Create a new sandbox server.
    pub fn new(config: Config, backend: B, session_manager: Arc<SessionManager>) -> Self {
        Self {
            config: Arc::new(config),
            backend: Arc::new(backend),
            session_manager,
            tool_router: Self::tool_router(),
        }
    }

    /// Run code in the specified sandbox environment.
    #[tool(description = "Run code in an isolated Nix sandbox")]
    async fn run(
        &self,
        Parameters(params): Parameters<RunParams>,
    ) -> Result<CallToolResult, McpError> {
        let env_name = &params.env;
        let code = &params.code;

        // Look up environment
        let env_meta = self.config.environments.get(env_name).ok_or_else(|| {
            let available: Vec<_> = self.config.environments.keys().collect();
            McpError::invalid_params(
                format!("Unknown environment: '{env_name}'. Available: {available:?}"),
                None,
            )
        })?;

        info!(
            env = %env_name,
            code_len = code.len(),
            session = ?params.session,
            "Running code"
        );

        // Resolve project dir for runtime mounting
        let project_dir = self.config.resolved_project_dir();
        let project_mount = self.config.project_mount();

        // Dispatch: session → SessionManager, no session → ephemeral backend
        let result = if let Some(ref session_id) = params.session {
            self.session_manager
                .execute(
                    session_id,
                    env_name,
                    env_meta,
                    code,
                    project_dir.as_deref(),
                    &project_mount,
                )
                .await
        } else {
            self.backend
                .execute(env_meta, code, project_dir.as_deref(), &project_mount)
                .await
        };

        Ok(match result {
            Ok(exec_result) => format_result(
                exec_result.exit_code,
                exec_result.stdout,
                exec_result.stderr,
            ),
            Err(e) => {
                error!(error = %e, "Execution failed");
                CallToolResult::error(vec![Content::text(format!("Execution error: {e}"))])
            }
        })
    }
}

#[tool_handler]
impl<B: IsolationBackend + Clone + Send + Sync + 'static> ServerHandler for SandboxServer<B> {
    fn get_info(&self) -> ServerInfo {
        let envs: Vec<_> = self.config.environments.keys().collect();

        // Build environment descriptions
        let env_list = envs
            .iter()
            .map(|e| format!("- {e}"))
            .collect::<Vec<_>>()
            .join("\n");

        // Build base description
        let mut desc = format!(
            "Run commands in isolated Nix sandbox environments.\n\
             \n\
             Available environments:\n\
             {env_list}\n\
             \n\
             Use the 'run' tool with:\n\
             - code: the code to run\n\
             - env: one of the available environments (required)\n\
             \n\
             Choose the environment based on what tools your code needs."
        );

        // Add session info
        desc.push_str(
            "\n\nFor persistent state across calls, pass a `session` ID. \
             Variables, imports, and /workspace files persist within a session. \
             Each session is bound to its creation environment.",
        );

        // Add project info if configured (env var or TOML)
        if self.config.resolved_project_dir().is_some() {
            desc.push_str(&format!(
                "\n\nProject directory mounted at {} (read-only).",
                self.config.project_mount()
            ));
        }

        ServerInfo {
            protocol_version: rmcp::model::ProtocolVersion::V_2024_11_05,
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "nix-sandbox-mcp".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                title: None,
                icons: None,
                website_url: None,
            },
            instructions: Some(desc),
        }
    }
}

/// Serve the sandbox server over stdio.
///
/// Starts the session reaper, serves MCP, then cleans up all sessions on disconnect.
pub async fn serve_stdio<B: IsolationBackend + Clone + Send + Sync + 'static>(
    config: Config,
    backend: B,
    session_manager: Arc<SessionManager>,
) -> anyhow::Result<()> {
    // Start background reaper
    let reaper_handle = session_manager.start_reaper();

    let server = SandboxServer::new(config, backend, Arc::clone(&session_manager));

    info!("Starting MCP server on stdio");

    let service = server
        .serve(stdio())
        .await
        .map_err(|e| anyhow::anyhow!("Failed to start MCP server: {e}"))?;

    service
        .waiting()
        .await
        .map_err(|e| anyhow::anyhow!("MCP server error: {e}"))?;

    // MCP client disconnected — clean up
    info!("MCP client disconnected, cleaning up sessions");
    reaper_handle.abort();
    session_manager.destroy_all().await;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::ExecutionResult;
    use crate::config::{BackendType, EnvironmentMeta};
    use crate::session::SessionConfig;
    use async_trait::async_trait;
    use std::collections::HashMap;

    #[derive(Clone)]
    struct MockBackend;

    #[async_trait]
    impl IsolationBackend for MockBackend {
        async fn execute(
            &self,
            _env: &EnvironmentMeta,
            code: &str,
            _project_dir: Option<&std::path::Path>,
            _project_mount: &str,
        ) -> anyhow::Result<ExecutionResult> {
            Ok(ExecutionResult {
                exit_code: 0,
                stdout: format!("executed: {code}"),
                stderr: String::new(),
            })
        }
    }

    fn test_config() -> Config {
        let mut environments = HashMap::new();
        environments.insert(
            "test".to_string(),
            EnvironmentMeta {
                backend: BackendType::Jail,
                exec: "/bin/test".to_string(),
                session_exec: None,
                timeout_seconds: 30,
                memory_mb: 512,
                interpreter_type: None,
            },
        );
        Config {
            environments,
            project: None,
            session: None,
        }
    }

    fn test_session_manager() -> Arc<SessionManager> {
        Arc::new(SessionManager::new(SessionConfig::default()))
    }

    #[tokio::test]
    async fn test_run_success() {
        let server = SandboxServer::new(test_config(), MockBackend, test_session_manager());
        let params = Parameters(RunParams {
            code: "echo hello".to_string(),
            env: "test".to_string(),
            session: None,
        });

        let result = server.run(params).await.unwrap();
        assert!(!result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn test_run_unknown_env() {
        let server = SandboxServer::new(test_config(), MockBackend, test_session_manager());
        let params = Parameters(RunParams {
            code: "echo hello".to_string(),
            env: "unknown".to_string(),
            session: None,
        });

        let result = server.run(params).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_session_without_session_exec() {
        let server = SandboxServer::new(test_config(), MockBackend, test_session_manager());
        let params = Parameters(RunParams {
            code: "x = 42".to_string(),
            env: "test".to_string(),
            session: Some("mysession".to_string()),
        });

        // Should fail because test env has no session_exec
        let result = server.run(params).await.unwrap();
        assert!(result.is_error.unwrap_or(false));
    }
}
