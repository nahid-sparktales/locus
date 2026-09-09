"""Controller API for the optional independent runtime."""
from __future__ import annotations

import asyncio
import contextlib
import hmac
import time

from fastapi import APIRouter, Body, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse


def supervisor(app):
    runtime = getattr(app.state, "runtime", None)
    if runtime is None:
        raise HTTPException(404, "Independent runtime is not enabled")
    return runtime


def status(request: Request):
    return supervisor(request.app).status()


def heartbeat(request: Request):
    runtime = supervisor(request.app)
    runtime.controller_seen = time.monotonic()
    return {"ok": True}


async def detach(request: Request):
    await supervisor(request.app).detach()
    return {"ok": True}


async def worker_create(request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    try:
        worker = await runtime.ensure_worker(str(body.get("session_id") or ""), str(body.get("workspace") or ""),
                                             keep_running=body.get("keep_running"))
        return {"session_id": worker.session_id, "session_info": worker.session_info, "active": bool(worker.active_command),
                "path_prefix": f"/api/runtime/workers/{worker.session_id}",
                "websocket_path": f"/ws/runtime/{worker.session_id}"}
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(409, str(exc)) from exc


async def worker_update(session_id: str, request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    row = runtime.store.worker(session_id)
    if row is None:
        raise HTTPException(404, "Unknown runtime session")
    try:
        if "keep_running" in body:
            if not isinstance(body["keep_running"], bool):
                raise ValueError("keep_running must be a boolean")
            runtime.store.save_worker(session_id, row["workspace"], keep_running=body["keep_running"])
            from ..sessions import SessionMeta, session_agent_kind
            metadata = SessionMeta.get(session_id)
            kind = session_agent_kind(metadata)
            if kind in {"schedule", "event"} and metadata.get("agent_trigger_id"):
                runtime.store.set_automation(kind, metadata["agent_trigger_id"], body["keep_running"])
            for trigger in runtime.service.run_store.event_triggers():
                if trigger.get("target_session_id") == session_id:
                    runtime.store.set_automation("event", trigger["id"], body["keep_running"])
        action = body.get("action")
        if action == "stop":
            await runtime.stop_worker(session_id)
            runtime.store.state(session_id, "paused")
        elif action == "pause":
            await runtime.command(session_id, {"type": "interrupt", "reason": "app_shutdown"})
            runtime.store.state(session_id, "paused")
        elif action == "resume":
            if runtime.store.commands(session_id, "uncertain"):
                raise ValueError("Review the interrupted run through its recovery controls before resuming")
            runtime.store.state(session_id, "idle")
        elif action is not None:
            raise ValueError("Unknown worker action")
        return runtime.store.worker(session_id)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc


async def worker_command(session_id: str, request: Request, body: dict = Body(default_factory=dict)):
    try:
        return await supervisor(request.app).command(session_id, body)
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(409, str(exc)) from exc


async def decision_respond(request: Request, body: dict = Body(default_factory=dict)):
    try:
        await supervisor(request.app).resolve(str(body.get("id") or ""), str(body.get("fingerprint") or ""), body.get("response") or {})
        return {"ok": True}
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(409, str(exc)) from exc


def automation_update(kind: str, automation_id: str, request: Request, body: dict = Body(default_factory=dict)):
    if not isinstance(body.get("keep_running"), bool):
        raise HTTPException(422, "keep_running must be a boolean")
    try:
        supervisor(request.app).store.set_automation(kind, automation_id, body["keep_running"])
        return {"ok": True}
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc


async def credentials(request: Request, body: dict = Body(default_factory=dict)):
    """Write-only provisioning: controller-selected credentials stay off the event stream."""
    runtime = supervisor(request.app)
    kind = str(body.get("kind") or "")
    if kind not in {"connector", "account", "team"}:
        raise HTTPException(422, "Unknown credential kind")
    from ..runtime_store import identifier
    try:
        key = identifier(str(body.get("id") or ""))
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    runtime.private.set(f"{kind}:{key}", body.get("configuration"))
    if kind == "connector":
        for worker in runtime.workers.values():
            if not worker.active_command:
                await runtime.connector_capabilities(worker)
    return {"ok": True}


async def proxy(session_id: str, path: str, request: Request):
    runtime = supervisor(request.app)
    worker = runtime.workers.get(session_id)
    if worker is None:
        raise HTTPException(404, "The runtime worker is unavailable")
    body = await request.json() if request.method in {"POST", "PUT", "PATCH"} else None
    forwarded = "/" + path
    if request.url.query:
        forwarded += "?" + request.url.query
    try:
        # Reattaching to a running session is a read, never a destructive resume.
        if path == f"api/sessions/{session_id}/resume" and worker.session_info:
            return {"ok": True, "session_info": worker.session_info}
        return await runtime.request(worker, request.method, forwarded, body)
    except RuntimeError as exc:
        return JSONResponse({"detail": str(exc)}, status_code=getattr(exc, "status_code", 503))


async def socket_proxy(ws: WebSocket, session_id: str):
    runtime = getattr(ws.app.state, "runtime", None)
    token = str(getattr(ws.app.state, "auth_token", ""))
    if not runtime or ws.headers.get("origin") or not token or not hmac.compare_digest(ws.headers.get("x-locus-token", ""), token):
        await ws.close(code=1008)
        return
    worker = runtime.workers.get(session_id)
    if worker is None:
        await ws.close(code=1008, reason="Unknown worker")
        return
    await ws.accept()
    runtime.controller_seen = time.monotonic()
    subscriber = asyncio.Queue(maxsize=1024)
    worker.subscribers.add(subscriber)
    last = max(int(ws.query_params.get("after", "0")), 0)
    await ws.send_json({"type": "session_info", **worker.session_info})
    if last:
        while True:
            events = runtime.store.events(session_id, last)
            if not events:
                break
            for event in events:
                await ws.send_json(event)
                last = event["runtime_seq"]
    else:
        with runtime.store.runs._connect(readonly=True) as db:
            last = db.execute("SELECT COALESCE(MAX(seq),0) FROM runtime_events WHERE session_id=?", (session_id,)).fetchone()[0]
        await ws.send_json({"type": "runtime_cursor", "runtime_seq": last})
        for decision in runtime.store.decisions(session_id):
            await ws.send_json({**decision["event"], "runtime_decision": {"id": decision["id"], "fingerprint": decision["fingerprint"]}})

    async def pump():
        nonlocal last
        while True:
            event = await subscriber.get()
            if event.get("type") == "runtime_resync_required":
                await ws.close(code=1013, reason="Reconnect to restore saved events")
                return
            if event.get("runtime_seq", 0) > last:
                await ws.send_json(event)
                last = event["runtime_seq"]

    sending = asyncio.create_task(pump())
    try:
        while True:
            message = await ws.receive_json()
            runtime.controller_seen = time.monotonic()
            try:
                await runtime.command(session_id, message)
            except (ValueError, RuntimeError) as exc:
                await ws.send_json({"type": "command_error", "operation": message.get("type"), "message": str(exc)})
    except WebSocketDisconnect:
        pass
    finally:
        worker.subscribers.discard(subscriber)
        await runtime.controller_left(worker)
        sending.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await sending


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/runtime", status, methods=["GET"])
    router.add_api_route("/api/runtime/heartbeat", heartbeat, methods=["POST"])
    router.add_api_route("/api/runtime/detach", detach, methods=["POST"])
    router.add_api_route("/api/runtime/workers", worker_create, methods=["POST"])
    router.add_api_route("/api/runtime/workers/{session_id}", worker_update, methods=["PATCH"])
    router.add_api_route("/api/runtime/workers/{session_id}/commands", worker_command, methods=["POST"])
    router.add_api_route("/api/runtime/decisions/respond", decision_respond, methods=["POST"])
    router.add_api_route("/api/runtime/automations/{kind}/{automation_id}", automation_update, methods=["PATCH"])
    router.add_api_route("/api/runtime/credentials", credentials, methods=["POST"])
    router.add_api_route("/api/runtime/workers/{session_id}/{path:path}", proxy, methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
    router.add_api_websocket_route("/ws/runtime/{session_id}", socket_proxy)
