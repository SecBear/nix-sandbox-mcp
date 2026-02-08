#!/usr/bin/env python3
"""Sandbox agent — persistent interpreter inside a jailed environment.

Runs as a long-lived process, communicating with the Rust daemon via
length-prefixed JSON on stdin/stdout. Manages Python, Bash, and Node
interpreters that maintain state across executions.

Protocol: [4-byte big-endian length][JSON payload]

CRITICAL: Real stdin/stdout are saved at startup and used exclusively
for protocol messages. sys.stdout/sys.stderr are replaced to prevent
user code from corrupting the protocol stream.
"""

import io
import json
import os
import secrets
import struct
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout

# ─────────────────────────────────────────────────────────────────
# Protocol I/O — uses saved real file descriptors
# ─────────────────────────────────────────────────────────────────

# Save real stdin/stdout BEFORE any user code can touch them
REAL_STDIN = sys.stdin.buffer
REAL_STDOUT = sys.stdout.buffer

# Redirect sys.stdout/stderr so user print() can't corrupt protocol
sys.stdout = open(os.devnull, "w")
sys.stderr = open("/workspace/.agent.log", "a")


def send_message(msg: dict) -> None:
    """Send a length-prefixed JSON message on real stdout."""
    payload = json.dumps(msg).encode()
    REAL_STDOUT.write(struct.pack(">I", len(payload)))
    REAL_STDOUT.write(payload)
    REAL_STDOUT.flush()


def recv_message() -> dict:
    """Read a length-prefixed JSON message from real stdin."""
    raw_len = REAL_STDIN.read(4)
    if len(raw_len) < 4:
        raise EOFError("stdin closed")
    (length,) = struct.unpack(">I", raw_len)
    payload = REAL_STDIN.read(length)
    if len(payload) < length:
        raise EOFError("incomplete message")
    return json.loads(payload)


# ─────────────────────────────────────────────────────────────────
# Interpreters
# ─────────────────────────────────────────────────────────────────


class PythonInterpreter:
    """Persistent Python interpreter using exec() with a single shared namespace.

    Single dict avoids the globals/locals bug: with separate dicts,
    functions close over __globals__ (first arg), but exec() puts
    variables into __locals__ (second arg). So def foo(): return x
    followed by x = 42; foo() would fail.
    """

    def __init__(self):
        self.namespace = {"__builtins__": __builtins__}

    def execute(self, code: str) -> tuple[str, str, int]:
        """Execute code, returning (stdout, stderr, exit_code)."""
        buf_out = io.StringIO()
        buf_err = io.StringIO()
        try:
            with redirect_stdout(buf_out), redirect_stderr(buf_err):
                exec(code, self.namespace)  # single dict = globals IS locals
            return buf_out.getvalue(), buf_err.getvalue(), 0
        except SystemExit as e:
            return (
                buf_out.getvalue(),
                buf_err.getvalue(),
                e.code if isinstance(e.code, int) else 1,
            )
        except Exception:
            import traceback

            tb = traceback.format_exc()
            return buf_out.getvalue(), buf_err.getvalue() + tb, 1


class BashInterpreter:
    """Persistent bash process with per-execution nonce markers."""

    def __init__(self):
        self.proc = subprocess.Popen(
            ["bash", "--norc", "--noprofile", "-i"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def execute(self, code: str) -> tuple[str, str, int]:
        """Execute code, returning (stdout, stderr, exit_code)."""
        nonce = secrets.token_hex(16)
        stdout_marker = f"__STDOUT_DONE_{nonce}__"
        stderr_marker = f"__STDERR_DONE_{nonce}__"

        # Wrap code: run it, capture exit code, emit markers with exit code
        wrapped = (
            f"{code}\n"
            f"__exit_code__=$?\n"
            f"echo {stdout_marker} $__exit_code__\n"
            f"echo {stderr_marker} >&2\n"
        )

        self.proc.stdin.write(wrapped.encode())
        self.proc.stdin.flush()

        # Read stdout until marker
        stdout_lines = []
        exit_code = 0
        for line in iter(self.proc.stdout.readline, b""):
            decoded = line.decode(errors="replace")
            if stdout_marker in decoded:
                # Parse exit code from marker line
                parts = decoded.strip().split()
                if len(parts) >= 2:
                    try:
                        exit_code = int(parts[-1])
                    except ValueError:
                        pass
                break
            stdout_lines.append(decoded)

        # Read stderr until marker
        stderr_lines = []
        for line in iter(self.proc.stderr.readline, b""):
            decoded = line.decode(errors="replace")
            if stderr_marker in decoded:
                break
            stderr_lines.append(decoded)

        return "".join(stdout_lines), "".join(stderr_lines), exit_code

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)


class NodeInterpreter:
    """Persistent Node.js process with nonce markers."""

    def __init__(self):
        self.proc = subprocess.Popen(
            ["node", "-i"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Consume the Node REPL welcome banner
        # Node -i prints something like "> " on startup
        # We'll use markers to delimit output, so the banner is harmless
        # but we need to set up marker-based output reading

    def execute(self, code: str) -> tuple[str, str, int]:
        """Execute code, returning (stdout, stderr, exit_code)."""
        nonce = secrets.token_hex(16)
        stdout_marker = f"__STDOUT_DONE_{nonce}__"
        stderr_marker = f"__STDERR_DONE_{nonce}__"

        # Wrap code in try/catch and emit markers
        wrapped = (
            f"try {{ {code} }} catch(e) {{ process.stderr.write(e.stack + '\\n'); }}\n"
            f"console.log('{stdout_marker}');\n"
            f"process.stderr.write('{stderr_marker}\\n');\n"
        )

        self.proc.stdin.write(wrapped.encode())
        self.proc.stdin.flush()

        stdout_lines = []
        for line in iter(self.proc.stdout.readline, b""):
            decoded = line.decode(errors="replace")
            if stdout_marker in decoded:
                break
            # Filter out REPL prompt artifacts
            cleaned = decoded.lstrip("> ").lstrip("... ")
            if cleaned.strip() == "undefined":
                continue
            stdout_lines.append(cleaned)

        stderr_lines = []
        for line in iter(self.proc.stderr.readline, b""):
            decoded = line.decode(errors="replace")
            if stderr_marker in decoded:
                break
            stderr_lines.append(decoded)

        stdout = "".join(stdout_lines)
        stderr = "".join(stderr_lines)
        exit_code = 1 if stderr else 0
        return stdout, stderr, exit_code

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)


# ─────────────────────────────────────────────────────────────────
# Interpreter dispatch
# ─────────────────────────────────────────────────────────────────

# Registry mapping interpreter names to their classes
INTERPRETER_CLASSES = {
    "python": PythonInterpreter,
    "bash": BashInterpreter,
    "node": NodeInterpreter,
}

def dispatch_execute(interpreters: dict, interpreter_name: str, code: str) -> dict:
    """Dispatch code execution to the appropriate interpreter.

    Lazily creates interpreter instances on first use and caches them.
    Returns a dict with stdout, stderr, exit_code.
    """
    # check valid interpreter
    if interpreter_name not in INTERPRETER_CLASSES:
    # if not valid, return error dict
        return {"stdout": "", "stderr":"Error: invalid interpreter.", "exit_code": 1}
    # if valid, and not created, call the constructor
    if interpreter_name not in interpreters:
        interpreters[interpreter_name] = INTERPRETER_CLASSES[interpreter_name]()
    
    # call execute
    # return dict with results
    return dict(
        zip(
            ["stdout", "stderr", "exit_code"],
            interpreters[interpreter_name].execute(code),
        )
    )


# ─────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────


def main():
    # Send Ready message
    send_message({"type": "ready"})

    interpreters = {}

    while True:
        try:
            msg = recv_message()
        except EOFError:
            break

        msg_type = msg.get("type")

        if msg_type == "shutdown":
            break
        elif msg_type == "ping":
            send_message({"type": "pong"})
        elif msg_type == "execute":
            req_id = msg.get("id", "")
            interpreter_name = msg.get("interpreter", "python")
            code = msg.get("code", "")

            try:
                result = dispatch_execute(interpreters, interpreter_name, code)
                send_message(
                    {
                        "type": "result",
                        "id": req_id,
                        "stdout": result["stdout"],
                        "stderr": result["stderr"],
                        "exit_code": result["exit_code"],
                    }
                )
            except Exception as e:
                # Catch-all: send error response so daemon doesn't hang
                import traceback

                tb = traceback.format_exc()
                # Log to agent log file for debugging
                print(tb, file=sys.stderr)
                send_message(
                    {
                        "type": "error",
                        "message": f"Agent internal error: {e}",
                    }
                )
        else:
            send_message(
                {
                    "type": "error",
                    "message": f"Unknown message type: {msg_type}",
                }
            )

    # Cleanup
    for interp in interpreters.values():
        if hasattr(interp, "close"):
            try:
                interp.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
