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


async def status(request: Request):
    runtime = supervisor(request.app)
    value = runtime.status()
    if not hasattr(runtime, "readiness_cache"):
        runtime.readiness_cache, runtime.readiness_tasks = {}, {}
    async def refresh_account(key, configuration):
        provider = configuration.get("provider", "remote")
        readiness = "configured; credentials not yet verified"
        try:
            if provider == "claude_plan":
                from .claude import account_payload
                account = await asyncio.to_thread(account_payload, runtime.service, str(configuration.get("account_id") or ""))
                readiness = account["status"]
            elif provider == "chatgpt":
                from .providers import chatgpt_account_payload
                account = await asyncio.to_thread(chatgpt_account_payload, runtime.service, home_id=str(configuration.get("codex_home_id") or ""))
                readiness = account["status"]
            elif provider == "ollama":
                readiness = "ready" if await asyncio.to_thread(runtime.providers.healthy, str(configuration.get("host") or "http://127.0.0.1:11434")) else "unavailable"
        except Exception:
            readiness = "unavailable"
        runtime.readiness_cache[key] = (time.monotonic(), readiness)
    accounts = []
    for key, configuration in runtime.private.read().items():
        if not key.startswith("account:") or not isinstance(configuration, dict):
            continue
        prior_time, readiness = runtime.readiness_cache.get(key, (0, "checking account"))
        task = runtime.readiness_tasks.get(key)
        if time.monotonic() - prior_time > 30 and (task is None or task.done()):
            runtime.readiness_tasks[key] = asyncio.create_task(refresh_account(key, configuration))
        accounts.append({"id": key[8:], "provider": configuration.get("provider", "remote"), "model": configuration.get("model", ""), "readiness": readiness})
    return {**value, "accounts": accounts}


def heartbeat(request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    runtime.controller_seen = time.monotonic()
    if not body.get("relayed"):
        runtime.direct_controller_seen = runtime.controller_seen
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
        elif action == "acknowledge_interruption":
            reviewed = body.get("reviewed_command_ids")
            current = runtime.store.commands(session_id, "uncertain")
            if not isinstance(reviewed, list) or not current or sorted(reviewed) != sorted(item["id"] for item in current):
                raise ValueError("Review every current interrupted request before allowing new work")
            await runtime.stop_worker(session_id)
            with runtime.store.runs._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                latest = [item[0] for item in db.execute("SELECT id FROM runtime_commands WHERE session_id=? AND state='uncertain'", (session_id,))]
                if sorted(latest) != sorted(reviewed):
                    raise ValueError("Another request was interrupted; reload the saved progress")
                db.execute("UPDATE runtime_commands SET state='abandoned' WHERE session_id=? AND state='uncertain'", (session_id,))
            runtime.store.append(session_id, {"type": "runtime_interruption_reviewed", "command_ids": reviewed,
                                            "message": "Saved work retained. Interrupted requests will not be replayed."})
            runtime.store.state(session_id, "idle")
        elif action == "resume":
            if any(item["state"] == "uncertain" for item in runtime.store.decisions(session_id, include_inflight=True)):
                raise ValueError("A desktop action has an uncertain outcome. Review its effects and stop this agent before allowing new work.")
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
    if path == "api/runtime/native/claim" and request.method == "POST":
        try:
            return runtime.store.claim_native(session_id, str(body.get("id") or ""), str(body.get("fingerprint") or ""))
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc
    forwarded = "/" + path
    if request.url.query:
        forwarded += "?" + request.url.query
    controller_work = request.method == "POST" and path.startswith("api/reusable-checks/") and path.rsplit("/", 1)[-1] in {"propose", "test", "verify"}
    recovery_turn = request.method == "POST" and path.startswith("api/orchestrations/") and path.rsplit("/", 1)[-1] in {"resume", "retry", "reassign", "replay", "duplicate", "run-with-locus"}
    task_file_work = request.method == "POST" and path in {
        f"api/sessions/{session_id}/task/restore", f"api/sessions/{session_id}/task/checks",
    }
    admitted = controller_work or recovery_turn or task_file_work
    if admitted:
        if runtime.paused:
            raise HTTPException(409, "Resume this runtime before starting work.")
        if worker.active_command or any(other.active_command and runtime.store.worker(other.session_id)["workspace"] == runtime.store.worker(session_id)["workspace"] for other in runtime.workers.values()) or sum(bool(other.active_command) for other in runtime.workers.values()) >= runtime.limit:
            raise HTTPException(409, "Wait for an available runtime slot before running checks or changing task files.")
        # Persist admission before the request crosses the worker boundary. The
        # operation outlives its HTTP subscriber, just like a websocket turn.
        operation = runtime.store.enqueue(session_id, {"type": "controller_check", "path": path})
        runtime.store.command_state(operation, "sent")
        worker.active_command = operation
        runtime.store.state(session_id, "running")

    async def invoke():
        settled = not admitted
        launched = False
        try:
            if path == f"api/sessions/{session_id}/resume" and worker.session_info:
                return {"ok": True, "session_info": worker.session_info}
            value = await runtime.request(worker, request.method, forwarded, body, timeout=660 if controller_work else 30)
            settled = True
            launched = recovery_turn and value.get("ok") is True
            if launched:
                for previous in runtime.store.commands(session_id, "uncertain"):
                    if previous["command"].get("run_id") == value.get("source_run_id"):
                        runtime.store.command_state(previous["id"], "superseded_by_recovery")
            return value
        except RuntimeError as exc:
            # A validated worker rejection is final. Transport failures and
            # server errors retain uncertainty and workspace ownership.
            settled = 400 <= getattr(exc, "status_code", 503) < 500
            return JSONResponse({"detail": str(exc)}, status_code=getattr(exc, "status_code", 503))
        except Exception:
            return JSONResponse({"detail": "The worker connection was interrupted. Review its saved progress before retrying."}, status_code=503)
        finally:
            if admitted and not launched:
                runtime.store.command_state(operation, "completed" if settled else "uncertain")
                if settled and worker.active_command == operation:
                    worker.active_command = ""
                    if runtime.store.worker(session_id)["state"] != "paused":
                        runtime.store.state(session_id, "idle")
                elif not settled:
                    runtime.store.state(session_id, "interrupted")

    task = asyncio.create_task(invoke())
    # Keep a strong reference until the worker request finishes even when the
    # controller cancels its HTTP connection.
    if not hasattr(runtime, "controller_operations"):
        runtime.controller_operations = set()
    runtime.controller_operations.add(task)
    task.add_done_callback(runtime.controller_operations.discard)
    return await asyncio.shield(task)


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
    runtime.direct_controller_seen = runtime.controller_seen
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
                await ws.send_json(runtime.restore_decision_event(event))
                last = event["runtime_seq"]
    else:
        with runtime.store.runs._connect(readonly=True) as db:
            last = db.execute("SELECT COALESCE(MAX(seq),0) FROM runtime_events WHERE session_id=?", (session_id,)).fetchone()[0]
        await ws.send_json({"type": "runtime_cursor", "runtime_seq": last})
        for decision in runtime.store.decisions(session_id):
            await ws.send_json(runtime.restore_decision_event({**decision["event"], "runtime_decision": {"id": decision["id"], "fingerprint": decision["fingerprint"]}}))

    async def pump():
        nonlocal last
        while True:
            event = await subscriber.get()
            if event.get("type") == "runtime_resync_required":
                await ws.close(code=1013, reason="Reconnect to restore saved events")
                return
            if event.get("runtime_seq", 0) > last:
                await ws.send_json(runtime.restore_decision_event(event))
                last = event["runtime_seq"]

    sending = asyncio.create_task(pump())
    try:
        while True:
            message = await ws.receive_json()
            runtime.controller_seen = time.monotonic()
            runtime.direct_controller_seen = runtime.controller_seen
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


async def providers_ollama(request: Request, body: dict = Body()):
    try:
        return await supervisor(request.app).providers.ensure_ollama(str(body.get("host") or "http://127.0.0.1:11434"))
    except (ValueError, OSError) as exc:
        raise HTTPException(409, str(exc)) from exc


def resume_runtime(request: Request):
    runtime = supervisor(request.app)
    runtime.paused = False
    runtime.private.set("paused", False)
    return {"ok": True}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/runtime/providers/ollama", providers_ollama, methods=["POST"])
    router.add_api_route("/api/runtime/resume", resume_runtime, methods=["POST"])
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
