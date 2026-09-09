"""Independent worker supervisor. The desktop is a replaceable controller."""
from __future__ import annotations

import asyncio
import contextlib
import json
import os
import secrets
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import requests
from websockets.asyncio.client import connect

from .runtime_store import PrivateStore, RuntimeStore, identifier

TURN_COMMANDS = {"user_message", "retry_last"}
DECISION_EVENTS = {"permission_request", "question_required", "dispatch_plan_ready", "mcp_input_request"}
NATIVE_EVENTS = {"computer_action_request", "browser_action_request", "simulator_action_request", "notes_action_request", "identity_context_request", "identity_action_request"}
CONFIG_PATHS = {"/api/provider", "/api/permissions", "/api/config", "/api/images/provider"}


@dataclass
class Worker:
    session_id: str
    process: asyncio.subprocess.Process
    port: int
    token: str
    ws: Any = None
    pump: asyncio.Task | None = None
    log_task: asyncio.Task | None = None
    subscribers: set = field(default_factory=set)
    active_command: str = ""
    last_controller: float = 0
    session_info: dict = field(default_factory=dict)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class RuntimeSupervisor:
    def __init__(self, app, root: Path, *, port: int, limit: int = 2):
        self.app = app
        self.service = app.state.service
        self.store = RuntimeStore(self.service.run_store)
        self.private = PrivateStore(root)
        self.root = root
        self.port = port
        self.limit = max(1, min(limit, 4))
        self.workers: dict[str, Worker] = {}
        self.launch_lock = asyncio.Lock()
        self.coordinator: asyncio.Task | None = None
        self.controller_seen = 0.0
        self.stopping = False
        self.automation = None
        identity = self.private.read().get("runtime_id") or secrets.token_hex(16)
        self.private.set("runtime_id", identity)
        self.runtime_id = identity

    async def start(self) -> None:
        # A prior process's sent work has an uncertain outcome. Never replay it.
        for row in self.store.workers():
            if row["state"] not in {"idle", "paused", "completed"} or self.store.commands(row["session_id"], "sent"):
                self.store.interrupted(row["session_id"])
        self.coordinator = asyncio.create_task(self.coordinate())

    async def close(self) -> None:
        self.stopping = True
        if self.coordinator:
            self.coordinator.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.coordinator
        if self.automation:
            await self.automation.close()
        for session_id in list(self.workers):
            await self.stop_worker(session_id)

    def status(self) -> dict:
        return {"id": self.runtime_id, "version": 1, "protocol_version": 1,
                "independent": True, "connected": True, "workers": self.store.workers(),
                "pending_approvals": self.store.decisions(), "max_active_chats": self.limit,
                "capabilities": {"durable_events": True, "background_schedules": True,
                                 "desktop_requires_controller": True, "remote_chatgpt": True}}

    async def ensure_worker(self, session_id: str, workspace: str, *, keep_running: bool | None = None) -> Worker:
        identifier(session_id)
        async with self.launch_lock:
            record = self.store.save_worker(session_id, workspace, keep_running=keep_running)
            existing = self.workers.get(session_id)
            if existing and existing.process.returncode is None:
                return existing
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            token = secrets.token_hex(32)
            environment = dict(os.environ)
            environment.update(LOCUS_PARENT_PID=str(os.getpid()), LOCUS_AGENT_TOKEN=token,
                               LOCUS_RUNTIME_CHILD="1", LOCUS_DOCUMENT_COORDINATOR="0",
                               LOCUS_CODEX_BROKER_URL=f"ws://127.0.0.1:{self.port}/ws/internal/codex",
                               LOCUS_CODEX_BROKER_TOKEN=self.private.token())
            environment.pop("LOCUS_RUNTIME_HOME", None)
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "ollama_code.server", "--host", "127.0.0.1", "--port", str(port),
                "--cwd", workspace, env=environment, stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
            worker = Worker(session_id, process, port, token)
            self.workers[session_id] = worker
            # Always drain child output; provider errors may include secrets, so
            # raw child output is deliberately not exported as a runtime event.
            worker.log_task = asyncio.create_task(self._drain(worker))
            try:
                for _ in range(120):
                    if process.returncode is not None:
                        raise RuntimeError("The agent process exited during startup")
                    try:
                        await self.request(worker, "GET", "/api/health", timeout=1)
                        break
                    except (requests.RequestException, RuntimeError):
                        await asyncio.sleep(0.25)
                else:
                    raise RuntimeError("The agent did not become ready")
                saved = self.private.read().get(f"worker:{session_id}", {})
                for path, body in saved.items():
                    if path in CONFIG_PATHS:
                        await self.request(worker, "POST", path, body)
                resumed = await self.request(worker, "POST", f"/api/sessions/{session_id}/resume", {})
                worker.session_info = resumed.get("session_info", {})
                worker.ws = await connect(f"ws://127.0.0.1:{port}/ws/chat",
                                          additional_headers={"X-Locus-Token": token}, max_size=4*1024*1024)
                worker.pump = asyncio.create_task(self._pump(worker))
                await self.connector_capabilities(worker)
                self.store.state(session_id, "interrupted" if record["state"] == "interrupted" else "idle")
                return worker
            except BaseException:
                await self.stop_worker(session_id)
                raise

    async def _drain(self, worker: Worker) -> None:
        if worker.process.stdout:
            while await worker.process.stdout.read(65536):
                pass

    async def request(self, worker: Worker, method: str, path: str, body=None, *, timeout=30) -> dict:
        def invoke():
            with requests.Session() as client:
                client.trust_env = False
                response = client.request(method, f"http://127.0.0.1:{worker.port}{path}",
                                          headers={"X-Locus-Token": worker.token}, json=body,
                                          timeout=timeout, allow_redirects=False)
                if response.status_code >= 400:
                    error = RuntimeError(response.text[:2000])
                    error.status_code = response.status_code
                    raise error
                return response.json() if response.content else {}
        result = await asyncio.to_thread(invoke)
        if method in {"POST", "PUT", "PATCH"} and path in CONFIG_PATHS:
            saved = self.private.read().get(f"worker:{worker.session_id}", {})
            saved[path] = {**saved.get(path, {}), **(body or {})}
            self.private.set(f"worker:{worker.session_id}", saved)
        return result

    async def send(self, worker: Worker, message: dict) -> None:
        async with worker.send_lock:
            if worker.ws is None:
                raise RuntimeError("The agent is disconnected")
            await worker.ws.send(json.dumps(message))

    async def command(self, session_id: str, message: dict) -> dict:
        worker = self.workers.get(session_id)
        if not worker:
            row = self.store.worker(session_id)
            if not row:
                raise ValueError("Unknown runtime session")
            worker = await self.ensure_worker(session_id, row["workspace"])
        if message.get("type") in TURN_COMMANDS:
            key = self.enqueue(session_id, message)
            return {"ok": True, "state": "queued", "request_id": key}
        if message.get("type") in {"permission_decision", "question_response", "dispatch_decision", "mcp_input_response"} | {kind.replace("request", "result") for kind in NATIVE_EVENTS}:
            decision = message.pop("runtime_decision", {})
            await self.resolve(str(decision.get("id", "")), str(decision.get("fingerprint", "")), message)
        elif message.get("type") == "set_connector_control":
            await self.connector_capabilities(worker)
        else:
            await self.send(worker, message)
        return {"ok": True}

    def enqueue(self, session_id: str, message: dict) -> str:
        from .runstore import sanitize_event
        message = dict(message)
        message.setdefault("request_id", message.get("run_id") or secrets.token_hex(16))
        key = self.store.enqueue(session_id, sanitize_event(message))
        self.private.set(f"command:{key}", message)
        return key

    async def publish(self, worker: Worker, event: dict) -> None:
        durable = self.store.append(worker.session_id, event)
        for subscriber in tuple(worker.subscribers):
            try:
                subscriber.put_nowait(durable)
            except asyncio.QueueFull:
                # The client reconnects from its acknowledged cursor.
                worker.subscribers.discard(subscriber)
                while not subscriber.empty():
                    subscriber.get_nowait()
                subscriber.put_nowait({"type": "runtime_resync_required"})

    async def _pump(self, worker: Worker) -> None:
        try:
            async for raw in worker.ws:
                event = json.loads(raw)
                kind = event.get("type")
                if kind == "session_info":
                    worker.session_info = event
                if kind in DECISION_EVENTS | NATIVE_EVENTS:
                    decision = self.store.decision(worker.session_id, event)
                    event["runtime_decision"] = {"id": decision["id"], "fingerprint": decision["fingerprint"]}
                    self.store.state(worker.session_id, "waiting_for_locus" if kind in NATIVE_EVENTS else "waiting_approval")
                if kind == "turn_done":
                    if worker.active_command:
                        self.store.command_state(worker.active_command, "completed")
                    worker.active_command = ""
                    if self.store.worker(worker.session_id)["state"] != "paused":
                        self.store.state(worker.session_id, "idle")
                if kind == "connector_action_request":
                    await self._connector_action(worker, event)
                    # Only the service performs connector actions. Never ask the desktop twice.
                    continue
                await self.publish(worker, event)
        except asyncio.CancelledError:
            raise
        except Exception:
            if not self.stopping:
                self.store.interrupted(worker.session_id)
                await self.publish(worker, {"type": "runtime_worker_interrupted", "message": "The worker stopped. Review saved progress before resuming."})

    async def connector_capabilities(self, worker: Worker) -> None:
        saved = self.private.read()
        connections = [{"id": row["id"], "kind": row["kind"]}
                       for row in self.service.run_store.connector_connections()
                       if row.get("enabled", True) and saved.get(f"connector:{row['id']}")]
        await self.send(worker, {"type": "set_connector_control", "capability": {"protocol_version": 1, "connections": connections}})

    async def controller_left(self, worker: Worker) -> None:
        if worker.subscribers:
            return
        record = self.store.worker(worker.session_id)
        if record and not record["keep_running"]:
            self.store.state(worker.session_id, "paused")
            if worker.active_command:
                await self.send(worker, {"type": "interrupt", "reason": "app_shutdown"})

    async def _connector_action(self, worker: Worker, event: dict) -> None:
        from .runtime_connectors import RuntimeConnectors
        # Persist the intent before an external effect. An interrupted receipt is
        # uncertain, never an invitation to resend a message or repeat a write.
        action_id = str(event.get("idempotency_key") or event.get("request_id") or "")
        with self.store.runs._connect() as db:
            previous = db.execute("SELECT payload FROM runtime_events WHERE session_id=? AND json_extract(payload,'$.action_id')=? ORDER BY seq DESC LIMIT 1", (worker.session_id, action_id)).fetchone()
        if previous:
            receipt = json.loads(previous[0])
            result = receipt.get("result") or {"error": "This external action has an uncertain outcome; review it before retrying."}
        else:
            self.store.append(worker.session_id, {"type": "connector_action_intent", "action_id": action_id})
            result = await RuntimeConnectors(self).action(event)
            self.store.append(worker.session_id, {"type": "connector_action_receipt", "action_id": action_id, "result": result})
        await self.send(worker, {"type": "connector_action_result", "request_id": event.get("request_id"), "result": result})

    async def resolve(self, key: str, fingerprint: str, response: dict) -> None:
        decisions = [row for row in self.store.decisions() if row["id"] == key]
        if not decisions:
            raise ValueError("This decision is no longer current")
        event = decisions[0]["event"]
        expected = {"permission_request": "permission_decision", "question_required": "question_response", "dispatch_plan_ready": "dispatch_decision", "mcp_input_request": "mcp_input_response"}.get(event["type"], event["type"].replace("request", "result"))
        identity_field = "run_id" if expected == "dispatch_decision" else "request_id"
        if response.get("type") != expected or response.get(identity_field) != event.get(identity_field):
            raise ValueError("This response does not match the pending decision")
        session_id = self.store.resolve(key, fingerprint, response)
        worker = self.workers.get(session_id)
        if not worker or worker.process.returncode is not None:
            self.store.interrupted(session_id)
            raise ValueError("The worker stopped; review the interrupted action before resuming")
        await self.send(worker, response)
        with self.store.runs._connect() as db:
            db.execute("UPDATE runtime_decisions SET state='resolved' WHERE id=? AND state='sending'", (key,))
        self.store.state(session_id, "running" if worker.active_command else "idle")

    async def stop_worker(self, session_id: str) -> None:
        worker = self.workers.pop(session_id, None)
        if not worker:
            return
        if worker.pump:
            worker.pump.cancel()
        if worker.ws:
            await worker.ws.close()
        if worker.process.returncode is None:
            worker.process.terminate()
            try:
                await asyncio.wait_for(worker.process.wait(), timeout=5)
            except TimeoutError:
                worker.process.kill()
                await worker.process.wait()
        if worker.active_command:
            self.store.interrupted(session_id)
        if worker.log_task:
            await worker.log_task

    async def detach(self) -> None:
        self.controller_seen = 0
        for session_id, worker in list(self.workers.items()):
            record = self.store.worker(session_id)
            if not record or not record["keep_running"]:
                if worker.active_command:
                    await self.send(worker, {"type": "interrupt", "reason": "app_shutdown"})
                self.store.state(session_id, "paused")

    async def coordinate(self) -> None:
        from .runtime_automation import RuntimeAutomation
        automation = self.automation = RuntimeAutomation(self)
        while True:
            try:
                if self.controller_seen and time.monotonic() - self.controller_seen > 35:
                    await self.detach()
                await automation.tick()
                active = sum(bool(worker.active_command) for worker in self.workers.values())
                for record in self.store.workers():
                    if active >= self.limit:
                        break
                    if record["state"] in {"paused", "interrupted", "waiting_for_locus", "waiting_approval"}:
                        continue
                    if not self.controller_seen and not record["keep_running"]:
                        continue
                    commands = self.store.commands(record["session_id"])
                    if not commands:
                        continue
                    worker = await self.ensure_worker(record["session_id"], record["workspace"])
                    if worker.active_command:
                        continue
                    # Shared local workspaces retain single-writer admission.
                    if any(other.active_command and self.store.worker(other.session_id)["workspace"] == record["workspace"]
                           for other in self.workers.values() if other is not worker):
                        continue
                    item = commands[0]
                    self.store.command_state(item["id"], "sent")
                    worker.active_command = item["id"]
                    self.store.state(worker.session_id, "running")
                    await self.send(worker, self.private.read().get(f"command:{item['id']}", item["command"]))
                    active += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.store.append("runtime", {"type": "runtime_error", "message": str(exc)[:1000]})
            await asyncio.sleep(1)


def main() -> None:
    import argparse

    import uvicorn

    from . import server
    parser = argparse.ArgumentParser(description="Independent Locus agent runtime")
    parser.add_argument("--home", required=True)
    parser.add_argument("--port", type=int, default=8793)
    parser.add_argument("--cwd", default=os.getcwd())
    args = parser.parse_args()
    root = Path(args.home).expanduser().resolve()
    private = PrivateStore(root)
    import fcntl
    ownership = (root / "supervisor.lock").open("a")
    try:
        fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("This runtime already has a supervisor") from None
    os.environ["LOCUS_RUNTIME_COORDINATOR"] = "1"
    os.environ.pop("LOCUS_PARENT_PID", None)
    app = server.create_app()
    app.state.auth_token = private.token()
    app.state.service = server.build_service(cwd=args.cwd)
    app.state.runtime = RuntimeSupervisor(app, root, port=args.port)
    descriptor = root / "endpoint.json"
    descriptor.write_text(json.dumps({"id": app.state.runtime.runtime_id, "url": f"http://127.0.0.1:{args.port}", "version": 1}))
    os.chmod(descriptor, 0o600)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning", timeout_graceful_shutdown=8)


if __name__ == "__main__":
    main()
