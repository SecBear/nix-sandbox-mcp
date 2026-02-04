# Phase 2b: Session Persistence (Spike + Implementation)

## Overview

Phase 2b adds session persistence to nix-sandbox-mcp, enabling multi-turn workflows where state (variables, files, imported modules) persists across `run()` calls.

**Prerequisites:** Phase 2a shipped (run tool, project mounting, flake integration)

**Approach:** Spike first, then implement. The IPC agent pattern is promising but needs validation.

---

## Why Sessions?

**Without sessions:**
```json
run(code: "x = [1,2,3,4,5]", env: "python")         // x created
run(code: "print(sum(x))", env: "python")           // Error: x not defined
```

**With sessions:**
```json
run(code: "x = [1,2,3,4,5]", env: "python", session: "analysis")
run(code: "print(sum(x))", env: "python", session: "analysis")  // Returns: 15
```

Use cases:
- Data exploration: Load data → transform → analyze → visualize
- Incremental development: Define function → test → refine
- Complex builds: Setup → compile → test (without re-running setup)

---

## Research Insights (2026-02-02)

This section captures key learnings from comprehensive research on AI sandboxing solutions, session management, and agentic workflows.

### Industry Session Lifecycle Patterns

**Platform Comparison:**

| Platform | Max Session | Idle Timeout | Resume Time | Key Feature |
|----------|-------------|--------------|-------------|-------------|
| **E2B** | 24 hours | Configurable | <200ms (snapshot) | Pause/resume |
| **Modal** | 24 hours | Configurable | Sub-second | gVisor isolation |
| **Daytona** | Unlimited | N/A | ~90ms | Persistent by default |
| **ChatGPT Code Interpreter** | ~hours | 15-30 min | N/A | Session-per-conversation |
| **Devin** | 24 hours | N/A | N/A | Full dev environment |

**Key Finding:** 8-24 hour sessions with standby mode is the industry standard. Sessions should support:
- **Standby mode:** Zero compute cost after idle timeout (15-30 min typical)
- **Fast resume:** <25ms from standby (snapshot-based)
- **TTL cleanup:** Auto-terminate orphaned sessions (24h max)

### IPC Agent Architecture Validation

**Our proposed design aligns with industry patterns:**

1. **E2B uses Firecracker + templates:** Pre-snapshotted microVMs for rapid provisioning
2. **Modal uses gVisor + socket communication:** User-space kernel with IPC
3. **Agent Sandbox (K8s):** gVisor by default, Unix socket for control

**Unix Socket Pattern is Validated:**
- Modal sandboxes communicate via socket-based IPC
- E2B uses similar control plane architecture
- Our IPC agent design matches these proven patterns

**Agent Process Model:**
```
┌─────────────────────────────────────────────────┐
│  Industry Pattern: "Sidecar Agent"              │
│                                                 │
│  ┌─────────────┐     ┌──────────────────────┐  │
│  │   Daemon    │────▶│  Jailed Agent        │  │
│  │  (control)  │     │  - Unix socket       │  │
│  └─────────────┘     │  - Persistent REPL   │  │
│        ▲             │  - State management  │  │
│        │             └──────────────────────┘  │
│        │                                        │
│  MCP Protocol                                   │
└─────────────────────────────────────────────────┘
```

### MicroVM vs Container Trade-offs

**Isolation Technology Comparison:**

| Technology | Startup | Security | I/O Performance | Best For |
|------------|---------|----------|-----------------|----------|
| **Firecracker** | 125ms | Hardware (KVM) | Good | High-density, max security |
| **Cloud-Hypervisor** | 100-150ms | Hardware (KVM) | Better | Better I/O workloads |
| **gVisor** | 50-100ms | Software (user kernel) | Medium | K8s integration |
| **Bubblewrap** | <10ms | Process (namespace) | Native | Dev workflows |

**Recommendation for nix-sandbox-mcp:**

**Phase 2b (Current):** Use jail.nix/bubblewrap for sessions
- Fastest startup (<10ms)
- Sufficient for most agent workloads
- Matches current architecture

**Phase 3 (Future):** Add microVM tier via microvm.nix
- Cloud-Hypervisor recommended (better I/O than Firecracker)
- For production untrusted code scenarios
- Can share `/nix/store` read-only via virtiofs

**Recent Validation (Feb 2026):** Michael Stapelberg's [coding agent blog post](https://michael.stapelberg.ch/posts/2026-02-01-coding-agent-microvm-nix/) demonstrates:
- cloud-hypervisor with 8 vCPUs, 4GB RAM
- Shared read-only `/nix/store` for cached software
- Ephemeral VMs with isolated state directory
- "Boots and responds to pings within a few seconds"

### Session State Management

**Two-Tier State Model (from industry patterns):**

1. **Working Memory (Session-Specific):**
   - Python/Node interpreter state
   - Environment variables
   - File system changes in `/workspace`
   - **Purged when session terminates**

2. **Checkpoint State (Recoverable):**
   - Snapshot before/after tool invocations
   - Enable mid-workflow resume after crashes
   - Store in daemon's state directory

**LangGraph Persistence Pattern:**
```python
# Checkpointing at state transitions
await checkpoint(session_id, state)

# Recovery on session resume
state = await restore_checkpoint(session_id)
```

**Implication:** Consider checkpoint support in agent protocol for future crash recovery.

### Resource Limits at Hypervisor Level

**NVIDIA Security Guidance (2025):**

> "Hypervisor-level enforcement means attackers can't bypass even with root access inside the sandbox."

**Recommended Limits:**

| Resource | Default | Test/Build | Max |
|----------|---------|------------|-----|
| **Timeout** | 30s | 10-30 min | 60 min |
| **CPU** | 2 cores | 4 cores | 8 cores |
| **Memory** | 512 MB | 2 GB | 8 GB |
| **Disk** | 1 GB | 4 GB | 10 GB |

**For bubblewrap sessions:** Use cgroups for resource limits
**For microVM sessions:** Hypervisor-enforced limits (future)

### Network Isolation Patterns

**Industry Standard: Allowlist-Based Proxy**
```
┌──────────────────────────────────────────────┐
│  Sandbox (no direct network)                 │
│                                              │
│  ┌──────────┐     ┌─────────────────────┐   │
│  │  Agent   │────▶│  Unix Socket Proxy  │   │
│  └──────────┘     └─────────────────────┘   │
└──────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────┐
│  Host Proxy (allowlist enforced)             │
│  - registry.npmjs.org ✓                      │
│  - pypi.org ✓                                │
│  - github.com ✓                              │
│  - * ✗                                       │
└──────────────────────────────────────────────┘
```

**Recommendation:** Default network-disabled, with optional allowlist in config.

### Error Handling in Sessions

**From Agentic Workflows Research:**

> "Agentic systems don't fail like normal software. They fail halfway through intentions."

**Session-Specific Error Handling:**

1. **Transient errors (network, timeout):** Retry with exponential backoff
2. **Permanent errors (syntax, import):** Return immediately, no retry
3. **Session errors (agent crash):** Auto-restart agent, preserve state if possible

**Actionable Error Pattern:**
```json
{
  "stdout": "",
  "stderr": "Session 'analysis' timed out after 30s. The session state is preserved. Consider: 1) Increasing timeout, 2) Breaking operation into smaller steps, 3) Using session='analysis' to continue where you left off.",
  "exit_code": 124,
  "session_preserved": true
}
```

### Multi-Interpreter Session Design

**Open Question from Plan:** "Should one session support switching interpreters?"

**Industry Answer:** Yes, but with caveats.

**E2B/Modal Pattern:**
- Single session, multiple interpreter processes
- Shell state: Use persistent bash process (not subprocess per command)
- Python state: Persistent REPL with `exec()` in shared namespace
- Node state: Similar persistent REPL pattern

**Recommendation:** Support multi-interpreter per session (already proposed in spike). Use persistent processes per interpreter type within the session.

### Key Takeaways for Phase 2b

1. **IPC agent pattern is industry-validated** - proceed with spike
2. **8-24 hour session max with idle timeout** - implement standby mode
3. **Bubblewrap is sufficient for Phase 2b** - microVMs can wait for Phase 3
4. **Persistent interpreter processes** - not subprocess per command
5. **Checkpoint support** - consider for crash recovery (optional enhancement)
6. **Actionable error messages** - especially for session state preservation
7. **Network isolation** - default disabled, allowlist-based proxy pattern

### Updated Spike Success Criteria

Based on research, add these criteria:

- [ ] Session idle timeout triggers standby (process paused, socket preserved)
- [ ] Session resume from standby < 100ms
- [ ] Multi-interpreter support (Python + bash in same session)
- [ ] Shell state persists (use persistent bash, not subprocess)
- [ ] Error messages indicate session state preservation

---

## Spike: IPC Agent Architecture

### Goal

Validate that a control-socket approach works reliably for Python, bash, and Node.

### Design

```
┌─────────────────────────────────────────────────────────────┐
│  Daemon (Rust)                                              │
│                                                             │
│  SessionManager                                             │
│  ├── Session "dev-1" ──────────┐                           │
│  │   └── unix socket           │                           │
│  └── Session "analysis" ────┐  │                           │
│      └── unix socket        │  │                           │
└─────────────────────────────│──│────────────────────────────┘
                              │  │
                              ▼  ▼
┌─────────────────────────────────────────────────────────────┐
│  Jailed Process (per session)                               │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Agent (small binary)                                │   │
│  │  - Listens on unix socket                           │   │
│  │  - Receives: {"code": "...", "env": "python"}       │   │
│  │  - Executes code in appropriate interpreter         │   │
│  │  - Returns: {"stdout": "...", "stderr": "...",      │   │
│  │              "exit_code": 0}                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  /workspace (tmpfs, persists within session)               │
│  /project (mounted from host)                              │
└─────────────────────────────────────────────────────────────┘
```

### Agent Protocol

**Request:**
```json
{
  "id": "req-123",
  "type": "execute",
  "interpreter": "python",
  "code": "x = 42\nprint(x)"
}
```

**Response:**
```json
{
  "id": "req-123",
  "stdout": "42\n",
  "stderr": "",
  "exit_code": 0
}
```

### Agent Implementation (Spike)

A minimal agent in Python (could be Rust for production):

```python
#!/usr/bin/env python3
"""Session agent - receives commands over unix socket, executes them."""

import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = os.environ.get("AGENT_SOCKET", "/tmp/agent.sock")

# Persistent namespaces for each interpreter
python_globals = {}
python_locals = {}

def execute_python(code: str) -> tuple[str, str, int]:
    """Execute Python code in persistent namespace."""
    import io
    from contextlib import redirect_stdout, redirect_stderr

    stdout_capture = io.StringIO()
    stderr_capture = io.StringIO()

    try:
        with redirect_stdout(stdout_capture), redirect_stderr(stderr_capture):
            exec(code, python_globals, python_locals)
        return stdout_capture.getvalue(), stderr_capture.getvalue(), 0
    except Exception as e:
        return stdout_capture.getvalue(), f"{type(e).__name__}: {e}\n", 1

def execute_bash(code: str) -> tuple[str, str, int]:
    """Execute bash code."""
    result = subprocess.run(
        ["bash", "-c", code],
        capture_output=True,
        text=True,
        timeout=30
    )
    return result.stdout, result.stderr, result.returncode

def execute_node(code: str) -> tuple[str, str, int]:
    """Execute Node.js code."""
    result = subprocess.run(
        ["node", "-e", code],
        capture_output=True,
        text=True,
        timeout=30
    )
    return result.stdout, result.stderr, result.returncode

INTERPRETERS = {
    "python": execute_python,
    "bash": execute_bash,
    "node": execute_node,
}

def handle_request(data: bytes) -> bytes:
    """Process a single request."""
    try:
        req = json.loads(data.decode())
        interpreter = req.get("interpreter", "bash")
        code = req["code"]

        if interpreter not in INTERPRETERS:
            return json.dumps({
                "id": req.get("id"),
                "stdout": "",
                "stderr": f"Unknown interpreter: {interpreter}",
                "exit_code": 1
            }).encode()

        stdout, stderr, exit_code = INTERPRETERS[interpreter](code)

        return json.dumps({
            "id": req.get("id"),
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": exit_code
        }).encode()

    except Exception as e:
        return json.dumps({
            "stdout": "",
            "stderr": str(e),
            "exit_code": 1
        }).encode()

def main():
    # Clean up old socket
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)

    print(f"Agent listening on {SOCKET_PATH}", file=sys.stderr)

    while True:
        conn, _ = server.accept()
        try:
            # Simple protocol: length-prefixed JSON
            length_bytes = conn.recv(4)
            if not length_bytes:
                continue
            length = int.from_bytes(length_bytes, 'big')
            data = conn.recv(length)

            response = handle_request(data)

            conn.sendall(len(response).to_bytes(4, 'big'))
            conn.sendall(response)
        finally:
            conn.close()

if __name__ == "__main__":
    main()
```

### Spike Tasks

1. **Build agent binary** (Nix derivation)
2. **Wrap in jail** with socket accessible to daemon
3. **Test manually:**
   - Start jailed agent
   - Connect from outside jail
   - Send Python code, verify persistent state
   - Send bash code
   - Verify isolation (can't escape jail)
4. **Measure:**
   - Latency per request
   - Memory overhead of persistent interpreter
   - Cleanup behavior

### Spike Success Criteria

- [ ] Agent starts in jail, socket accessible from host
- [ ] Python state persists: `x=1` then `print(x)` works
- [ ] Shell commands work
- [ ] Node commands work
- [ ] Response latency < 50ms for simple commands
- [ ] Clean shutdown when socket closed

---

## Implementation (Post-Spike)

### Tool Schema Update

```json
{
  "name": "run",
  "inputSchema": {
    "properties": {
      "code": {
        "type": "string",
        "description": "Code to execute (raw code, not interpreter invocations)"
      },
      "env": {
        "type": "string",
        "description": "Execution environment: python, node, bash, or custom"
      },
      "session": {
        "type": "string",
        "description": "Session ID for persistent state. Omit for ephemeral."
      }
    },
    "required": ["code", "env"]
  }
}
```

### Session Manager

**File:** `daemon/src/session.rs`

```rust
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::net::UnixStream;
use tokio::sync::RwLock;
use anyhow::Result;

pub struct SessionConfig {
    pub idle_timeout: Duration,      // Default: 30 min
    pub max_lifetime: Duration,      // Default: 24 hours
}

pub struct Session {
    pub id: String,
    pub created_at: Instant,
    pub last_used: Instant,
    socket_path: PathBuf,
    // Process handle for cleanup
}

impl Session {
    pub async fn execute(&mut self, interpreter: &str, code: &str) -> Result<ExecutionResult> {
        self.last_used = Instant::now();

        let mut stream = UnixStream::connect(&self.socket_path).await?;

        let request = serde_json::json!({
            "interpreter": interpreter,
            "code": code
        });

        // Send length-prefixed request
        let req_bytes = serde_json::to_vec(&request)?;
        stream.write_all(&(req_bytes.len() as u32).to_be_bytes()).await?;
        stream.write_all(&req_bytes).await?;

        // Read length-prefixed response
        let mut len_buf = [0u8; 4];
        stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;

        let mut resp_buf = vec![0u8; len];
        stream.read_exact(&mut resp_buf).await?;

        let resp: AgentResponse = serde_json::from_slice(&resp_buf)?;

        Ok(ExecutionResult {
            stdout: resp.stdout,
            stderr: resp.stderr,
            exit_code: resp.exit_code,
        })
    }

    pub fn is_expired(&self, config: &SessionConfig) -> bool {
        let now = Instant::now();
        now.duration_since(self.last_used) > config.idle_timeout
            || now.duration_since(self.created_at) > config.max_lifetime
    }
}

pub struct SessionManager {
    sessions: RwLock<HashMap<String, Session>>,
    config: SessionConfig,
}

impl SessionManager {
    pub async fn get_or_create(&self, session_id: &str) -> Result<&mut Session> {
        let mut sessions = self.sessions.write().await;

        if !sessions.contains_key(session_id) {
            let session = self.create_session(session_id).await?;
            sessions.insert(session_id.to_string(), session);
        }

        Ok(sessions.get_mut(session_id).unwrap())
    }

    async fn create_session(&self, id: &str) -> Result<Session> {
        // 1. Create unique socket path
        // 2. Start jailed agent process with socket
        // 3. Wait for agent to be ready
        // 4. Return session handle
        todo!()
    }

    pub async fn cleanup_expired(&self) {
        let mut sessions = self.sessions.write().await;
        let expired: Vec<_> = sessions
            .iter()
            .filter(|(_, s)| s.is_expired(&self.config))
            .map(|(k, _)| k.clone())
            .collect();

        for id in expired {
            if let Some(session) = sessions.remove(&id) {
                // Kill agent process
                drop(session);
            }
        }
    }

    pub async fn destroy_all(&self) {
        let mut sessions = self.sessions.write().await;
        sessions.clear();  // Drop triggers cleanup
    }
}
```

### Connection Lifecycle

```
MCP Connect
    │
    ▼
┌───────────────────────────┐
│  Daemon creates           │
│  SessionManager           │
└───────────────────────────┘
    │
    │  run(session: "dev")
    ▼
┌───────────────────────────┐
│  get_or_create("dev")     │
│  - Spawns jailed agent    │
│  - Connects socket        │
└───────────────────────────┘
    │
    │  More run() calls with session: "dev"
    ▼
┌───────────────────────────┐
│  Reuses existing session  │
│  State persists           │
└───────────────────────────┘
    │
    │  Idle timeout OR MCP disconnect
    ▼
┌───────────────────────────┐
│  Session cleanup          │
│  - Kills agent process    │
│  - Removes socket         │
└───────────────────────────┘
```

### Config

```toml
[session]
idle_timeout_seconds = 1800   # 30 minutes
max_lifetime_seconds = 86400  # 24 hours
```

---

## Testing

### Unit Tests

```rust
#[tokio::test]
async fn test_session_state_persists() {
    let manager = SessionManager::new(SessionConfig::default());

    let session = manager.get_or_create("test").await.unwrap();

    // Set variable
    let r1 = session.execute("python", "x = 42").await.unwrap();
    assert_eq!(r1.exit_code, 0);

    // Read variable
    let r2 = session.execute("python", "print(x)").await.unwrap();
    assert_eq!(r2.stdout.trim(), "42");
}

#[tokio::test]
async fn test_sessions_isolated() {
    let manager = SessionManager::new(SessionConfig::default());

    let s1 = manager.get_or_create("session1").await.unwrap();
    let s2 = manager.get_or_create("session2").await.unwrap();

    s1.execute("python", "x = 1").await.unwrap();
    s2.execute("python", "x = 2").await.unwrap();

    let r1 = s1.execute("python", "print(x)").await.unwrap();
    let r2 = s2.execute("python", "print(x)").await.unwrap();

    assert_eq!(r1.stdout.trim(), "1");
    assert_eq!(r2.stdout.trim(), "2");
}
```

### Integration Tests

```python
# In nix/tests/default.nix

with subtest("Session state persists"):
    run("x = 42", session="test")
    result = run("print(x)", session="test")
    assert "42" in result

with subtest("Different sessions isolated"):
    run("y = 1", session="s1")
    run("y = 2", session="s2")
    r1 = run("print(y)", session="s1")
    r2 = run("print(y)", session="s2")
    assert "1" in r1
    assert "2" in r2

with subtest("Session expires after idle"):
    run("z = 1", session="expire-test")
    # Wait for idle timeout
    time.sleep(idle_timeout + 1)
    result = run("print(z)", session="expire-test")
    assert "not defined" in result or "error" in result.lower()
```

---

## Timeline

1. **Spike (2-3 days):**
   - Build agent
   - Test in jail
   - Validate design

2. **Implementation (3-5 days):**
   - SessionManager
   - Integration with run tool
   - Cleanup logic
   - Tests

3. **Polish (1-2 days):**
   - Error handling
   - Logging
   - Documentation

---

## Open Questions (Resolve During Spike)

1. **Socket path:** Inside jail at `/tmp/agent.sock`? Or exposed via jail combinator?

   **Research insight:** E2B and Modal expose sockets via hypervisor-level mechanisms. For bubblewrap, use jail combinator to bind-mount socket into accessible location.

2. **Agent language:** Python spike is easy, but Rust agent would be more robust. Worth the extra work?

   **Research insight:** Start with Python for spike (faster iteration). E2B's agent is Python-based. Production can migrate to Rust if needed for memory safety, but Python is proven viable.

3. **Multi-interpreter sessions:** Should one session support switching interpreters? Or one interpreter per session?

   **Research insight:** Industry standard is multi-interpreter per session. E2B and Modal both support this. Implement with separate persistent processes per interpreter type within the same jailed environment.

4. **File persistence:** `/workspace` is tmpfs. Should we persist it to disk for resume after idle timeout?

   **Research insight:** E2B supports pause/resume with state preservation. For standby mode, preserve `/workspace` to disk (in daemon's state dir). For session termination, clean up. Consider checkpointing for crash recovery.

5. **Shell state:** Shell variables don't persist across bash invocations. Use a persistent bash process instead of subprocess per command?

   **Research insight:** YES. Use persistent bash process. This is how professional sandboxes handle shell state. The agent should maintain a long-running bash subprocess and feed commands to it, preserving environment variables and working directory.

---

## References

### Internal
- Phase 2a plan: `2026-02-02-phase2a-run-tool-and-project-context.md`

### AI Sandboxing Platforms
- E2B Documentation: https://e2b.dev/docs - Firecracker microVMs, session persistence, template system
- E2B Session Model: https://e2b.dev/docs/sandbox/persistence - Pause/resume, 24-hour max
- Modal Sandboxes: https://modal.com/docs/guide/sandboxes - gVisor isolation, Python-first
- Daytona: https://www.daytona.io/ - Sub-90ms startup, unlimited sessions
- ChatGPT Code Interpreter: ~1hr lifetime, 15-30min idle timeout

### Nix Ecosystem
- jail.nix: https://git.sr.ht/~alexdavid/jail.nix - Bubblewrap jail library
- jail.nix NixCon 2025: https://talks.nixcon.org/nixcon-2025/talk/3QH3PZ/
- microvm.nix: https://github.com/microvm-nix/microvm.nix - Multi-hypervisor microVMs
- Coding Agent MicroVMs (Feb 2026): https://michael.stapelberg.ch/posts/2026-02-01-coding-agent-microvm-nix/
- nixpak: https://github.com/nixpak/nixpak - Runtime sandboxing with portals

### MCP & Agentic Workflows
- MCP Specification 2025-11-25: https://modelcontextprotocol.io/specification/2025-11-25
- AGENTS.md Standard: https://agents.md/ - Project context for AI agents
- Claude Code Best Practices: https://www.anthropic.com/engineering/claude-code-best-practices
- NVIDIA Sandboxing Guidance: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk

### Isolation Technologies
- Firecracker: https://firecracker-microvm.github.io/ - 125ms boot, <5MB overhead
- Cloud-Hypervisor: https://github.com/cloud-hypervisor/cloud-hypervisor - Better I/O than Firecracker
- gVisor: https://gvisor.dev/ - User-space kernel for K8s
- Bubblewrap: https://github.com/containers/bubblewrap - Lightweight unprivileged sandboxes

### Security Research
- Agent Sandbox for K8s: https://www.infoq.com/news/2025/12/agent-sandbox-kubernetes/
- MCP Security Best Practices: https://www.stackhawk.com/blog/mcp-server-security-best-practices/
- Nix Security Advisory (2025): https://discourse.nixos.org/t/security-advisory-privilege-escalations-in-nix-lix-and-guix/66017
