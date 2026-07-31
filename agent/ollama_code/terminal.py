"""A streamed command console for the GUI.

This is a command runner, not a terminal emulator: there is no PTY, so
`isatty()` is false, programs disable colour and progress bars, and
full-screen applications (vim, top, less) will not work. What it does give you
is a command running in the workspace with its output arriving live, the
ability to answer a `y/n` prompt, and a cancel that kills the whole process
tree.

Nothing here touches the chat turn: a console command never occupies the
agent's single turn slot, so you can keep talking to the model while a build
runs.
"""
from __future__ import annotations

import codecs
import os
import select
import subprocess
import threading
import time
import uuid
from collections.abc import Callable
from datetime import datetime
from typing import Any

from .permissions import PermissionManager
from .tools import signal_process_group

READ_SIZE = 65_536
FLUSH_INTERVAL = 0.05
FLUSH_BYTES = 8_192
MAX_EVENT_TEXT = 65_536
DEFAULT_TIMEOUT = 600
MAX_TIMEOUT = 3_600
MAX_OUTPUT = 2_000_000
RECORD_CAP = 8_000
RING_BUFFER = 65_536
SIGINT_GRACE = 2.0
SIGTERM_GRACE = 2.0
#: How long to wait for a lingering grandchild after the shell itself exits.
LINGER_GRACE = 2.0


class TerminalRejected(Exception):
    """A run could not start. `code` is one of blocked/busy/invalid/spawn_failed."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class TerminalRun:
    """One command, its process, and the pump thread's bookkeeping."""

    def __init__(
        self,
        run_id: str,
        command: str,
        cwd: str,
        timeout: int,
        record: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        self.run_id = run_id
        self.command = command
        self.cwd = cwd
        self.timeout = timeout
        self.proc: subprocess.Popen | None = None
        self.started_at = datetime.now()
        self.deadline = time.monotonic() + timeout
        self.seq = 0
        self.total_bytes = 0
        self.emitted_bytes = 0
        self.truncated = False
        self.inputs = 0
        self.cancelled = False
        self.cancel_reason: str | None = None
        self.sigterm_at: float | None = None
        self.sigkill_at: float | None = None
        self.stdin_queue: list[str] = []
        self.lock = threading.Lock()
        self.ring = bytearray()
        self.recorded: list[str] = []
        self.record = record

    def snapshot(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "command": self.command,
            "cwd": self.cwd,
            "started_at": self.started_at.isoformat(timespec="seconds"),
            "running": self.proc is not None and self.proc.poll() is None,
        }


class TerminalManager:
    """Runs one console command at a time and streams its output."""

    def __init__(
        self,
        emit: Callable[[dict[str, Any]], None],
        perms: PermissionManager,
        record: Callable[[dict[str, Any]], None] | None = None,
        config: dict[str, Any] | None = None,
    ) -> None:
        self._emit = emit
        self._perms = perms
        self._record = record
        self._config = config or {}
        self._run: TerminalRun | None = None
        self._lock = threading.Lock()

    # ----------------------------------------------------------------- start

    def start(
        self,
        command: str,
        cwd: str,
        run_id: str = "",
        timeout: int = 0,
        record: Callable[[dict[str, Any]], None] | None = None,
    ) -> str:
        command = (command or "").strip()
        if not command:
            raise TerminalRejected("invalid", "a command is required")

        # The deny list is checked here rather than in the socket handler so
        # every caller inherits it. A blocked command spawns nothing.
        blocked = self._perms.blocked_reason("bash", {"command": command})
        if blocked:
            self._emit({
                "type": "terminal_error",
                "run_id": run_id or "",
                "code": "blocked",
                "message": blocked,
            })
            raise TerminalRejected("blocked", blocked)

        with self._lock:
            if self._run is not None and self._run.proc is not None \
                    and self._run.proc.poll() is None:
                message = "a command is already running"
                self._emit({
                    "type": "terminal_error", "run_id": run_id or "",
                    "code": "busy", "message": message,
                })
                raise TerminalRejected("busy", message)

            resolved = run_id.strip() or uuid.uuid4().hex[:12]
            limit = timeout if timeout > 0 else int(
                self._config.get("terminal_timeout") or DEFAULT_TIMEOUT
            )
            limit = max(1, min(limit, MAX_TIMEOUT))
            run = TerminalRun(resolved, command, cwd, limit, record=record)

            shell = str(self._config.get("terminal_shell") or os.environ.get("SHELL") or "/bin/sh")
            login = bool(self._config.get("terminal_login_shell", True))
            argv = [shell, "-lc", command] if login else [shell, "-c", command]
            env = {
                **os.environ,
                "PYTHONUNBUFFERED": "1",
                # No PTY, so tell programs not to expect one.
                "TERM": "dumb",
                "PAGER": "cat",
                "GIT_PAGER": "cat",
                "GIT_TERMINAL_PROMPT": "0",
            }
            try:
                run.proc = subprocess.Popen(  # noqa: S603 - running commands is the point
                    argv,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    # Merged into one pipe on purpose: with two pipes and no
                    # PTY, libc block-buffers stdout while stderr stays
                    # unbuffered, so the two arrive in an order that bears no
                    # relation to what the program actually wrote.
                    stderr=subprocess.STDOUT,
                    cwd=cwd or None,
                    env=env,
                    bufsize=0,
                    start_new_session=True,
                )
            except OSError as e:
                self._emit({
                    "type": "terminal_error", "run_id": resolved,
                    "code": "spawn_failed", "message": str(e),
                })
                raise TerminalRejected("spawn_failed", str(e)) from e

            self._run = run

        self._emit({
            "type": "terminal_started",
            "run_id": run.run_id,
            "command": command,
            "cwd": cwd,
            "pid": run.proc.pid,
            "shell": shell,
            "timeout": run.timeout,
            "started_at": run.started_at.isoformat(timespec="seconds"),
            "resumed": False,
        })
        threading.Thread(target=self._pump, args=(run,), daemon=True).start()
        return run.run_id

    # ------------------------------------------------------------------ pump

    def _pump(self, run: TerminalRun) -> None:
        proc = run.proc
        assert proc is not None and proc.stdout is not None
        fd = proc.stdout.fileno()
        os.set_blocking(fd, False)
        # Incremental so a multi-byte character split across a read boundary
        # is not mangled into a replacement character.
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        buffer = ""
        last_flush = time.monotonic()
        exited_at: float | None = None

        eof = False
        while True:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if readable:
                try:
                    chunk = os.read(fd, READ_SIZE)
                    # A closed pipe selects as readable and reads empty; that
                    # is EOF, meaning every writer is gone.
                    if chunk == b"":
                        eof = True
                except (BlockingIOError, InterruptedError):
                    chunk = b""
                except OSError:
                    chunk = b""
                    eof = True
                if chunk:
                    run.total_bytes += len(chunk)
                    text = decoder.decode(chunk)
                    if text:
                        buffer += text
                        run.ring.extend(text.encode("utf-8"))
                        if len(run.ring) > RING_BUFFER:
                            del run.ring[: len(run.ring) - RING_BUFFER]
                        if len("".join(run.recorded)) < RECORD_CAP:
                            run.recorded.append(text)

            self._drain_stdin(run)

            now = time.monotonic()
            if buffer and (len(buffer) >= FLUSH_BYTES or now - last_flush >= FLUSH_INTERVAL):
                self._flush(run, buffer)
                buffer = ""
                last_flush = now

            if not run.cancelled and now > run.deadline:
                self.cancel(run.run_id, reason="timeout")

            self._escalate(run, now)

            if eof:
                break
            if proc.poll() is not None:
                # The shell exited but a backgrounded grandchild still holds
                # the pipe. Give it a moment, then stop regardless so `cmd &`
                # cannot wedge the console open.
                if exited_at is None:
                    exited_at = now
                elif now - exited_at > LINGER_GRACE:
                    break

        tail = decoder.decode(b"", final=True)
        if tail:
            buffer += tail
        if buffer:
            self._flush(run, buffer)

        code = proc.wait()
        self._finish(run, code)

    def _flush(self, run: TerminalRun, text: str) -> None:
        if run.emitted_bytes >= MAX_OUTPUT:
            # Keep reading (the caller still drains the pipe) but stop
            # emitting, so a runaway command cannot flood the socket.
            run.truncated = True
            return
        for start in range(0, len(text), MAX_EVENT_TEXT):
            piece = text[start:start + MAX_EVENT_TEXT]
            run.emitted_bytes += len(piece.encode("utf-8"))
            self._emit({
                "type": "terminal_output",
                "run_id": run.run_id,
                "seq": run.seq,
                "text": piece,
            })
            run.seq += 1

    def _drain_stdin(self, run: TerminalRun) -> None:
        proc = run.proc
        if proc is None or proc.stdin is None:
            return
        with run.lock:
            pending, run.stdin_queue = run.stdin_queue, []
        for line in pending:
            try:
                proc.stdin.write(line.encode("utf-8"))
                proc.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                return

    def _escalate(self, run: TerminalRun, now: float) -> None:
        proc = run.proc
        if proc is None or not run.cancelled or proc.poll() is not None:
            return
        if run.sigkill_at is not None and now >= run.sigkill_at:
            signal_process_group(proc, 9)
            run.sigkill_at = None
        elif run.sigterm_at is not None and now >= run.sigterm_at:
            signal_process_group(proc, 15)
            run.sigterm_at = None
            run.sigkill_at = now + SIGTERM_GRACE

    def _finish(self, run: TerminalRun, code: int) -> None:
        duration = int((datetime.now() - run.started_at).total_seconds() * 1000)
        exit_code = code if code is not None and code >= 0 else None
        signal_name = None
        if code is not None and code < 0:
            try:
                import signal as _signal

                signal_name = _signal.Signals(-code).name
            except (ValueError, ImportError):
                signal_name = str(-code)

        reason = run.cancel_reason or ("exited" if exit_code is not None else "failed")
        self._emit({
            "type": "terminal_exit",
            "run_id": run.run_id,
            "exit_code": exit_code,
            "signal": signal_name,
            "reason": reason,
            "duration_ms": duration,
            "truncated": run.truncated,
            "total_bytes": run.total_bytes,
        })

        record = run.record or self._record
        if record is not None and self._config.get("terminal_record_output", True):
            # Stdin is deliberately not recorded — only how many lines were
            # sent. A y/n answer is the happy case; a password is the one that
            # would otherwise be written to disk.
            record({
                "type": "terminal",
                "run_id": run.run_id,
                "command": run.command,
                "cwd": run.cwd,
                "started": run.started_at.isoformat(timespec="seconds"),
                "duration_ms": duration,
                "exit_code": exit_code,
                "signal": signal_name,
                "reason": reason,
                "inputs": run.inputs,
                "truncated": run.truncated,
                "total_bytes": run.total_bytes,
                "output": "".join(run.recorded)[:RECORD_CAP],
            })

    # --------------------------------------------------------------- control

    def send_input(self, run_id: str, text: str, newline: bool = True) -> bool:
        run = self._active(run_id)
        if run is None:
            self._emit({
                "type": "terminal_error", "run_id": run_id,
                "code": "unknown_run", "message": "that command is no longer running",
            })
            return False
        with run.lock:
            run.stdin_queue.append(text + ("\n" if newline else ""))
            run.inputs += 1
        return True

    def close_stdin(self, run_id: str) -> bool:
        run = self._active(run_id)
        if run is None or run.proc is None or run.proc.stdin is None:
            return False
        try:
            run.proc.stdin.close()
        except OSError:
            return False
        return True

    def cancel(self, run_id: str, force: bool = False, reason: str = "cancelled") -> bool:
        run = self._active(run_id)
        if run is None or run.proc is None:
            return False
        run.cancelled = True
        run.cancel_reason = reason
        now = time.monotonic()
        if force:
            signal_process_group(run.proc, 9)
            return True
        # Interrupt first, then escalate on the pump loop's own clock.
        signal_process_group(run.proc, 2)
        run.sigterm_at = now + SIGINT_GRACE
        return True

    def cancel_all(self, force: bool = True) -> int:
        run = self._run
        if run is None or run.proc is None or run.proc.poll() is not None:
            return 0
        self.cancel(run.run_id, force=force, reason="cancelled")
        return 1

    def snapshot(self) -> list[dict[str, Any]]:
        run = self._run
        if run is None or run.proc is None or run.proc.poll() is not None:
            return []
        return [run.snapshot()]

    def attach(self) -> list[dict[str, Any]]:
        """Replay events so a reconnecting client can pick a live run back up."""
        run = self._run
        if run is None or run.proc is None or run.proc.poll() is not None:
            return []
        events: list[dict[str, Any]] = [{
            "type": "terminal_started",
            "run_id": run.run_id,
            "command": run.command,
            "cwd": run.cwd,
            "pid": run.proc.pid,
            "timeout": run.timeout,
            "started_at": run.started_at.isoformat(timespec="seconds"),
            "resumed": True,
        }]
        if run.ring:
            events.append({
                "type": "terminal_output",
                "run_id": run.run_id,
                "seq": run.seq,
                "text": run.ring.decode("utf-8", errors="replace"),
                "gap": run.total_bytes > len(run.ring),
            })
        return events

    def _active(self, run_id: str) -> TerminalRun | None:
        run = self._run
        if run is None or run.run_id != run_id:
            return None
        if run.proc is None or run.proc.poll() is not None:
            return None
        return run
