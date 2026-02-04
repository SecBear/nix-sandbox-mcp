# nix-sandbox-mcp Roadmap

## Design Principles

1. **Operator power, Claude simplicity** - Rich config for operators, minimal interface for Claude
2. **Context efficiency** - Claude's context is expensive; expose only what's needed for accuracy
3. **Nix-native** - Leverage Nix's reproducibility; build-time over runtime configuration
4. **Fast feedback loops** - Quick execution, actionable errors

## Current State

**Phase 2a** (Complete)
- `run(code, env)` tool interface
- Project directory mounting (read-only)
- Flake integration for custom environments
- Dynamic tool description listing available environments

## Planned Phases

### Phase 2b: Session Persistence

**Goal**: Enable multi-turn workflows where state persists across `run()` calls.

**Approach**: IPC agent pattern
- Long-running interpreter process inside jail
- Unix socket communication from daemon
- Session lifecycle management (idle timeout, cleanup)

**Enables**:
- Persistent Python/Node state (variables, imports)
- Writable `/workspace` that persists within session
- File retrieval from session workspace

**Plan**: `thoughts/shared/plans/2026-02-02-phase2b-sessions-spike.md`

### Phase 2c: Decoupled Sandbox Architecture

**Goal**: Allow operators to add custom sandboxes without rebuilding the server.

**Approach**: Sandbox artifacts
- Server ships with base environments (python, shell, node)
- Custom sandboxes are separate Nix derivations with standard structure
- Daemon loads additional sandboxes from paths in config at runtime
- `nix-sandbox-mcp.lib.mkSandbox` for building sandbox artifacts

**Key Design**:
- Operator complexity, Claude simplicity
- Claude interface unchanged: `{"code": "...", "env": "name"}`
- No context bloat - just env names exposed
- Backend-agnostic (works with jail now, microvm later)

**Config**:
```toml
# Built-in presets (bundled)
[environments.python]
preset = "python"

# Custom sandboxes (loaded at runtime)
[environments.python-data]
sandbox = "/nix/store/xxx-python-data"
```

**Plan**: `thoughts/shared/plans/2026-02-03-phase2c-decoupled-sandboxes.md`

### Phase 3: microVM Backend

**Goal**: Stronger isolation for untrusted code scenarios.

**Approach**: Cloud Hypervisor via microvm.nix
- Hardware-level isolation (KVM)
- Pause/resume/snapshot capabilities
- Shared read-only `/nix/store` via virtiofs

**Use cases**:
- Running untrusted user code
- Production deployments with stricter security requirements

### Phase 4+: Future

- **macOS support** - Seatbelt or Virtualization.framework
- **GPU passthrough** - For ML workloads
- **Remote/HTTP transport** - Run sandbox on remote machine
- **Network allowlists** - Fine-grained network control (specific domains)

## Deferred Ideas

Features considered but deferred for simplicity:

### Declarative Package Lists

```toml
# DEFERRED - not implementing now
[environments.data-science]
preset = "python"
packages = ["numpy", "pandas", "matplotlib"]
```

**Why deferred**:
- Adds complexity to the Nix layer
- Phase 2c provides a better solution via `mkSandbox`
- `python.withPackages` pattern works well

**Solution (Phase 2c)**: Create a sandbox with `mkSandbox`:
```nix
# my-sandboxes/flake.nix
{
  inputs.nix-sandbox-mcp.url = "github:owner/nix-sandbox-mcp";

  outputs = { nixpkgs, nix-sandbox-mcp, ... }: {
    packages.x86_64-linux.data-science = nix-sandbox-mcp.lib.mkSandbox {
      name = "data-science";
      packages = [ (pkgs.python3.withPackages (ps: [ ps.numpy ps.pandas ])) ];
      interpreter = "python3 -c";
    };
  };
}
```
Then in config: `sandbox = "/path/to/result"`

### Per-Environment Network Control

```toml
# Future consideration
[environments.api-testing]
preset = "python"
network = true
```

**Status**: Can be added to `mkSandbox` options in Phase 2c. Currently all environments have network disabled for security. Network-enabled sandboxes would be opt-in at the sandbox definition level, not runtime.

### Rich Sandbox Spec for Claude

Exposing detailed metadata (packages, limits, capabilities) to Claude.

**Why deferred**:
- Bloats context, degrades performance
- Claude doesn't need to know internals
- Current minimal interface (`code` + `env`) is sufficient

**Principle**: Operator configures complexity, Claude sees simplicity.

## References

- Phase 1 plan: `thoughts/shared/plans/2026-02-01-phase1-mvp-nix-layer.md`
- Phase 2a plan: `thoughts/shared/plans/2026-02-02-phase2a-run-tool-and-project-context.md`
- Phase 2b plan: `thoughts/shared/plans/2026-02-02-phase2b-sessions-spike.md`
- Phase 2c plan: `thoughts/shared/plans/2026-02-03-phase2c-decoupled-sandboxes.md`
- Claude's ideal sandbox feedback: See git history for context
