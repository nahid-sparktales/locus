"""Long-lived development servers the agent starts and owns.

Deliberately not ``TerminalManager``: that class runs one console command at a
time, kills anything past an hour, and breaks its pump two seconds after the
shell exits — three behaviours that exist to protect the user's Console and
each of which would kill a dev server. This manager is the inverse shape:
several named runs, no deadline, a bounded ring of recent output, and nothing
emitted to the Console's event stream — the agent reads output through the
``status`` action, and the user watches the page itself in the Browser tab.

Servers outlive the conversation that started them and die with the backend:
``stop_all`` runs at shutdown beside the terminal's own cleanup.
"""
from __future__ import annotations

import os
import shlex
import signal
import socket
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable
from datetime import datetime
from typing import Any

from .proxy import sanitized_child_environment
from .tools import signal_process_group

#: Recent output kept per server, in lines. Enough to show a crash and the
#: startup banner; bounded so a chatty watcher cannot grow without limit.
RING_LINES = 400
#: One output line is capped so a minified bundle dumped to stdout cannot make
#: a single line the whole ring.
MAX_LINE_CHARS = 2_000
#: How long ``start`` waits for a given port to accept a connection.
PORT_WAIT_SECONDS = 90.0
PORT_POLL_SECONDS = 0.25
#: Grace between SIGTERM and SIGKILL when stopping.
TERM_GRACE_SECONDS = 2.0
#: A runaway loop starting servers is a bug, not a workload.
MAX_SERVERS = 8


class DevServerError(Exception):
    """A server could not be started or addressed."""


class DevServerRun:
    """One spawned server and its recent output."""

    def __init__(self, name: str, command: str, cwd: str, port: int | None) -> None:
        self.name = name
        self.command = command
        self.cwd = cwd
        self.port = port
        self.proc: subprocess.Popen | None = None
        self.started_at = datetime.now()
        self.monotonic_start = time.monotonic()
        self.ring: deque[str] = deque(maxlen=RING_LINES)
        self.lock = threading.Lock()

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def tail(self, lines: int = 40) -> str:
        with self.lock:
            recent = list(self.ring)[-lines:]
        return "\n".join(recent)

    def snapshot(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "command": self.command,
            "cwd": self.cwd,
            "port": self.port,
            "pid": self.proc.pid if self.proc else None,
            "running": self.running,
            "exit_code": None if self.running or self.proc is None else self.proc.poll(),
            "started_at": self.started_at.isoformat(timespec="seconds"),
            "uptime_seconds": int(time.monotonic() - self.monotonic_start),
        }


class DevServerManager:
    """Named, long-lived child processes with bounded output rings."""

    def __init__(self, perms: Any, config: dict[str, Any] | None = None) -> None:
        self._perms = perms
        self._config = config or {}
        self._runs: dict[str, DevServerRun] = {}
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ start

    def start(
        self,
        command: str,
        cwd: str,
        port: int | None = None,
        name: str = "",
        should_stop: Callable[[], bool] | None = None,
    ) -> dict[str, Any]:
        command = command.strip()
        if not command:
            raise DevServerError("a command is required")
        # The same deny list the console applies, checked the same way.
        blocked = self._perms.blocked_reason("bash", {"command": command})
        if blocked:
            raise DevServerError(f"refused: {blocked}")
        # The manager owns the process group; a shell-backgrounded command
        # would orphan the real server behind an exiting shell.
        if command.rstrip().endswith("&"):
            raise DevServerError(
                "do not background the command with '&'; the server is managed for you"
            )

        resolved = name.strip() or self._default_name(command)
        with self._lock:
            existing = self._runs.get(resolved)
            if existing is not None and existing.running:
                raise DevServerError(
                    f"'{resolved}' is already running (pid {existing.proc.pid}); "
                    "stop it first or pass a different name"
                )
            if sum(1 for run in self._runs.values() if run.running) >= MAX_SERVERS:
                raise DevServerError(f"already running {MAX_SERVERS} servers; stop one first")

            run = DevServerRun(resolved, command, cwd, port)
            shell = str(
                self._config.get("terminal_shell") or os.environ.get("SHELL") or "/bin/sh"
            )
            env = sanitized_child_environment({
                **os.environ,
                "PYTHONUNBUFFERED": "1",
                "TERM": "dumb",
                "FORCE_COLOR": "0",
                "NO_COLOR": "1",
            })
            try:
                run.proc = subprocess.Popen(  # noqa: S603 - running commands is the point
                    [shell, "-c", command],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    cwd=cwd or None,
                    env=env,
                    bufsize=0,
                    start_new_session=True,
                )
            except OSError as e:
                raise DevServerError(f"could not start: {e}") from e
            self._runs[resolved] = run

        threading.Thread(target=self._pump, args=(run,), daemon=True).start()

        ready = self._await_ready(run, should_stop=should_stop)
        return {**run.snapshot(), **ready, "tail": run.tail()}

    def _await_ready(
        self,
        run: DevServerRun,
        should_stop: Callable[[], bool] | None,
    ) -> dict[str, Any]:
        if run.port is None:
            # Nothing to probe; give the process a moment to fail fast.
            time.sleep(1.0)
            if not run.running:
                return {"ready": False, "reason": "exited"}
            return {"ready": True, "reason": "running (no port to probe)"}

        deadline = time.monotonic() + PORT_WAIT_SECONDS
        while time.monotonic() < deadline:
            if should_stop and should_stop():
                # The server was the point of this call; a stop aborts it too
                # rather than leaving a half-announced orphan running.
                self.stop(run.name)
                return {"ready": False, "reason": "stopped by the user"}
            if not run.running:
                return {"ready": False, "reason": "exited"}
            try:
                with socket.create_connection(("127.0.0.1", run.port), timeout=0.1):
                    return {"ready": True, "reason": "port open"}
            except OSError:
                time.sleep(PORT_POLL_SECONDS)
        return {"ready": False, "reason": f"port {run.port} not open after {int(PORT_WAIT_SECONDS)}s"}

    def _pump(self, run: DevServerRun) -> None:
        proc = run.proc
        if proc is None or proc.stdout is None:
            return
        buffer = b""
        while True:
            chunk = proc.stdout.read(65_536)
            if not chunk:
                break
            buffer += chunk
            *lines, buffer = buffer.split(b"\n")
            with run.lock:
                for raw in lines:
                    text = raw.decode("utf-8", "replace")[:MAX_LINE_CHARS]
                    run.ring.append(text)
        if buffer:
            with run.lock:
                run.ring.append(buffer.decode("utf-8", "replace")[:MAX_LINE_CHARS])
        code = proc.wait()
        with run.lock:
            run.ring.append(f"[server exited with code {code}]")

    # ----------------------------------------------------------------- control

    def status(self) -> list[dict[str, Any]]:
        with self._lock:
            runs = list(self._runs.values())
        return [{**run.snapshot(), "tail": run.tail()} for run in runs]

    def stop(self, name: str = "") -> list[str]:
        """Stop one named server, or every server when unnamed."""
        with self._lock:
            targets = [
                run for run in self._runs.values()
                if (not name or run.name == name) and run.running
            ]
        stopped: list[str] = []
        for run in targets:
            proc = run.proc
            if proc is None:
                continue
            signal_process_group(proc, signal.SIGTERM)
            deadline = time.monotonic() + TERM_GRACE_SECONDS
            while time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.05)
            if proc.poll() is None:
                signal_process_group(proc, signal.SIGKILL)
            stopped.append(run.name)
        with self._lock:
            for run in targets:
                self._runs.pop(run.name, None)
        return stopped

    def stop_all(self) -> int:
        return len(self.stop())

    @staticmethod
    def _default_name(command: str) -> str:
        try:
            words = shlex.split(command)
        except ValueError:
            words = command.split()
        return (words[0] if words else "server").rsplit("/", 1)[-1][:32]


__all__ = ["DevServerError", "DevServerManager", "DevServerRun"]
