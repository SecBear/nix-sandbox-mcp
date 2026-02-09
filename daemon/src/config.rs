//! Configuration loaded from Nix-generated metadata.
//!
//! The Nix wrapper passes environment metadata via the `NIX_SANDBOX_METADATA`
//! environment variable as JSON.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;
use tracing::{debug, info, warn};

/// Top-level configuration for the daemon.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Available execution environments, keyed by name.
    pub environments: HashMap<String, EnvironmentMeta>,

    /// Project configuration (optional).
    #[serde(default)]
    pub project: Option<ProjectConfig>,

    /// Session persistence configuration (optional).
    #[serde(default)]
    pub session: Option<SessionConfigToml>,
}

/// Session persistence configuration (as read from TOML/JSON).
#[derive(Debug, Clone, Deserialize)]
pub struct SessionConfigToml {
    /// Idle timeout in seconds before a session is reaped.
    #[serde(default = "default_idle_timeout")]
    pub idle_timeout_seconds: u64,

    /// Maximum session lifetime in seconds, regardless of activity.
    #[serde(default = "default_max_lifetime")]
    pub max_lifetime_seconds: u64,
}

/// Project directory configuration.
/// Note: Project is always mounted read-only for security and reproducibility.
/// Use Claude's Edit tool for file modifications.
#[derive(Debug, Clone, Deserialize)]
pub struct ProjectConfig {
    /// Path to the project directory.
    #[serde(default = "default_project_path")]
    pub path: PathBuf,

    /// Mount point inside the sandbox.
    #[serde(default = "default_mount_point")]
    pub mount_point: String,

    /// Whether to use the project's flake.nix devShell.
    #[serde(default)]
    pub use_flake: bool,

    /// Environment variables to inherit from the host.
    #[serde(default)]
    pub inherit_env: InheritEnv,
}

/// Environment variables to inherit into the sandbox.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct InheritEnv {
    /// List of environment variable names to pass through.
    #[serde(default)]
    pub vars: Vec<String>,
}

fn default_project_path() -> PathBuf {
    ".".into()
}

fn default_mount_point() -> String {
    "/project".into()
}

impl Config {
    /// Load configuration from the `NIX_SANDBOX_METADATA` environment variable.
    pub fn from_env() -> Result<Self> {
        let metadata_json = std::env::var("NIX_SANDBOX_METADATA")
            .context("NIX_SANDBOX_METADATA not set - are you running via the Nix wrapper?")?;

        let config: Self =
            serde_json::from_str(&metadata_json).context("Failed to parse NIX_SANDBOX_METADATA")?;

        Ok(config)
    }

    /// Resolve the project directory to an absolute path.
    ///
    /// Priority: `PROJECT_DIR` env var > TOML `[project]` config.
    pub fn resolved_project_dir(&self) -> Option<PathBuf> {
        // Env var takes priority (MCP-conventional configuration)
        if let Ok(dir) = std::env::var("PROJECT_DIR") {
            let path = PathBuf::from(&dir);
            if path.is_dir() {
                return Some(path);
            }
        }
        // Fall back to TOML config
        self.project.as_ref().map(|p| {
            if p.path.is_absolute() {
                p.path.clone()
            } else {
                std::env::current_dir().unwrap_or_default().join(&p.path)
            }
        })
    }

    /// Get the project mount point inside the sandbox.
    ///
    /// Priority: `PROJECT_MOUNT` env var > TOML config > default `/project`.
    pub fn project_mount(&self) -> String {
        std::env::var("PROJECT_MOUNT").unwrap_or_else(|_| {
            self.project
                .as_ref()
                .map(|p| p.mount_point.clone())
                .unwrap_or_else(|| "/project".into())
        })
    }

    /// Scan a directory for sandbox artifacts and return discovered environments.
    ///
    /// Each subdirectory should contain:
    /// - `metadata.json` with name, interpreter_type, timeout_seconds, memory_mb
    /// - `bin/run` — ephemeral execution wrapper
    /// - `bin/session-run` (optional) — session execution wrapper
    ///
    /// Invalid entries are logged and skipped.
    pub fn scan_sandbox_dir(dir: &Path) -> HashMap<String, EnvironmentMeta> {
        let mut envs = HashMap::new();

        let entries = match std::fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(e) => {
                debug!(path = %dir.display(), error = %e, "Cannot read sandbox directory");
                return envs;
            }
        };

        for entry in entries {
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    warn!(error = %e, "Error reading sandbox directory entry");
                    continue;
                }
            };

            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            // Parse metadata.json
            let meta_path = path.join("metadata.json");
            let meta_str = match std::fs::read_to_string(&meta_path) {
                Ok(s) => s,
                Err(e) => {
                    warn!(path = %meta_path.display(), error = %e, "Skipping sandbox: cannot read metadata.json");
                    continue;
                }
            };

            let artifact_meta: SandboxArtifactMeta = match serde_json::from_str(&meta_str) {
                Ok(m) => m,
                Err(e) => {
                    warn!(path = %meta_path.display(), error = %e, "Skipping sandbox: invalid metadata.json");
                    continue;
                }
            };

            // Verify bin/run exists
            let run_path = path.join("bin/run");
            if !run_path.exists() {
                warn!(sandbox = %artifact_meta.name, path = %run_path.display(), "Skipping sandbox: bin/run not found");
                continue;
            }

            // Check for optional bin/session-run
            let session_run_path = path.join("bin/session-run");
            let session_exec = if session_run_path.exists() {
                Some(session_run_path.to_string_lossy().into_owned())
            } else {
                None
            };

            let env_meta = EnvironmentMeta {
                backend: BackendType::Jail,
                exec: run_path.to_string_lossy().into_owned(),
                session_exec,
                timeout_seconds: artifact_meta.timeout_seconds,
                memory_mb: artifact_meta.memory_mb,
                interpreter_type: Some(artifact_meta.interpreter_type),
            };

            info!(name = %artifact_meta.name, path = %path.display(), "Discovered sandbox");
            envs.insert(artifact_meta.name, env_meta);
        }

        envs
    }

    /// Merge discovered sandbox environments into the config.
    ///
    /// Custom sandboxes override bundled presets on name collision (with info log).
    pub fn merge_environments(&mut self, extra: HashMap<String, EnvironmentMeta>) {
        for (name, meta) in extra {
            if self.environments.contains_key(&name) {
                info!(name = %name, "Custom sandbox overrides bundled environment");
            }
            self.environments.insert(name, meta);
        }
    }

    /// Create a config from a JSON string (for testing).
    #[cfg(test)]
    pub fn from_json(json: &str) -> Result<Self> {
        let config: Self = serde_json::from_str(json).context("Failed to parse JSON")?;
        Ok(config)
    }
}

/// Metadata parsed from a sandbox artifact's `metadata.json`.
#[derive(Debug, Deserialize)]
struct SandboxArtifactMeta {
    name: String,
    interpreter_type: String,
    #[serde(default = "default_timeout")]
    timeout_seconds: u64,
    #[serde(default = "default_memory")]
    memory_mb: u64,
}

/// Metadata for a single execution environment.
#[derive(Debug, Clone, Deserialize)]
pub struct EnvironmentMeta {
    /// Which backend to use ("jail" or "microvm").
    pub backend: BackendType,

    /// Path to the executable that runs code in this environment (ephemeral).
    /// For jail backend, this is the jail wrapper script.
    pub exec: String,

    /// Path to the session jail wrapper (runs the persistent agent).
    /// If absent, sessions are not supported for this environment.
    #[serde(default)]
    pub session_exec: Option<String>,

    /// Maximum execution time in seconds.
    #[serde(default = "default_timeout")]
    pub timeout_seconds: u64,

    /// Memory limit in megabytes.
    #[serde(default = "default_memory")]
    pub memory_mb: u64,

    /// Interpreter type for this environment (e.g., "python", "bash", "node").
    /// Used to map custom sandbox environments to the correct agent interpreter.
    /// If None, falls back to name-based matching for bundled presets.
    #[serde(default)]
    pub interpreter_type: Option<String>,
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

const fn default_idle_timeout() -> u64 {
    300
}

const fn default_max_lifetime() -> u64 {
    3600
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_metadata_json() {
        let json = r#"{
            "environments": {
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

        // interpreter_type defaults to None when not in JSON
        assert!(python.interpreter_type.is_none());

        // No project config
        assert!(config.project.is_none());
    }

    #[test]
    fn parse_metadata_with_interpreter_type() {
        let json = r#"{
            "environments": {
                "data-science": {
                    "backend": "jail",
                    "exec": "/nix/store/xxx/bin/run",
                    "interpreter_type": "python"
                }
            }
        }"#;

        let config = Config::from_json(json).unwrap();
        let ds = &config.environments["data-science"];
        assert_eq!(ds.interpreter_type.as_deref(), Some("python"));
    }

    #[test]
    fn scan_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let envs = Config::scan_sandbox_dir(dir.path());
        assert!(envs.is_empty());
    }

    #[test]
    fn scan_nonexistent_dir() {
        let envs = Config::scan_sandbox_dir(std::path::Path::new("/nonexistent/path"));
        assert!(envs.is_empty());
    }

    #[test]
    fn scan_valid_sandbox() {
        let dir = tempfile::tempdir().unwrap();
        let sandbox = dir.path().join("data-science");
        std::fs::create_dir_all(sandbox.join("bin")).unwrap();

        // Write metadata.json
        std::fs::write(
            sandbox.join("metadata.json"),
            r#"{"name": "data-science", "interpreter_type": "python", "timeout_seconds": 60, "memory_mb": 1024}"#,
        ).unwrap();

        // Create bin/run (just needs to exist)
        std::fs::write(sandbox.join("bin/run"), "#!/bin/sh\n").unwrap();

        let envs = Config::scan_sandbox_dir(dir.path());
        assert_eq!(envs.len(), 1);
        assert!(envs.contains_key("data-science"));

        let meta = &envs["data-science"];
        assert_eq!(meta.interpreter_type.as_deref(), Some("python"));
        assert_eq!(meta.timeout_seconds, 60);
        assert_eq!(meta.memory_mb, 1024);
        assert!(meta.exec.ends_with("bin/run"));
        assert!(meta.session_exec.is_none());
    }

    #[test]
    fn scan_sandbox_with_session() {
        let dir = tempfile::tempdir().unwrap();
        let sandbox = dir.path().join("my-env");
        std::fs::create_dir_all(sandbox.join("bin")).unwrap();

        std::fs::write(
            sandbox.join("metadata.json"),
            r#"{"name": "my-env", "interpreter_type": "bash"}"#,
        )
        .unwrap();
        std::fs::write(sandbox.join("bin/run"), "#!/bin/sh\n").unwrap();
        std::fs::write(sandbox.join("bin/session-run"), "#!/bin/sh\n").unwrap();

        let envs = Config::scan_sandbox_dir(dir.path());
        let meta = &envs["my-env"];
        assert!(meta.session_exec.is_some());
    }

    #[test]
    fn scan_skips_missing_bin_run() {
        let dir = tempfile::tempdir().unwrap();
        let sandbox = dir.path().join("broken");
        std::fs::create_dir_all(&sandbox).unwrap();

        std::fs::write(
            sandbox.join("metadata.json"),
            r#"{"name": "broken", "interpreter_type": "python"}"#,
        )
        .unwrap();
        // No bin/run — should be skipped

        let envs = Config::scan_sandbox_dir(dir.path());
        assert!(envs.is_empty());
    }

    // Validate custom sandboxes override bundled presets on name collision.
    // Create a Config with a "python" environment, merge in another "python"
    // from scanning, and assert the merged version wins.
    #[test]
    fn merge_environments_override() {
        let json = r#"{
            "environments": {
                "python": {
                    "backend": "jail",
                    "exec": "/nix/store/xxx-python-sandbox/bin/run",
                    "timeout_seconds": 30,
                    "memory_mb": 512
                }
            }
        }"#;

        // create a Config with a bundled "python" environment,
        let mut config = Config::from_json(json).unwrap();

        // then call merge_environments() with a HashMap containing a different "python" entry (e.g., different exec path)
        let env_meta = EnvironmentMeta {
            backend: BackendType::Jail,
            exec: String::from("/custom/bin/run"),
            interpreter_type: Some("python".to_string()),
            session_exec: Some("/some/path".to_string()),
            timeout_seconds: 30,
            memory_mb: 512,
        };
        let envs = HashMap::from([(String::from("python"), env_meta)]);

        // and assert the merged version wins.
        config.merge_environments(envs);
        assert_eq!(config.environments["python"].exec, "/custom/bin/run");
    }

    #[test]
    fn merge_environments_additive() {
        // merge in "ruby" alongside "python" override, assert config now has both
        let json = r#"{
            "environments": {
                "python": {
                    "backend": "jail",
                    "exec": "/nix/store/xxx-python-sandbox/bin/run",
                    "timeout_seconds": 30,
                    "memory_mb": 512
                }
            }
        }"#;

        let mut config = Config::from_json(json).unwrap();

        let env_meta_python = EnvironmentMeta {
            backend: BackendType::Jail,
            exec: String::from("/custom/bin/run"),
            interpreter_type: Some("python".to_string()),
            session_exec: Some("/some/path".to_string()),
            timeout_seconds: 30,
            memory_mb: 512,
        };

        let env_meta_ruby = EnvironmentMeta {
            backend: BackendType::Jail,
            exec: String::from("/custom-ruby/bin/run"),
            interpreter_type: Some("bash".to_string()),
            session_exec: Some("/some/other/path".to_string()),
            timeout_seconds: 30,
            memory_mb: 512,
        };
        let envs = HashMap::from([
            (String::from("python"), env_meta_python),
            (String::from("ruby"), env_meta_ruby),
        ]);

        config.merge_environments(envs);
        assert_eq!(config.environments["python"].exec, "/custom/bin/run");
        assert_eq!(config.environments["ruby"].exec, "/custom-ruby/bin/run");
    }

    #[test]
    fn resolved_project_dir_from_config() {
        let json = r#"{
            "environments": {},
            "project": {
                "path": "/home/user/myproject",
                "mount_point": "/project"
            }
        }"#;
        let config = Config::from_json(json).unwrap();
        // Falls back to config when PROJECT_DIR is not set
        assert_eq!(
            config.resolved_project_dir(),
            Some(PathBuf::from("/home/user/myproject"))
        );
    }

    #[test]
    fn resolved_project_dir_none_without_config() {
        let json = r#"{"environments": {}}"#;
        let config = Config::from_json(json).unwrap();
        assert!(config.resolved_project_dir().is_none());
    }

    #[test]
    fn project_mount_from_config() {
        let json = r#"{
            "environments": {},
            "project": {
                "path": "/tmp",
                "mount_point": "/custom-mount"
            }
        }"#;
        let config = Config::from_json(json).unwrap();
        // Falls back to config mount_point when PROJECT_MOUNT is not set
        assert_eq!(config.project_mount(), "/custom-mount");
    }

    #[test]
    fn project_mount_default() {
        let json = r#"{"environments": {}}"#;
        let config = Config::from_json(json).unwrap();
        assert_eq!(config.project_mount(), "/project");
    }

    #[test]
    fn parse_metadata_with_project() {
        let json = r#"{
            "environments": {
                "shell": {
                    "backend": "jail",
                    "exec": "/nix/store/yyy-shell-sandbox/bin/run"
                }
            },
            "project": {
                "path": "/home/user/myproject",
                "mount_point": "/project",
                "use_flake": true,
                "inherit_env": {
                    "vars": ["DATABASE_URL", "RUST_LOG"]
                }
            }
        }"#;

        let config = Config::from_json(json).unwrap();

        let project = config.project.as_ref().expect("project should be set");
        assert_eq!(project.path, PathBuf::from("/home/user/myproject"));
        assert_eq!(project.mount_point, "/project");
        assert!(project.use_flake);
        assert_eq!(project.inherit_env.vars, vec!["DATABASE_URL", "RUST_LOG"]);
    }
}
