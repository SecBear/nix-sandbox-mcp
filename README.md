# nix-sandbox-mcp

A Nix-native MCP server for reproducible, sandboxed code execution.

**nix-sandbox-mcp** lets LLMs execute code in isolated environments defined by Nix. Unlike Docker-based alternatives, environments are reproducible, composable, and leverage the Nix store for efficient caching. Sandboxing is provided by [jail.nix](https://git.sr.ht/~alexdavid/jail.nix) (bubblewrap) with planned support for [microvm.nix](https://github.com/astro/microvm.nix) (hardware-isolated VMs).

## Why?

| Problem | nix-sandbox-mcp Solution |
|---------|--------------------------|
| Docker images are opaque blobs | Nix flakes define environments declaratively |
| "Works on my machine" | Reproducible builds via Nix |
| Shared kernel attack surface | jail.nix (namespaces) or microvm.nix (hardware isolation) |
| Slow cold starts | Pre-built Nix closures, optional pre-warming |
| Complex environment setup | Reference a flake, get exact packages |

## Features

- **Reproducible environments** — Defined via Nix flakes, bit-for-bit identical everywhere
- **Modular isolation backends** — jail.nix (fast, namespace-based) or microvm.nix (secure, VM-based)
- **Session persistence** — Stateful multi-turn workflows with `session` parameter
- **MCP protocol** — Works with Claude Desktop, any MCP client
- **Simple config** — TOML configuration, reference presets or your own flakes
- **Minimal Rust daemon** — Handles MCP protocol and process dispatch only; Nix does the heavy lifting

## Quick Start

```bash
# Run with bundled presets (shell, python, node)
nix run github:secbear/nix-sandbox-mcp

# Or build a configured instance
nix build github:secbear/nix-sandbox-mcp#default
```

Add to Claude Desktop (`~/.config/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "nix-sandbox": {
      "command": "nix",
      "args": ["run", "github:secbear/nix-sandbox-mcp"]
    }
  }
}
```

## Configuration

Create `config.toml`:

```toml
[daemon]
transport = "stdio"
log_level = "info"

[defaults]
backend = "jail"          # "jail" or "microvm"
timeout_seconds = 30
memory_mb = 512

# ─────────────────────────────────────────────────────────────
# Project (Optional)
# Mount your project directory into the sandbox (read-only)
# ─────────────────────────────────────────────────────────────

[project]
path = "."                # Project directory (default: current directory)
mount_point = "/project"  # Where to mount inside sandbox

# ─────────────────────────────────────────────────────────────
# Environments
# ─────────────────────────────────────────────────────────────

# Use bundled presets
[environments.shell]
preset = "shell"

[environments.python]
preset = "python"

[environments.node]
preset = "node"

# Reference your own flake (Phase 2a.3 - coming soon)
# [environments.dev]
# flake = "github:myorg/dev-envs#default"
```

Add custom environments by referencing any Nix flake in your config:

```toml
[environments.data-science]
flake = "github:myorg/envs#data-science"
interpreter = "python3 -c"
```

See [Custom Environments](#custom-environments) below for a full walkthrough.

## Bundled Presets

Three presets cover common use cases:

| Preset | Description | Packages |
|--------|-------------|----------|
| `shell` | Minimal Linux environment | bash, coreutils, grep, sed, awk, findutils, jq, tree, diffutils, file, bc |
| `python` | Python 3 with PyYAML | python3 (+pyyaml), coreutils |
| `node` | Node.js runtime | nodejs, coreutils |

Presets use the jail backend by default. Override with `backend = "microvm"` for stronger isolation.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         config.toml                             │
│   [environments.python]                                         │
│   preset = "python"                                             │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                │ nix eval
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                       Nix Build Layer                           │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │   Presets   │  │ User Flakes │  │    Backend Wrappers     │ │
│  │ shell.nix   │  │ (external)  │  │  jail.nix / microvm.nix │ │
│  │ python.nix  │  │             │  │                         │ │
│  │ node.nix    │  │             │  │                         │ │
│  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘ │
│         │                │                      │              │
│         └────────────────┴──────────────────────┘              │
│                          │                                      │
│                          ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  environments.json                        │  │
│  │  {                                                        │  │
│  │    "python": {                                            │  │
│  │      "backend": "jail",                                   │  │
│  │      "exec": "/nix/store/...-jailed-python/bin/run"      │  │
│  │    }                                                      │  │
│  │  }                                                        │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                │ NIX_SANDBOX_METADATA env var
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Rust Daemon                                │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  MCP Protocol    │  │  Backend Trait   │                    │
│  │  (JSON-RPC/stdio)│  │                  │                    │
│  │                  │  │  ┌────────────┐  │                    │
│  │  tools/list      │  │  │JailBackend │  │                    │
│  │  tools/call      │──▶  │  (exec)    │  │                    │
│  │                  │  │  └────────────┘  │                    │
│  │                  │  │  ┌────────────┐  │                    │
│  │                  │  │  │MicrovmBack │  │                    │
│  │                  │  │  │  (boot VM) │  │                    │
│  │                  │  │  └────────────┘  │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Design Principles

1. **Nix does the heavy lifting** — Environment resolution, package management, sandbox wrappers are all Nix
2. **Rust daemon is minimal** — Only MCP protocol handling and process dispatch
3. **TOML is the interface** — Users configure via TOML; it's evaluated by Nix
4. **Modular backends** — Trait-based backend abstraction allows jail.nix today, microvm.nix tomorrow

## Repository Structure

```
nix-sandbox-mcp/
│
├── flake.nix                      # Main entry point
├── flake.lock
├── config.example.toml            # Example configuration
├── README.md
├── LICENSE
│
├── agent/
│   └── sandbox_agent.py           # Persistent interpreter for sessions
│
├── nix/
│   ├── environments/              # Bundled preset definitions
│   │   ├── shell.nix              # Minimal shell environment
│   │   ├── python.nix             # Python 3 environment
│   │   ├── node.nix               # Node.js environment
│   │   └── default.nix            # Exports all presets
│   │
│   ├── backends/
│   │   ├── jail.nix               # jail.nix backend integration
│   │   └── microvm.nix            # microvm.nix backend (planned)
│   │
│   └── lib/
│       ├── mkSandbox.nix          # Build standalone sandbox artifacts
│       ├── mkEnvironment.nix      # env def + backend → built artifact
│       ├── fromToml.nix           # Parse TOML config, build all envs
│       └── mkMetadata.nix         # Generate environments.json
│
└── daemon/                        # Rust MCP server
    ├── Cargo.toml
    ├── Cargo.lock
    └── src/
        ├── main.rs                # Entry point, loads metadata
        ├── config.rs              # Parse environments.json
        ├── mcp.rs                 # MCP server, run tool handler
        ├── session.rs             # Session lifecycle management
        ├── backend.rs             # Backend trait + JailBackend
        └── transport/             # Agent IPC (length-prefixed JSON)
```

## Implementation Roadmap

### Phase 1: Core (jail.nix backend) ✅
- [x] Nix flake structure with preset environments
- [x] jail.nix integration for sandboxing
- [x] TOML config parsing in Nix
- [x] Minimal Rust daemon with MCP protocol
- [x] JailBackend implementation (fork + exec)
- [x] `tools/list` and `tools/call` handlers
- [x] Works with Claude Desktop

### Phase 2a: Project Context ✅
- [x] `run` tool with `command` + `environment` parameters
- [x] Project directory mounting (read-only at `/project`)
- [x] Dynamic tool description showing available environments
- [x] Timeout enforcement with clear error messages
- [ ] Custom flake references in config (coming soon)

### Phase 2b: Session Persistence ✅
- [x] Length-prefixed JSON IPC protocol
- [x] Persistent Python/Bash/Node interpreters
- [x] Session lifecycle management (idle timeout, cleanup)
- [x] Writable /workspace within sessions
- [x] `session` parameter on `run` tool

### Phase 2c: Decoupled Sandbox Architecture ✅
- [x] `mkSandbox` function for standalone sandbox artifacts
- [x] Directory scanning for custom sandboxes at startup
- [x] Runtime project mounting via `PROJECT_DIR` env var
- [x] `interpreter_type` field on environment metadata
- [x] Custom sandboxes override bundled presets on name collision

### Phase 3: MicroVM Backend (Planned)
- [ ] microvm.nix integration
- [ ] Hardware-level isolation for untrusted code
- [ ] virtiofs for /nix/store sharing

## Custom Environments

### Decoupled Sandboxes (Recommended)

Build standalone sandbox artifacts with `mkSandbox` — no server rebuild required.

#### Step 1: Create a flake with `mkSandbox`

```nix
# my-envs/flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-sandbox-mcp.url = "github:secbear/nix-sandbox-mcp";
  };

  outputs = { nixpkgs, nix-sandbox-mcp, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.data-science = nix-sandbox-mcp.lib.mkSandbox {
        inherit pkgs;
        name = "data-science";
        interpreter_type = "python";  # required: "python", "bash", or "node"
        packages = [
          (pkgs.python3.withPackages (ps: [ ps.numpy ps.pandas ps.requests ]))
        ];
        # timeout_seconds = 60;  # optional, default: 30
        # memory_mb = 1024;      # optional, default: 512
      };
    };
}
```

`interpreter_type` is **required** — it tells the session agent which interpreter to use:
- `"python"` — Python REPL (variables persist across calls)
- `"bash"` — Bash shell (environment persists across calls)
- `"node"` — Node.js REPL (variables persist across calls)

#### Step 2: Build and install into the sandbox directory

```bash
# Create the sandbox directory
mkdir -p ~/.config/nix-sandbox-mcp/sandboxes

# Build and symlink (local flake)
nix build path:./my-envs#data-science \
  -o ~/.config/nix-sandbox-mcp/sandboxes/data-science

# Or from a remote flake
nix build github:myorg/my-envs#data-science \
  -o ~/.config/nix-sandbox-mcp/sandboxes/data-science
```

#### Step 3: Restart the MCP server

Restart Claude Desktop (or your MCP client). The daemon scans the sandbox directory at startup — the new `data-science` environment will appear automatically.

#### Step 4: Use it

The environment is now available as `env: "data-science"` in the `run` tool. Claude can use it like any other environment:

```json
{"code": "import pandas as pd; print(pd.__version__)", "env": "data-science"}
```

Sessions work too — pass a `session` ID for persistent state across calls.

#### Notes

- **Project-agnostic**: The same sandbox artifact works for any project. The daemon passes the project directory at runtime via environment variables.
- **Override bundled presets**: If your custom sandbox has the same name as a bundled preset (e.g., `"python"`), the custom version takes priority.
- **Custom directory**: Override the sandbox directory with `$NIX_SANDBOX_DIR`. Default: `~/.config/nix-sandbox-mcp/sandboxes/`.
- **No hot-reload**: Adding or removing sandboxes requires restarting the MCP server.

### Config-Based Environments

You can also add custom environments by referencing any Nix flake in `config.toml`. This requires rebuilding the server:

```toml
[environments.data-science]
flake = "github:myorg/my-envs#default"   # or a local path: "path:./my-envs"
interpreter = "python3 -c"               # how to run code in this env
```

```bash
nix build  # Rebuild required
```

### Quick single-package environments

For simple cases, reference packages directly from nixpkgs:

```toml
[environments.jq-shell]
flake = "nixpkgs#jq"
interpreter = "bash -s"
```

## Security Model

### jail.nix (Namespace Isolation)
- Linux user namespaces (unprivileged)
- PID namespace (isolated process tree)
- Network namespace (no network by default)
- Mount namespace (read-only /nix/store, tmpfs home)
- seccomp-bpf syscall filtering

**Threat model**: Protects against accidental damage and basic malicious code. Does NOT protect against kernel exploits (shared kernel).

### microvm.nix (Hardware Isolation)
- Separate Linux kernel per sandbox
- Hardware virtualization (KVM)
- virtiofs for read-only /nix/store access
- vsock for host-guest communication

**Threat model**: Full VM isolation. Protects against kernel exploits. Recommended for untrusted code execution.

## Prior Art & Inspiration

- [sandbox-mcp](https://github.com/pottekkat/sandbox-mcp) — Docker-based MCP sandbox (Go)
- [code-sandbox-mcp](https://github.com/Automata-Labs-team/code-sandbox-mcp) — Docker-based code execution
- [@anthropic-ai/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) — Bubblewrap + seccomp for Claude Code
- [jail.nix](https://git.sr.ht/~alexdavid/jail.nix) — Nix library for bubblewrap sandboxing
- [microvm.nix](https://github.com/astro/microvm.nix) — NixOS microVMs

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, architecture overview, and development guidelines.

## License

MIT
