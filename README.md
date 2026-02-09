# nix-sandbox-mcp

Sandboxed code execution for LLMs, powered by Nix.

LLMs need to run code. Most solutions reach for Docker — heavyweight,
non-reproducible, and yet another daemon to manage. nix-sandbox-mcp uses Nix
instead: environments are declarative flake expressions, sandboxing is
[jail.nix](https://git.sr.ht/~alexdavid/jail.nix) (bubblewrap + Linux
namespaces, no root required), and a planned
[microvm.nix](https://github.com/astro/microvm.nix) backend adds full VM
isolation when you need it. Everything runs locally — no cloud, no containers,
no image pulls.

## Quick Start

[Nix with flakes](https://nixos.org/download/) on Linux. Add to your MCP client
config:

```json
{
  "mcpServers": {
    "nix-sandbox": {
      "command": "nix",
      "args": ["run", "github:secbear/nix-sandbox-mcp", "--", "--stdio"],
      "env": {
        "PROJECT_DIR": "/home/user/myproject"
      }
    }
  }
}
```

That's it. The LLM gets three sandboxed environments (shell, python, node) with
your project mounted read-only at `/project`. Drop `PROJECT_DIR` if you don't
need project access.

## Custom Environments

The bundled presets are a starting point. Define your own with a Nix flake:

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
      packages.x86_64-linux = {
        data-science = nix-sandbox-mcp.lib.mkSandbox {
          inherit pkgs;
          name = "data-science";
          interpreter_type = "python";
          packages = [
            (pkgs.python3.withPackages (ps: [ ps.numpy ps.pandas ps.requests ]))
          ];
        };

        nix-tools = nix-sandbox-mcp.lib.mkSandbox {
          inherit pkgs;
          name = "nix-tools";
          interpreter_type = "bash";
          packages = [ pkgs.ripgrep pkgs.fd pkgs.jq pkgs.yq-go pkgs.tree ];
        };
      };
    };
}
```

Point `NIX_SANDBOX_ENVS` at your flake refs. They're built at server startup and
merged with the bundled presets:

```json
{
  "mcpServers": {
    "nix-sandbox": {
      "command": "nix",
      "args": ["run", "github:secbear/nix-sandbox-mcp", "--", "--stdio"],
      "env": {
        "PROJECT_DIR": "/home/user/myproject",
        "NIX_SANDBOX_ENVS": "github:myorg/envs#data-science,github:myorg/envs#nix-tools"
      }
    }
  }
}
```

Now the LLM can use custom tools against your live codebase, fully sandboxed:

```bash
# env: "nix-tools"
rg "TODO" /project/src --type rust -c
# /project/src/main.rs:3
# /project/src/config.rs:1
```

```python
# env: "data-science"
import pandas as pd
df = pd.read_csv("/project/data/results.csv")
print(df.describe())
```

`interpreter_type` maps the sandbox to an agent REPL — `"python"`, `"bash"`, or
`"node"`. Pass a `session` ID to persist variables and imports across calls.

If you prefer pre-building over startup builds, `nix build` your sandbox into
`~/.config/nix-sandbox-mcp/sandboxes/` and skip `NIX_SANDBOX_ENVS` entirely. The
daemon scans that directory at startup.

## Configuration

All runtime settings are env vars in the MCP client JSON:

| Variable               | Purpose                                        | Default                               |
| ---------------------- | ---------------------------------------------- | ------------------------------------- |
| `PROJECT_DIR`          | Project directory to mount read-only           | _(none)_                              |
| `PROJECT_MOUNT`        | Mount point inside sandbox                     | `/project`                            |
| `NIX_SANDBOX_ENVS`     | Comma-separated flake refs to build at startup | _(none)_                              |
| `NIX_SANDBOX_DIR`      | Pre-built sandbox directory                    | `~/.config/nix-sandbox-mcp/sandboxes` |
| `SESSION_IDLE_TIMEOUT` | Idle timeout in seconds                        | `300`                                 |
| `SESSION_MAX_LIFETIME` | Max session lifetime in seconds                | `3600`                                |

Build-time settings (environment definitions, default timeouts) live in
[`config.example.toml`](config.example.toml) for customizing the bundled presets
or baking additional environments into the server at build time.

## Security

**jail.nix (namespace isolation)** — the current backend. Uses bubblewrap to
create unprivileged sandboxes with separate user, PID, network, and mount
namespaces plus seccomp-bpf syscall filtering. No network access by default.
Project files are mounted read-only. This protects against accidental damage and
opportunistic malicious code. It does _not_ protect against kernel exploits —
the sandbox shares the host kernel.

**microvm.nix (VM isolation)** — planned. Separate Linux kernel per sandbox via
KVM, virtiofs for store access, vsock for communication. Full isolation
including kernel attack surface. This is the right choice for running untrusted
code from the internet.

## Architecture

```
MCP Client
  │ JSON-RPC over stdio
  ▼
Shell wrapper
  │ builds NIX_SANDBOX_ENVS, execs daemon
  ▼
Rust daemon
  ├─ ephemeral ──▶ bubblewrap jail ──▶ interpreter
  └─ session   ──▶ bubblewrap jail ──▶ sandbox_agent.py ──▶ persistent REPL
```

The daemon handles MCP protocol and process dispatch. Nix handles everything
else — environment resolution, package composition, sandbox wrapper generation.
Environments come from three sources (bundled presets, `NIX_SANDBOX_ENVS`
startup builds, pre-built artifacts in `$NIX_SANDBOX_DIR`) and all produce the
same artifact format. The daemon doesn't know which source an environment came
from.

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, repo layout, and
internals.

## Roadmap

| Phase | Status  | What                                                   |
| ----- | ------- | ------------------------------------------------------ |
| 1     | Done    | jail.nix backend, bundled presets, MCP protocol        |
| 2a    | Done    | Project mounting, custom flake refs in config          |
| 2b    | Done    | Session persistence (Python, Bash, Node REPLs)         |
| 2c    | Done    | Decoupled sandboxes (`mkSandbox`, directory scanning)  |
| 2d    | Done    | MCP-conventional config (env vars, `NIX_SANDBOX_ENVS`) |
| 3     | Planned | microvm.nix backend for hardware-level isolation       |
| 3     | Planned | Dead interpreter recovery (restart bash/node on crash) |

## License

MIT
