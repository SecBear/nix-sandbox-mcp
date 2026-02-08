# Contributing to nix-sandbox-mcp

## Prerequisites

- **Nix with flakes enabled** — The project uses Nix flakes exclusively
- **Rust toolchain** — Managed by the flake devShell (`nix develop`)
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

**Important**: Nix flakes only see git-tracked files. You must `git add` new files before `nix build` will see them. This is the most common "why isn't my change picked up?" issue.

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
├── daemon/                           # Rust MCP server (rmcp crate)
│   └── src/
│       ├── main.rs                   # Entry point, loads metadata, scans sandbox dir
│       ├── config.rs                 # Parse metadata, scan sandbox artifacts, merge envs
│       ├── mcp.rs                    # MCP server, run tool handler
│       ├── session.rs                # Session lifecycle management
│       ├── backend.rs                # Backend trait + JailBackend
│       └── transport/                # Agent IPC (length-prefixed JSON)
│
├── agent/
│   └── sandbox_agent.py              # Persistent interpreter for sessions
│
├── nix/
│   ├── environments/                 # Bundled preset definitions
│   │   ├── shell.nix
│   │   ├── python.nix
│   │   ├── node.nix
│   │   └── default.nix
│   ├── backends/
│   │   ├── jail.nix                  # jail.nix backend (mkJailedEnv + mkSessionJailedEnv)
│   │   └── microvm.nix              # microvm.nix backend (planned)
│   └── lib/
│       ├── mkSandbox.nix             # Build standalone sandbox artifacts (Phase 2c)
│       ├── mkEnvironment.nix         # env def + backend -> built artifact
│       ├── fromToml.nix              # Parse TOML config, build all envs
│       └── mkMetadata.nix            # Generate environments.json
│
├── config.example.toml               # Reference configuration
├── flake.nix                         # Main entry point (exposes lib.mkSandbox)
└── flake.lock
```

## Architecture: Sandbox Artifacts (Phase 2c)

Custom sandboxes are standalone Nix derivations with a standard layout:

```
/nix/store/xxx-sandbox-data-science/
  metadata.json       # {name, interpreter_type, timeout_seconds, memory_mb}
  bin/run             # Ephemeral execution (jailed via bubblewrap)
  bin/session-run     # Session execution (jailed, runs sandbox_agent.py)
```

**Discovery flow:**
1. Daemon starts → scans `$NIX_SANDBOX_DIR` or `~/.config/nix-sandbox-mcp/sandboxes/`
2. Each subdirectory is parsed: read `metadata.json`, verify `bin/run` exists
3. Discovered environments are merged with bundled presets (custom overrides on collision)
4. Adding/removing sandboxes requires restarting the MCP server

**Build-time vs runtime project mounting:**
- **Bundled presets** (via `fromToml.nix`): use `c.ro-bind` — project path baked into the derivation at build time
- **mkSandbox artifacts**: use `c.add-runtime` — check `$PROJECT_DIR` env var at bwrap invocation time
- This means mkSandbox artifacts are project-agnostic: same Nix store path, different projects

**`interpreter_type`** maps custom environments to agent interpreters. The agent supports exactly three: `python`, `bash`, `node`. A "data-science" sandbox with `interpreter_type = "python"` uses the Python interpreter with custom packages on PATH.

## Architecture: Session Persistence

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

### Key Design Decisions

- **Length-prefixed JSON protocol** (4-byte big-endian + payload), not newline-delimited — code output can contain newlines
- **Stdin/stdout pipes**, not Unix sockets — simpler, works inside namespaced jails
- **Per-session Mutex** — Serializes concurrent requests to the same session in arrival order
- **Real stdin/stdout saved at agent startup** — `sandbox_agent.py` saves the real file descriptors, then replaces `sys.stdout` with `/dev/null` so interpreter output doesn't corrupt the protocol
- **Lazy interpreter instantiation** — Interpreters are created on first use within a session, not at session creation

## Interpreter Implementation Guide

Each interpreter (Python, Bash, Node) is a long-lived subprocess (or exec namespace) managed by `sandbox_agent.py`. They share a common pattern:

1. **Nonce-based markers** — A random nonce is generated per execution. Markers like `__SANDBOX_STDOUT_{nonce}__` delimit where captured output begins/ends
2. **Separate stdout/stderr** — Each stream is captured independently using the marker protocol
3. **Exit code reporting** — Reported via a dedicated marker in the output stream

### Python
Uses `exec()` in a shared namespace dictionary — no subprocess needed. Variables, imports, and definitions persist across calls.

### Bash
Persistent `bash` subprocess. Commands are wrapped with `echo` markers and the exit code is captured via `$?`.

### Node.js
Custom REPL configuration — see gotchas below for the many subtleties.

## Gotchas & Lessons Learned

### Node.js REPL

1. **`node -e` doesn't initialize stdin as a readable stream** when stdin is a pipe. The REPL needs a proper readable stdin to accept input. Workaround: write the REPL setup script to a temp file and run `node <file>` instead. The file is written to `$TMPDIR` (which the jail sets to the per-session `/workspace` tmpfs) to avoid path collisions between concurrent sessions.

2. **The REPL overrides `context.console`** to route output through its own `output` stream. This means `console.log()` in user code goes through the REPL's writer (which we suppress). Fix: after creating the REPL, restore console with `new Console(process.stdout, process.stderr)` so user code output works normally.

3. **`process.stdout.write()` bypasses REPL output routing; `console.log()` does not.** Our REPL config sets `writer: () => ''` to suppress result echoing. Protocol markers must use `process.stdout.write()` directly to guarantee they appear in the output stream regardless of REPL configuration.

4. **`try/catch` wrapping creates block scope**, which prevents `let`/`const` declarations from persisting across executions. In JavaScript, `let x = 1` inside a `try {}` block is scoped to that block. Solution: send user code directly to the REPL without wrapping, and infer the exit code from stderr presence instead.

5. **`.break` cancels pending multiline mode.** If user code has an unclosed bracket or incomplete expression, the REPL enters multiline mode and treats subsequent input as continuation — including our marker commands. Sending `.break` after user code forces the REPL back to normal mode so markers execute immediately.

### Nix Flakes

- **Flakes only see git-tracked files** — `git add` before `nix build`. This is the #1 source of "my changes aren't showing up" confusion.
- **The `debug` attr in flake.nix** is a custom `perSystem` attribute, not accessible via `nix eval .#debug`. Use `nix eval .#debug.x86_64-linux` or similar.

### Concurrency

- **rmcp dispatches `tool/call` requests as concurrent tokio tasks** — Multiple MCP calls can arrive and execute simultaneously.
- **Per-session mutexes serialize execution but don't guarantee wire-order** — Tokio task scheduling is non-deterministic; the first-spawned task isn't necessarily the first to acquire the lock.
- **Testing implication** — Use proper request-response cycling (send request, read response, then send next) rather than assuming ordering from concurrent sends.

## Submitting Changes

1. Open an issue to discuss significant changes before submitting a PR
2. Run `cargo test` from `daemon/` and verify tests pass
3. Run `nix flake check` for full integration validation
4. Keep PRs focused — one logical change per PR
