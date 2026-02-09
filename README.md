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

**Requirements:** Linux with [Nix (flakes enabled)](https://nixos.org/download/).
The sandbox uses bubblewrap + Linux namespaces for isolation — macOS and Windows
are not supported. WSL2 may work if your kernel has user namespaces enabled.

Add to your MCP client config:

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
namespaces. No network access by default.
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

## Design: Context Budget

MCP servers pay a token tax: every tool schema is injected into the LLM's
context window at connection time. A server exposing 60 tools can burn ~47k
tokens before the user says anything. This matters because context is finite
and expensive — tokens spent on tool definitions are tokens unavailable for
reasoning.

**Common approaches and their costs:**

| Approach | Init cost | Trade-off |
| --- | --- | --- |
| Static loading (all tools upfront) | ~150 tokens × N tools | Context bloat scales linearly with tool count |
| Dynamic discovery (list → schema → call) | ~400 tokens fixed | Extra round-trips per invocation; LLM must learn discovery protocol |
| Skill/guide documents (SKILL.md) | ~800 tokens on activation | Rich guidance but heavy; separate document to maintain |

**Our approach: one parameterized tool.**

nix-sandbox-mcp exposes a single `run` tool that takes an `env` parameter.
Adding environments (python, node, shell, custom flakes) doesn't add tools —
it adds a value to a parameter. The fixed context cost is ~420 tokens
regardless of how many environments are configured:

| Component | Tokens | What it contains |
| --- | --- | --- |
| Tool schema | ~75 | Name, params (`code`, `env`, `session`), selection guidance |
| Server instructions | ~160 | Environment list, session workflow, debugging hints |
| Per-parameter descriptions | ~80 | Field-level usage hints via JSON Schema |
| **Total** | **~420** | Constant — does not grow with environment count |

Compare: if each environment were a separate tool (3 bundled + 5 custom = 8
tools), that would cost ~1,200+ tokens and grow with every environment added.

**Where guidance lives:**

Rather than a separate guidance document, tool-selection and workflow hints are
embedded directly in the MCP protocol fields that LLMs already read:

- **Tool description** — when to use the sandbox vs built-in shell (isolation,
  reproducibility, resource limits vs file edits, git, host commands)
- **Server instructions** — available environments, session lifecycle
  (ephemeral by default, sessions for multi-step work), debugging hints
- **Parameter descriptions** — per-field usage via JSON Schema `description`

This keeps all guidance in-band and co-located with the tool definition. No
extra documents to load, no discovery protocol to learn, no activation step.

## Roadmap

| Phase | Status  | What                                                   |
| ----- | ------- | ------------------------------------------------------ |
| 1     | Done    | jail.nix backend, bundled presets, MCP protocol        |
| 2a    | Done    | Project mounting, custom flake refs in config          |
| 2b    | Done    | Session persistence (Python, Bash, Node REPLs)         |
| 2c    | Done    | Decoupled sandboxes (`mkSandbox`, directory scanning)  |
| 2d    | Done    | MCP-conventional config (env vars, `NIX_SANDBOX_ENVS`) |
| 3a    | Planned | microvm.nix backend for hardware-level isolation       |
| 3b    | Planned | Dead interpreter recovery (restart bash/node on crash) |

## License

MIT
