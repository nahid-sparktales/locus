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
GROUP_POLL_SECONDS = 0.05


class _SupervisorInterrupted(SystemExit):
    """Propagate cancellation only after the owned invocation has been cleaned up."""

    def __init__(self, signum):
        super().__init__(128 + signum)
        self.signum = signum


def _terminate_owned_group(child):
    """Reaping the direct child does not establish that its descendants exited."""
    stdout = stderr = None
    communication_complete = group_gone = False
    errors = []

    def record_error(sig, error):
        record = {"signal": int(sig), "errno": error.errno}
        if record not in errors:
            errors.append(record)

    for sig, grace in (
        (signal.SIGTERM, TERMINATE_SECONDS),
        (signal.SIGKILL, KILL_SECONDS),
    ):
        deadline = time.monotonic() + grace
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            group_gone = True
        except OSError as error:
            record_error(sig, error)
        while True:
            remaining = max(0, deadline - time.monotonic())
            if not communication_complete:
                try:
                    stdout, stderr = child.communicate(
                        timeout=min(GROUP_POLL_SECONDS, remaining)
                    )
                    communication_complete = True
                except subprocess.TimeoutExpired:
                    pass
            if not group_gone:
                try:
                    # Probe only the session/process group created by this call.
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    group_gone = True
                except OSError as error:
                    record_error(0, error)
            if communication_complete and group_gone:
                return stdout, stderr, communication_complete, group_gone, errors
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if communication_complete:
                time.sleep(min(GROUP_POLL_SECONDS, remaining))
        if group_gone:
            # A child outside this group may still hold an output pipe open.
            # It is not ours to discover or signal.
            break
    return stdout, stderr, communication_complete, group_gone, errors


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
    """Preserve deadline/interruption failures, including a cleanup-time zero exit."""
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
    child = None
    interruption = None
    cleaning_up = True

    def interrupt(signum, _frame):
        nonlocal interruption
        if interruption is None:
            interruption = _SupervisorInterrupted(signum)
        # Defer signals during spawn until Popen returns the owned group identity.
        # Repeated signals must not interrupt bounded teardown or its receipt.
        if child is not None and not cleaning_up:
            raise interruption

    previous_handlers = {}
    errors = []
    timed_out = False
    communication_complete = False
    group_gone = None
    stdout = stderr = None
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[sig] = signal.signal(sig, interrupt)
        if interruption is not None:
            raise interruption
        child = subprocess.Popen(
            arguments,
            env=environment,
            pass_fds=descriptors,
            start_new_session=True,
            **kwargs,
        )
        try:
            cleaning_up = False
            if interruption is not None:
                raise interruption
            stdout, stderr = child.communicate(timeout=timeout)
            communication_complete = True
            # Scheduling delays cannot turn completion beyond the deadline into
            # success. The already-reaped process is not signalled on this path.
            timed_out = time.monotonic() - started > timeout
        except (
            subprocess.TimeoutExpired,
            KeyboardInterrupt,
            _SupervisorInterrupted,
        ) as error:
            cleaning_up = True
            if isinstance(error, subprocess.TimeoutExpired):
                timed_out = True
            else:
                interruption = error
            stdout, stderr, communication_complete, group_gone, errors = (
                _terminate_owned_group(child)
            )
        finally:
            cleaning_up = True
        result = (
            128 + getattr(interruption, "signum", signal.SIGINT)
            if interruption is not None
            else TIMEOUT_RESULT
            if timed_out
            else child.returncode
        )
        if timed_out or interruption is not None:
            receipt = {
                "schemaVersion": 1,
                **context,
                "status": "failed",
                "reason": "supervisor-interrupted"
                if interruption is not None
                else "supervisor-timeout",
                "result": result,
                "interruptionSignal": getattr(interruption, "signum", signal.SIGINT)
                if interruption is not None
                else None,
                "observedReturnCode": child.returncode,
                "startedAt": started_at,
                "endedAt": utc_now(),
                "deadlineWallSeconds": timeout,
                "elapsedWallSeconds": time.monotonic() - started,
                "supervisedProcessReaped": child.returncode is not None,
                "communicationComplete": communication_complete,
                "ownedProcessGroupGone": group_gone,
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
        if interruption is not None:
            raise interruption
    finally:
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    value = ProcessResult(arguments, result, stdout, stderr, timed_out)
    if check and result != 0:
        raise subprocess.CalledProcessError(
            result, arguments, output=stdout, stderr=stderr
        )
    return value
