# Contributing to nix-sandbox-mcp

## Prerequisites

- **Nix with flakes enabled** — the project uses Nix flakes exclusively
- **Rust toolchain** — managed by the flake devShell (`nix develop`)
- **Linux** — jail.nix requires Linux namespaces (user, PID, mount, network)

## Building

```bash
# Full server (Nix layer + Rust daemon + environments)
nix build

# Fast Rust iteration (skips Nix rebuild)
cd daemon && cargo build

# Enter dev shell with all tools
nix develop
```

**Common pitfall**: Nix flakes only see git-tracked files. You must `git add` new files before `nix build` will pick them up.

## Testing

```bash
# Unit tests (fast, from daemon/)
cd daemon && cargo test

# VM integration tests (slow, full sandbox testing)
nix flake check
```

## Repository Layout

```
nix-sandbox-mcp/
├── daemon/                           # Rust MCP daemon (rmcp crate)
│   └── src/
│       ├── main.rs                   # Entry point, config loading, sandbox scanning
│       ├── config.rs                 # Metadata parsing, sandbox discovery, env var config
│       ├── mcp.rs                    # MCP server, run tool handler
│       ├── session.rs                # Session lifecycle, reaper task
│       ├── backend.rs                # Backend trait, ExecutionResult
│       ├── backend/
│       │   └── jail.rs              # JailBackend (bubblewrap process spawning)
│       └── transport/                # Agent IPC (length-prefixed JSON over pipes)
│
├── agent/
│   └── sandbox_agent.py              # Persistent interpreter for sessions
│
├── nix/
│   ├── environments/                 # Bundled preset definitions (shell, python, node)
│   ├── backends/
│   │   └── jail.nix                  # jail.nix backend (mkJailedEnv + mkSessionJailedEnv)
│   └── lib/
│       ├── mkSandbox.nix             # Public API: build standalone sandbox artifacts
│       └── fromToml.nix              # Parse TOML config, build all envs + metadata
│
├── config.example.toml               # Build-time configuration (environment definitions)
├── flake.nix                         # Entry point, wrapper script, lib.mkSandbox
└── flake.lock
```

## Configuration Architecture

Configuration is split into two layers:

**Build-time (Nix, TOML)** — things that require Nix evaluation:
- `[environments.*]` — which presets/flakes to build
- `[defaults]` — timeout_seconds, memory_mb
- `[project] use_flake = true` — create env from project's devShell

**Runtime (env vars)** — things the MCP client controls:
- `PROJECT_DIR` / `PROJECT_MOUNT` — project directory mounting
- `SESSION_IDLE_TIMEOUT` / `SESSION_MAX_LIFETIME` — session timeouts
- `NIX_SANDBOX_ENVS` — on-the-fly custom environment building
- `NIX_SANDBOX_DIR` — pre-built sandbox directory

The split follows MCP convention: runtime settings go in the client JSON (`"env": {...}`), build-time settings go in the Nix layer. The daemon reads TOML metadata first with fallback to env vars, so existing configs keep working.

### How `NIX_SANDBOX_ENVS` works

The shell wrapper script in `flake.nix` handles this *before* exec'ing the daemon:

1. Creates a temp directory
2. Symlinks any existing `$NIX_SANDBOX_DIR` entries into it
3. Runs `nix build $flakeref -o $tmpdir/env-$j` for each comma-separated ref
4. Exports `NIX_SANDBOX_DIR=$tmpdir`

The daemon's existing scanner picks up the results. It has no knowledge of `NIX_SANDBOX_ENVS` — the wrapper translates it into a directory of sandbox artifacts, which is an interface the daemon already understands.

### How project mounting works

All environments use `runtimeProjectMount = true` in jail.nix. This means the bwrap wrapper checks `$PROJECT_DIR` at invocation time and adds `--ro-bind "$PROJECT_DIR" "$PROJECT_MOUNT"`. The sandbox derivations are project-agnostic — same Nix store path regardless of which project gets mounted.

## Sandbox Artifact Format

Custom sandboxes (from `mkSandbox` or `NIX_SANDBOX_ENVS`) are Nix derivations with a standard layout:

```
/nix/store/xxx-sandbox-data-science/
  metadata.json       # {name, interpreter_type, timeout_seconds, memory_mb}
  bin/run             # Ephemeral execution wrapper (jailed)
  bin/session-run     # Session execution wrapper (jailed, runs sandbox_agent.py)
```

The daemon scans `$NIX_SANDBOX_DIR`, reads `metadata.json` from each subdirectory, verifies `bin/run` exists, and merges discovered environments with bundled presets (custom overrides on name collision).

## Session Architecture

End-to-end flow for a session `run` call:

```
MCP client
  → tools/call "run" {code, env, session}
    → Rust daemon (mcp.rs)
      → SessionManager.execute(session_id, env, code)
        → acquires per-session Mutex
          → StdioPipeTransport.send(request)
            → sandbox_agent.py (inside jail)
              → Interpreter.execute(code)
            ← length-prefixed JSON response
          ← response
        ← release Mutex
      ← result
    ← MCP tool response
  ← JSON-RPC result
```

### Key decisions

- **Length-prefixed JSON** (4-byte big-endian + payload), not newline-delimited — code output can contain newlines
- **Stdin/stdout pipes**, not Unix sockets — simpler, works inside namespaced jails
- **Per-session Mutex** — serializes concurrent requests to the same session
- **Real stdin/stdout saved at agent startup** — `sandbox_agent.py` replaces `sys.stdout` with `/dev/null` so interpreter output doesn't corrupt the protocol
- **Lazy interpreter instantiation** — interpreters are created on first use, not at session creation

### Interpreter implementation

Each interpreter (Python, Bash, Node) is a long-lived subprocess managed by `sandbox_agent.py`. They share a pattern:

1. **Nonce-based markers** — random nonce per execution, markers delimit captured output
2. **Separate stdout/stderr** — each stream captured independently
3. **Exit code reporting** — via dedicated marker in the output stream

**Python**: Uses `exec()` in a shared namespace dict. No subprocess needed.
**Bash**: Persistent `bash` subprocess. Commands wrapped with echo markers.
**Node**: Custom REPL — see gotchas below.

## Gotchas

### Node.js REPL

1. `node -e` doesn't initialize stdin as readable when stdin is a pipe. Write REPL setup to a temp file and run `node <file>` instead.
2. The REPL overrides `context.console`. Restore it after creation with `new Console(process.stdout, process.stderr)`.
3. `process.stdout.write()` bypasses REPL routing; `console.log()` does not. Protocol markers must use `process.stdout.write()`.
4. `try/catch` wrapping creates block scope, preventing `let`/`const` from persisting. Send code directly to the REPL instead.
5. `.break` cancels pending multiline mode. Send it after user code to ensure markers execute immediately.

### Nix

- Flakes only see git-tracked files — `git add` before `nix build`.
- The `debug` attr in flake.nix is a custom `perSystem` attribute, not accessible via `nix eval .#debug`. Use `nix eval .#debug.x86_64-linux`.

### Concurrency

- rmcp dispatches `tool/call` requests as concurrent tokio tasks.
- Per-session mutexes serialize execution but don't guarantee wire-order — tokio task scheduling is non-deterministic.
- In tests: use proper request-response cycling, don't assume ordering from concurrent sends.

## Submitting Changes

1. Open an issue to discuss significant changes before submitting a PR
2. Run `cargo test` from `daemon/` and verify tests pass
3. Run `nix flake check` for full integration validation
4. Keep PRs focused — one logical change per PR
