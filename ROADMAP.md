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
- Operators can already create custom flakes with any packages
- `python.withPackages` pattern works today via flake references

**Workaround**: Create a custom flake with desired packages:
```nix
# my-env/flake.nix
{
  outputs = { nixpkgs, ... }: {
    packages.x86_64-linux.default =
      nixpkgs.legacyPackages.x86_64-linux.python3.withPackages (ps: [
        ps.numpy ps.pandas ps.matplotlib
      ]);
  };
}
```
Then reference: `flake = "/path/to/my-env"`

### Per-Environment Network Control

```toml
# Future consideration
[environments.api-testing]
preset = "python"
network = true
```

**Status**: May add in Phase 2c or 3. Currently all environments have network disabled for security.

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
- Claude's ideal sandbox feedback: See git history for context
