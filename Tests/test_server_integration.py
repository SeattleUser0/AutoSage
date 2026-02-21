import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest


def _free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()
    return port


def _wait_for_health(base_url: str, timeout_s: float = 20.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{base_url}/healthz", timeout=1.0) as resp:
                if resp.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("AutoSageServer did not become healthy within timeout.")


def _post_json(url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=10.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


@pytest.mark.skipif(shutil.which("ngspice") is None, reason="ngspice not installed")
def test_server_runs_circuits_job_and_exposes_artifacts():
    repo_root = Path(__file__).resolve().parents[1]
    port = _free_port()
    runs_dir = tempfile.mkdtemp(prefix="autosage-integration-runs-")
    base_url = f"http://127.0.0.1:{port}"

    env = os.environ.copy()
    env["AUTOSAGE_PORT"] = str(port)
    env["AUTOSAGE_RUNS_DIR"] = runs_dir

    proc = subprocess.Popen(
        ["swift", "run", "AutoSageServer"],
        cwd=str(repo_root),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        _wait_for_health(base_url)
        create_payload = {
            "tool_name": "circuits.simulate",
            "mode": "sync",
            "wait_ms": 15000,
            "input": {
                "netlist": "V1 in 0 PULSE(0 1 0 1n 1n 1m 2m)\nR1 in out 1000\nC1 out 0 1e-6",
                "analysis": "tran",
                "probes": ["v(out)"],
                "options": {"tran": {"tstop": 0.01, "step": 0.0001}},
            },
        }
        created = _post_json(f"{base_url}/v1/jobs", create_payload)
        job_id = created["job_id"]

        deadline = time.time() + 20.0
        job = None
        while time.time() < deadline:
            job = _get_json(f"{base_url}/v1/jobs/{job_id}")
            if job.get("status") in {"succeeded", "failed"}:
                break
            time.sleep(0.1)

        assert job is not None
        assert job["status"] == "succeeded"

        artifacts = _get_json(f"{base_url}/v1/jobs/{job_id}/artifacts")
        names = sorted(item["name"] for item in artifacts["files"])
        assert "circuit.cir" in names
        assert "ngspice.log" in names
        # ngspice.raw is included when produced by the local ngspice build/config.
        if "ngspice.raw" in names:
            assert any(item["name"] == "ngspice.raw" for item in artifacts["files"])
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(runs_dir, ignore_errors=True)
