# nix-sandbox-mcp Roadmap

## Design Principles

1. **Operator power, Claude simplicity** - Rich config for operators, minimal interface for Claude
2. **Context efficiency** - Claude's context is expensive; expose only what's needed for accuracy
3. **Nix-native** - Leverage Nix's reproducibility; build-time over runtime configuration
4. **Fast feedback loops** - Quick execution, actionable errors

## Current State

**Phase 2c** (Complete)
- Decoupled sandbox architecture: custom sandboxes without server rebuild
- `mkSandbox` function for building standalone sandbox artifacts
- Directory scanning at startup (`~/.config/nix-sandbox-mcp/sandboxes/`)
- Runtime project mounting via `PROJECT_DIR` env var
- All Phase 2b features (sessions, IPC protocol, lifecycle management)

## Completed Phases

### Phase 2b: Session Persistence ✅

**Implemented**: IPC agent pattern with length-prefixed JSON protocol.

- Long-running interpreter process inside jail (`sandbox_agent.py`)
- Stdin/stdout pipe transport from daemon (not Unix socket — simpler)
- Per-session Mutex for arrival-order request serialization
- Session lifecycle: idle timeout (300s), max lifetime (3600s), reaper (60s)
- Python: shared namespace via `exec()`
- Bash: persistent subprocess with nonce markers
- Node: custom REPL (no prompt, no echo, let/const persistence)
- Lazy interpreter instantiation within sessions

### Phase 2c: Decoupled Sandbox Architecture ✅

**Implemented**: Standalone sandbox artifacts loaded at startup.

- `lib.mkSandbox` function: `{ pkgs, name, interpreter_type, packages }` → derivation with `metadata.json` + `bin/run` + `bin/session-run`
- Daemon scans `~/.config/nix-sandbox-mcp/sandboxes/` (or `$NIX_SANDBOX_DIR`) at startup
- Custom sandboxes override bundled presets on name collision
- Runtime project mounting via `PROJECT_DIR`/`PROJECT_MOUNT` env vars
- `interpreter_type` field on `EnvironmentMeta` — explicit mapping to agent interpreters
- Sandbox artifacts are project-agnostic (build once, use everywhere)
- `runtimeProjectMount` flag on jail.nix's `mkJailedEnv`/`mkSessionJailedEnv` — uses `c.add-runtime` for dynamic project binding

## Planned Phases

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

