---
date: 2026-02-01T12:00:00-08:00
researcher: Claude
git_commit: initial (no commits yet)
branch: main
repository: nix-sandbox-mcp
topic: "Architecture Review and Implementation Roadmap for nix-sandbox-mcp"
tags: [research, codebase, mcp, nix, sandboxing, jail-nix, microvm, architecture]
status: complete
last_updated: 2026-02-01
last_updated_by: Claude
---

# Research: Architecture Review and Implementation Roadmap for nix-sandbox-mcp

**Date**: 2026-02-01T12:00:00-08:00
**Researcher**: Claude
**Git Commit**: initial (no commits yet)
**Branch**: main
**Repository**: nix-sandbox-mcp

## Research Question

Review current progress on nix-sandbox-mcp, identify remaining work, and provide architectural recommendations for a modular backend approach supporting jail.nix and microvm.nix.

## Summary

The project has a solid foundation with:
- Well-designed Rust daemon using rmcp with proper MCP protocol implementation
- Clean TOML-based configuration model
- Backend trait abstraction ready for multiple implementations
- Comprehensive documentation and architecture diagrams

**Current Status**: ~40% complete (Rust daemon structure done, Nix layer not yet implemented)

**Critical Missing Pieces**:
1. Nix library layer (`nix/environments/`, `nix/backends/`, `nix/lib/`)
2. jail.nix integration for actual sandboxing
3. TOML parsing in Nix with `fromToml.nix`

**Key Recommendations**:
1. Simplify the single `execute` tool approach - it's correct
2. Add language-specific convenience tools for discoverability
3. Implement jail.nix backend first, then microvm.nix
4. Consider bubblewrap-based approach for development iteration

## Detailed Findings

### Current Implementation Status

#### Completed (Rust Daemon)

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| Config parsing | `daemon/src/config.rs:1-111` | Complete | Parses `NIX_SANDBOX_METADATA` JSON |
| Backend trait | `daemon/src/backend.rs:1-43` | Complete | `IsolationBackend` trait with `execute()` |
| Jail backend | `daemon/src/backend/jail.rs:1-99` | Complete | Fork+exec with timeout |
| MCP server | `daemon/src/mcp.rs:1-214` | Complete | Uses rmcp with tool_router macro |
| Main entry | `daemon/src/main.rs:1-56` | Complete | CLI args, logging setup |

**MCP Tool Design** (`daemon/src/mcp.rs:29-38`):
```rust
pub struct ExecuteParams {
    pub environment: String,  // e.g., "python", "shell", "node"
    pub code: String,
}
```

This single-tool approach is good - aligns with best practices for code execution MCPs.

#### Not Yet Implemented (Nix Layer)

| Component | Planned Location | Status | Priority |
|-----------|------------------|--------|----------|
| Preset environments | `nix/environments/*.nix` | Not created | High |
| jail.nix backend | `nix/backends/jail.nix` | Not created | High |
| microvm.nix backend | `nix/backends/microvm.nix` | Not created | Medium |
| TOML parser | `nix/lib/fromToml.nix` | Not created | High |
| Env builder | `nix/lib/mkEnvironment.nix` | Not created | High |
| Metadata gen | `nix/lib/mkMetadata.nix` | Not created | High |

### Architecture Analysis

#### Current Design Strengths

1. **Clean separation of concerns**:
   - TOML config → Nix evaluation → JSON metadata → Rust daemon
   - Rust handles MCP protocol only; Nix handles environment definition

2. **Correct backend abstraction** (`daemon/src/backend.rs:31-42`):
   ```rust
   #[async_trait]
   pub trait IsolationBackend: Send + Sync {
       async fn execute(&self, env: &EnvironmentMeta, code: &str) -> Result<ExecutionResult>;
   }
   ```

3. **Flexible configuration** (`config.example.toml`):
   - Supports presets, custom flakes, per-environment overrides
   - Backend-specific options (hypervisor choice for microvm)

4. **Using rmcp correctly** (`daemon/src/mcp.rs:40-49`):
   - Proper `#[tool_router]` and `#[tool_handler]` usage
   - Single execute tool with environment parameter

#### Architecture Concerns

1. **flake.nix references non-existent Nix files** (`flake.nix:54-60`):
   ```nix
   presets = if isLinux then import ./nix/environments { inherit pkgs; } else { };
   mkServer = configPath:
     let
       built = import ./nix/lib/fromToml.nix {
         inherit pkgs jail presets;
       } configPath;
   ```
   These files don't exist yet.

2. **No actual sandboxing implemented**: `JailBackend` just calls `Command::new(&env.exec)` - relies on Nix wrapper providing the jail.

3. **Missing microvm backend module**: `daemon/src/backend/` only has `jail.rs`, no `microvm.rs`.

### jail.nix Integration Pattern

Based on jail.nix documentation, here's the recommended integration:

```nix
# nix/backends/jail.nix
{ pkgs, jail }:

{
  # Wrap an environment package in a jail
  mkJailedEnv = { name, env, networkAccess ? false, extraPerms ? [] }:
    jail name "${env}/bin/run" (c: [
      # Base: fake /proc, /dev, tmpfs home, coreutils
      c.base

      # Read-only Nix store access (only runtime closure)
      c.bind-nix-store-runtime-closure

      # Writable workspace for code execution
      (c.tmpfs "/workspace")
      (c.set-env "HOME" "/workspace")

      # Network access if needed
    ] ++ (if networkAccess then [ c.network ] else [])
      ++ extraPerms
    );
}
```

**Key jail.nix combinators for code execution**:
- `c.base` - Minimal setup (coreutils, bash, fake filesystem)
- `c.bind-nix-store-runtime-closure` - Only expose needed packages
- `c.tmpfs "/path"` - Ephemeral writable directories
- `c.network` - Optional network access
- `c.add-pkg-deps [ pkg1 pkg2 ]` - Add packages to PATH
- `c.set-env "VAR" "value"` - Environment variables

### microvm.nix Integration Pattern

For stronger isolation, microvm.nix provides full VM separation:

```nix
# nix/backends/microvm.nix
{ pkgs, microvm }:

{
  mkMicrovmEnv = { name, packages, vcpu ? 2, mem ? 1024 }:
    microvm.nixosModules.microvm {
      networking.hostName = name;

      microvm = {
        hypervisor = "cloud-hypervisor";  # Fast, Rust-based
        vcpu = vcpu;
        mem = mem;

        # Share /nix/store read-only via virtiofs
        shares = [{
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }];

        # vsock for host-guest communication
        vsock.cid = 3;  # Unique per VM
      };

      environment.systemPackages = packages;
    };
}
```

**Hypervisor recommendations**:
| Hypervisor | Boot Time | Security | virtiofs | Recommendation |
|------------|-----------|----------|----------|----------------|
| cloud-hypervisor | ~200ms | High (Rust) | Yes | Default choice |
| firecracker | ~125ms | Highest | No | For ephemeral, no sharing |
| qemu | ~400ms | Standard | Yes | Development/debugging |

### Recommended Implementation Order

#### Phase 1: Minimal Working System (Priority: High)

1. **Create preset environments** (`nix/environments/`):
   ```nix
   # nix/environments/python.nix
   { pkgs }:
   pkgs.buildEnv {
     name = "sandbox-python";
     paths = [ pkgs.python3 pkgs.coreutils ];
   }
   ```

2. **Create jail.nix wrapper** (`nix/backends/jail.nix`):
   - Wrap environment with bubblewrap sandbox
   - Generate executable at `/bin/run` that reads code from stdin

3. **Create TOML parser** (`nix/lib/fromToml.nix`):
   - Parse config, resolve presets/flakes
   - Build all environments, generate metadata JSON

4. **Test end-to-end**:
   ```bash
   nix build .#default
   echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./result/bin/nix-sandbox-mcp
   ```

#### Phase 2: Polish and Features

5. **Add custom flake support** in `fromToml.nix`
6. **Implement timeout enforcement** via cgroups in jail wrapper
7. **Add resource limits** (memory, CPU)
8. **Better error messages** with structured error types

#### Phase 3: microvm.nix Backend

9. **Add microvm.nix input** to flake (currently commented out)
10. **Create MicrovmBackend** in Rust (`daemon/src/backend/microvm.rs`):
    - Boot VM, communicate via vsock
    - Handle virtiofs for /nix/store sharing
11. **Guest agent** (Rust binary in VM) for code execution
12. **Add `backend = "microvm"` config support**

### Architectural Recommendations

#### 1. Keep the Single Execute Tool

The current design with one `execute` tool accepting `environment` + `code` is correct. This aligns with MCP best practices:
- Fewer tools = less context consumption
- Clear mental model for AI
- Easy to extend environments without code changes

**Optional enhancement**: Add language-specific aliases for discoverability:
```rust
#[tool(description = "Execute Python code (alias for execute with environment='python')")]
async fn python(&self, code: String) -> Result<CallToolResult, McpError> {
    self.execute(ExecuteParams { environment: "python".into(), code }).await
}
```

#### 2. Simplify the Nix Wrapper Script

Instead of complex Nix evaluation at build time, consider:

```nix
# The jail wrapper script (written by Nix, executed by Rust)
pkgs.writeShellScript "run-python" ''
  # This script runs inside bubblewrap
  exec python3 - <<'EOF'
  $(cat)
  EOF
''
```

The Rust daemon passes code via stdin, captures stdout/stderr.

#### 3. Add Backend Selection Logic

Extend `EnvironmentMeta` to include more backend-specific config:

```rust
#[derive(Debug, Clone, Deserialize)]
pub struct EnvironmentMeta {
    pub backend: BackendType,
    pub exec: String,
    pub timeout_seconds: u64,
    pub memory_mb: u64,

    // Backend-specific
    #[serde(default)]
    pub jail_config: Option<JailConfig>,
    #[serde(default)]
    pub microvm_config: Option<MicrovmConfig>,
}
```

#### 4. Consider Development vs Production Modes

For faster iteration during development:
- **Dev mode**: Use bubblewrap directly without full Nix build
- **Prod mode**: Full Nix-built jail wrappers

```toml
[daemon]
mode = "development"  # Skip Nix wrapper, use bwrap directly
```

#### 5. File Handling for Code Execution

The current design reads code from stdin. Consider also supporting:
- File paths within the sandbox
- Multiple files (for projects)
- Working directory specification

```rust
pub struct ExecuteParams {
    pub environment: String,
    pub code: Option<String>,       // Code via parameter
    pub files: Option<Vec<File>>,   // Multiple files
    pub entrypoint: Option<String>, // Which file to run
}
```

### Security Considerations

#### jail.nix Security Model

- **Namespace isolation**: PID, mount, network, user namespaces
- **Seccomp**: Syscall filtering (can add custom filters)
- **Read-only filesystem**: Only tmpfs writable areas
- **No network by default**: Must explicitly grant

**Limitation**: Shared kernel - not protected against kernel exploits.

#### microvm.nix Security Model

- **Full VM isolation**: Separate kernel per sandbox
- **KVM-based**: Hardware virtualization
- **virtiofs**: Read-only /nix/store sharing

**Recommended for**: Untrusted code, production deployments.

### Missing Functionality Checklist

- [ ] `nix/environments/shell.nix` - Minimal shell preset
- [ ] `nix/environments/python.nix` - Python 3 preset
- [ ] `nix/environments/node.nix` - Node.js preset
- [ ] `nix/environments/default.nix` - Export all presets
- [ ] `nix/backends/jail.nix` - jail.nix integration
- [ ] `nix/backends/microvm.nix` - microvm.nix integration (Phase 3)
- [ ] `nix/lib/mkEnvironment.nix` - Environment builder
- [ ] `nix/lib/fromToml.nix` - TOML config parser
- [ ] `nix/lib/mkMetadata.nix` - Metadata JSON generator
- [ ] `daemon/src/backend/microvm.rs` - MicrovmBackend (Phase 3)
- [ ] End-to-end integration tests
- [ ] Claude Desktop integration test

## Code References

- `daemon/src/config.rs:40-56` - EnvironmentMeta struct definition
- `daemon/src/backend.rs:31-42` - IsolationBackend trait
- `daemon/src/backend/jail.rs:32-71` - JailBackend execute implementation
- `daemon/src/mcp.rs:40-49` - SandboxServer with tool_router
- `daemon/src/mcp.rs:52-98` - Execute tool implementation
- `flake.nix:54-71` - mkServer function (references unimplemented Nix)
- `config.example.toml:17-32` - Environment configuration examples

## Architecture Insights

### Design Patterns Observed

1. **Configuration-as-Code**: TOML config evaluated by Nix, not runtime parsing
2. **Trait-based abstraction**: IsolationBackend trait for multiple backends
3. **Nix-first philosophy**: Rust daemon is thin; Nix handles environment definition
4. **MCP best practices**: Single consolidated execute tool

### External Dependencies

| Dependency | Purpose | Version/Source |
|------------|---------|----------------|
| rmcp | MCP protocol | 0.14 (crates.io) |
| jail-nix | Bubblewrap sandboxing | sourcehut:~alexdavid/jail.nix |
| microvm.nix | VM isolation | github:astro/microvm.nix (planned) |
| flake-parts | Flake structure | github:hercules-ci/flake-parts |
| fenix | Rust toolchain | github:nix-community/fenix |

## Related Research

- [jail.nix Documentation](https://alexdav.id/projects/jail-nix/)
- [microvm.nix Documentation](https://microvm-nix.github.io/microvm.nix/)
- [sandbox-mcp](https://github.com/pottekkat/sandbox-mcp) - Docker-based reference
- [rmcp Examples](https://github.com/modelcontextprotocol/rust-sdk/tree/main/examples/servers)

## Open Questions

1. **Multi-file execution**: Should environments support project directories, or just single-file execution?

2. **Persistent state**: Should some environments maintain state between executions (e.g., installed packages)?

3. **Resource monitoring**: Should the daemon report resource usage (memory, CPU time) in execution results?

4. **Pre-warming**: Is sandbox pre-warming necessary for acceptable latency?

5. **macOS support**: The README mentions macOS but bubblewrap/microvm are Linux-only. Clarify the macOS story (remote execution? native sandboxing?).
