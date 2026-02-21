from __future__ import annotations

import base64
import mimetypes
import os
import tempfile
from pathlib import Path
from typing import Any, Dict

from autosage.runner import RunnerError, run_process

DEFAULT_LIMITS = {
    "timeout_ms": 10_000,
    "max_stdout_bytes": 1_000_000,
    "max_stderr_bytes": 1_000_000,
    "max_file_bytes": 10_000_000,
}

ALLOWED_FILE_EXTENSIONS = {".log", ".raw", ".txt"}


def _build_limits(limits: dict | None) -> dict:
    merged = dict(DEFAULT_LIMITS)
    if limits:
        for key in DEFAULT_LIMITS:
            if key in limits and isinstance(limits[key], int):
                merged[key] = limits[key]
    return merged


def _error_response(error_type: str, message: str, details: dict | None = None) -> dict:
    return {
        "ok": False,
        "stdout": "",
        "stderr": "",
        "files": [],
        "metrics": {"elapsed_ms": 0, "exit_code": -1},
        "error": {"type": error_type, "message": message, "details": details or {}},
    }


def _response(
    ok: bool,
    stdout: str,
    stderr: str,
    files: list,
    elapsed_ms: int,
    exit_code: int,
    error: dict | None = None,
) -> dict:
    return {
        "ok": ok,
        "stdout": stdout,
        "stderr": stderr,
        "files": files,
        "metrics": {"elapsed_ms": elapsed_ms, "exit_code": exit_code},
        "error": error,
    }


def _collect_files(workdir: Path, max_file_bytes: int) -> list[dict]:
    output = []
    for entry in sorted(workdir.iterdir(), key=lambda p: p.name):
        if not entry.is_file():
            continue
        if entry.suffix.lower() not in ALLOWED_FILE_EXTENSIONS:
            continue
        size = entry.stat().st_size
        if size > max_file_bytes:
            continue
        data = entry.read_bytes()
        mime = mimetypes.guess_type(entry.name)[0] or "application/octet-stream"
        output.append(
            {
                "name": entry.name,
                "mime": mime,
                "bytes_base64": base64.b64encode(data).decode("ascii"),
            }
        )
    return output


def _log_has_errors(log_text: str) -> bool:
    lower_lines = [line.lower() for line in log_text.splitlines()]
    return any(("error:" in line) or ("fatal" in line) for line in lower_lines)


def _log_relevant_excerpt(log_text: str, limit_lines: int = 50) -> str:
    lines = log_text.splitlines()
    relevant = [line for line in lines if ("error:" in line.lower()) or ("fatal" in line.lower())]
    if relevant:
        return "\n".join(relevant[:limit_lines])
    return "\n".join(lines[:limit_lines])


def version(limits: dict | None = None) -> dict:
    cfg = _build_limits(limits)
    with tempfile.TemporaryDirectory(prefix="autosage_ngspice_") as tmp:
        cwd = Path(tmp)
        try:
            stdout, stderr, exit_code, elapsed_ms = run_process(
                ["ngspice", "-v"],
                cwd=str(cwd),
                timeout_ms=cfg["timeout_ms"],
                max_stdout_bytes=cfg["max_stdout_bytes"],
                max_stderr_bytes=cfg["max_stderr_bytes"],
            )
            if exit_code != 0:
                stdout, stderr, exit_code, elapsed_ms = run_process(
                    ["ngspice", "-V"],
                    cwd=str(cwd),
                    timeout_ms=cfg["timeout_ms"],
                    max_stdout_bytes=cfg["max_stdout_bytes"],
                    max_stderr_bytes=cfg["max_stderr_bytes"],
                )
            ok = exit_code == 0
            return _response(
                ok=ok,
                stdout=stdout,
                stderr=stderr,
                files=[],
                elapsed_ms=elapsed_ms,
                exit_code=exit_code,
                error=None if ok else {"type": "process_failed", "message": "ngspice version command failed.", "details": {}},
            )
        except RunnerError as exc:
            return _error_response(exc.error_type, exc.message, exc.details)


def smoketest(limits: dict | None = None) -> dict:
    cfg = _build_limits(limits)
    netlist = "\n".join(
        [
            "* ngspice smoke test",
            "V1 in 0 DC 1",
            "R1 in out 1k",
            "C1 out 0 1u",
            ".tran 1u 1m",
            ".end",
            "",
        ]
    )
    with tempfile.TemporaryDirectory(prefix="autosage_ngspice_") as tmp:
        cwd = Path(tmp)
        cir_file = cwd / "smoke.cir"
        cir_file.write_text(netlist, encoding="utf-8")
        try:
            stdout, stderr, exit_code, elapsed_ms = run_process(
                ["ngspice", "-b", "-r", "smoke.raw", "-o", "smoke.log", "smoke.cir"],
                cwd=str(cwd),
                timeout_ms=cfg["timeout_ms"],
                max_stdout_bytes=cfg["max_stdout_bytes"],
                max_stderr_bytes=cfg["max_stderr_bytes"],
            )
            files = _collect_files(cwd, cfg["max_file_bytes"])
            ok = exit_code == 0 and len(files) > 0
            error = None
            if not ok:
                error = {"type": "process_failed", "message": "ngspice smoketest failed.", "details": {}}
            return _response(ok, stdout, stderr, files, elapsed_ms, exit_code, error)
        except RunnerError as exc:
            return _error_response(exc.error_type, exc.message, exc.details)


def validate_netlist(netlist_text: str, limits: dict | None = None) -> dict:
    cfg = _build_limits(limits)
    if not isinstance(netlist_text, str) or not netlist_text.strip():
        return _error_response("invalid_input", "netlist_text must be a non-empty string.", {})

    with tempfile.TemporaryDirectory(prefix="autosage_ngspice_") as tmp:
        cwd = Path(tmp)
        cir_file = cwd / "input.cir"
        cir_file.write_text(netlist_text, encoding="utf-8")
        log_path = cwd / "validate.log"
        try:
            stdout, stderr, exit_code, elapsed_ms = run_process(
                ["ngspice", "-b", "-o", "validate.log", "input.cir"],
                cwd=str(cwd),
                timeout_ms=cfg["timeout_ms"],
                max_stdout_bytes=cfg["max_stdout_bytes"],
                max_stderr_bytes=cfg["max_stderr_bytes"],
            )
            log_text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
            has_log_errors = _log_has_errors(log_text)
            ok = (exit_code == 0) and not has_log_errors
            files = _collect_files(cwd, cfg["max_file_bytes"])
            error = None
            if not ok:
                details: Dict[str, Any] = {"exit_code": exit_code}
                if log_text:
                    details["log_excerpt"] = _log_relevant_excerpt(log_text, 50)
                error = {"type": "validation_failed", "message": "ngspice reported validation errors.", "details": details}
            return _response(ok, stdout, stderr, files, elapsed_ms, exit_code, error)
        except RunnerError as exc:
            return _error_response(exc.error_type, exc.message, exc.details)

