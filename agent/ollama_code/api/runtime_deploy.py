"""SSH connection, snapshot review, and isolated remote execution endpoints."""
from __future__ import annotations

import asyncio
import base64
import json
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, Body, HTTPException, Request

from .. import runtime_snapshots as snapshots
from ..runtime_store import identifier
from .runtime import supervisor


def remotes(request):
    runtime = supervisor(request.app)
    if not hasattr(runtime, "remotes"):
        from ..runtime_remote import RemoteRuntimes
        runtime.remotes = RemoteRuntimes(runtime)
    return runtime.remotes


async def invoke(call, *args, **kwargs):
    try:
        return await asyncio.to_thread(call, *args, **kwargs)
    except (ValueError, OSError, KeyError) as exc:
        raise HTTPException(409, str(exc)) from exc


def list_remotes(request: Request):
    return {"runtimes": remotes(request).records()}


async def validate_host(request: Request, body: dict = Body(default_factory=dict)):
    return await invoke(remotes(request).validate, str(body.get("host", "")))


async def install_host(request: Request, body: dict = Body(default_factory=dict)):
    return await invoke(remotes(request).install, str(body.get("host", "")), str(body.get("package", "")), str(body.get("sha256", "")))


async def remote_status(runtime_id: str, request: Request):
    return await invoke(remotes(request).status, runtime_id)


async def remote_remove(runtime_id: str, request: Request):
    return await invoke(remotes(request).remove, runtime_id)


async def remote_call(runtime_id: str, request: Request, body: dict = Body(default_factory=dict)):
    method = str(body.get("method", "GET"))
    if method not in {"GET", "POST", "PATCH", "DELETE"}:
        raise HTTPException(422, "Invalid method")
    return await invoke(remotes(request).request, runtime_id, method, str(body.get("path", "")), body.get("body"))


async def snapshot_preview(request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    review = await invoke(snapshots.preview, Path(str(body.get("workspace", ""))), body.get("selected_files"))
    review_id = uuid.uuid4().hex
    directory = runtime.root / "reviews"
    directory.mkdir(exist_ok=True, mode=0o700)
    (directory / (review_id + ".json")).write_text(json.dumps(review))
    return {**review, "id": review_id}


async def deploy(runtime_id: str, request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    try:
        review_id = identifier(str(body.get("review_id", "")))
        review = json.loads((runtime.root / "reviews" / (review_id + ".json")).read_text())
        if body.get("fingerprint") != review["fingerprint"]:
            raise ValueError("Review this project snapshot before deploying")
        configuration = dict(body.get("configuration") or {})
        from ..reusable_checks import ReusableCheckStore
        store = ReusableCheckStore(runtime.service.run_store)
        selected = body.get("selected_checks") or []
        frozen = store.freeze(review["workspace"], review["workspace"], agent_id=str(configuration.get("agent_id") or ""), selected=selected)
        configuration["reusable_checks"] = [store.get(item["id"], item["version"]) for item in frozen]
        return await invoke(remotes(request).deploy, runtime_id, review, configuration)
    except (ValueError, OSError) as exc:
        raise HTTPException(409, str(exc)) from exc


async def retrieve(runtime_id: str, deployment_id: str, request: Request):
    return await invoke(remotes(request).retrieve, runtime_id, deployment_id)


async def apply_return(runtime_id: str, deployment_id: str, request: Request, body: dict = Body(default_factory=dict)):
    manager = remotes(request)
    record = manager.record(runtime_id)
    deployment = next((item for item in record["deployments"] if item["id"] == deployment_id), None)
    if not deployment or not deployment.get("return"):
        raise HTTPException(409, "Retrieve and review this deployment's results first")
    result = deployment["return"]
    return {"applied": await invoke(snapshots.apply_changes, deployment["baseline"], result["snapshot"], Path(result["directory"]), body.get("selected_files") or [])}


async def import_snapshot(request: Request, body: dict = Body(default_factory=dict)):
    runtime = supervisor(request.app)
    try:
        deployment_id = identifier(str(body.get("deployment_id") or uuid.uuid4().hex))
        imports = runtime.root / "imports"
        imports.mkdir(exist_ok=True, mode=0o700)
        descriptor = imports / (deployment_id + ".json")
        review, configuration = body["snapshot"], body.get("configuration") or {}
        previous = json.loads(descriptor.read_text()) if descriptor.exists() else None
        if previous and previous["fingerprint"] != review["fingerprint"]:
            raise ValueError("This deployment ID already identifies another snapshot")
        if previous and previous["state"] == "ready":
            return previous
        destination = runtime.root / "workspaces" / deployment_id
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        from ..sessions import SessionStore
        if not previous:
            # An interrupted rename may have installed the reviewed files before
            # its descriptor was written. Adopt only an identical untouched tree.
            if destination.exists() and snapshots.preview(destination)["fingerprint"] != review["fingerprint"]:
                raise ValueError("The interrupted upload has changed. Review it before deploying again")
            # Only a fresh staging directory is removed on a failed transfer.
            staging = destination.with_name(".upload-" + uuid.uuid4().hex)
            try:
                await invoke(snapshots.unpack, base64.b64decode(body["archive"], validate=True), staging, review["files"])
                import os
                if not destination.exists():
                    os.replace(staging, destination)
            finally:
                if staging.exists():
                    import shutil
                    shutil.rmtree(staging)
            session = SessionStore(cwd=str(destination))
            previous = {"id": deployment_id, "session_id": session.session_id, "workspace": str(destination), "fingerprint": review["fingerprint"], "state": "configuring", "created_at": time.time()}
            descriptor.write_text(json.dumps(previous))
        session_id = previous["session_id"]
        from ..reusable_checks import ReusableCheckStore
        check_store = ReusableCheckStore(runtime.service.run_store)
        imported_checks = configuration.get("reusable_checks") or []
        if not isinstance(imported_checks, list) or len(imported_checks) > 64:
            raise ValueError("Select at most 64 approved checks")
        for check in imported_checks:
            check_store.import_approved(check, str(destination), deployment_id)
        if configuration.get("agent_id"):
            from ..sessions import SessionMeta
            SessionMeta.update(session_id, agent_profile_id=str(configuration["agent_id"]))
        keep = configuration.get("keep_running") is True
        worker = await runtime.ensure_worker(session_id, str(destination), keep_running=keep)
        for kind in ("account", "connector"):
            for credential in configuration.get(kind + "s", []):
                key = identifier(credential["id"])
                runtime.private.set(f"{kind}:{key}", credential["configuration"])
                if kind == "connector" and credential.get("connection") and not runtime.service.run_store.connector_connection(key):
                    runtime.service.run_store.create_connector_connection({**credential["connection"], "id": key})
        provider = configuration.get("provider") or {}
        if not provider:
            raise ValueError("Select a model account for the remote agent")
        if provider.get("provider") == "ollama":
            await runtime.providers.ensure_ollama(str(provider.get("host") or "http://127.0.0.1:11434"))
        await runtime.request(worker, "POST", "/api/provider", provider)
        if provider.get("model"):
            await runtime.request(worker, "POST", "/api/config", {"model": provider["model"]})
        account_key = identifier(str(provider.get("account_id") or "ollama"))
        runtime.private.set(f"account:{account_key}", provider)
        await runtime.request(worker, "POST", "/api/permissions", configuration.get("permissions") or {"mode": "ask"})
        await runtime.connector_capabilities(worker)
        result = {"id": deployment_id, "session_id": session_id, "workspace": str(destination),
                  "fingerprint": review["fingerprint"], "keep_running": keep, "state": "ready", "created_at": time.time()}
        (imports / (deployment_id + ".baseline.json")).write_text(json.dumps({**review, "workspace": str(destination)}))
        if configuration.get("schedule") and not previous.get("schedule_id"):
            from .schedules import schedule_create
            schedule = runtime.service.run_store.schedule(deployment_id)
            if schedule is None:
                schedule = await invoke(schedule_create, runtime.service, {**configuration["schedule"], "id": deployment_id, "workspace_root": str(destination), "execution_environment": "local"})
            elif schedule.get("workspace_root") != str(destination):
                raise ValueError("The deployment schedule already belongs to another workspace")
            runtime.store.set_automation("schedule", schedule["id"], keep)
            runtime.private.set(f"automation:schedule:{schedule['id']}", configuration)
            result["schedule_id"] = schedule["id"]
            descriptor.write_text(json.dumps({**result, "state": "configuring"}))
        if configuration.get("prompt"):
            runtime.enqueue(worker.session_id, {"type": "user_message", "text": str(configuration["prompt"]), "request_id": deployment_id,
                                               "agent_config": configuration.get("agent_config") or {}, "mode": "work"})
        descriptor.write_text(json.dumps({**previous, **result}))
        return {**previous, **result}
    except (ValueError, OSError, KeyError) as exc:
        raise HTTPException(409, str(exc)) from exc


async def export_snapshot(deployment_id: str, request: Request):
    runtime = supervisor(request.app)
    try:
        descriptor = runtime.root / "imports" / (identifier(deployment_id) + ".json")
        record = json.loads(descriptor.read_text())
        workers = [worker for worker in runtime.store.workers() if worker["workspace"] == record["workspace"]]
        if any(worker["state"] in {"running", "waiting_for_locus", "waiting_approval"} for worker in workers):
            raise ValueError("Pause or finish this agent before retrieving a consistent snapshot")
        review = await invoke(snapshots.preview, Path(record["workspace"]))
        data = await invoke(snapshots.archive, review)
        runs = [run for run in runtime.service.run_store.list_runs(limit=500) if run.get("session_id") == record["session_id"] or run.get("workspace_root") == record["workspace"]]
        from ..usage_ledger import UsageLedger
        ledger = UsageLedger(runtime.service.run_store)
        usage = [row for row in ledger.records() if row["context"].get("workspace") == record["workspace"] or row["session_id"] == record["session_id"]]
        from ..task_state import TaskStateStore
        task_store = TaskStateStore(runtime.service.run_store)
        contracts = []
        with runtime.service.run_store._connect(readonly=True) as db:
            for row in db.execute("SELECT payload FROM task_records WHERE json_extract(payload,'$.workspace_root')=?", (record["workspace"],)):
                contract = json.loads(row[0])
                status, reason = task_store.completion(contract["id"])
                contracts.append({**contract, "verification_status": status, "verification_reason": reason, "evidence": task_store.receipts(contract["id"])})
        return {"task_contracts": contracts, "snapshot": review, "archive": base64.b64encode(data).decode(), "runs": runs, "usage_records": usage, "accounting": ledger.summarize(usage),
                "events": runtime.store.events(record["session_id"], limit=1000)}
    except (ValueError, OSError) as exc:
        raise HTTPException(409, str(exc)) from exc


async def pause_runtime(request: Request):
    runtime = supervisor(request.app)
    runtime.paused = True
    runtime.private.set("paused", True)
    for row in runtime.store.workers():
        runtime.store.state(row["session_id"], "paused")
        worker = runtime.workers.get(row["session_id"])
        if worker and worker.active_command:
            await runtime.send(worker, {"type": "interrupt", "reason": "app_shutdown"})
    runtime.controller_seen = 0
    return {"ok": True, "message": "Agents are checkpointing; wait until active work has drained before updating or stopping the service"}


def register_routes(router: APIRouter):
    for path, function, methods in [
        ("/api/runtime/webhooks/{connection_id}", webhook, ["POST"]),
        ("/api/runtime/remotes", list_remotes, ["GET"]),
        ("/api/runtime/remotes/validate", validate_host, ["POST"]),
        ("/api/runtime/remotes/install", install_host, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}", remote_status, ["GET"]),
        ("/api/runtime/remotes/{runtime_id}", remote_remove, ["DELETE"]),
        ("/api/runtime/remotes/{runtime_id}/control", remote_control, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/login", remote_login, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/request", remote_call, ["POST"]),
        ("/api/runtime/snapshots/preview", snapshot_preview, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/deploy", deploy, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/deployments/{deployment_id}/retry", retry_deployment, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/deployments/{deployment_id}/retrieve", retrieve, ["POST"]),
        ("/api/runtime/remotes/{runtime_id}/deployments/{deployment_id}/apply", apply_return, ["POST"]),
        ("/api/runtime/snapshots/import", import_snapshot, ["POST"]),
        ("/api/runtime/snapshots/{deployment_id}", export_snapshot, ["GET"]),
        ("/api/runtime/pause", pause_runtime, ["POST"]),
    ]:
        router.add_api_route(path, function, methods=methods)


async def webhook(connection_id: str, request: Request):
    from ..event_triggers import verify_webhook_signature
    runtime = supervisor(request.app)
    connection = runtime.service.run_store.connector_connection(connection_id)
    raw = await request.body()
    if len(raw) > 256 * 1024:
        raise HTTPException(413, "Webhook exceeds the size limit")
    secret = runtime.private.read().get(f"connector:{connection_id}") or {}
    timestamp = request.headers.get("x-locus-timestamp", "")
    if not connection or not connection["enabled"] or connection["kind"] != "webhook" or not secret.get("hmac_secret") or not verify_webhook_signature(secret["hmac_secret"], timestamp, request.headers.get("x-locus-signature", ""), raw):
        raise HTTPException(401, "Invalid webhook authorization")
    try:
        event_id = identifier(request.headers.get("x-locus-event-id", ""))
        body = json.loads(raw)
        event_name = str(body["event"])
        result = runtime.service.run_store.ingest_event(connection_id, {
            "source": "webhook", "source_event_id": event_id, "event_type": event_name,
            "occurred_at": float(timestamp), "subject": body.get("subject", event_name),
            "text": body.get("text", ""), "data": body.get("data", body),
        })
        return {"ok": True, **result}
    except (ValueError, KeyError) as exc:
        raise HTTPException(422, str(exc)) from exc


async def remote_control(runtime_id: str, request: Request, body: dict = Body(default_factory=dict)):
    return await invoke(remotes(request).control, runtime_id, str(body.get("action", "")))


async def remote_login(runtime_id: str, request: Request, body: dict = Body(default_factory=dict)):
    return await invoke(remotes(request).login, runtime_id, str(body.get("account_id", "")), str(body.get("method", "device_code")))


async def retry_deployment(runtime_id: str, deployment_id: str, request: Request):
    return await invoke(remotes(request).retry_deployment, runtime_id, deployment_id)
