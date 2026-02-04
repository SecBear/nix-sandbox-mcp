# Phase 2c: Decoupled Sandbox Architecture

## Overview

Decouple sandbox definitions from the MCP server, allowing operators to add custom sandboxes without rebuilding the server. The server ships with base environments (python, shell, node) and loads additional sandboxes from paths specified in config.

**Goal**: Operator ergonomics without any Claude interface changes.

## Design Principles

1. **Operator power, Claude simplicity** - Operators configure sandboxes; Claude just sees env names
2. **No context bloat** - Claude's interface unchanged: `{"code": "...", "env": "name"}`
3. **Nix-native** - Sandboxes are flake outputs with standard structure
4. **Incremental** - Base presets still bundled; custom sandboxes are additive
5. **Backend-agnostic** - Sandbox artifacts work with jail (now) and microvm (future)

## Current State

```toml
# All environments require server rebuild
[environments.python]
preset = "python"

[environments.custom]
flake = "github:org/repo#pkg"  # Still baked into server at build time
```

## Desired End State

```toml
# Built-in presets (bundled with server)
[environments.python]
preset = "python"

[environments.shell]
preset = "shell"

[environments.node]
preset = "node"

# Custom sandboxes (loaded at runtime, no rebuild)
[environments.python-data]
sandbox = "/nix/store/xxx-python-data"

[environments.portal-repo]
sandbox = "github:myorg/portal#sandbox"
```

Claude sees: `Available environments: python, shell, node, python-data, portal-repo`

---

## Sandbox Artifact Structure

A sandbox is a Nix derivation with a standard layout:

```
/nix/store/xxx-sandbox-python-data/
  bin/run           # Backend-specific executable (reads code from stdin)
  metadata.json     # Self-describing metadata
```

### metadata.json Schema

```json
{
  "name": "python-data",
  "backend": "jail",
  "interpreter": "python3 -c",
  "stdin_mode": "arg",
  "timeout_seconds": 30,
  "memory_mb": 512,
  "description": "Python 3.11 with numpy, pandas, matplotlib"
}
```

**Required fields:**
- `name` - Environment name (for validation)
- `backend` - "jail" (bubblewrap) or "microvm" (future: cloud-hypervisor)

**Optional fields (with defaults):**
- `interpreter` - For display/debugging (default: inferred)
- `stdin_mode` - "arg" or "pipe" (default: "arg")
- `timeout_seconds` - Default timeout (default: 30)
- `memory_mb` - Default memory limit (default: 512)
- `description` - Human-readable description (default: null)

**Backend-specific fields (future):**
- `microvm.vcpus` - CPU count for microvm backend
- `microvm.kernel` - Custom kernel path
- `microvm.rootfs` - Root filesystem image

---

## Implementation

### 2c.1: Sandbox Artifact Builder

**File:** `nix/lib/mkSandbox.nix`

```nix
# Build a standalone sandbox artifact
{ pkgs, backends }:

{
  name,
  packages,
  interpreter ? "bash -s",
  stdinMode ? null,  # Auto-detect from interpreter
  backend ? "jail",  # "jail" or "microvm" (future)
  timeout_seconds ? 30,
  memory_mb ? 512,
  description ? null,
  # Advanced options
  projectMount ? "/project",
  inheritVars ? [],
  # Backend-specific options
  backendOptions ? {},
}:

let
  # Select backend implementation
  backendImpl = backends.${backend} or (throw "Unknown backend: ${backend}");

  # Build the wrapped executable using selected backend
  wrapped = backendImpl.mkEnvironment {
    inherit name packages interpreter stdinMode projectMount inheritVars;
  } // backendOptions;

  # Auto-detect stdin mode from interpreter flags
  effectiveStdinMode = if stdinMode != null then stdinMode
    else if builtins.match ".*-[ce]$" interpreter != null then "arg"
    else "pipe";

  metadata = {
    inherit name backend interpreter timeout_seconds memory_mb;
    stdin_mode = effectiveStdinMode;
  } // (if description != null then { inherit description; } else {});

  metadataFile = pkgs.writeText "metadata.json" (builtins.toJSON metadata);
in
pkgs.runCommand "sandbox-${name}" { } ''
  mkdir -p $out/bin
  ln -s ${wrapped}/bin/run $out/bin/run
  cp ${metadataFile} $out/metadata.json
''
```

### 2c.2: Backend Abstraction

**File:** `nix/backends/default.nix`

```nix
{ pkgs, jail, microvm ? null }:

{
  jail = import ./jail.nix { inherit pkgs jail; };

  # Future: microvm backend
  # microvm = import ./microvm.nix { inherit pkgs microvm; };
}
```

**File:** `nix/backends/jail.nix` (update interface)

```nix
{ pkgs, jail }:

{
  # Unified interface for all backends
  mkEnvironment = {
    name,
    packages,
    interpreter,
    stdinMode,
    projectMount,
    inheritVars,
  }:
    # ... existing mkJailedEnv logic ...
    # Returns derivation with bin/run
}
```

### 2c.3: Expose mkSandbox in Flake

**File:** `flake.nix`

Add to outputs:
```nix
lib = {
  mkSandbox = import ./nix/lib/mkSandbox.nix {
    inherit pkgs;
    backends = import ./nix/backends { inherit pkgs jail; };
  };
};
```

Usage in external flake:
```nix
# my-sandboxes/flake.nix
{
  inputs.nix-sandbox-mcp.url = "github:owner/nix-sandbox-mcp";

  outputs = { self, nixpkgs, nix-sandbox-mcp, ... }: {
    packages.x86_64-linux.python-data = nix-sandbox-mcp.lib.mkSandbox {
      name = "python-data";
      packages = with nixpkgs.legacyPackages.x86_64-linux; [
        (python3.withPackages (ps: [ ps.numpy ps.pandas ps.matplotlib ]))
      ];
      interpreter = "python3 -c";
      backend = "jail";  # or "microvm" in the future
      description = "Python with data science libraries";
    };
  };
}
```

### 2c.4: Update Config Schema

**File:** `daemon/src/config.rs`

```rust
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum EnvironmentSource {
    /// Built-in preset
    Preset { preset: String },
    /// External sandbox artifact path
    Sandbox { sandbox: String },
    /// Flake reference (built at config load time - existing behavior)
    Flake { flake: String, interpreter: Option<String> },
}

#[derive(Debug, Clone, Deserialize)]
pub struct EnvironmentConfig {
    #[serde(flatten)]
    pub source: EnvironmentSource,

    // Optional overrides
    pub timeout_seconds: Option<u64>,
    pub memory_mb: Option<u64>,
}
```

### 2c.5: Load Sandboxes at Runtime

**File:** `daemon/src/config.rs`

```rust
impl Config {
    pub fn from_env() -> Result<Self> {
        // Load base config with presets (from NIX_SANDBOX_METADATA)
        let mut config = Self::load_base_metadata()?;

        // Load additional config file if present
        if let Ok(config_path) = std::env::var("NIX_SANDBOX_CONFIG") {
            let extra = Self::load_config_file(&config_path)?;
            config.merge_environments(extra)?;
        }

        Ok(config)
    }

    fn load_sandbox_from_path(path: &str) -> Result<EnvironmentMeta> {
        let metadata_path = Path::new(path).join("metadata.json");
        let metadata: SandboxMetadata = serde_json::from_reader(
            File::open(&metadata_path)
                .with_context(|| format!("Cannot open {}", metadata_path.display()))?
        )?;

        Ok(EnvironmentMeta {
            backend: metadata.backend.parse()?,
            exec: Path::new(path).join("bin/run").to_string_lossy().into(),
            timeout_seconds: metadata.timeout_seconds,
            memory_mb: metadata.memory_mb,
        })
    }
}
```

### 2c.6: Update Flake Wrapper

**File:** `flake.nix`

The server wrapper now:
1. Bundles base presets (python, shell, node)
2. Reads additional sandboxes from config at runtime

```nix
mkServer = configPath:
  let
    # Build base presets only
    baseEnvs = import ./nix/lib/baseEnvironments.nix {
      inherit pkgs jail presets;
    };
  in
  pkgs.writeShellApplication {
    name = "nix-sandbox-mcp";
    runtimeInputs = [ daemon ] ++ baseEnvs.drvs;
    text = ''
      export NIX_SANDBOX_METADATA='${baseEnvs.metadataJson}'
      export NIX_SANDBOX_CONFIG='${configPath}'
      exec nix-sandbox-mcp-daemon "$@"
    '';
  };
```

---

## Usage Examples

### Operator: Create Custom Sandbox

```bash
# Create a sandbox flake
mkdir python-data && cd python-data
cat > flake.nix << 'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-sandbox-mcp.url = "github:owner/nix-sandbox-mcp";
  };

  outputs = { nixpkgs, nix-sandbox-mcp, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.default = nix-sandbox-mcp.lib.mkSandbox {
        name = "python-data";
        packages = [ (pkgs.python3.withPackages (ps: [ ps.numpy ps.pandas ])) ];
        interpreter = "python3 -c";
        backend = "jail";  # Explicit backend selection
      };
    };
}
EOF

# Build it
nix build
ls result/
# bin/run  metadata.json
```

### Operator: Register with Server

```toml
# config.toml
[environments.python-data]
sandbox = "/path/to/python-data/result"
# Or use Nix store path directly:
# sandbox = "/nix/store/xxx-sandbox-python-data"
```

### Claude: Use It

```json
{"code": "import pandas as pd; print(pd.__version__)", "env": "python-data"}
```

---

## Testing

### Automated

```bash
# Build a test sandbox
nix build .#testSandbox

# Verify structure
test -x ./result/bin/run
test -f ./result/metadata.json
jq .name ./result/metadata.json  # Should output sandbox name

# Test execution
echo 'print("hello")' | ./result/bin/run

# Integration test: server loads external sandbox
./test-local.sh  # Add test for external sandbox loading
```

### Manual

- [ ] Create custom sandbox with mkSandbox
- [ ] Add to config via `sandbox = "path"`
- [ ] Server discovers and lists it
- [ ] Claude can use `env: "custom-name"`
- [ ] Existing presets still work

---

## Migration

**Non-breaking change.** Existing configs continue to work:
- `preset = "python"` → Still works (bundled)
- `flake = "..."` → Still works (built at server build time)

New option:
- `sandbox = "path"` → Loaded at runtime

---

## Success Criteria

1. **Sandbox artifact**: `nix build` produces `bin/run` + `metadata.json`
2. **mkSandbox API**: External flakes can use `nix-sandbox-mcp.lib.mkSandbox`
3. **Runtime loading**: Daemon loads sandboxes from paths in config
4. **No rebuild**: Adding sandbox to config doesn't require server rebuild
5. **Claude unchanged**: Interface still `{"code": "...", "env": "name"}`
6. **Backend-agnostic**: Artifact structure works for jail and future microvm

---

## Future Considerations

- **Flake ref resolution**: `sandbox = "github:org/repo#sandbox"` built on first use
- **Sandbox registry**: Directory scanning (`/etc/nix-sandbox-mcp/sandboxes/`)
- **Hot reload**: Daemon reloads config on SIGHUP
- **Validation**: Check sandbox artifact structure at load time
- **microvm backend**: Same artifact interface, different isolation

---

## File Summary

| File | Action | Description |
|------|--------|-------------|
| `nix/lib/mkSandbox.nix` | Create | Sandbox artifact builder (backend-agnostic) |
| `nix/backends/default.nix` | Modify | Export unified backend interface |
| `nix/backends/jail.nix` | Modify | Implement `mkEnvironment` interface |
| `flake.nix` | Modify | Export `lib.mkSandbox`, update `mkServer` |
| `daemon/src/config.rs` | Modify | Add `sandbox` source type, runtime loading |
| `config.example.toml` | Modify | Document `sandbox = "path"` option |
| `nix/tests/default.nix` | Modify | Add external sandbox test |
