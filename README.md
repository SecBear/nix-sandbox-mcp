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

Use with your config:

```nix
# your-flake/flake.nix
{
  inputs.nix-sandbox-mcp.url = "github:secbear/nix-sandbox-mcp";

  outputs = { nix-sandbox-mcp, ... }: {
    packages.x86_64-linux.mcp-server = 
      nix-sandbox-mcp.lib.mkServer ./config.toml;
  };
}
```

## Bundled Presets

Three presets cover common use cases:

| Preset | Description | Packages |
|--------|-------------|----------|
| `shell` | Minimal Linux environment | coreutils, bash, grep, sed, awk, jq, curl |
| `python` | Python 3 with standard library | python3 |
| `node` | Node.js runtime | nodejs_22 |

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
├── nix/
│   ├── environments/              # Bundled preset definitions
│   │   ├── shell.nix              # Minimal shell environment
│   │   ├── python.nix             # Python 3 environment  
│   │   ├── node.nix               # Node.js environment
│   │   └── default.nix            # Exports all presets
│   │
│   ├── backends/
│   │   ├── jail.nix               # jail.nix backend integration
│   │   └── microvm.nix            # microvm.nix backend (future)
│   │
│   └── lib/
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
        ├── mcp/
        │   ├── mod.rs
        │   ├── protocol.rs        # JSON-RPC types
        │   └── handler.rs         # tools/list, tools/call
        └── backend/
            ├── mod.rs             # IsolationBackend trait
            ├── jail.rs            # Fork + exec jail wrapper
            └── microvm.rs         # VM boot + vsock (future)
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

### Phase 2b: Sessions (Planned)
- [ ] Session persistence via IPC
- [ ] Stateful sandbox interactions

### Phase 3: MicroVM Backend (Planned)
- [ ] microvm.nix integration
- [ ] Hardware-level isolation for untrusted code
- [ ] virtiofs for /nix/store sharing

## Environment Flake Contract

When referencing external flakes, they should export a package:

```nix
# github:myorg/envs/flake.nix
{
  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.default = pkgs.buildEnv {
        name = "my-env";
        paths = [
          pkgs.python311
          (pkgs.python311.withPackages (ps: [ ps.requests ps.numpy ]))
          pkgs.jq
          pkgs.ripgrep
        ];
      };
    };
}
```

The flake output is wrapped by the chosen backend (jail.nix or microvm.nix) automatically.

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

Contributions welcome. Please open an issue to discuss significant changes before submitting a PR.

## License

MIT
