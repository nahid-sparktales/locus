#!/usr/bin/env python3
"""Serialize cooperating Locus app-host tests and local-chain sessions per user.

The lock is advisory, not an authorization boundary. Wrap the whole service/test
session, not individual launches. Inherited descriptors keep nested runners from
deadlocking and keep the lock alive until the last cooperating child exits.
"""

import argparse
import contextlib
import fcntl
import os
import signal
import stat
import subprocess
import time
from pathlib import Path

FD_ENV = "LOCUS_TEST_EXECUTION_LOCK_FD"
PATH_ENV = "LOCUS_TEST_EXECUTION_LOCK_PATH"
DEFAULT_LOCK = Path(f"/tmp/locus-test-execution-{os.getuid()}.lock")


def inherited_lock(path: Path | None = None) -> int:
    """Reject stale, substituted or unopened inherited descriptor markers."""
    path = (path or DEFAULT_LOCK).absolute()
    try:
        fd = int(os.environ[FD_ENV])
        actual = os.fstat(fd)
        expected = path.lstat()
        if (
            fd < 3
            or os.environ.get(PATH_ENV) != str(path)
            or not stat.S_ISREG(actual.st_mode)
            or not stat.S_ISREG(expected.st_mode)
            or actual.st_uid != os.getuid()
            or actual.st_mode & 0o077
            or (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino)
        ):
            raise ValueError("Invalid shared execution lock descriptor")
        # flock uses the inherited open file description. This is nonblocking,
        # and proves that this description owns (or can acquire) the lock.
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (KeyError, OSError, ValueError) as error:
        raise RuntimeError("No valid inherited Locus test execution lock") from error


@contextlib.contextmanager
def execution_lock(timeout: float = 600, path: Path | None = None):
    if timeout < 0:
        raise ValueError("Lock timeout must not be negative")
    path = (path or DEFAULT_LOCK).absolute()
    if FD_ENV in os.environ:
        yield inherited_lock(path)
        return
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    previous = {key: os.environ.get(key) for key in (FD_ENV, PATH_ENV)}
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
        ):
            raise RuntimeError("Unsafe shared execution lock file")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        "Another Locus test or local-chain session owns the execution lock"
                    ) from None
                time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        os.environ[FD_ENV] = str(fd)
        os.environ[PATH_ENV] = str(path)
        yield fd
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        # Do not LOCK_UN: an inherited child may still hold this same open-file
        # description. Closing releases it only after all owners have exited.
        os.close(fd)


def run_locked(arguments: list[str], **kwargs):
    """subprocess.run, carrying an already-held lock into the child process."""
    path = Path(os.environ.get(PATH_ENV, DEFAULT_LOCK))
    fd = inherited_lock(path)
    environment = dict(kwargs.pop("env", os.environ))
    environment.update({FD_ENV: str(fd), PATH_ENV: str(path)})
    descriptors = tuple({*kwargs.pop("pass_fds", ()), fd})
    check = kwargs.pop("check", False)
    return subprocess.run(
        arguments, env=environment, pass_fds=descriptors, check=check, **kwargs
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock-timeout", type=float, default=600)
    parser.add_argument("--lock-file", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--assert-held", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.assert_held:
        inherited_lock(args.lock_file)
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A command after -- is required")
    with execution_lock(args.lock_timeout, args.lock_file) as fd:
        child = subprocess.Popen(command, pass_fds=(fd,), start_new_session=True)

        def interrupt(_signal, _frame):
            raise KeyboardInterrupt

        previous = signal.signal(signal.SIGTERM, interrupt)
        try:
            return child.wait()
        except KeyboardInterrupt:
            # Only the process group created by this invocation is addressed.
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            except ProcessLookupError:
                pass
            return 130
        finally:
            signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, TimeoutError, ValueError) as error:
        raise SystemExit(str(error)) from None
