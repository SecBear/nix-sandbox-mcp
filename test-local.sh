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
