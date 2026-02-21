import shutil

import pytest

from autosage.tools import ngspice


@pytest.mark.skipif(shutil.which("ngspice") is None, reason="ngspice not installed")
def test_ngspice_version_returns_ok_true():
    result = ngspice.version()
    assert result["ok"] is True
    assert result["metrics"]["exit_code"] == 0


@pytest.mark.skipif(shutil.which("ngspice") is None, reason="ngspice not installed")
def test_ngspice_smoketest_produces_file():
    result = ngspice.smoketest()
    assert result["ok"] is True
    assert len(result["files"]) >= 1

