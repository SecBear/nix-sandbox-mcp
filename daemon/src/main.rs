//! nix-sandbox-mcp daemon
//!
//! Minimal MCP server that dispatches code execution to Nix-built sandboxes.
//! Environment metadata is passed via `NIX_SANDBOX_METADATA` env var.

use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use tracing::info;
use tracing_subscriber::EnvFilter;

use nix_sandbox_mcp_daemon::{
    backend::JailBackend,
    config::Config,
    mcp,
    session::{SessionConfig, SessionManager},
};

#[derive(Parser, Debug)]
#[command(name = "nix-sandbox-mcp-daemon")]
#[command(about = "MCP server for Nix-based sandboxed code execution")]
struct Args {
    /// Run in stdio mode (for MCP clients)
    #[arg(long)]
    stdio: bool,

    /// Log level (trace, debug, info, warn, error)
    #[arg(long, default_value = "info")]
    log_level: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize logging (stderr so stdout is free for MCP protocol)
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&args.log_level)),
        )
        .with_writer(std::io::stderr)
        .init();

    // Load environment metadata from Nix wrapper
    let config = Config::from_env().context("Failed to load configuration")?;

    info!(
        environments = ?config.environments.keys().collect::<Vec<_>>(),
        "Loaded configuration"
    );

    // Initialize backend
    let backend = JailBackend::new();

    // Initialize session manager
    let session_config = config
        .session
        .as_ref()
        .map(SessionConfig::from_toml)
        .unwrap_or_default();
    let session_manager = Arc::new(SessionManager::new(session_config));

    if args.stdio {
        mcp::serve_stdio(config, backend, session_manager).await?;
    } else {
        anyhow::bail!("Only --stdio mode is currently supported");
    }

    Ok(())
}
