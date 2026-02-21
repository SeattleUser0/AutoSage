import sys

import pytest

from autosage.runner import RunnerError, run_process


def test_runner_timeout_kills_process(tmp_path):
    with pytest.raises(RunnerError) as exc:
        run_process(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            cwd=str(tmp_path),
            timeout_ms=100,
            max_stdout_bytes=1000,
            max_stderr_bytes=1000,
        )
    assert exc.value.error_type == "timeout"

