# Testing Guide: nix-sandbox-mcp as MCP Server

Terminal-focused guide for testing nix-sandbox-mcp with MCP Inspector.

## Prerequisites

- **Linux** (required for sandboxing; macOS can only build the daemon)
- **Nix** with flakes enabled
- **Node.js/npm** (for MCP Inspector)

## 1. Build the Server

```bash
cd /Users/bear/dev/nix-sandbox-mcp

# Build with default config (shell, python, node presets)
nix build .#default

# Verify it built
ls -la result/bin/nix-sandbox-mcp
```

## 2. Quick Sanity Check (CLI)

Before using the inspector, verify the server works:

```bash
# Run existing tests
./test-local.sh

# Manual test: send MCP messages directly
./result/bin/nix-sandbox-mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
```

Expected: You should see the `execute` tool with its schema.

## 3. Testing with MCP Inspector

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is an interactive developer tool for testing MCP servers. It provides a web UI but runs from terminal.

### 3.1 Launch Inspector

```bash
# Run inspector with your built server
npx @modelcontextprotocol/inspector ./result/bin/nix-sandbox-mcp --stdio
```

This starts a local web server (typically http://localhost:5173) and opens it in your browser. If you're on a headless Linux machine, note the URL and access it remotely or use port forwarding.

**Alternative: Build fresh each time**
```bash
npx @modelcontextprotocol/inspector nix run .# -- --stdio
```

### 3.2 Inspector Interface

Once connected, the Inspector provides:

| Tab | What it shows |
|-----|---------------|
| **Tools** | Lists available tools (`execute`), shows schema, lets you test with custom inputs |
| **Resources** | Lists resources (none for this server) |
| **Prompts** | Lists prompt templates (none for this server) |
| **Notifications** | Server logs and notifications |

### 3.3 Testing the execute Tool

In the **Tools** tab:

1. Click on `execute` tool
2. Fill in the form:
   - `environment`: `python` (or `shell`, `node`)
   - `code`: `print("hello from sandbox")`
3. Click "Run Tool"
4. Observe the response

### 3.4 Test Cases for Inspector

Run these through the Inspector's Tools tab:

**Basic execution:**
```json
{"environment": "python", "code": "print(sum(range(10)))"}
```

**Shell command:**
```json
{"environment": "shell", "code": "echo $HOME && pwd && whoami"}
```

**Node.js:**
```json
{"environment": "node", "code": "console.log(Array.from({length:5}, (_,i) => i*i))"}
```

**Error handling - syntax error:**
```json
{"environment": "python", "code": "print('unterminated"}
```

**Error handling - runtime exception:**
```json
{"environment": "python", "code": "raise ValueError('test error')"}
```

**Security - network blocked:**
```json
{"environment": "python", "code": "import socket; s = socket.socket(); s.connect(('1.1.1.1', 80))"}
```

**Security - filesystem isolated:**
```json
{"environment": "python", "code": "print(open('/etc/passwd').read())"}
```

**Edge case - stderr capture:**
```json
{"environment": "python", "code": "import sys; print('stdout'); sys.stderr.write('stderr')"}
```

**Edge case - unknown environment:**
```json
{"environment": "rust", "code": "fn main() {}"}
```

## 4. Raw CLI Testing (No Inspector)

For quick iteration without the Inspector UI:

### 4.1 Interactive Session Script

```bash
#!/bin/bash
# Save as test-interactive.sh

SERVER="./result/bin/nix-sandbox-mcp --stdio"

# Initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cli-test","version":"1.0"}}}' | $SERVER

# List tools
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | $SERVER

# Execute Python
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print(2**100)"}}}' | $SERVER
```

### 4.2 One-liner Tests

```bash
# Python calculation
./result/bin/nix-sandbox-mcp --stdio <<< '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"import math; print(math.factorial(20))"}}}'

# Shell - check working directory
./result/bin/nix-sandbox-mcp --stdio <<< '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"shell","code":"pwd && ls -la"}}}'
```

### 4.3 Pretty-print Output

Pipe through `jq` for readable output:

```bash
./result/bin/nix-sandbox-mcp --stdio <<'EOF' 2>/dev/null | jq -s '.[-1]'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"for i in range(5): print(f'Line {i}')"}}}
EOF
```

## 5. What to Evaluate

### UX Questions

| Question | How to test |
|----------|-------------|
| Is the tool schema clear? | Check `tools/list` response - does schema explain environment options? |
| Are errors helpful? | Try invalid environment, syntax errors, runtime errors |
| Is output format good? | Check stdout/stderr combined format: `stdout\n--- stderr ---\nstderr` |
| Is security working? | Try network access, reading /etc/passwd |
| What about timeouts? | Try `import time; time.sleep(60)` |

### Specific Things to Check

1. **Tool description** - Does it list available environments?
2. **Error on unknown env** - Is the error message helpful? Does it suggest valid options?
3. **stdout vs stderr** - Is the `--- stderr ---` separator clear or confusing?
4. **Exit codes** - Does `is_error` in response match actual failure?
5. **Empty code** - What happens with `{"environment": "python", "code": ""}`?

### Recording Results

```bash
# Create notes file
cat >> thoughts/shared/ux-evaluation-notes.md << 'EOF'
## Session: $(date +%Y-%m-%d)

### Tool Discovery
- tools/list response: [describe]
- Schema clarity: [1-5]

### Execution
- Python works: [yes/no]
- Shell works: [yes/no]
- Node works: [yes/no]

### Error Handling
- Unknown env message: [copy error]
- Syntax error clarity: [1-5]
- Runtime error clarity: [1-5]

### Output Format
- stdout only: [clear/confusing]
- stderr only: [clear/confusing]
- both: [clear/confusing]

### Security
- Network blocked: [yes/no]
- Filesystem isolated: [yes/no]

### UX Issues Found
- ...

### Ideas for Improvement
- ...
EOF
```

## 6. Debugging

### View Server Logs

```bash
# Run with visible stderr logs
./result/bin/nix-sandbox-mcp --stdio 2>&1 | tee server-output.log
```

### Log MCP Traffic

```bash
# Create debug wrapper
cat > /tmp/mcp-debug.sh << 'EOF'
#!/bin/bash
tee /tmp/mcp-in.log | ./result/bin/nix-sandbox-mcp --stdio 2>/tmp/mcp-err.log | tee /tmp/mcp-out.log
EOF
chmod +x /tmp/mcp-debug.sh

# Use with inspector
npx @modelcontextprotocol/inspector /tmp/mcp-debug.sh

# Then check logs
cat /tmp/mcp-in.log   # requests
cat /tmp/mcp-out.log  # responses
cat /tmp/mcp-err.log  # server stderr
```

### Common Issues

| Symptom | Likely cause |
|---------|--------------|
| Inspector can't connect | Server not built, or not on Linux |
| "Unknown environment" | Environment name typo, or preset not in config |
| Execution hangs | Timeout not enforced, or code waiting on stdin |
| Empty response | Check server stderr for errors |

## 7. Quick Reference

### Available Environments (default config)

| Environment | Interpreter | What's included |
|-------------|-------------|-----------------|
| `python` | `python3 -c` | Python 3 + stdlib |
| `shell` | `bash -s` | coreutils, bash, grep, sed, awk, jq, curl |
| `node` | `node -e` | Node.js 22 |

### MCP Protocol Basics

**Initialize** (required first):
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
```

**List tools:**
```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

**Call execute tool:**
```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"execute","arguments":{"environment":"python","code":"print('hello')"}}}
```

### Response Format

Success:
```json
{"result":{"content":[{"type":"text","text":"hello\n"}],"isError":false}}
```

Error (non-zero exit):
```json
{"result":{"content":[{"type":"text","text":"Traceback...\nValueError: ..."}],"isError":true}}
```

Combined stdout+stderr:
```json
{"result":{"content":[{"type":"text","text":"output\n--- stderr ---\nwarning"}]}}
```

## 8. Testing Checklist

```
[ ] Server builds: nix build .#default
[ ] test-local.sh passes
[ ] Inspector connects: npx @modelcontextprotocol/inspector ./result/bin/nix-sandbox-mcp --stdio
[ ] tools/list shows execute with schema
[ ] Python execution works
[ ] Shell execution works
[ ] Node execution works
[ ] Unknown environment gives helpful error
[ ] Syntax errors are clear
[ ] Runtime errors are clear
[ ] Network is blocked
[ ] Filesystem is isolated
[ ] stderr is captured
[ ] Exit codes set isError correctly
```
