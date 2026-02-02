//! Configuration loaded from Nix-generated metadata.
//!
//! The Nix wrapper passes environment metadata via the `NIX_SANDBOX_METADATA`
//! environment variable as JSON.

use std::collections::HashMap;

use anyhow::{Context, Result};
use serde::Deserialize;

/// Top-level configuration for the daemon.
#[derive(Debug, Clone)]
pub struct Config {
    /// Available execution environments, keyed by name.
    pub environments: HashMap<String, EnvironmentMeta>,
}

impl Config {
    /// Load configuration from the `NIX_SANDBOX_METADATA` environment variable.
    pub fn from_env() -> Result<Self> {
        let metadata_json = std::env::var("NIX_SANDBOX_METADATA")
            .context("NIX_SANDBOX_METADATA not set - are you running via the Nix wrapper?")?;

        let environments: HashMap<String, EnvironmentMeta> =
            serde_json::from_str(&metadata_json).context("Failed to parse NIX_SANDBOX_METADATA")?;

        Ok(Self { environments })
    }

    /// Create a config from a JSON string (for testing).
    #[cfg(test)]
    pub fn from_json(json: &str) -> Result<Self> {
        let environments: HashMap<String, EnvironmentMeta> =
            serde_json::from_str(json).context("Failed to parse JSON")?;
        Ok(Self { environments })
    }
}

/// Metadata for a single execution environment.
#[derive(Debug, Clone, Deserialize)]
pub struct EnvironmentMeta {
    /// Which backend to use ("jail" or "microvm").
    pub backend: BackendType,

    /// Path to the executable that runs code in this environment.
    /// For jail backend, this is the jail wrapper script.
    pub exec: String,

    /// Maximum execution time in seconds.
    #[serde(default = "default_timeout")]
    pub timeout_seconds: u64,

    /// Memory limit in megabytes.
    #[serde(default = "default_memory")]
    pub memory_mb: u64,
}

/// Available isolation backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BackendType {
    /// jail.nix backend (bubblewrap, namespace isolation).
    Jail,
    /// microvm.nix backend (hardware VM isolation).
    #[allow(dead_code)]
    Microvm,
}

const fn default_timeout() -> u64 {
    30
}

const fn default_memory() -> u64 {
    512
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_metadata_json() {
        let json = r#"{
            "python": {
                "backend": "jail",
                "exec": "/nix/store/xxx-python-sandbox/bin/run",
                "timeout_seconds": 30,
                "memory_mb": 512
            },
            "shell": {
                "backend": "jail",
                "exec": "/nix/store/yyy-shell-sandbox/bin/run"
            }
        }"#;

        let config = Config::from_json(json).unwrap();

        assert_eq!(config.environments.len(), 2);
        assert!(config.environments.contains_key("python"));
        assert!(config.environments.contains_key("shell"));

        let python = &config.environments["python"];
        assert_eq!(python.backend, BackendType::Jail);
        assert_eq!(python.timeout_seconds, 30);

        // Check defaults are applied
        let shell = &config.environments["shell"];
        assert_eq!(shell.timeout_seconds, 30);
        assert_eq!(shell.memory_mb, 512);
    }
}
