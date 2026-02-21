from __future__ import annotations

import os
import selectors
import subprocess
import time
from typing import List, Tuple


class RunnerError(Exception):
    def __init__(self, error_type: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.error_type = error_type
        self.message = message
        self.details = details or {}


def run_process(
    argv: List[str],
    cwd: str,
    timeout_ms: int,
    max_stdout_bytes: int,
    max_stderr_bytes: int,
) -> Tuple[str, str, int, int]:
    if not argv:
        raise RunnerError("invalid_request", "argv must not be empty.")
    if timeout_ms <= 0:
        raise RunnerError("invalid_request", "timeout_ms must be > 0.")
    if max_stdout_bytes <= 0 or max_stderr_bytes <= 0:
        raise RunnerError("invalid_request", "max stdout/stderr byte limits must be > 0.")

    start = time.monotonic()
    try:
        process = subprocess.Popen(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
            shell=False,
        )
    except FileNotFoundError as exc:
        raise RunnerError("process_not_found", f"Executable not found: {argv[0]}", {"argv0": argv[0]}) from exc
    except OSError as exc:
        raise RunnerError("process_start_failed", str(exc), {"argv": " ".join(argv)}) from exc

    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, data="stdout")
    selector.register(process.stderr, selectors.EVENT_READ, data="stderr")

    stdout_buf = bytearray()
    stderr_buf = bytearray()
    stdout_truncated = False
    stderr_truncated = False
    timeout_s = timeout_ms / 1000.0

    while selector.get_map():
        elapsed = time.monotonic() - start
        if elapsed >= timeout_s:
            process.terminate()
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                process.kill()
            raise RunnerError(
                "timeout",
                f"Process exceeded timeout of {timeout_ms} ms.",
                {"timeout_ms": timeout_ms},
            )

        events = selector.select(timeout=0.05)
        if not events and process.poll() is not None:
            break

        for key, _ in events:
            stream = key.fileobj
            channel = key.data
            try:
                chunk = os.read(stream.fileno(), 65536)
            except OSError:
                chunk = b""
            if not chunk:
                try:
                    selector.unregister(stream)
                except Exception:
                    pass
                continue

            if channel == "stdout":
                remaining = max_stdout_bytes - len(stdout_buf)
                if remaining > 0:
                    stdout_buf.extend(chunk[:remaining])
                if len(chunk) > remaining:
                    stdout_truncated = True
            else:
                remaining = max_stderr_bytes - len(stderr_buf)
                if remaining > 0:
                    stderr_buf.extend(chunk[:remaining])
                if len(chunk) > remaining:
                    stderr_truncated = True

    exit_code = process.wait()
    elapsed_ms = int((time.monotonic() - start) * 1000)
    stdout_text = stdout_buf.decode("utf-8", errors="replace")
    stderr_text = stderr_buf.decode("utf-8", errors="replace")
    if stdout_truncated:
        stdout_text += "\n[stdout truncated]"
    if stderr_truncated:
        stderr_text += "\n[stderr truncated]"

    return stdout_text, stderr_text, exit_code, elapsed_ms

