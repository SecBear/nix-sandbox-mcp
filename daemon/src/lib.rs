//! nix-sandbox-mcp daemon library
//!
//! This crate provides the core functionality for the nix-sandbox-mcp daemon:
//! - Configuration parsing from Nix-generated metadata
//! - MCP server implementation using rmcp
//! - Backend trait and implementations for sandboxed execution

pub mod backend;
pub mod config;
pub mod mcp;
pub mod session;
pub mod transport;
