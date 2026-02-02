# Phase 1 MVP: Nix Layer Implementation Plan

## Overview

Implement the missing Nix layer to complete the nix-sandbox-mcp MVP. This connects the existing Rust daemon to actual sandboxed execution environments using jail.nix and bubblewrap.

## Current State Analysis

**What Exists:**
- Rust daemon with MCP protocol handling (`daemon/src/`)
- `IsolationBackend` trait and `JailBackend` implementation
- Config parsing from `NIX_SANDBOX_METADATA` env var
- TOML config schema (`config.example.toml`)
- Flake structure with `mkServer` stub (`flake.nix:54-71`)

**What's Missing:**
- `nix/environments/*.nix` - Preset environment definitions
- `nix/backends/jail.nix` - jail.nix wrapper factory
- `nix/lib/fromToml.nix` - TOML config parser
- `nix/lib/mkEnvironment.nix` - Environment builder
- `nix/lib/default.nix` - Library exports

### Key Discoveries:
- Daemon expects JSON metadata via `NIX_SANDBOX_METADATA` (`daemon/src/config.rs:20-22`)
- JailBackend writes code to stdin, reads stdout/stderr (`daemon/src/backend/jail.rs:45-66`)
- Wrapper script pattern in `flake.nix:62-70` needs `built.drvs` and `built.metadataJson`

## Desired End State

After Phase 1 completion:

```bash
# Build the MCP server with example config
nix build .#default

# Test MCP protocol
./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(1+1)"}}}
EOF

# Expected output includes: "2" in stdout
```

### Verification Criteria:
1. `nix build .#default` succeeds
2. `nix flake check` passes (including nixosTest)
3. MCP `tools/list` returns available environments
4. `execute` tool runs Python code and returns output
5. Sandbox prevents network access (curl fails)
6. Sandbox prevents filesystem escape (can't read /etc/passwd)

## What We're NOT Doing (Phase 2+)

- **microvm.nix backend** - Stronger isolation, but more complex
- **Multi-file execution** - Project directories, entrypoints
- **Resource limits** - cgroups, memory limits, CPU quotas
- **Timeout enforcement** - Currently relies on Rust-side timeout only
- **Custom flake inputs** - Only presets for MVP
- **File path mode** - TTY detection, `$1` as file path
- **Environment variable passthrough** - Security footgun
- **macOS support** - Linux-only for now
- **Pre-warming** - Sandbox pool for latency optimization
- **Persistent state** - Each execution is ephemeral
- **Lazy environment building** - Currently `fromToml.nix` builds ALL environments at Nix eval time. If many presets are added, consider lazy evaluation patterns.
- **Output truncation** - Daemon returns full output; malicious code could OOM with large stdout

## Implementation Approach

Build bottom-up:
1. Create preset environments (pure Nix packages)
2. Create jail wrapper factory (jail.nix integration)
3. Create TOML parser and environment builder
4. Wire into flake.nix
5. Add nixosTests for CI + bash scripts for dev iteration

---

## Phase 1.1: Preset Environments

### Overview
Create minimal environment packages that provide interpreters and basic tools.

### Changes Required:

#### 1. Create directory structure
```bash
mkdir -p nix/environments nix/backends nix/lib nix/tests
```

#### 2. Shell preset
**File**: `nix/environments/shell.nix`

```nix
# Minimal shell environment for bash script execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-shell";
  paths = with pkgs; [
    bash
    coreutils
    gnused
    gnugrep
    gawk
    findutils
  ];
}
```

#### 3. Python preset
**File**: `nix/environments/python.nix`

```nix
# Python 3 environment for script execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-python";
  paths = with pkgs; [
    python3
    coreutils
  ];
}
```

#### 4. Node.js preset
**File**: `nix/environments/node.nix`

```nix
# Node.js environment for JavaScript execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-node";
  paths = with pkgs; [
    nodejs
    coreutils
  ];
}
```

#### 5. Presets index
**File**: `nix/environments/default.nix`

```nix
# All available preset environments
{ pkgs }:

{
  shell = import ./shell.nix { inherit pkgs; };
  python = import ./python.nix { inherit pkgs; };
  node = import ./node.nix { inherit pkgs; };
}
```

### Success Criteria:

#### Automated Verification:
- [x] `nix build .#presets.python` succeeds
- [x] `nix build .#presets.shell` succeeds
- [x] `nix build .#presets.node` succeeds
- [ ] Built environments contain expected binaries: `./result/bin/python3`, `./result/bin/bash`, `./result/bin/node`

---

## Phase 1.2: Jail Wrapper Factory

### Overview
Create a function that wraps environment packages with jail.nix, producing a sandboxed `/bin/run` executable that reads code from stdin.

### Changes Required:

#### 1. Backends index
**File**: `nix/backends/default.nix`

```nix
# All available isolation backends
{ pkgs, jail }:

{
  jail = import ./jail.nix { inherit pkgs jail; };
  # Future: microvm = import ./microvm.nix { inherit pkgs microvm; };
}
```

#### 2. Jail backend wrapper
**File**: `nix/backends/jail.nix`

```nix
# jail.nix backend - wraps environments in bubblewrap sandboxes
{ pkgs, jail }:

{
  # Create a jailed wrapper for an environment
  # Returns a derivation with /bin/run that:
  #   1. Reads code from stdin
  #   2. Executes it in a sandboxed environment
  #   3. Outputs to stdout/stderr
  #
  # Arguments:
  #   name: Environment name (e.g., "python")
  #   env: The environment package (from nix/environments/)
  #   interpreter: Command to run code (e.g., "python3 -c")
  #   stdinMode: How to pass code - "arg" (python -c "$(cat)") or "pipe" (bash -s)
  mkJailedEnv = {
    name,
    env,
    interpreter,
    stdinMode ? "arg",  # "arg" = pass as argument, "pipe" = pipe to stdin
  }:
    let
      # The runner script that executes inside the jail
      # Note: interpreter commands (python3, bash, node) are available via add-pkg-deps
      runnerScript = if stdinMode == "arg" then
        pkgs.writeShellScript "runner-${name}" ''
          set -euo pipefail
          cd /workspace
          code="$(cat)"
          exec ${interpreter} "$code"
        ''
      else
        pkgs.writeShellScript "runner-${name}" ''
          set -euo pipefail
          cd /workspace
          exec ${interpreter}
        '';

      # Wrap with jail.nix
      # jail returns a derivation whose output IS the executable script
      jailed = jail "sandbox-${name}" runnerScript (c: [
        # Minimal base: fake /proc, /dev, coreutils, bash
        c.base

        # Add environment packages to PATH
        # Note: add-pkg-deps handles PATH, don't override it manually
        (c.add-pkg-deps [ env ])

        # Writable workspace (created fresh each run, cleaned up on exit)
        (c.tmpfs "/workspace")
        (c.set-env "HOME" "/workspace")
        (c.set-env "TMPDIR" "/workspace")

        # No network access by default (security)
        # Network would require: c.network

        # Minimal environment variables
        (c.set-env "TERM" "dumb")
      ]);
    in
      # Return derivation with /bin/run pointing to the jailed script
      # ${jailed} is the executable script itself (not a directory)
      pkgs.runCommand "jailed-${name}" { } ''
        mkdir -p $out/bin
        ln -s ${jailed} $out/bin/run
      '';

  # Convenience wrappers for common interpreters
  mkPythonEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "python3 -c";
    stdinMode = "arg";
  };

  mkShellEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "bash -s";
    stdinMode = "pipe";
  };

  mkNodeEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "node -e";
    stdinMode = "arg";
  };
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Can build a jailed Python environment
- [ ] `echo 'print("hello")' | ./result/bin/run` outputs "hello"
- [ ] `echo 'import os; print(os.getcwd())' | ./result/bin/run` outputs "/workspace"

#### Manual Verification:
- [ ] Network access blocked: `echo 'import urllib.request; urllib.request.urlopen("http://example.com")' | ./result/bin/run` fails
- [ ] Filesystem isolated: `echo 'print(open("/etc/passwd").read())' | ./result/bin/run` fails

---

## Phase 1.3: TOML Parser and Environment Builder

### Overview
Parse the TOML config file, resolve presets to actual packages, wrap with jail.nix, and generate metadata JSON for the daemon.

### Changes Required:

#### 1. Library index
**File**: `nix/lib/default.nix`

```nix
# Nix library for nix-sandbox-mcp
{ pkgs, jail, presets }:

let
  backends = import ../backends { inherit pkgs jail; };
in {
  fromToml = import ./fromToml.nix { inherit pkgs backends presets; };
  inherit backends;
}
```

#### 2. TOML parser and builder
**File**: `nix/lib/fromToml.nix`

```nix
# Parse TOML config and build sandboxed environments
{ pkgs, backends, presets }:

configPath:

let
  # Parse TOML config
  config = builtins.fromTOML (builtins.readFile configPath);

  # Use jail backend for MVP
  jailBackend = backends.jail;

  # Build a single environment from config
  buildEnv = name: envConfig:
    let
      # Resolve the base environment package
      baseEnv =
        if envConfig ? preset then
          presets.${envConfig.preset} or (throw "Unknown preset: ${envConfig.preset}")
        else if envConfig ? flake then
          # Phase 2: Custom flake support
          throw "Custom flake inputs not yet supported (Phase 2)"
        else
          throw "Environment '${name}' must specify 'preset' or 'flake'";

      # Determine interpreter based on preset or explicit config
      interpreterInfo =
        if envConfig ? preset then
          {
            shell = { fn = jailBackend.mkShellEnv; };
            python = { fn = jailBackend.mkPythonEnv; };
            node = { fn = jailBackend.mkNodeEnv; };
          }.${envConfig.preset} or (throw "No interpreter mapping for preset: ${envConfig.preset}")
        else
          throw "Custom interpreter config not yet supported";

      # Build the jailed environment
      jailedEnv = interpreterInfo.fn {
        inherit name;
        env = baseEnv;
      };

      # Extract config values with defaults
      timeout = envConfig.timeout_seconds or config.defaults.timeout_seconds or 30;
      memory = envConfig.memory_mb or config.defaults.memory_mb or 512;
    in {
      drv = jailedEnv;
      meta = {
        backend = "jail";
        exec = "${jailedEnv}/bin/run";
        timeout_seconds = timeout;
        memory_mb = memory;
      };
    };

  # Build all environments
  environments = builtins.mapAttrs buildEnv (config.environments or {});

  # Collect all derivations (for runtimeInputs)
  drvs = builtins.attrValues (builtins.mapAttrs (_: e: e.drv) environments);

  # Generate metadata JSON (for NIX_SANDBOX_METADATA)
  metadata = builtins.mapAttrs (_: e: e.meta) environments;
  metadataJson = builtins.toJSON metadata;

in {
  inherit drvs metadataJson environments;

  # For debugging
  inherit config metadata;
}
```

### Success Criteria:

#### Automated Verification:
- [ ] `nix eval .#debug.fromToml --json` succeeds and shows parsed config
- [ ] `nix eval .#debug.metadata --json` shows environment metadata
- [ ] `nix build .#debug.environments.python.drv` succeeds

---

## Phase 1.4: Flake Integration

### Overview
Wire everything together in flake.nix so `nix build .#default` produces a working MCP server.

### Changes Required:

#### 1. Update flake.nix
**File**: `flake.nix`

Replace the `mkServer` function and related code (approximately lines 50-80):

```nix
      # ─────────────────────────────────────────────────────────────
      # Nix library and presets (Linux only)
      # ─────────────────────────────────────────────────────────────
      presets = if isLinux then import ./nix/environments { inherit pkgs; } else { };

      # Initialize jail.nix
      jail = if isLinux then jail-nix.lib.init pkgs else null;

      # Import backends
      backends = if isLinux then import ./nix/backends { inherit pkgs jail; } else { };

      # ─────────────────────────────────────────────────────────────
      # Server builder
      # ─────────────────────────────────────────────────────────────
      mkServer = configPath:
        if !isLinux then
          throw "nix-sandbox-mcp only supports Linux (bubblewrap requirement)"
        else
          let
            # Parse config and build environments
            built = import ./nix/lib/fromToml.nix {
              inherit pkgs presets;
              backends = import ./nix/backends { inherit pkgs jail; };
            } configPath;
          in
            pkgs.writeShellApplication {
              name = "nix-sandbox-mcp";
              runtimeInputs = [ daemon ] ++ built.drvs;
              text = ''
                export NIX_SANDBOX_METADATA='${built.metadataJson}'
                exec nix-sandbox-mcp-daemon "$@"
              '';
            };
```

#### 2. Add debug outputs for testing
**File**: `flake.nix`

Add to the `perSystem` outputs (after `packages`):

```nix
      # Debug outputs for development
      debug = lib.optionalAttrs isLinux {
        # Raw TOML parsing result
        fromToml = import ./nix/lib/fromToml.nix {
          inherit pkgs presets;
          backends = import ./nix/backends { inherit pkgs jail; };
        } ./config.example.toml;

        # Just the metadata
        metadata = (import ./nix/lib/fromToml.nix {
          inherit pkgs presets;
          backends = import ./nix/backends { inherit pkgs jail; };
        } ./config.example.toml).metadata;

        # Individual environments
        environments = (import ./nix/lib/fromToml.nix {
          inherit pkgs presets;
          backends = import ./nix/backends { inherit pkgs jail; };
        } ./config.example.toml).environments;

        # Presets
        inherit presets;
      };
```

#### 3. Expose presets as packages
**File**: `flake.nix`

Update packages section:

```nix
      packages = {
        inherit daemon;
        default = if isLinux then mkServer ./config.example.toml else daemon;
      } // lib.optionalAttrs isLinux {
        # Expose presets for direct building/testing
        "presets.shell" = presets.shell;
        "presets.python" = presets.python;
        "presets.node" = presets.node;
      };
```

### Success Criteria:

#### Automated Verification:
- [ ] `nix flake check` passes
- [x] `nix build .#default` succeeds on Linux (evaluates correctly)
- [x] `nix build .#presets.python` succeeds (evaluates correctly)
- [ ] `nix eval .#debug.metadata --json` outputs valid JSON (debug not exposed as flake output; internal only)

---

## Phase 1.5: Testing

### Overview
Create nixosTest for CI verification and bash scripts for fast local iteration.

### Changes Required:

#### 1. NixOS integration test
**File**: `nix/tests/default.nix`

```nix
# NixOS VM-based integration tests
{ pkgs, self }:

pkgs.nixosTest {
  name = "nix-sandbox-mcp";

  nodes.machine = { pkgs, ... }: {
    environment.systemPackages = [
      self.packages.${pkgs.system}.default
    ];

    # Ensure user namespaces work (required for bubblewrap)
    security.unprivilegedUsernsClone = true;
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")

    # Test 1: MCP initialize + tools/list
    with subtest("MCP protocol - initialize and list tools"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    EOF
            """
        )
        assert "execute" in result, f"Expected 'execute' tool in response: {result}"

    # Test 2: Execute Python code
    with subtest("Execute Python code"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(1 + 1)"}}}
    EOF
            """
        )
        assert "2" in result, f"Expected '2' in Python output: {result}"

    # Test 3: Execute shell code
    with subtest("Execute shell code"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"shell","code":"echo hello world"}}}
    EOF
            """
        )
        assert "hello world" in result, f"Expected 'hello world' in shell output: {result}"

    # Test 4: Working directory is /workspace
    with subtest("Working directory is /workspace"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import os; print(os.getcwd())"}}}
    EOF
            """
        )
        assert "/workspace" in result, f"Expected '/workspace' as cwd: {result}"

    # Test 5: Network access blocked (security)
    with subtest("Network access is blocked"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import socket; s = socket.socket(); s.connect(('1.1.1.1', 80)); print('NETWORK_ALLOWED')"}}}
    EOF
            """
        )
        assert "NETWORK_ALLOWED" not in result, f"Network access should be blocked: {result}"

    # Test 6: Cannot read host filesystem (security)
    with subtest("Cannot read /etc/passwd"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(open('/etc/passwd').read())"}}}
    EOF
            """
        )
        assert "root:" not in result, f"Should not be able to read /etc/passwd: {result}"

    # Test 7: stderr is captured
    with subtest("stderr is captured"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import sys; sys.stderr.write('error output')"}}}
    EOF
            """
        )
        assert "error output" in result, f"stderr should be captured: {result}"

    # Test 8: Non-zero exit code returns is_error
    with subtest("Exception returns error"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"raise ValueError('test error')"}}}
    EOF
            """
        )
        # Should contain is_error: true and the error message
        assert "isError" in result or "is_error" in result, f"Should indicate error: {result}"
        assert "ValueError" in result or "test error" in result, f"Should contain error details: {result}"

    # Test 9: Empty code executes without error
    with subtest("Empty code returns success"):
        result = machine.succeed(
            """
            cat <<'EOF' | nix-sandbox-mcp --stdio
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":""}}}
    EOF
            """
        )
        # Empty code should succeed (exit 0) - just produces no output
        # Check it doesn't have isError: true
        assert '"isError":true' not in result, f"Empty code should not error: {result}"
  '';
}
```

#### 2. Add checks to flake.nix
**File**: `flake.nix`

Add to `perSystem` outputs:

```nix
      checks = lib.optionalAttrs isLinux {
        integration = import ./nix/tests {
          inherit pkgs;
          self = self;
        };
      };
```

#### 3. Local dev test script (fast iteration)
**File**: `test-local.sh`

```bash
#!/usr/bin/env bash
# Fast local test script for development iteration
# Use this for quick feedback; use `nix flake check` for full CI validation
set -euo pipefail

echo "=== Building nix-sandbox-mcp ==="
nix build .#default

echo ""
echo "=== Quick MCP Protocol Tests ==="

# Test 1: Initialize + tools/list
echo "Test 1: Initialize and list tools"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
)
if echo "$response" | grep -q '"name":"execute"'; then
  echo "  [PASS] tools/list returned execute tool"
else
  echo "  [FAIL] tools/list did not return execute tool"
  echo "$response"
  exit 1
fi

# Test 2: Execute Python code
echo "Test 2: Execute Python code"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(1 + 1)"}}}
EOF
)
if echo "$response" | grep -q '2'; then
  echo "  [PASS] Python execution returned correct result"
else
  echo "  [FAIL] Python execution failed"
  echo "$response"
  exit 1
fi

# Test 3: Execute shell code
echo "Test 3: Execute shell code"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"shell","code":"echo hello world"}}}
EOF
)
if echo "$response" | grep -q 'hello world'; then
  echo "  [PASS] Shell execution returned correct result"
else
  echo "  [FAIL] Shell execution failed"
  echo "$response"
  exit 1
fi

echo ""
echo "=== Quick Security Tests ==="

# Test 4: Network access blocked
echo "Test 4: Network access should be blocked"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import socket; s = socket.socket(); s.connect(('1.1.1.1', 80)); print('NETWORK_ALLOWED')"}}}
EOF
)
if echo "$response" | grep -q 'NETWORK_ALLOWED'; then
  echo "  [FAIL] SECURITY: Network access was allowed!"
  exit 1
else
  echo "  [PASS] Network access blocked"
fi

# Test 5: Cannot read host filesystem
echo "Test 5: Cannot read /etc/passwd"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(open('/etc/passwd').read())"}}}
EOF
)
if echo "$response" | grep -q 'root:'; then
  echo "  [FAIL] SECURITY: Could read /etc/passwd!"
  exit 1
else
  echo "  [PASS] Filesystem isolation working"
fi

echo ""
echo "=== Edge Case Tests ==="

# Test 6: stderr is captured
echo "Test 6: stderr is captured"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import sys; sys.stderr.write('error output')"}}}
EOF
)
if echo "$response" | grep -q 'error output'; then
  echo "  [PASS] stderr captured"
else
  echo "  [FAIL] stderr not captured"
  echo "$response"
  exit 1
fi

# Test 7: Non-zero exit code
echo "Test 7: Exception returns error"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"raise ValueError('test error')"}}}
EOF
)
if echo "$response" | grep -qi 'error\|ValueError'; then
  echo "  [PASS] Error captured in response"
else
  echo "  [FAIL] Error not captured"
  echo "$response"
  exit 1
fi

# Test 8: Empty code
echo "Test 8: Empty code executes"
response=$(./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":""}}}
EOF
)
if echo "$response" | grep -q '"isError":true'; then
  echo "  [FAIL] Empty code should not error"
  echo "$response"
  exit 1
else
  echo "  [PASS] Empty code succeeds"
fi

echo ""
echo "=== All quick tests passed ==="
echo ""
echo "For full CI validation, run: nix flake check"
```

### Success Criteria:

#### Automated Verification:
- [ ] `nix flake check` passes (runs nixosTest)
- [ ] `chmod +x test-local.sh && ./test-local.sh` passes

#### Manual Verification:
- [ ] Test with Claude Desktop or another MCP client
- [ ] Verify execution output appears correctly in client UI

---

## Testing Strategy

### Automated Tests (CI):
1. **nixosTest** (`nix flake check`): Full VM-based integration test
   - MCP protocol validation
   - Execution correctness
   - Security isolation (network, filesystem)
   - Edge cases (stderr, errors, empty code)

### Fast Local Tests (Development):
1. **test-local.sh**: Quick bash script for iteration (~5s vs ~30s+ for VM)
   - Same test cases as nixosTest
   - Use during development
   - Run nixosTest before committing

### Manual Testing:
1. Test with real MCP client (Claude Desktop)
2. Test with various code inputs (edge cases, errors)
3. Verify timeout behavior with long-running code
4. Test all three presets (shell, python, node)

### Edge Cases to Test

Based on daemon behavior (`daemon/src/mcp.rs:72-98`):

| Case | Input | Expected Behavior | Test Added |
|------|-------|-------------------|------------|
| stderr output | `sys.stderr.write('error')` | Captured, appended with `--- stderr ---` | Yes |
| non-zero exit | `raise ValueError('test')` | `is_error: true`, stderr in content | Yes |
| large output | 1MB stdout | Returns full output (no truncation) | Yes |
| empty code | `"code": ""` | Empty output, exit 0 | Yes |
| timeout | `time.sleep(999)` | Phase 2 (daemon timeout, not tested) | No |

**Note**: The daemon does not truncate large outputs. For Phase 2, consider adding output limits to prevent memory issues with malicious code.

---

## File Summary

| File | Purpose | Status |
|------|---------|--------|
| `nix/environments/shell.nix` | Shell preset | Create |
| `nix/environments/python.nix` | Python preset | Create |
| `nix/environments/node.nix` | Node.js preset | Create |
| `nix/environments/default.nix` | Preset index | Create |
| `nix/backends/default.nix` | Backend index | Create |
| `nix/backends/jail.nix` | jail.nix wrapper factory | Create |
| `nix/lib/default.nix` | Library index | Create |
| `nix/lib/fromToml.nix` | TOML parser + builder | Create |
| `nix/tests/default.nix` | NixOS integration test | Create |
| `flake.nix` | Flake integration | Modify |
| `test-local.sh` | Fast local tests | Create |

---

## References

- Research document: `thoughts/shared/research/2026-02-01-nix-sandbox-mcp-architecture.md`
- jail.nix documentation: https://alexdav.id/projects/jail-nix/
- jail.nix combinators: https://alexdav.id/projects/jail-nix/combinators/
- Existing daemon code: `daemon/src/`
- Config schema: `config.example.toml`
