//! MCP server implementation using rmcp.
//!
//! Exposes sandboxed execution environments as MCP tools.

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

/// MCP server for sandboxed code execution.
#[derive(Clone)]
pub struct SandboxServer<B: Clone> {
    config: Arc<Config>,
    backend: Arc<B>,
    tool_router: ToolRouter<Self>,
}

/// Parameters for the run tool.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct RunParams {
    /// The command to run in the sandbox.
    #[schemars(description = "The command to run in the sandbox")]
    pub command: String,

    /// The execution environment to use (e.g., "python", "shell", "node").
    /// Required - choose based on what tools the command needs.
    #[schemars(description = "Execution environment (required): python, node, shell, or custom")]
    pub environment: String,
}

#[tool_router]
impl<B: IsolationBackend + Clone + Send + Sync + 'static> SandboxServer<B> {
    /// Create a new sandbox server.
    pub fn new(config: Config, backend: B) -> Self {
        Self {
            config: Arc::new(config),
            backend: Arc::new(backend),
            tool_router: Self::tool_router(),
        }
    }

    /// Run a command in the specified sandbox environment.
    #[tool(description = "Run a command in an isolated Nix sandbox")]
    async fn run(
        &self,
        Parameters(params): Parameters<RunParams>,
    ) -> Result<CallToolResult, McpError> {
        let env_name = &params.environment;
        let command = &params.command;

        // Look up environment
        let env = self.config.environments.get(env_name).ok_or_else(|| {
            let available: Vec<_> = self.config.environments.keys().collect();
            McpError::invalid_params(
                format!("Unknown environment: '{env_name}'. Available: {available:?}"),
                None,
            )
        })?;

        info!(environment = %env_name, command_len = command.len(), "Running command");

        // Execute in sandbox
        match self.backend.execute(env, command).await {
            Ok(result) => {
                let is_error = result.exit_code != 0;

                // Combine stdout/stderr
                let output = if result.stderr.is_empty() {
                    result.stdout
                } else if result.stdout.is_empty() {
                    result.stderr
                } else {
                    format!("{}\n--- stderr ---\n{}", result.stdout, result.stderr)
                };

                if is_error {
                    Ok(CallToolResult::error(vec![Content::text(output)]))
                } else {
                    Ok(CallToolResult::success(vec![Content::text(output)]))
                }
            }
            Err(e) => {
                error!(error = %e, "Execution failed");
                Ok(CallToolResult::error(vec![Content::text(format!(
                    "Execution error: {e}"
                ))]))
            }
        }
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
             - command: the command to run\n\
             - environment: one of the available environments (required)\n\
             \n\
             Choose the environment based on what tools your command needs."
        );

        // Add project info if configured
        if let Some(project) = &self.config.project {
            desc.push_str(&format!(
                "\n\nProject directory mounted at {} (read-only).",
                project.mount_point
            ));

            if project.use_flake {
                desc.push_str("\nProject's devShell available as 'project' environment.");
            }
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
pub async fn serve_stdio<B: IsolationBackend + Clone + Send + Sync + 'static>(
    config: Config,
    backend: B,
) -> anyhow::Result<()> {
    let server = SandboxServer::new(config, backend);

    info!("Starting MCP server on stdio");

    let service = server
        .serve(stdio())
        .await
        .map_err(|e| anyhow::anyhow!("Failed to start MCP server: {e}"))?;

    service
        .waiting()
        .await
        .map_err(|e| anyhow::anyhow!("MCP server error: {e}"))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::ExecutionResult;
    use crate::config::{BackendType, EnvironmentMeta};
    use async_trait::async_trait;
    use std::collections::HashMap;

    #[derive(Clone)]
    struct MockBackend;

    #[async_trait]
    impl IsolationBackend for MockBackend {
        async fn execute(
            &self,
            _env: &EnvironmentMeta,
            command: &str,
        ) -> anyhow::Result<ExecutionResult> {
            Ok(ExecutionResult {
                exit_code: 0,
                stdout: format!("executed: {command}"),
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
                timeout_seconds: 30,
                memory_mb: 512,
            },
        );
        Config {
            environments,
            project: None,
        }
    }

    #[tokio::test]
    async fn test_run_success() {
        let server = SandboxServer::new(test_config(), MockBackend);
        let params = Parameters(RunParams {
            command: "echo hello".to_string(),
            environment: "test".to_string(),
        });

        let result = server.run(params).await.unwrap();
        assert!(!result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn test_run_unknown_env() {
        let server = SandboxServer::new(test_config(), MockBackend);
        let params = Parameters(RunParams {
            command: "echo hello".to_string(),
            environment: "unknown".to_string(),
        });

        let result = server.run(params).await;
        assert!(result.is_err());
    }
}
