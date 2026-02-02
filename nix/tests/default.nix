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
