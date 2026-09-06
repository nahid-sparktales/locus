"""Supervision checks launch only disposable Python children, never an app/fuzzer."""

import json
import os
import plistlib
import signal
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import RunWalletSwiftFuzz as swift  # noqa: E402
import WalletFuzzEvidence as evidence  # noqa: E402
import WalletFuzzProcess as process  # noqa: E402
import WalletTestExecution as execution  # noqa: E402


@pytest.fixture
def owned_lock(tmp_path, monkeypatch):
    monkeypatch.delenv(execution.FD_ENV, raising=False)
    monkeypatch.delenv(execution.PATH_ENV, raising=False)
    with execution.execution_lock(path=tmp_path / "synthetic.lock"):
        yield


def invoke(tmp_path, script, **kwargs):
    return process.run_bounded(
        [sys.executable, "-c", script],
        timeout_receipt=tmp_path / "timeout.json",
        context={"operation": "synthetic-only"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        **kwargs,
    )


def test_phase_bounds_do_not_replace_fuzzer_requested_duration():
    assert process.phase_deadline("replay", 86400) == 300
    assert process.phase_deadline("fuzz", 60) == 360
    assert process.phase_deadline("fuzz", 86400) == 86700
    for kind, seconds in (("build", 60), ("fuzz", 0), ("fuzz", 86401)):
        with pytest.raises(ValueError):
            process.phase_deadline(kind, seconds)


@pytest.mark.parametrize("deadline", [0, -1, float("nan"), float("inf"), True])
def test_unbounded_or_invalid_deadline_rejected(tmp_path, deadline):
    with pytest.raises(ValueError, match="deadline"):
        invoke(tmp_path, "pass", timeout=deadline)


def test_supervisor_requires_owned_lock_before_spawn(tmp_path, monkeypatch):
    monkeypatch.delenv(execution.FD_ENV, raising=False)
    with pytest.raises(RuntimeError, match="inherited"):
        invoke(tmp_path, "pass", timeout=1)


def test_success_keeps_output_and_inherited_lock(tmp_path, owned_lock):
    script = (
        f"import os,sys; from pathlib import Path; sys.path.insert(0, {str(ROOT / 'Tools')!r}); "
        "import WalletTestExecution as e; print(e.inherited_lock(Path(os.environ[e.PATH_ENV])) >= 3)"
    )
    result = invoke(tmp_path, script, timeout=5)
    assert result.returncode == 0 and not result.timed_out
    assert result.stdout.strip() == "True"
    assert not (tmp_path / "timeout.json").exists()


def test_regular_failure_is_not_reinterpreted(tmp_path, owned_lock):
    result = invoke(tmp_path, "raise SystemExit(7)", timeout=5)
    assert result.returncode == 7 and not result.timed_out
    with pytest.raises(subprocess.CalledProcessError) as error:
        invoke(tmp_path, "raise SystemExit(9)", timeout=5, check=True)
    assert error.value.returncode == 9
    assert not (tmp_path / "timeout.json").exists()


def test_zero_exit_during_timeout_cleanup_remains_failed(tmp_path, owned_lock):
    script = "import signal,time,sys; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(60)"
    result = invoke(tmp_path, script, timeout=0.5)
    receipt = json.loads((tmp_path / "timeout.json").read_text())
    assert result.timed_out and result.returncode == 124
    assert receipt["observedReturnCode"] == 0
    assert receipt["status"] == "failed" and receipt["result"] == 124
    assert receipt["targetCPUSeconds"] == 0
    assert not receipt["campaignCredit"] and not receipt["releaseApproval"]
    claimed = receipt.pop("receiptSHA256")
    assert claimed == evidence.digest(receipt)
    with pytest.raises(FileExistsError):
        evidence.immutable_json(tmp_path / "timeout.json", {})


def test_unresponsive_owned_child_gets_bounded_kill(tmp_path, owned_lock, monkeypatch):
    monkeypatch.setattr(process, "TERMINATE_SECONDS", 0.1)
    monkeypatch.setattr(process, "KILL_SECONDS", 1)
    script = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
    result = invoke(tmp_path, script, timeout=0.5)
    receipt = json.loads((tmp_path / "timeout.json").read_text())
    assert result.returncode == 124
    assert receipt["observedReturnCode"] == -signal.SIGKILL
    assert receipt["supervisedProcessReaped"] and receipt["communicationComplete"]


def test_cleanup_error_still_records_immutable_failure(tmp_path, owned_lock, monkeypatch):
    child = Mock(pid=314159, returncode=None)
    child.communicate.side_effect = subprocess.TimeoutExpired("synthetic", 1)
    popen = Mock(return_value=child)
    kill = Mock(side_effect=PermissionError(1, "synthetic denied"))
    monkeypatch.setattr(process.subprocess, "Popen", popen)
    monkeypatch.setattr(process.os, "killpg", kill)
    result = invoke(tmp_path, "unused", timeout=1)
    receipt = json.loads((tmp_path / "timeout.json").read_text())
    assert result.returncode == 124 and result.timed_out
    assert not receipt["supervisedProcessReaped"] and not receipt["communicationComplete"]
    assert len(receipt["cleanupErrors"]) == 2
    assert [call.args for call in kill.call_args_list] == [
        (314159, signal.SIGTERM),
        (314159, signal.SIGKILL),
    ]
    assert popen.call_args.kwargs["start_new_session"] is True
    assert int(os.environ[execution.FD_ENV]) in popen.call_args.kwargs["pass_fds"]


def test_late_reaped_success_is_failed_without_signalling(tmp_path, owned_lock, monkeypatch):
    child = Mock(pid=314159, returncode=0)
    child.communicate.return_value = ("", "")
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process.time, "monotonic", Mock(side_effect=[0, 2, 2]))
    kill = Mock()
    monkeypatch.setattr(process.os, "killpg", kill)
    assert invoke(tmp_path, "unused", timeout=1).returncode == 124
    kill.assert_not_called()


def test_exact_invoked_configuration_is_retained_without_rebasing(tmp_path):
    products = tmp_path / "products"
    phase = tmp_path / "phase"
    products.mkdir()
    phase.mkdir()
    invoked = products / "unique.xctestrun"
    configuration = {
        "TestBundlePath": "__TESTROOT__/Debug/Locus.app/PlugIns/LocusTests.xctest",
        "EnvironmentVariables": {"LOCUS_FUZZ_PHASE": "replay"},
    }
    content = plistlib.dumps(configuration, fmt=plistlib.FMT_BINARY)
    invoked.write_bytes(content)
    identity = swift.retain_test_configuration(invoked, phase, {"chunkID": "synthetic"})
    assert (phase / "invoked.xctestrun").read_bytes() == content
    receipt = json.loads((phase / "invocation.json").read_text())
    assert receipt["xctestrunSHA256"] == identity == evidence.sha256(invoked)
    assert receipt["relativePathBase"] == str(products)
    assert receipt["invokedPath"] == str(invoked)
    invoked.unlink()
    assert evidence.sha256(phase / "invoked.xctestrun") == identity
    invoked.write_bytes(content)
    with pytest.raises(FileExistsError):
        swift.retain_test_configuration(invoked, phase, {})


def test_timeout_cannot_accrue_even_with_apparently_successful_metrics(tmp_path):
    source = {"revision": "a" * 40, "dirty": False}
    run, manifest = evidence.new_run(tmp_path, "swift", source, {}, [], ["evm_decoder"])
    phase = run / "evm_decoder/fuzz"
    (phase / "corpus").mkdir(parents=True)
    (phase / "artifacts").mkdir()
    (phase / "process.log").write_text("#3 DONE cov: 5 ft: 8\nstat::number_of_executed_units: 3\n")
    result = evidence.finish_receipt(
        run,
        manifest,
        phase,
        target="evm_decoder",
        kind="fuzz",
        chunk_id="synthetic",
        started_at=evidence.utc_now(),
        ended_at=evidence.utc_now(),
        binary={},
        binary_after={},
        corpus_before=evidence.directory_digest(phase / "corpus"),
        result=124,
        metrics=None,
        source_after=source,
        requested_seconds=60,
    )
    assert result["status"] == "failed" and result["targetCPUSeconds"] == 0
    assert result["files"]["process.log"] == evidence.sha256(phase / "process.log")
