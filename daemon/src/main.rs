//! nix-sandbox-mcp daemon
//!
//! Minimal MCP server that dispatches code execution to Nix-built sandboxes.
//! Environment metadata is passed via `NIX_SANDBOX_METADATA` env var.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use tracing::{debug, info};
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

/// Get a path from an environment variable, falling back to root.
fn dirs_or_default(var: &str) -> PathBuf {
    std::env::var(var)
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/"))
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
    let mut config = Config::from_env().context("Failed to load configuration")?;

    // Scan for custom sandbox artifacts
    let sandbox_dir = std::env::var("NIX_SANDBOX_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            dirs_or_default("HOME")
                .join(".config/nix-sandbox-mcp/sandboxes")
        });

    if sandbox_dir.is_dir() {
        let extra = Config::scan_sandbox_dir(&sandbox_dir);
        if !extra.is_empty() {
            info!(count = extra.len(), dir = %sandbox_dir.display(), "Discovered custom sandboxes");
            config.merge_environments(extra);
        }
    } else {
        debug!(dir = %sandbox_dir.display(), "Sandbox directory does not exist, skipping scan");
    }

    info!(
        environments = ?config.environments.keys().collect::<Vec<_>>(),
        "Loaded configuration"
    );

    // Initialize backend
    let backend = JailBackend::new();

    // Initialize session manager (TOML config takes priority, then env vars)
    let session_config = config
        .session
        .as_ref()
        .map(SessionConfig::from_toml)
        .unwrap_or_else(SessionConfig::from_env);
    let session_manager = Arc::new(SessionManager::new(session_config));

    if args.stdio {
        mcp::serve_stdio(config, backend, session_manager).await?;
    } else {
        anyhow::bail!("Only --stdio mode is currently supported");
    }

    Ok(())
}
