# NixOS VM-based integration tests
{ pkgs, mcpServer }:

pkgs.testers.nixosTest {
  name = "nix-sandbox-mcp";

  nodes.machine = { pkgs, ... }: {
    environment.systemPackages = [
      mcpServer
      pkgs.python3
    ];

    # Ensure user namespaces work (required for bubblewrap)
    security.unprivilegedUsernsClone = true;
  };

  testScript = ''
def mcp_call(code: str) -> str:
    """Send MCP request and return response."""
    return machine.succeed(f"""
        ( cat <<'MCPEOF'
{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2024-11-05","capabilities":{{}},"clientInfo":{{"name":"test","version":"1.0"}}}}}}
{{"jsonrpc":"2.0","method":"notifications/initialized"}}
{code}
MCPEOF
        sleep 0.2 ) | nix-sandbox-mcp --stdio 2>/dev/null
    """)


machine.wait_for_unit("multi-user.target")

# Test 1: MCP initialize + tools/list
with subtest("MCP protocol - initialize and list tools"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    assert "run" in result, f"Expected 'run' tool in response: {result}"

# Test 2: Run Python code
with subtest("Run Python code"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"print(1 + 1)"}}}')
    assert "2" in result, f"Expected '2' in Python output: {result}"

# Test 3: Run shell code
with subtest("Run shell code"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"shell","code":"echo hello world"}}}')
    assert "hello world" in result, f"Expected 'hello world' in shell output: {result}"

# Test 4: Working directory is /workspace
with subtest("Working directory is /workspace"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"import os; print(os.getcwd())"}}}')
    assert "/workspace" in result, f"Expected '/workspace' as cwd: {result}"

# Test 5: Network access blocked (security)
with subtest("Network access is blocked"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"import socket; s = socket.socket(); s.connect((chr(49)+chr(46)+chr(49)+chr(46)+chr(49)+chr(46)+chr(49), 80)); print(chr(78)+chr(69)+chr(84)+chr(87)+chr(79)+chr(82)+chr(75)+chr(95)+chr(79)+chr(75))"}}}')
    # Check for network error (blocked) rather than success
    assert "Network is unreachable" in result or "Connection refused" in result or "Errno" in result, f"Network access should be blocked: {result}"

# Test 6: Filesystem isolation (security)
# Note: jail.nix creates a synthetic /etc/passwd with only root and current user
with subtest("Filesystem isolation - synthetic passwd"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"print(len(open(chr(47)+chr(101)+chr(116)+chr(99)+chr(47)+chr(112)+chr(97)+chr(115)+chr(115)+chr(119)+chr(100)).readlines()))"}}}')
    # Real passwd has many users (20+), synthetic jail passwd has only 2-3
    # Output includes trailing newline so check for "2\n" or "3\n"
    assert ':"2\\n"' in result or ':"3\\n"' in result, f"Should see synthetic passwd with ~2 entries: {result}"

# Test 7: stderr is captured
with subtest("stderr is captured"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"import sys; sys.stderr.write(chr(101)+chr(114)+chr(114)+chr(111)+chr(114)+chr(32)+chr(111)+chr(117)+chr(116)+chr(112)+chr(117)+chr(116))"}}}')
    assert "error output" in result, f"stderr should be captured: {result}"

# Test 8: Non-zero exit code returns is_error
with subtest("Exception returns error"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"raise ValueError(chr(116)+chr(101)+chr(115)+chr(116)+chr(32)+chr(101)+chr(114)+chr(114)+chr(111)+chr(114))"}}}')
    assert "isError" in result or "is_error" in result, f"Should indicate error: {result}"
    assert "ValueError" in result or "test error" in result, f"Should contain error details: {result}"

# Test 9: Empty command executes without error
with subtest("Empty command returns success"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":""}}}')
    assert '"isError":true' not in result, f"Empty command should not error: {result}"


# ─────────────────────────────────────────────────────────────────
# Session persistence tests
# ─────────────────────────────────────────────────────────────────

import json

# Deploy request-response helper script into the VM.
# This does proper sequential MCP communication: send request, readline()
# for response, send next. No sleep delays, no out-of-order races.
machine.succeed("""cat > /tmp/mcp_session.py <<'PYEOF'
import subprocess, json, sys

calls = json.loads(sys.stdin.read())
proc = subprocess.Popen(
    ['nix-sandbox-mcp', '--stdio'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
)

def send(msg):
    proc.stdin.write((json.dumps(msg) + chr(10)).encode())
    proc.stdin.flush()

def recv():
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        try:
            return json.loads(line.decode())
        except (json.JSONDecodeError, ValueError):
            continue

# MCP handshake
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}})
recv()
send({"jsonrpc":"2.0","method":"notifications/initialized"})

# Sequential tool calls: send request, wait for response, repeat
results = {}
for i, call in enumerate(calls, start=2):
    send({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":"run","arguments":call}})
    resp = recv()
    if resp and "id" in resp:
        results[str(resp["id"])] = json.dumps(resp)

proc.stdin.close()
try:
    proc.wait(timeout=10)
except Exception:
    proc.kill()

print(json.dumps(results))
PYEOF
""")

def mcp_session(*tool_calls) -> dict:
    """Send tool calls sequentially with proper request-response sync.

    Uses a helper script that manages a subprocess: send one request,
    readline() the response, send next. This mirrors real MCP client
    behavior — zero delays, deterministic ordering.

    Returns dict mapping JSON-RPC id (int) to response JSON string.
    Tool call ids start at 2 (id 1 is the initialize handshake).
    """
    calls_json = json.dumps(list(tool_calls))
    # Write calls to file to avoid shell quoting issues
    machine.succeed(f"""
        cat > /tmp/mcp_calls.json <<'JSONEOF'
{calls_json}
JSONEOF
    """)
    raw = machine.succeed("python3 /tmp/mcp_session.py < /tmp/mcp_calls.json")
    # Convert string keys back to ints for clean test assertions
    parsed = json.loads(raw.strip())
    return {int(k): v for k, v in parsed.items()}


# Test 10: Python state persists across session calls
with subtest("Session state persists - Python"):
    resps = mcp_session(
        {"env": "python", "code": "x = 42", "session": "pytest1"},
        {"env": "python", "code": "print(x)", "session": "pytest1"},
    )
    # id:3 is print(x) — match by id, not response order
    assert "42" in resps.get(3, ""), f"Expected '42' from session state: {resps}"


# Test 11: Different sessions are isolated
with subtest("Different sessions are isolated"):
    resps = mcp_session(
        {"env": "python", "code": "y = 99", "session": "iso_a"},
        {"env": "python", "code": "print(y)", "session": "iso_a"},
        {"env": "python", "code": "print(y)", "session": "iso_b"},
    )
    # id:3 (iso_a print) should have 99, id:4 (iso_b print) should have NameError
    assert "99" in resps.get(3, ""), f"Expected '99' from iso_a: {resps}"
    assert "NameError" in resps.get(4, ""), f"Expected NameError from iso_b: {resps}"


# Test 12: Shell env vars persist in session
with subtest("Shell session persists env vars"):
    resps = mcp_session(
        {"env": "shell", "code": "export MY_VAR=hello_sessions", "session": "shtest1"},
        {"env": "shell", "code": "echo $MY_VAR", "session": "shtest1"},
    )
    assert "hello_sessions" in resps.get(3, ""), f"Expected 'hello_sessions': {resps}"


# Test 13: /workspace files persist within session
with subtest("Workspace files persist in session"):
    resps = mcp_session(
        {"env": "python", "code": "open('/workspace/test.txt', 'w').write('persisted')", "session": "wstest"},
        {"env": "python", "code": "print(open('/workspace/test.txt').read())", "session": "wstest"},
    )
    assert "persisted" in resps.get(3, ""), f"Expected 'persisted': {resps}"


# Test 14: Ephemeral execution still works without session param
with subtest("Ephemeral execution without session"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"env":"python","code":"print(123)"}}}')
    assert "123" in result, f"Expected '123' from ephemeral execution: {result}"


# Test 15: Env mismatch returns clear error
with subtest("Session env mismatch returns error"):
    resps = mcp_session(
        {"env": "python", "code": "x = 1", "session": "envmix"},
        {"env": "shell", "code": "echo hi", "session": "envmix"},
    )
    # id:3 (shell on python-bound session) should get env mismatch error
    r3 = resps.get(3, "")
    assert "bound to environment" in r3 or "not" in r3, f"Expected env mismatch error: {resps}"
  '';
}
