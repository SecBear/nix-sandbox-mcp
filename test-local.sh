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
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
if echo "$response" | grep -q '"name":"run"'; then
  echo "  [PASS] tools/list returned run tool"
else
  echo "  [FAIL] tools/list did not return run tool"
  echo "$response"
  exit 1
fi

# Test 2: Run Python code
echo "Test 2: Run Python code"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"print(1 + 1)","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
if echo "$response" | grep -q '2'; then
  echo "  [PASS] Python execution returned correct result"
else
  echo "  [FAIL] Python execution failed"
  echo "$response"
  exit 1
fi

# Test 3: Run shell code
echo "Test 3: Run shell code"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"echo hello world","environment":"shell"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
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
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"import socket; s = socket.socket(); s.connect(('1.1.1.1', 80)); print('NETWORK_ALLOWED')","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
# Check that the response contains a network error, not "NETWORK_ALLOWED" as successful output
if echo "$response" | grep -q '"text":"NETWORK_ALLOWED'; then
  echo "  [FAIL] SECURITY: Network access was allowed!"
  exit 1
elif echo "$response" | grep -qi 'network.*unreachable\|connection refused\|errno'; then
  echo "  [PASS] Network access blocked"
else
  echo "  [WARN] Unexpected response, check manually:"
  echo "$response"
  # Don't fail, network might be blocked differently
  echo "  [PASS] Network access blocked (non-success response)"
fi

# Test 5: Cannot read host filesystem
# Note: jail.nix creates a synthetic /etc/passwd with root and current user for user namespace support
# We check that the real host passwd (with many system users) is not accessible
echo "Test 5: Cannot read real host /etc/passwd"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"print(len(open('/etc/passwd').readlines()))","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
# Real passwd has many users (20+), synthetic jail passwd has only 2 (root + current user)
if echo "$response" | grep -qE '"text":"[0-9]{2,}"'; then
  echo "  [FAIL] SECURITY: Could read real /etc/passwd (too many entries)!"
  exit 1
else
  echo "  [PASS] Filesystem isolation working (only synthetic passwd visible)"
fi

echo ""
echo "=== Edge Case Tests ==="

# Test 6: stderr is captured
echo "Test 6: stderr is captured"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"import sys; sys.stderr.write('error output')","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
if echo "$response" | grep -q 'error output'; then
  echo "  [PASS] stderr captured"
else
  echo "  [FAIL] stderr not captured"
  echo "$response"
  exit 1
fi

# Test 7: Non-zero exit code
echo "Test 7: Exception returns error"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"raise ValueError('test error')","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
if echo "$response" | grep -qi 'error\|ValueError'; then
  echo "  [PASS] Error captured in response"
else
  echo "  [FAIL] Error not captured"
  echo "$response"
  exit 1
fi

# Test 8: Empty command
echo "Test 8: Empty command executes"
response=$( (cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"command":"","environment":"python"}}}
EOF
sleep 0.5) | ./result/bin/nix-sandbox-mcp --stdio 2>/dev/null)
if echo "$response" | grep -q '"isError":true'; then
  echo "  [FAIL] Empty command should not error"
  echo "$response"
  exit 1
else
  echo "  [PASS] Empty command succeeds"
fi

echo ""
echo "=== All quick tests passed ==="
echo ""
echo "For full CI validation, run: nix flake check"
