# UX Evaluation: nix-sandbox-mcp v0.1.0

**Date:** 2026-02-02
**Tested with:** Claude Code (claude-opus-4-5-20251101)
**Environment:** Linux, Nix flakes, pre-built jail.nix sandboxes
**Config:** Default presets (python, shell, node)

## Summary

First real-world test of nix-sandbox-mcp as an MCP server with an LLM client. **Result: Excellent.** The single-tool design works naturally, execution is instant, and Claude uses it effectively without confusion.

---

## Test Results

### Basic Functionality

#### Python: Prime Numbers
**Prompt:** "Use Python to calculate the first 20 prime numbers"

**Tool Call:**
```json
{
  "environment": "python",
  "code": "\ndef is_prime(n):\n    if n < 2:\n        return False\n    for i in range(2, int(n**0.5) + 1):\n        if n % i == 0:\n            return False\n    return True\n\nprimes = []\nnum = 2\nwhile len(primes) < 20:\n    if is_prime(num):\n        primes.append(num)\n    num += 1\n\nprint(\"First 20 prime numbers:\")\nprint(primes)\n"
}
```

**Output:**
```
First 20 prime numbers:
[2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71]
```

**Observations:**
- Claude wrote a complete function, not a one-liner
- Correctly chose `python` environment
- Instant execution

---

#### Shell: Working Directory
**Prompt:** "Run a shell command to show the current working directory"

**Tool Call:**
```json
{
  "environment": "shell",
  "code": "pwd"
}
```

**Output:**
```
/workspace
```

**Observations:**
- Claude correctly identified this as a shell task
- Sandbox working directory is `/workspace` (isolated from host)
- Claude noted the isolation in its response

---

#### Node.js: UUID Generation
**Prompt:** "Write and execute a Node.js script that generates a random UUID"

**Tool Call:**
```json
{
  "environment": "node",
  "code": "\nconst crypto = require('crypto');\n\nconst uuid = crypto.randomUUID();\n\nconsole.log('Generated UUID:', uuid);\n"
}
```

**Output:**
```
Generated UUID: 68c5900b-2457-40e7-a590-0e70966dee40
```

**Observations:**
- Claude used Node's built-in crypto (no external deps needed)
- Correct environment selection

---

### Real-World Use Cases

#### Financial Calculation: Compound Interest
**Prompt:** "Calculate compound interest on $10,000 at 7% annual rate over 30 years, show year-by-year breakdown."

**Tool Call:**
```json
{
  "environment": "python",
  "code": "<30-line program with formatted table output>"
}
```

**Output:** Year-by-year table showing growth from $10,000 to $76,122.55

**Key Result:**
```
Final Balance: $76,122.55
Total Interest Earned: $66,122.55
Growth Multiple: 7.61x
```

**Observations:**
- Claude went beyond the ask: added formatting, insights
- Professional-quality output

---

#### Data Transformation: Hex to RGB
**Prompt:** "Convert this list of hex colors to RGB values: #FF5733, #33FF57, #3357FF"

**Output:**
```
Hex        RGB                  R     G     B
---------------------------------------------
#FF5733    rgb(255, 87, 51)     255   87    51
#33FF57    rgb(51, 255, 87)     51    255   87
#3357FF    rgb(51, 87, 255)     51    87    255
```

**Observations:**
- Clean tabular output
- Claude added color descriptions in response

---

#### Security: SHA256 Hash
**Prompt:** "What's the SHA256 hash of 'my-secret-string'?"

**Output:**
```
Input: 'my-secret-string'
SHA256: 3f99eb272844c925224de17c52c6b8e323e82cd692c037cf93d48ffa982dc2d0
```

**Observations:**
- Used Python's hashlib (stdlib, no deps)
- Quick, correct answer

---

### Code Analysis & Debugging

#### Performance Analysis: O(n²) Detection
**Prompt:** "This Python function is supposed to find duplicates but it's slow. Run it and tell me why: `def find_dupes(lst): return [x for x in lst if lst.count(x) > 1]`"

**Tool Call:** Benchmarking code with multiple list sizes + fixed version

**Output:**
```
Benchmarking find_dupes():
Size       Time (ms)    Operations
----------------------------------------
100        0.15         10,000
500        2.89         250,000
1000       11.45        1,000,000
2000       45.23        4,000,000
5000       283.67       25,000,000

PROBLEM: O(n²) time complexity!

With 5000 items:
  Slow version: 283.67 ms
  Fast version: 0.56 ms
  Speedup: 506x faster
```

**Observations:**
- Claude didn't just explain, it proved with benchmarks
- Provided the fix with Counter
- Excellent teaching moment

---

#### Regex Validation
**Prompt:** "Test if this regex correctly matches email addresses: `^[a-zA-Z0-9+_.-]+@[a-zA-Z0-9.-]+$`"

**Output:** 17 test cases, identified 6 false positives (dots at boundaries, consecutive dots, etc.)

**Key Finding:**
```
⚠️ The regex has issues:
  • .user@domain.com: Local starts with dot - INVALID but matches!
  • user..name@domain.com: Consecutive dots - INVALID but matches!
  • user@.com: Domain starts with dot - INVALID but matches!
```

**Observations:**
- Claude proactively tested edge cases
- Provided improved regex
- Recommended library for production use

---

### Algorithm Verification

#### Binary Search with Exhaustive Testing
**Prompt:** "Implement binary search and prove it works with a sorted list of 1000 elements."

**Output:** Complete implementation with 4 test suites:
1. Find specific values
2. Search for missing values (odd numbers)
3. Exhaustive verification (all 1000 elements)
4. Performance comparison vs linear search

**Key Results:**
```
All 1000 elements found correctly: ✓ PASS
Average comparisons: 8.99
Max comparisons: 10 (matches log₂1000)
vs Linear (worst case): 100x faster

RESULT: Binary search implementation VERIFIED ✓
```

**Observations:**
- Claude understood "prove it works" = comprehensive testing
- Compared against theoretical bounds
- Self-verified correctness

---

### Shell Scripting

#### Domain Extraction One-Liner
**Prompt:** "Write a shell one-liner that extracts all unique domain names from a list of URLs."

**Output:**
```bash
sed -E 's|^https?://([^/]+).*|\1|' urls.txt | sort -u
```

With test data showing correct extraction:
```
api.github.com
docs.python.org
news.ycombinator.com
subdomain.example.org
www.example.com
```

**Observations:**
- Claude created test data to demonstrate
- Provided alternative with awk
- Explained each part of the command

---

#### File Discovery with Size Calculation
**Prompt:** "Write a shell command that finds all files modified in the last 24 hours and calculates their total size."

**Output:**
```bash
# Human-readable
find /path -type f -mtime -1 -print0 | xargs -0 du -ch | tail -1

# Precise bytes
find /path -type f -mtime -1 -exec stat -c %s {} \; | awk '{sum+=$1} END {print sum}'
```

**Observations:**
- Created test files including backdated "old" file to prove filtering works
- Provided multiple approaches
- Explained flags

---

### Data Processing

#### Python itertools.groupby Demo
**Prompt:** "Demonstrate Python's itertools.groupby with a practical example."

**Output:** Three examples:
1. Group transactions by date
2. Group by category with aggregation
3. Consecutive runs (classic use case)

Plus the critical gotcha:
```python
# WRONG - data not sorted
[1, 2, 1, 2, 1]  →  5 groups

# CORRECT - sorted first
[1, 1, 1, 2, 2]  →  2 groups
```

**Observations:**
- Practical real-world example (sales transactions)
- Warned about the non-obvious sorting requirement
- Teaching-quality explanation

---

#### Month-over-Month Growth Analysis
**Prompt:** "I have sales data: [{'month': 'Jan', 'sales': 1200}, {'month': 'Feb', 'sales': 1500}, {'month': 'Mar', 'sales': 1100}]. Calculate month-over-month growth percentages."

**Output:**
```
Month    Sales     Change     Growth %
---------------------------------------------
Jan      $1,200        N/A        N/A
Feb      $1,500     +$300     +25.0%
Mar      $1,100     -$400     -26.7%
---------------------------------------------

Jan → Mar (Total): -$100 (-8.3%)
```

**Observations:**
- Formatted output suitable for reports
- Added insights (best/worst month, average)
- Business-ready analysis

---

### Quick Utilities

#### XML to JSON Conversion
**Prompt:** "Convert this XML to JSON: `<user><name>Alice</name><age>30</age></user>`"

**Output:**
```json
{
  "user": {
    "name": "Alice",
    "age": 30
  }
}
```

**Observations:**
- Auto-converted numeric string to integer
- Mentioned xmltodict for complex cases

---

#### UUID Generation (Batch)
**Prompt:** "Generate 10 random UUIDs for test fixtures."

**Output:** 10 UUIDs in multiple formats:
- Numbered list
- Python list literal
- JSON array

**Observations:**
- Anticipated copy-paste needs
- Multiple output formats

---

#### Base64 Round-Trip
**Prompt:** "Base64 encode this string, then decode it back to verify."

**Output:**
```
Original:  'this string'
Encoded:   'dGhpcyBzdHJpbmc='
Decoded:   'this string'
Verified:  True ✓
```

**Observations:**
- Self-verification pattern
- Clean, trustworthy output

---

## UX Analysis

### What Works Excellently

| Aspect | Rating | Notes |
|--------|--------|-------|
| Environment selection | ★★★★★ | Claude always picks correctly |
| Execution speed | ★★★★★ | Instant (pre-built envs) |
| Output clarity | ★★★★★ | Clean stdout, Claude summarizes |
| Tool discovery | ★★★★★ | Single tool, obvious interface |
| Error handling | Not tested | Needs follow-up |

### Claude's Usage Patterns

1. **Writes complete programs** - Not one-liners; adds structure, tests, formatting
2. **Self-verifies** - Benchmarks, exhaustive tests, round-trip checks
3. **Teaches** - Explains gotchas, provides alternatives
4. **Anticipates needs** - Multiple output formats, insights beyond the ask

### Design Validation

| Design Decision | Validated? | Evidence |
|-----------------|------------|----------|
| Single `execute` tool | ✅ Yes | No confusion, natural usage |
| `environment` parameter | ✅ Yes | Always correct selection |
| Pre-built envs | ✅ Yes | Instant execution |
| stdout/stderr combined | ✅ Partial | No stderr-heavy cases tested |
| `/workspace` cwd | ✅ Yes | Claude understood isolation |

---

## Metrics

- **Tests run:** 15
- **Success rate:** 100%
- **Environment mismatches:** 0
- **Execution failures:** 0
- **Average response quality:** Excellent (detailed, formatted, insightful)

---

## Recommendations

### For v0.1.0 Release
- Ship it. UX is production-ready.
- Consider adding available environments to tool description

### For Future Testing
- [ ] Error cases (syntax errors, runtime exceptions)
- [ ] Timeout behavior (30s limit)
- [ ] Network blocking (requests.get fails gracefully?)
- [ ] Large output handling
- [ ] stdin-dependent code (input())

### Potential Enhancements (Not Urgent)
- Per-environment tool aliases (optional convenience)
- Structured output mode (JSON response option)
- Execution metadata (timing, memory used)

---

## Appendix: Tool Schema

The server exposes this interface:

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

Server instructions sent to client:
```
Execute code in isolated Nix-built sandbox environments.
Available environments: ["node", "python", "shell"]

Use the 'execute' tool with:
- environment: one of ["node", "python", "shell"]
- code: the code to run
```
