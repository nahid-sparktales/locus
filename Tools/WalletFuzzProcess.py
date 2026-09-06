"""Bounded engineering-process supervision, never fuzz CPU/completion credit.

Only the new process group created by this invocation may be signalled. An
application launched outside that group is deliberately not discovered or killed.
The inherited execution-lock descriptor remains owned by surviving children.
"""

import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from WalletFuzzEvidence import digest, immutable_json, utc_now
from WalletTestExecution import DEFAULT_LOCK, FD_ENV, PATH_ENV, inherited_lock

VERSION_SECONDS = 30
CORPUS_SECONDS = 60
FETCH_SECONDS = 600
BUILD_SECONDS = 1800
REPLAY_SECONDS = 300
PHASE_OVERHEAD_SECONDS = 300
TERMINATE_SECONDS = 10
KILL_SECONDS = 5
TIMEOUT_RESULT = 124


def phase_deadline(kind: str, requested_seconds: int) -> int:
    if kind not in ("replay", "fuzz") or not 1 <= requested_seconds <= 86400:
        raise ValueError("Invalid bounded fuzz phase")
    return (
        REPLAY_SECONDS
        if kind == "replay"
        else requested_seconds + PHASE_OVERHEAD_SECONDS
    )


@dataclass(frozen=True)
class ProcessResult:
    args: list[str]
    returncode: int
    stdout: object
    stderr: object
    timed_out: bool


def run_bounded(
    arguments, *, timeout, timeout_receipt: Path, context: dict, check=False, **kwargs
):
    """Preserve failures even if a timed-out child exits zero during cleanup."""
    if type(timeout) not in (int, float) or not 0 < timeout <= 90000:
        raise ValueError("A finite positive engineering deadline is required")
    if any(
        key in kwargs
        for key in ("start_new_session", "process_group", "preexec_fn", "shell")
    ):
        raise ValueError("The bounded supervisor owns process-group creation")
    path = Path(os.environ.get(PATH_ENV, DEFAULT_LOCK))
    fd = inherited_lock(path)
    environment = dict(kwargs.pop("env", os.environ))
    environment.update({FD_ENV: str(fd), PATH_ENV: str(path)})
    descriptors = tuple({*kwargs.pop("pass_fds", ()), fd})
    started_at = utc_now()
    started = time.monotonic()
    child = subprocess.Popen(
        arguments,
        env=environment,
        pass_fds=descriptors,
        start_new_session=True,
        **kwargs,
    )
    errors = []
    timed_out = False
    communication_complete = False
    stdout = stderr = None
    try:
        stdout, stderr = child.communicate(timeout=timeout)
        communication_complete = True
        # Scheduling delays cannot turn completion beyond the deadline into a
        # successful bounded run. The already-reaped process is not signalled.
        timed_out = time.monotonic() - started > timeout
    except subprocess.TimeoutExpired:
        timed_out = True
        for sig, grace in (
            (signal.SIGTERM, TERMINATE_SECONDS),
            (signal.SIGKILL, KILL_SECONDS),
        ):
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass
            except OSError as error:
                errors.append({"signal": int(sig), "errno": error.errno})
            try:
                stdout, stderr = child.communicate(timeout=grace)
                communication_complete = True
                break
            except subprocess.TimeoutExpired:
                continue
    result = TIMEOUT_RESULT if timed_out else child.returncode
    if timed_out:
        receipt = {
            "schemaVersion": 1,
            **context,
            "status": "failed",
            "reason": "supervisor-timeout",
            "result": TIMEOUT_RESULT,
            "observedReturnCode": child.returncode,
            "startedAt": started_at,
            "endedAt": utc_now(),
            "deadlineWallSeconds": timeout,
            "elapsedWallSeconds": time.monotonic() - started,
            "supervisedProcessReaped": child.returncode is not None,
            "communicationComplete": communication_complete,
            "cleanupErrors": errors,
            "cleanupScope": "invocation-process-group-only",
            "terminationGraceSeconds": TERMINATE_SECONDS,
            "killGraceSeconds": KILL_SECONDS,
            "targetCPUSeconds": 0,
            "campaignCredit": False,
            "releaseApproval": False,
        }
        receipt["receiptSHA256"] = digest(receipt)
        immutable_json(timeout_receipt, receipt)
    value = ProcessResult(arguments, result, stdout, stderr, timed_out)
    if check and result != 0:
        raise subprocess.CalledProcessError(
            result, arguments, output=stdout, stderr=stderr
        )
    return value
