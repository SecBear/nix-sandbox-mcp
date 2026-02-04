# NixOS VM-based integration tests
{ pkgs, mcpServer }:

pkgs.testers.nixosTest {
  name = "nix-sandbox-mcp";

  nodes.machine = { pkgs, ... }: {
    environment.systemPackages = [
      mcpServer
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
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"print(1 + 1)"}}}')
    assert "2" in result, f"Expected '2' in Python output: {result}"

# Test 3: Run shell code
with subtest("Run shell code"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"shell","command":"echo hello world"}}}')
    assert "hello world" in result, f"Expected 'hello world' in shell output: {result}"

# Test 4: Working directory is /workspace
with subtest("Working directory is /workspace"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"import os; print(os.getcwd())"}}}')
    assert "/workspace" in result, f"Expected '/workspace' as cwd: {result}"

# Test 5: Network access blocked (security)
with subtest("Network access is blocked"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"import socket; s = socket.socket(); s.connect((chr(49)+chr(46)+chr(49)+chr(46)+chr(49)+chr(46)+chr(49), 80)); print(chr(78)+chr(69)+chr(84)+chr(87)+chr(79)+chr(82)+chr(75)+chr(95)+chr(79)+chr(75))"}}}')
    # Check for network error (blocked) rather than success
    assert "Network is unreachable" in result or "Connection refused" in result or "Errno" in result, f"Network access should be blocked: {result}"

# Test 6: Filesystem isolation (security)
# Note: jail.nix creates a synthetic /etc/passwd with only root and current user
with subtest("Filesystem isolation - synthetic passwd"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"print(len(open(chr(47)+chr(101)+chr(116)+chr(99)+chr(47)+chr(112)+chr(97)+chr(115)+chr(115)+chr(119)+chr(100)).readlines()))"}}}')
    # Real passwd has many users (20+), synthetic jail passwd has only 2-3
    # Output includes trailing newline so check for "2\n" or "3\n"
    assert ':"2\\n"' in result or ':"3\\n"' in result, f"Should see synthetic passwd with ~2 entries: {result}"

# Test 7: stderr is captured
with subtest("stderr is captured"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"import sys; sys.stderr.write(chr(101)+chr(114)+chr(114)+chr(111)+chr(114)+chr(32)+chr(111)+chr(117)+chr(116)+chr(112)+chr(117)+chr(116))"}}}')
    assert "error output" in result, f"stderr should be captured: {result}"

# Test 8: Non-zero exit code returns is_error
with subtest("Exception returns error"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":"raise ValueError(chr(116)+chr(101)+chr(115)+chr(116)+chr(32)+chr(101)+chr(114)+chr(114)+chr(111)+chr(114))"}}}')
    assert "isError" in result or "is_error" in result, f"Should indicate error: {result}"
    assert "ValueError" in result or "test error" in result, f"Should contain error details: {result}"

# Test 9: Empty command executes without error
with subtest("Empty command returns success"):
    result = mcp_call('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"environment":"python","command":""}}}')
    assert '"isError":true' not in result, f"Empty command should not error: {result}"
  '';
}
