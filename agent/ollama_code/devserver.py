"""Long-lived development servers the agent starts and owns.

This is deliberately separate from the app-owned interactive Terminal. The
agent can own several named development servers with no fixed deadline and a
bounded ring of recent output. The agent reads that output through the
``status`` action, while the user watches the page itself in the Browser tab.

Services outlive the conversation that started them and die with the backend:
``stop_all`` runs when the backend shuts down. The native Terminal has a
separate lifetime owned by the app.

A workspace can name its servers in ``.locus/launch.json`` so the agent starts
them by name instead of guessing a command from the package manifest — and so a
server someone already has running can be *attached to* rather than started
twice on a port that is busy.
"""
from __future__ import annotations

import json
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

#: Where a workspace names its servers. Same shape as the editor launch files
#: people already keep, so an existing one can usually be copied across.
LAUNCH_FILE = os.path.join(".locus", "launch.json")
#: A launch file is hand-written configuration, not data; anything this size is
#: not one.
MAX_LAUNCH_BYTES = 256 * 1024


def _loopback_port_is_open(port: int) -> bool:
    """Probe both loopback families without trusting a startup banner.

    macOS commonly resolves ``localhost`` to ``::1`` first. Vite-based servers
    may therefore listen only on IPv6 even though their banner says
    ``http://localhost:<port>``. Probing only 127.0.0.1 reports a false timeout
    while the site is already available in the browser.
    """
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, port), timeout=0.1):
                return True
        except OSError:
            continue
    return False


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

    #: Words that mark a line as worth seeing when only errors were asked for.
    #: Substring matching, because build tools agree on the vocabulary and on
    #: nothing else about their output format.
    ERROR_MARKERS = ("error", "err!", "fatal", "exception", "traceback",
                     "failed", "failure", "cannot find", "not found")

    def tail(self, lines: int = 40, level: str = "all", search: str = "") -> str:
        """Recent output, optionally narrowed.

        Filtering happens on the way out rather than on the way in: a line that
        looks uninteresting while it scrolls past is often the one that explains
        the crash three lines later, so the ring keeps everything.
        """
        with self.lock:
            recent = list(self.ring)
        if level == "error":
            recent = [
                line for line in recent
                if any(marker in line.lower() for marker in self.ERROR_MARKERS)
            ]
        if search:
            needle = search.lower()
            recent = [line for line in recent if needle in line.lower()]
        return "\n".join(recent[-max(1, lines):])

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
        # The same deny list used for every agent-initiated shell command.
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
                # The manager, not the chat turn, owns this process. Stopping
                # the task stops waiting for readiness but deliberately leaves
                # the service alive for the Terminal panel to inspect or stop.
                return {
                    "ready": run.running,
                    "reason": "detached; readiness check stopped with the task",
                    "detached": True,
                }
            if not run.running:
                return {"ready": False, "reason": "exited"}
            if _loopback_port_is_open(run.port):
                return {"ready": True, "reason": "port open"}
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

    def status(
        self,
        lines: int = 40,
        level: str = "all",
        search: str = "",
    ) -> list[dict[str, Any]]:
        with self._lock:
            runs = list(self._runs.values())
        return [
            {**run.snapshot(), "tail": run.tail(lines=lines, level=level, search=search)}
            for run in runs
        ]

    def stop(self, name: str = "") -> list[str]:
        """Stop and forget one named service, or every service when unnamed."""
        with self._lock:
            matches = [
                run for run in self._runs.values()
                if not name or run.name == name
            ]
        for run in matches:
            if not run.running:
                continue
            proc = run.proc
            if proc is None:
                continue
            signal_process_group(proc, signal.SIGTERM)
            deadline = time.monotonic() + TERM_GRACE_SECONDS
            while time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.05)
            if proc.poll() is None:
                signal_process_group(proc, signal.SIGKILL)
        with self._lock:
            for run in matches:
                if self._runs.get(run.name) is run:
                    self._runs.pop(run.name, None)
        return [run.name for run in matches]

    def stop_all(self) -> int:
        return len(self.stop())

    # ---------------------------------------------------------- configurations

    def configurations(self, workspace: str) -> list[dict[str, Any]]:
        """Read ``.locus/launch.json``, or return nothing if there is none.

        Never raises for a missing or malformed file: a broken launch file
        should degrade to "no named configurations", not break every dev-server
        call in the workspace.
        """
        path = os.path.join(workspace or "", LAUNCH_FILE)
        try:
            if os.path.getsize(path) > MAX_LAUNCH_BYTES:
                return []
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        except (OSError, ValueError):
            return []
        raw = document.get("configurations") if isinstance(document, dict) else None
        if not isinstance(raw, list):
            return []
        found = []
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            name = str(entry.get("name") or "").strip()
            if not name:
                continue
            executable = str(entry.get("runtimeExecutable") or "").strip()
            args = entry.get("runtimeArgs")
            args = [str(a) for a in args] if isinstance(args, list) else []
            port = entry.get("port")
            found.append({
                "name": name,
                "command": " ".join(shlex.quote(p) for p in ([executable, *args] if executable else [])),
                "port": int(port) if isinstance(port, int) else None,
                "cwd": str(entry.get("cwd") or "").strip(),
                "url": str(entry.get("url") or "").strip(),
            })
        return found

    def configuration(self, workspace: str, name: str) -> dict[str, Any] | None:
        wanted = name.strip().lower()
        for entry in self.configurations(workspace):
            if entry["name"].lower() == wanted:
                return entry
        return None

    def attach(self, name: str, url: str, port: int | None, cwd: str) -> dict[str, Any]:
        """Record a server someone else is running, without spawning anything.

        A configuration with a URL and no command means "this is already up" —
        starting a second copy would only fight the first for the port.
        """
        if port is not None and not _loopback_port_is_open(port):
            raise DevServerError(
                f"nothing is listening on port {port}; start '{name}' yourself first, "
                "or give the configuration a runtimeExecutable"
            )
        return {
            "name": name,
            "command": "",
            "cwd": cwd,
            "port": port,
            "pid": None,
            "running": True,
            "exit_code": None,
            "attached": True,
            "url": url,
            "ready": True,
            "reason": "attached to a server that was already running",
            "tail": "",
        }

    @staticmethod
    def _default_name(command: str) -> str:
        try:
            words = shlex.split(command)
        except ValueError:
            words = command.split()
        return (words[0] if words else "server").rsplit("/", 1)[-1][:32]


__all__ = ["DevServerError", "DevServerManager", "DevServerRun"]
