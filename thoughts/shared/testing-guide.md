# Testing Guide: nix-sandbox-mcp as MCP Server

This guide covers how to test nix-sandbox-mcp with real MCP clients to evaluate the UX.

## Prerequisites

- **Linux** (required for sandboxing; macOS can only build the daemon)
- **Nix** with flakes enabled
- **Claude Desktop** or another MCP client
- Optionally: `mcp-inspector` for protocol debugging

## 1. Build the Server

```bash
cd /Users/bear/dev/nix-sandbox-mcp

# Build with default config (shell, python, node presets)
nix build .#default

# Verify it built
ls -la result/bin/nix-sandbox-mcp
```

## 2. Quick Sanity Check (CLI)

Before testing with Claude, verify the server works:

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

## 3. Testing with mcp-inspector (Optional)

[mcp-inspector](https://github.com/anthropics/mcp-inspector) provides a UI for testing MCP servers.

```bash
# Install globally
npm install -g @anthropic-ai/mcp-inspector

# Run inspector against your server
mcp-inspector ./result/bin/nix-sandbox-mcp --stdio
```

In the inspector:
1. Connect to the server
2. Browse available tools
3. Try calling `execute` with different environments
4. Observe response format and timing

## 4. Testing with Claude Desktop

### 4.1 Configure Claude Desktop

Edit `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "nix-sandbox": {
      "command": "/Users/bear/dev/nix-sandbox-mcp/result/bin/nix-sandbox-mcp",
      "args": ["--stdio"]
    }
  }
}
```

**Alternative (builds fresh each time):**
```json
{
  "mcpServers": {
    "nix-sandbox": {
      "command": "nix",
      "args": ["run", "/Users/bear/dev/nix-sandbox-mcp", "--", "--stdio"]
    }
  }
}
```

### 4.2 Restart Claude Desktop

After editing config, restart Claude Desktop completely (quit and reopen).

### 4.3 Verify Connection

In Claude Desktop, you should see the MCP server icon in the chat input area. Click it to verify "nix-sandbox" is connected and `execute` tool is available.

## 5. Evaluation Prompts

Use these prompts to evaluate the UX. Note observations for each.

### Category A: Basic Functionality

**A1. Simple execution**
> Write a Python one-liner that prints the first 10 Fibonacci numbers.

*Observe: Does Claude naturally use the execute tool? Does it choose the right environment?*

**A2. Environment switching**
> First, use Python to calculate 2^100. Then use shell to list the contents of /workspace.

*Observe: Does Claude switch environments smoothly? Is the output clear?*

**A3. Multi-step computation**
> Write a shell script that generates 5 random numbers, then use Python to calculate their average.

*Observe: Can Claude handle multi-step workflows? Does it pass data between executions?*

### Category B: Tool Discovery

**B1. What can you do?**
> What code execution capabilities do you have?

*Observe: Does Claude accurately describe the available environments?*

**B2. Implicit environment selection**
> Run `console.log(Array.from({length: 5}, (_, i) => i*i))`

*Observe: Does Claude infer the right environment (node) from the code?*

**B3. Error on unknown environment**
> Execute some Rust code for me: `fn main() { println!("hello"); }`

*Observe: How does Claude handle environments that don't exist? Does the error message help?*

### Category C: Error Handling

**C1. Syntax error**
> Run this Python: `print("hello`

*Observe: Is the error message clear? Does Claude offer to fix it?*

**C2. Runtime exception**
> Use Python to open and read a file called /nonexistent/file.txt

*Observe: How is the exception displayed? stdout vs stderr handling?*

**C3. Security boundary**
> Use Python to make an HTTP request to https://example.com

*Observe: Does the sandbox block network access? Is the error understandable?*

### Category D: Edge Cases

**D1. Large output**
> Use Python to print numbers 1 to 10000, one per line.

*Observe: Does output get truncated? Is it readable?*

**D2. Long-running code**
> Write Python code that sleeps for 60 seconds then prints "done".

*Observe: Does the timeout work? How is timeout communicated?*

**D3. Interactive/input**
> Write Python that asks for user input with input().

*Observe: How is this handled? (Should fail/hang - stdin isn't connected)*

### Category E: Real-World Tasks

**E1. Data processing**
> I have this JSON: `{"users": [{"name": "Alice", "age": 30}, {"name": "Bob", "age": 25}]}`. Use Python to find the average age.

*Observe: Natural workflow for data tasks?*

**E2. Algorithm implementation**
> Implement quicksort in Python and test it with [3,1,4,1,5,9,2,6].

*Observe: Does Claude test its own code? Iterative refinement?*

**E3. Shell scripting**
> Use shell commands to create a simple directory structure with nested folders and files, then display it with tree or ls -R.

*Observe: File system operations in sandbox?*

## 6. What to Evaluate

### UX Metrics

| Metric | What to observe |
|--------|-----------------|
| **Discoverability** | Does Claude find and use the tool without prompting? |
| **Environment selection** | Does Claude pick the right environment? Does it ever pick wrong? |
| **Output clarity** | Is stdout/stderr clear? Is combined output confusing? |
| **Error messages** | When things fail, are errors helpful? |
| **Mental model** | Does single-tool-with-env-param feel natural? |
| **Iteration** | Can Claude run, see error, fix, re-run smoothly? |

### Potential Pain Points to Watch For

1. **"Unknown environment" errors** - Does Claude try environments that don't exist?
2. **Environment confusion** - Does Claude mix up what's available in each preset?
3. **Output formatting** - Is the `stdout\n--- stderr ---\nstderr` format confusing?
4. **No tool chaining** - Does Claude struggle without file persistence between calls?
5. **Sandbox limitations** - Does lack of network/filesystem access frustrate legitimate use cases?

### Alternative UX Ideas to Consider

Based on testing, you might consider:

| Current | Alternative | Trade-off |
|---------|-------------|-----------|
| Single `execute` tool | Per-language tools (`python`, `shell`, `node`) | More tools = more token overhead, but possibly better discoverability |
| `environment` param | Infer from code | Less explicit, but might be more natural |
| Combined stdout/stderr | Structured JSON response | Cleaner for parsing, but more complex for simple cases |
| Static config | Runtime environment creation | More flexible, but loses Nix reproducibility guarantees |

## 7. Recording Results

Create a file to capture your observations:

```bash
# After each test session
cat >> thoughts/shared/ux-evaluation-notes.md << 'EOF'
## Session: [DATE]

### What worked well
- ...

### Pain points
- ...

### Claude's behavior patterns
- ...

### UX change ideas
- ...
EOF
```

## 8. Debugging

### View server logs

The daemon logs to stderr. To see logs while testing:

```bash
# Run server manually with visible logs
./result/bin/nix-sandbox-mcp --stdio 2>server.log

# In another terminal
tail -f server.log
```

### Check MCP messages

For deep debugging, you can log the actual JSON-RPC traffic:

```bash
# Wrapper script to log MCP traffic
cat > /tmp/mcp-debug.sh << 'EOF'
#!/bin/bash
tee /tmp/mcp-in.log | ./result/bin/nix-sandbox-mcp --stdio 2>/tmp/mcp-err.log | tee /tmp/mcp-out.log
EOF
chmod +x /tmp/mcp-debug.sh
```

Then use `/tmp/mcp-debug.sh` as the command in Claude Desktop config.

## 9. Quick Reference: MCP Protocol

The server exposes one tool:

```json
{
  "name": "execute",
  "description": "Execute code in a sandboxed Nix environment",
  "inputSchema": {
    "type": "object",
    "properties": {
      "environment": {
        "type": "string",
        "description": "The sandbox environment to use (e.g., 'python', 'shell', 'node')"
      },
      "code": {
        "type": "string",
        "description": "The code to execute in the sandbox"
      }
    },
    "required": ["environment", "code"]
  }
}
```

Server info includes instructions listing available environments.
