"""Shared lock tests use short disposable child processes, never the app."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import WalletTestExecution as harness  # noqa: E402


@pytest.fixture
def lock_path(tmp_path, monkeypatch):
    monkeypatch.delenv(harness.FD_ENV, raising=False)
    monkeypatch.delenv(harness.PATH_ENV, raising=False)
    return tmp_path / "execution.lock"


def command(path, *args):
    return [
        sys.executable,
        str(ROOT / "Tools/WalletTestExecution.py"),
        "--lock-file",
        str(path),
        *args,
    ]


def test_lock_is_private_and_reentrant_for_cooperating_children(lock_path):
    with harness.execution_lock(path=lock_path):
        assert lock_path.stat().st_mode & 0o777 == 0o600
        with harness.execution_lock(path=lock_path):
            assert (
                harness.run_locked(command(lock_path, "--assert-held"), check=False).returncode == 0
            )
            result = harness.run_locked(
                command(lock_path, "--", sys.executable, "-c", "pass"), check=False
            )
            assert result.returncode == 0
    assert harness.FD_ENV not in os.environ


def test_competing_process_times_out_without_starting_command(lock_path, tmp_path):
    marker = tmp_path / "should-not-exist"
    with harness.execution_lock(path=lock_path):
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in (harness.FD_ENV, harness.PATH_ENV)
        }
        result = subprocess.run(
            command(
                lock_path,
                "--lock-timeout",
                "0",
                "--",
                sys.executable,
                "-c",
                f"open({str(marker)!r}, 'w').close()",
            ),
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
    assert result.returncode != 0
    assert "owns the execution lock" in result.stderr
    assert not marker.exists()


def test_exception_releases_only_own_lock(lock_path):
    with pytest.raises(RuntimeError, match="fixture"):
        with harness.execution_lock(path=lock_path):
            raise RuntimeError("fixture")
    with harness.execution_lock(timeout=0, path=lock_path):
        pass


def test_rejects_forged_or_stale_descriptor(lock_path, monkeypatch):
    monkeypatch.setenv(harness.FD_ENV, "999999")
    monkeypatch.setenv(harness.PATH_ENV, str(lock_path))
    with pytest.raises(RuntimeError, match="valid inherited"):
        with harness.execution_lock(path=lock_path):
            pass


def test_rejects_lock_path_substitution(lock_path, monkeypatch):
    with harness.execution_lock(path=lock_path):
        monkeypatch.setenv(harness.PATH_ENV, str(lock_path.parent / "other"))
        with pytest.raises(RuntimeError, match="valid inherited"):
            harness.inherited_lock(lock_path)


def test_rejects_symlink_lock(lock_path, tmp_path):
    target = tmp_path / "target"
    target.touch(mode=0o600)
    lock_path.symlink_to(target)
    with pytest.raises(OSError):
        with harness.execution_lock(path=lock_path):
            pass


def test_rejects_publicly_writable_lock(lock_path):
    lock_path.touch(mode=0o666)
    lock_path.chmod(0o666)
    with pytest.raises(RuntimeError, match="Unsafe"):
        with harness.execution_lock(path=lock_path):
            pass


def test_cli_preserves_failure_exit_status(lock_path):
    result = subprocess.run(
        command(lock_path, "--", sys.executable, "-c", "raise SystemExit(7)"), check=False
    )
    assert result.returncode == 7
