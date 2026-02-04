# Phase 2a: `run` Tool and Project Context

## Overview

Phase 2a evolves nix-sandbox-mcp from a simple code execution tool into a project-aware sandbox that can run tests, builds, and commands using the project's own Nix environment. This unlocks the primary use case: "Claude, run my tests with my toolchain."

**Timeline target:** Days, not weeks.

## What's In Scope

1. New `run(command)` tool replacing `execute(environment, code)`
2. Environment auto-detection from command
3. Project directory mounting (read-only default)
4. User-specified flake references in config
5. Project flake integration (`use_flake` for devShell)
6. Dynamic tool description reflecting config
7. Timeout enforcement at daemon level

## What's NOT In Scope (Phase 2b)

- Session persistence (needs IPC spike first)
- macOS support (Phase 3)
- microVM backend (Phase 3)

---

## Research Insights (2026-02-02)

This section captures key learnings from comprehensive research on AI sandboxing solutions, MCP best practices, and agentic workflows.

### Industry Landscape

**Best-in-Class AI Sandboxing Solutions:**

| Platform | Isolation | Startup | Max Session | Key Innovation |
|----------|-----------|---------|-------------|----------------|
| **E2B** | Firecracker microVM | ~150ms | 24 hours | Template-based snapshotting |
| **Modal** | gVisor | Sub-second | 24 hours | Python-first ML focus |
| **Daytona** | Docker (Kata opt.) | ~90ms | Unlimited | Fastest cold starts |
| **ChatGPT Code Interpreter** | Docker/K8s | N/A | ~hours | Integrated UX |

**Key Finding:** MicroVM technologies (Firecracker, Cloud-Hypervisor) have "rendered the old dichotomy of 'slow, secure VMs versus fast, insecure containers' largely obsolete" - achieving sub-200ms startup with hardware-level isolation.

**Nix Advantage:** Our jail.nix/bubblewrap approach provides <10ms startup for development workflows. For production untrusted code, we can tier up to microVMs via microvm.nix.

### MCP Tool Design Best Practices

**From MCP Specification (2025-11-25):**

1. **Tool Naming:** 1-128 characters, `A-Za-z0-9_-.` only, no spaces
2. **Error Handling:** Two-tier system:
   - **Protocol errors:** Standard JSON-RPC (unknown tools, malformed requests)
   - **Tool execution errors:** `isError: true` with actionable feedback for LLM self-correction

**Critical Security Pattern (43% of MCP servers have command injection flaws):**
```rust
// BAD: Shell interpretation
execute_shell("bash -c " + user_command)  // Injection risk!

// GOOD: Direct execution without shell
Command::new(interpreter).arg("-c").arg(code)  // No shell metacharacters
```

**Actionable Error Example:**
```json
{
  "content": [{
    "type": "text",
    "text": "Unknown environment 'rust'. Available: python, node, bash, project. Use env='project' to access your project's devShell."
  }],
  "isError": true
}
```

### Environment Selection Pattern

**Decision: No Auto-Detection**

After analysis, we chose explicit environment selection over auto-detection:
- Auto-detection heuristics are fragile (`cargo build` - shell or rust?)
- Can't detect *intent*, only text patterns
- Claude excels at task reasoning - let it choose

**How Claude Chooses:**
1. Reads tool description listing available environments
2. Understands the user's task
3. Selects appropriate environment explicitly

**Example Flow:**
```
User: "Calculate first 100 primes"
Claude thinks: "I need Python for computation"
Claude calls: run(code="...", env="python")

User: "Run our tests"
Claude thinks: "pytest runs in bash"
Claude calls: run(code="pytest tests/", env="bash")
```

This matches Claude Code's existing pattern of choosing between Bash/Read/Write tools.

### Agentic Workflow Patterns

**Most Common Agent Operations:**
- `npm test path/to/file.test.ts` (file-scoped preferred over full suite)
- `tsc --noEmit path/to/file.tsx` (file-scoped type check)
- `prettier --write path/to/file.tsx` (file-scoped formatting)
- `cargo build`, `make test` (project builds)

**File-Scoped Operations are Critical:**
> "80% time savings expected for 1-6 hour tasks" when using file-scoped commands vs full-project operations.

**Implication for `run` tool:**
- Auto-detect if command can be file-scoped
- Suggest optimizations in tool description
- Consider `scope?: "file" | "project"` parameter

### Security Recommendations

**From NVIDIA Security Guidance (2025):**

1. **Network:** Default-deny with allowlists (not blanket blocking)
2. **Filesystem:** Block writes outside `/workspace` and `/project`
3. **Config Protection:** Never allow writes to `.cursorrules`, `CLAUDE.md`, MCP configs

**Parameter Safety:**

| Safe for LLM Control | Requires Server Control |
|---------------------|------------------------|
| Code to execute | Interpreter choice (from config) |
| Working directory (within bounds) | Timeout max value |
| Environment vars (from whitelist) | Network destinations |
| Session ID | Filesystem mount paths |

**Our Approach:** Flake references come from config only, never from LLM parameters - this is correct and matches industry best practice.

### Tool Description Best Practices

**Design for the Agent, Not the User:**
> "Error messages should help the agent decide next steps"

**Dynamic Description Pattern:**
```rust
fn get_tool_description(&self) -> String {
    let envs: Vec<_> = self.config.environments.keys().collect();
    format!(
        "Run commands in isolated Nix sandbox.\n\
         Available: {envs:?}\n\
         Project mounted at /project ({})\n\
         Prefer file-scoped operations when possible.",
        self.config.project.mode
    )
}
```

### Timeout & Resource Patterns

**Industry Standards:**
- Individual commands: 30s - 5min typical
- Test suites: 10-30 min
- Builds: 30-60 min max

**Recommendation:** Per-environment timeout configuration (already planned) plus global max enforced at daemon level.

### Key Takeaways for Phase 2a

1. **No auto-detection** - Claude explicitly selects environment (required param)
2. **Error messages must be actionable** - list available environments on error
3. **Dynamic tool descriptions** - list available environments to help Claude choose
4. **No shell injection** - execute commands directly, not through shell
5. **Flake refs from config only** - correct security boundary (already planned)
6. **Trust Claude's reasoning** - same pattern as Bash/Read/Write tool selection

---

## Current State (Phase 1)

```
execute(environment: string, code: string)
```
- Explicit environment selection required
- Inline code only
- No project context
- Ephemeral execution only

## Desired End State (Phase 2a)

```
run(code: string, env: string)
```

**Basic usage:**
```json
{"code": "print(1+1)", "env": "python"}
{"code": "pytest tests/ -v", "env": "bash"}
{"code": "cargo build", "env": "bash"}
```

**Interface Design Rationale (2026-02-03):**

After experimentation, we chose `code` + `env` over alternatives:

- `command` → `code`: The word "command" primed LLMs to think "shell command", causing double-wrapping like `python -c "print('hi')"` when raw code was expected. `code` clearly signals "this is code to execute."

- `shell` → `bash`: More specific. LLMs know `bash` is an interpreter. `shell` is ambiguous.

- Kept `env` over `interpreter`: While `interpreter` works for simple cases (`interpreter="python"`), it's awkward for custom environments (`interpreter="rust-dev"`, `interpreter="project"`). `env` is general and scales to any configured environment.

The environment VALUES (`python`, `bash`, `node`) do the heavy lifting - they're intuitive interpreter names that guide the LLM on what code to send.

**Project config:**
```toml
[project]
path = "."
mode = "readonly"
use_flake = true  # Use project's flake.nix#devShell

[project.inherit_env]
vars = ["DATABASE_URL", "RUST_LOG"]
```

---

## Implementation

### 2a.1: New `run` Tool Interface

#### Design Decision: No Auto-Detection

**We explicitly chose NOT to auto-detect environments.** Instead:
- `environment` is a **required** parameter
- Claude selects the appropriate environment based on task reasoning
- Dynamic tool description lists available environments to help Claude choose

**Rationale:**
- Auto-detection heuristics are fragile and error-prone
- Claude excels at task reasoning (same pattern as choosing Bash vs Read vs Write)
- Explicit selection is more predictable and debuggable
- If Claude picks wrong, it sees the error and self-corrects
- Matches industry patterns (E2B, Modal use explicit selection)

#### Tool Schema

```json
{
  "name": "run",
  "description": "Execute code in an isolated Nix sandbox.\n\nAvailable environments:\n- python: Python 3 with standard library\n- node: Node.js runtime\n- bash: Bash with coreutils, curl, jq\n\nPass raw code (not shell commands to invoke interpreters).\n\nExamples:\n- Python: {\"code\": \"print('hi')\", \"env\": \"python\"} ✓\n- Wrong: {\"code\": \"python -c 'print(hi)'\", \"env\": \"python\"} ✗\n- Bash: {\"code\": \"ls -la\", \"env\": \"bash\"} ✓",
  "inputSchema": {
    "type": "object",
    "properties": {
      "code": {
        "type": "string",
        "description": "Code to execute (raw code, not shell invocations)"
      },
      "env": {
        "type": "string",
        "description": "Execution environment: python, node, bash, or custom"
      }
    },
    "required": ["code", "env"]
  }
}
```

#### Changes

**File:** `daemon/src/mcp.rs`

```rust
#[derive(Debug, Deserialize, JsonSchema)]
pub struct RunParams {
    /// Code to execute (raw code, not shell invocations)
    pub code: String,
    /// Execution environment: python, node, bash, or custom
    pub env: String,
}

#[tool(description = "Execute code in an isolated Nix sandbox")]
async fn run(
    &self,
    Parameters(params): Parameters<RunParams>,
) -> Result<CallToolResult, McpError> {
    let env_name = &params.env;

    let env_meta = self.config.environments.get(env_name).ok_or_else(|| {
        let available: Vec<_> = self.config.environments.keys().collect();
        McpError::invalid_params(
            format!("Unknown environment: '{env_name}'. Available: {available:?}"),
            None,
        )
    })?;

    // Execute and format result...
}
```

**No detect.rs needed** - environment selection is Claude's responsibility.

#### Breaking Change

The `execute` tool is removed. This is intentional—Phase 1 just shipped, no external users.

#### Success Criteria

- [x] `run(code: "print(1)", env: "python")` returns "1"
- [x] `run(code: "echo hi", env: "bash")` returns "hi"
- [x] `run(code: "console.log(1)", env: "node")` returns "1"
- [x] Unknown environment returns helpful error with available options
- [x] Tool description dynamically lists available environments

---

### 2a.2: Project Mounting

#### Config Schema

```toml
[project]
path = "."              # Default: CWD
mount_point = "/project"
# Note: Always read-only for security
```

#### Changes

**File:** `daemon/src/config.rs`

```rust
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProjectConfig {
    #[serde(default = "default_path")]
    pub path: PathBuf,

    #[serde(default)]
    pub mode: MountMode,

    #[serde(default = "default_mount")]
    pub mount_point: String,

    #[serde(default)]
    pub use_flake: bool,

    #[serde(default)]
    pub inherit_env: InheritEnv,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MountMode {
    #[default]
    Readonly,
    Readwrite,
}

fn default_path() -> PathBuf { ".".into() }
fn default_mount() -> String { "/project".into() }
```

**File:** `nix/backends/jail.nix`

Add project mounting combinator:

```nix
mkJailedEnv = {
  name,
  env,
  interpreter,
  stdinMode ? "arg",
  projectPath ? null,
  projectMount ? "/project",
  projectReadonly ? true,
}:
  let
    projectCombs = if projectPath != null then [
      (if projectReadonly
        then (c.readonly projectPath projectMount)
        else (c.rw-bind projectPath projectMount))
    ] else [];

    jailed = jail "sandbox-${name}" runnerScript (c: [
      c.base
      (c.add-pkg-deps [ env ])
      (c.tmpfs "/workspace")
      (c.set-env "HOME" "/workspace")
    ] ++ projectCombs);
  in
    # ...
```

**File:** `nix/lib/fromToml.nix`

Pass project config through to jail wrapper:

```nix
buildEnv = name: envConfig:
  let
    projectPath = if config ? project
      then builtins.toString (builtins.path { path = config.project.path; })
      else null;
    projectReadonly = (config.project.mode or "readonly") == "readonly";
  in
    jailBackend.mkJailedEnv {
      inherit name projectPath projectReadonly;
      # ...
    };
```

#### Success Criteria

- [x] `/project` exists in sandbox when `[project]` configured
- [x] Can read files: `run(code: "cat /project/README.md", env: "bash")`
- [x] Cannot write (always read-only)
- [x] Not mounted when `[project]` absent

---

### 2a.3: User-Specified Flake References

#### Config Schema

```toml
[environments.rust-dev]
flake = "github:oxalica/rust-overlay#default"
interpreter = "bash -s"

[environments.data-science]
flake = "/home/user/envs#python-data"
interpreter = "python3 -c"
```

#### Security Note

> **Flake references come from config only, never from LLM tool parameters.** Flake evaluation executes Nix code—this is safe for user-authored config but would be dangerous if Claude could specify arbitrary flake refs.

#### Changes

**File:** `nix/lib/fromToml.nix`

```nix
buildEnv = name: envConfig:
  let
    baseEnv =
      if envConfig ? preset then
        presets.${envConfig.preset}
      else if envConfig ? flake then
        let
          # Parse "flakeref#attr" format
          parts = builtins.match "([^#]+)#?(.*)" envConfig.flake;
          flakeRef = builtins.elemAt parts 0;
          attrPath = builtins.elemAt parts 1;

          flake = builtins.getFlake flakeRef;

          # Default to packages.${system}.default
          pkg = if attrPath == "" || attrPath == null
            then flake.packages.${pkgs.system}.default
            else let
              # Navigate attribute path
              attrs = builtins.filter (s: s != "") (builtins.split "\\." attrPath);
            in builtins.foldl' (acc: attr: acc.${attr}) flake attrs;
        in pkg
      else
        throw "Environment '${name}' must specify 'preset' or 'flake'";

    # Interpreter: explicit or inferred from preset
    interpreter = envConfig.interpreter or (
      if envConfig ? preset then presetInterpreters.${envConfig.preset}
      else "bash -s"
    );
  in
    # ...
```

#### Success Criteria

- [x] `flake = "github:..."` resolves and builds
- [x] `flake = "/local/path#attr"` works
- [x] Custom `interpreter` respected
- [x] Error message helpful when flake not found

---

### 2a.4: Project Flake Integration

#### Config Schema

```toml
[project]
path = "."
mode = "readonly"
use_flake = true  # Use project's devShell for environment

[project.inherit_env]
vars = ["DATABASE_URL", "API_KEY", "RUST_LOG"]
```

When `use_flake = true`:
- A "project" environment is auto-created from `./flake.nix#devShell`
- Project directory is mounted at `/project`
- Specified env vars are passed through

#### Changes

**File:** `nix/lib/fromToml.nix`

```nix
# Build project environment if use_flake = true
projectEnvironment =
  if (config.project.use_flake or false) then
    let
      projectPath = config.project.path or ".";
      flake = builtins.getFlake (builtins.toString projectPath);

      # Find devShell
      devShell = flake.devShells.${pkgs.system}.default
        or flake.devShell.${pkgs.system}
        or (throw "Project has no devShell in flake.nix");

      # Extract packages from devShell
      packages = devShell.buildInputs or devShell.nativeBuildInputs or [];

      env = pkgs.buildEnv {
        name = "project-devshell";
        paths = packages;
      };

      # Env vars to inherit
      inheritVars = config.project.inherit_env.vars or [];
    in {
      project = {
        drv = jailBackend.mkJailedEnv {
          name = "project";
          inherit env;
          interpreter = "bash -s";
          projectPath = builtins.toString projectPath;
          projectReadonly = (config.project.mode or "readonly") == "readonly";
          inherit inheritVars;
        };
        meta = {
          backend = "jail";
          exec = "...";
          timeout_seconds = config.defaults.timeout_seconds or 30;
          memory_mb = config.defaults.memory_mb or 512;
        };
      };
    }
  else {};

# Merge all environments
allEnvironments =
  (builtins.mapAttrs buildEnv (config.environments or {}))
  // projectEnvironment;
```

**File:** `nix/backends/jail.nix`

Add env var inheritance:

```nix
mkJailedEnv = {
  # ... existing params
  inheritVars ? [],
}:
  let
    # At build time, capture current env vars
    envCombinators = builtins.filter (x: x != null) (
      map (varName:
        let val = builtins.getEnv varName;
        in if val != "" then (c.set-env varName val) else null
      ) inheritVars
    );
  in
    jail "sandbox-${name}" runnerScript (c: [
      # ... base combinators
    ] ++ envCombinators);
```

#### Success Criteria

- [x] `use_flake = true` creates "project" environment
- [x] Project's devShell packages available
- [x] `inherit_env` vars passed into sandbox
- [x] Auto-detection can select "project" env for commands like `cargo`, `make`
- [x] Works with typical Rust/Python/Node project flakes

---

### 2a.5: Dynamic Tool Description

The tool description should reflect the current configuration so Claude knows what's available.

**File:** `daemon/src/mcp.rs`

```rust
fn get_info(&self) -> ServerInfo {
    let envs: Vec<_> = self.config.environments.keys().collect();

    let mut desc = format!(
        "Execute code in isolated Nix sandboxes.\n\
         \n\
         Available environments: {envs:?}\n\
         \n\
         Use 'run' tool with:\n\
         - code: raw code to execute\n\
         - env: one of the available environments\n\
         \n\
         Pass raw code, NOT shell commands (e.g., code=\"print('hi')\" not code=\"python -c 'print(hi)'\")"
    );

    // Add project info if configured
    if let Some(project) = &self.config.project {
        desc.push_str(&format!(
            "\n\nProject directory mounted at {} (read-only).",
            project.mount_point,
        ));

        if project.use_flake {
            desc.push_str("\nProject's devShell available as 'project' environment.");
        }
    }

    ServerInfo {
        instructions: Some(desc),
        // ...
    }
}
```

#### Success Criteria

- [x] Tool description lists available environments
- [x] Mentions `/project` mount when configured
- [x] Mentions "project" environment when `use_flake = true` (Phase 2a.4 required)

---

### 2a.6: Timeout Enforcement

Currently, timeout is in config but not enforced at daemon level.

**File:** `daemon/src/backend/jail.rs`

```rust
pub async fn execute(&self, env: &EnvironmentMeta, code: &str) -> Result<ExecutionResult> {
    let timeout = Duration::from_secs(env.timeout_seconds);

    match tokio::time::timeout(timeout, self.execute_inner(env, code)).await {
        Ok(result) => result,
        Err(_elapsed) => {
            // Process may still be running - it will be killed when dropped
            Err(anyhow::anyhow!(
                "Command timed out after {}s",
                env.timeout_seconds
            ))
        }
    }
}
```

#### Success Criteria

- [x] `run(code: "sleep 999", env: "bash")` times out with clear message
- [x] Timeout configurable per-environment in TOML

---

## Testing

### Update test-local.sh

```bash
# Phase 2a tests

echo "=== Phase 2a: run tool ==="

# Python execution
echo "Test: Python code execution"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"code":"print(1+1)","env":"python"}}}
EOF
)
assert_contains "$response" "2" "Python execution"

# Project mounting
echo "Test: Project mounted"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"code":"ls /project","env":"bash"}}}
EOF
)
assert_contains "$response" "README" "Project mounted"

# Timeout
echo "Test: Timeout enforcement"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"code":"sleep 999","env":"bash"}}}
EOF
)
assert_contains "$response" "timeout" "Timeout works"
```

### Manual Testing

```
[ ] Basic run() works with code + env params
[ ] Project files visible at /project
[ ] Cannot write to /project (read-only)
[ ] Custom flake environment works
[ ] Project flake devShell works
[ ] Timeout kills long commands
[ ] Works end-to-end with Claude Code
[ ] LLM sends raw code (not shell invocations like "python -c ...")
```

---

## File Summary

| File | Action | Description |
|------|--------|-------------|
| `daemon/src/mcp.rs` | Modify | New `run` tool (replaces execute), dynamic description |
| `daemon/src/config.rs` | Modify | Project config, mount mode |
| `daemon/src/backend/jail.rs` | Modify | Timeout error message improvement |
| `nix/backends/jail.nix` | Modify | Project mounting, env inheritance |
| `nix/lib/fromToml.nix` | Modify | Flake refs, project env |
| `config.example.toml` | Modify | New project section |
| `test-local.sh` | Modify | Phase 2a tests |

Note: No `detect.rs` needed - environment selection is Claude's responsibility via required parameter.

---

## Migration

**Tool change:** `execute` → `run`

```json
// Before (Phase 1)
{"name": "execute", "arguments": {"environment": "python", "code": "print(1)"}}

// After (Phase 2a)
{"name": "run", "arguments": {"code": "print(1)", "env": "python"}}
```

**Parameter changes:**
- `command` → `code` (clearer that it's code to execute, not a shell command)
- `environment` → `env` (shorter, same meaning)
- `shell` → `bash` (more specific interpreter name)

**Config additions:**
```toml
[project]
path = "."
use_flake = true

[project.inherit_env]
vars = ["DATABASE_URL"]

[environments.bash]
preset = "shell"  # renamed from [environments.shell]

[environments.custom]
flake = "github:owner/repo#attr"
```

---

## Next: Phase 2b

After Phase 2a ships, spike the IPC agent approach for session persistence. See `2026-02-02-phase2b-sessions-spike.md`.

---

## References

### MCP & Tool Design
- MCP Specification 2025-11-25: https://modelcontextprotocol.io/specification/2025-11-25
- MCP Tool Annotations: https://blog.marcnuri.com/mcp-tool-annotations-introduction
- MCP Server Best Practices: https://thenewstack.io/15-best-practices-for-building-mcp-servers-in-production/
- MCP Security Best Practices: https://www.stackhawk.com/blog/mcp-server-security-best-practices/

### Agentic Workflows
- AGENTS.md Standard: https://agents.md/ - Project context for AI agents (60K+ projects)
- Claude Code Best Practices: https://www.anthropic.com/engineering/claude-code-best-practices
- OpenAI Agents SDK: https://openai.github.io/openai-agents-python/
- NVIDIA Sandboxing Guidance: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk

### AI Sandboxing Platforms
- E2B: https://e2b.dev/ - Firecracker microVMs, template system
- Modal: https://modal.com/ - gVisor, Python-first ML focus
- Daytona: https://www.daytona.io/ - Sub-90ms startup
- Top Code Sandbox Products: https://modal.com/blog/top-code-agent-sandbox-products

### Nix Ecosystem
- jail.nix: https://git.sr.ht/~alexdavid/jail.nix - Bubblewrap jail library
- MCP-NixOS: https://github.com/utensils/mcp-nixos - Nix ecosystem MCP server
- Nix Flakes: https://zero-to-nix.com/concepts/flakes - Hermetic builds

### Security
- Shell Command Patterns: https://github.com/tumf/mcp-shell-server - Whitelist-based execution
- Error Handling in MCP: https://mcpcat.io/guides/error-handling-custom-mcp-servers/
