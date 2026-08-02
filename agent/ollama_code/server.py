"""FastAPI + WebSocket server exposing the ollama-code agent core to the GUI.

Run:  python -m ollama_code.server --port 8791

The agent turn runs in a worker thread (the core is synchronous); core events
are bridged into an asyncio queue and pushed to the connected WebSocket
client. Permission decisions travel back through concurrent.futures so the
worker thread blocks until the user answers in the app.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import hashlib
import ipaddress
import json
import os
import re
import sys
import uuid
from concurrent.futures import Future
from contextlib import asynccontextmanager, contextmanager
from copy import deepcopy
from threading import RLock
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from . import __version__, gitinfo
from .config import (
    MINIMUM_CONTEXT_WINDOW,
    context_window,
    non_negative_int,
    remote_api_key_from_env,
    save_config,
)
from .core import AgentCore
from .extensions import ExtensionError
from .langgraph_runtime import WorkflowError, validate_workflow, workflow_capabilities
from .ollama import OllamaError, effective_context_length
from .sessions import (
    SessionMeta,
    SessionStore,
    SessionTooLargeError,
    update_session_metadata,
)
from .terminal import TerminalManager, TerminalRejected

#: Tools whose success means files on disk may have changed.
_MUTATING_TOOLS = {"write_file", "edit_file", "multi_edit", "bash"}
MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024
MAX_USER_MESSAGE_CHARS = 1_000_000
MAX_TERMINAL_COMMAND_CHARS = 65_536
MAX_CHAT_IMAGE_ATTACHMENTS = 10
MAX_CHAT_IMAGE_BYTES = 15 * 1024 * 1024
MAX_CHAT_IMAGE_TOTAL_BYTES = 25 * 1024 * 1024
CHAT_IMAGE_MIME_TYPES = {"image/png", "image/jpeg", "image/gif", "image/webp"}


class ChatService:
    """Holds the core plus the state needed to bridge it to a WebSocket."""

    def __init__(self, core: AgentCore) -> None:
        self.core = core
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.ws: WebSocket | None = None
        self.event_pump: asyncio.Task[Any] | None = None
        self.pending_permissions: dict[str, Future[str]] = {}
        self.turn_future: Any = None
        self._state_guard = RLock()
        self._state_mutating = False
        core.on_event(self.emit)
        # Deliberately not sharing `turn_future`: a console command must never
        # occupy the chat's single turn slot.
        self.terminal = TerminalManager(
            emit=self.emit,
            perms=core.perms,
            record=lambda record: self.core.session.append(record),
            config=core.config,
        )

    # -- core event bridge (called from the worker thread) --
    def emit(self, event: dict[str, Any]) -> None:
        loop = self.loop
        if loop is None or not loop.is_running():
            return
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is loop:
            # Already on the loop thread (e.g. set_cwd handled inline): queue
            # directly so these events keep their order relative to events the
            # handler queues itself. call_soon_threadsafe would defer them.
            self.queue.put_nowait(event)
        else:
            loop.call_soon_threadsafe(self.queue.put_nowait, event)

        # Tell the client the working tree may have moved. Injected here rather
        # than in core so the CLI-shared tool path stays untouched.
        if (
            event.get("type") == "tool_result"
            and event.get("tool") in _MUTATING_TOOLS
            and event.get("ok")
            and not event.get("denied")
        ):
            follow_up = {"type": "workspace_changed", "reason": "tool", "tool": event["tool"]}
            if running is loop:
                self.queue.put_nowait(follow_up)
            else:
                loop.call_soon_threadsafe(self.queue.put_nowait, follow_up)

    #: Historical name; the core still registers the handler by this one.
    _on_core_event = emit

    # -- permission decider (blocks the worker thread until answered) --
    def decide(self, tool_name: str, summary: str, detail: str, request_id: str) -> str:
        fut: Future[str] = Future()
        self.pending_permissions[request_id] = fut
        try:
            return fut.result()
        finally:
            self.pending_permissions.pop(request_id, None)

    def answer_permission(self, request_id: str, decision: str) -> bool:
        fut = self.pending_permissions.get(request_id)
        if fut is None or fut.done():
            return False
        fut.set_result(decision if decision in ("once", "always", "deny") else "deny")
        return True

    def deny_all_pending(self) -> None:
        for fut in list(self.pending_permissions.values()):
            if not fut.done():
                fut.set_result("deny")

    @property
    def busy(self) -> bool:
        with self._state_guard:
            worker_busy = self.turn_future is not None and not self.turn_future.done()
            return self._state_mutating or worker_busy or bool(
                self.core.langgraph_engine.active_run_id
            )

    @contextmanager
    def state_mutation(self):
        """Reserve mutable agent state against turns and other mutations."""
        with self._state_guard:
            if self.busy:
                raise AgentBusyError
            self._state_mutating = True
        try:
            yield
        finally:
            with self._state_guard:
                self._state_mutating = False

    def start_turn(self, loop: asyncio.AbstractEventLoop, call, *args: Any) -> bool:
        """Atomically reserve the turn slot and submit its worker."""
        with self._state_guard:
            if self._state_mutating or (
                self.turn_future is not None and not self.turn_future.done()
            ) or self.core.langgraph_engine.active_run_id:
                return False
            self.turn_future = loop.run_in_executor(None, call, *args)
            return True

    def start_graph_step(self, loop: asyncio.AbstractEventLoop, call, *args: Any) -> bool:
        """Resume the already-reserved graph without treating it as a new turn."""
        with self._state_guard:
            if self._state_mutating or (
                self.turn_future is not None and not self.turn_future.done()
            ):
                return False
            self.turn_future = loop.run_in_executor(None, call, *args)
            return True

    def queue_event(self, event: dict[str, Any]) -> None:
        self.queue.put_nowait(event)


class AgentBusyError(RuntimeError):
    """Raised when a state mutation races with an active turn."""


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def _command_error(svc: ChatService, operation: str, message: str) -> None:
    """Report a rejected client command without ending the active turn."""
    svc.queue_event({
        "type": "command_error",
        "operation": operation,
        "message": message,
    })


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # Never leave a console command orphaned by a clean shutdown.
    svc: ChatService | None = getattr(app.state, "service", None)
    if svc is not None:
        svc.terminal.cancel_all(force=True)
        svc.core.close()


app = FastAPI(title="ollama-code", version=__version__, lifespan=lifespan)


@app.middleware("http")
async def block_browser_origins(request: Request, call_next):
    """Reject any request that carries a browser Origin.

    The service runs on localhost with the user's full file and shell
    privileges. A page on any website can send requests to 127.0.0.1, so
    without this check a visited page could read files, run commands, or wipe
    transcripts. Browsers always attach Origin to cross-site requests and
    cannot forge it; the native app sends none.
    """
    origin = request.headers.get("origin")
    if origin and origin not in _allowed_origins():
        return JSONResponse(
            {"detail": "cross-origin requests are not allowed"}, status_code=403
        )
    token = str(getattr(app.state, "auth_token", "") or "")
    if token and request.headers.get("x-locus-token") != token:
        return JSONResponse({"detail": "local agent authentication failed"}, status_code=401)
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > MAX_HTTP_BODY_BYTES:
                return JSONResponse({"detail": "request body is too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "invalid content-length"}, status_code=400)
    return await call_next(request)


def _allowed_origins() -> set[str]:
    return set(getattr(app.state, "allowed_origins", set()))


def service() -> ChatService:
    svc: ChatService | None = getattr(app.state, "service", None)
    if svc is None:
        raise HTTPException(503, "agent service is not ready")
    return svc


# --------------------------------------------------------------------- REST


@app.get("/api/health")
def health() -> dict[str, Any]:
    svc = service()
    try:
        svc.core.client.check()
        reachable = True
        error = None
    except OllamaError as e:
        reachable = False
        error = str(e)
    return {
        "ok": True,
        "version": __version__,
        # `ollama` is kept as the field name for client compatibility: it means
        # "the model backend is reachable", whichever provider that is.
        "ollama": reachable,
        "host": svc.core.host,
        "model": svc.core.model,
        "error": error,
        "provider": svc.core.provider,
    }


@app.get("/api/provider")
def get_provider() -> dict[str, Any]:
    return service().core.provider_state()


@app.post("/api/provider")
def set_provider(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Switch between the local runtime and a hosted endpoint.

    The API key is accepted here and held in memory only — it is never written
    to the config file and never returned by any endpoint.
    """
    svc = service()
    try:
        with svc.state_mutation():
            return _apply_provider(svc, body)
    except AgentBusyError as e:
        raise _busy_http() from e


def _apply_provider(svc: ChatService, body: dict[str, Any]) -> dict[str, Any]:
    """Apply a provider request after the service has reserved mutable state."""
    provider = str(body.get("provider") or "").strip().lower()
    if provider not in ("ollama", "remote"):
        raise HTTPException(422, "provider must be 'ollama' or 'remote'")

    if provider == "ollama":
        try:
            svc.core.use_ollama(
                host=str(body.get("host") or "") or None,
                context_window_tokens=body.get("context_window"),
            )
        except ValueError as e:
            raise HTTPException(422, str(e)) from e
        return svc.core.provider_state()

    base_url = str(body.get("base_url") or body.get("remote_base_url") or "").strip()
    if not base_url:
        raise HTTPException(422, "base_url is required for the remote provider")
    # A missing key means "keep the current one"; an explicit empty string
    # clears it, which is how the app removes a saved key.
    raw_key = body.get("api_key")
    api_key = None if raw_key is None else str(raw_key)
    # Same "missing means keep" rule as the key, so a URL-only update from an
    # older client cannot silently drop the account's identity.
    raw_style = body.get("auth_style")
    raw_label = body.get("account_label")
    raw_lists = body.get("lists_models")
    try:
        svc.core.use_remote(
            base_url=base_url,
            api_key=api_key,
            model=str(body.get("model") or ""),
            auth_style=None if raw_style is None else str(raw_style),
            account_label=None if raw_label is None else str(raw_label),
            lists_models=None if raw_lists is None else bool(raw_lists),
            context_window_tokens=body.get("context_window"),
        )
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    if body.get("verify"):
        try:
            svc.core.client.check()
        except OllamaError as e:
            raise HTTPException(502, str(e)) from e
    return svc.core.provider_state()


@app.get("/api/models")
def models() -> dict[str, Any]:
    svc = service()
    try:
        raw = svc.core.client.list_models()
    except OllamaError as e:
        raise HTTPException(502, str(e)) from e
    configured = context_window(svc.core.config.get("context_window"))
    is_ollama = svc.core.provider != "remote"
    # One /api/ps for the whole list rather than one per model.
    resident: dict[str, int] = {}
    if is_ollama:
        try:
            for entry in svc.core.client.running_models():
                window = entry.get("context_length")
                if isinstance(window, int) and window > 0:
                    for key in (entry.get("name"), entry.get("model")):
                        if key:
                            resident[key] = window
        except OllamaError:
            resident = {}
    out: list[dict[str, Any]] = []
    for m in raw:
        name = m.get("name")
        if not name:
            continue
        trained = svc.core.client.context_length(name)
        # The window this model is really running in, not the one it was
        # trained for. The GUI meters against this, and metering against the
        # trained window reads reassuringly low right up to the point where
        # replies start getting truncated. 0 still means "not known", which is
        # the honest answer for a model that is not loaded and for an endpoint
        # that advertises nothing.
        #
        # A configured window only describes the model the agent is actually
        # running: `num_ctx` is sent for that one alone, so claiming the rest
        # run in it too would be a guess about models nobody has loaded.
        window = 0
        if is_ollama:
            model_configured = configured if name == svc.core.model else 0
            window = effective_context_length(
                resident.get(name, 0), trained, model_configured
            )
            if window <= 0:
                # Measured on an earlier run and remembered since. Still an
                # observation, and it keeps the meter alive for a model Ollama
                # has evicted rather than blanking it every five idle minutes.
                window = svc.core.remembered_model_window(name)
        out.append({
            "name": name,
            "size": m.get("size") or 0,
            "parameter_size": (m.get("details") or {}).get("parameter_size", ""),
            "context_length": window,
            "trained_context_length": trained,
        })
    return {"models": out, "current": svc.core.model}


@app.get("/api/sessions")
def sessions(
    include_archived: bool = False,
    limit: int = Query(100, ge=1, le=500),
    query: str = Query("", max_length=500),
) -> dict[str, Any]:
    svc = service()
    return {
        "sessions": SessionStore.summaries(
            limit=limit,
            include_archived=include_archived,
            query=query,
        ),
        "current": svc.core.session.session_id,
    }


@app.post("/api/sessions/new")
def session_new(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Start a fresh saved session, preserving the previous transcript on disk."""
    svc = service()
    try:
        with svc.state_mutation():
            reason = str(body.get("reason") or "new_session")
            info = svc.core.new_session(reason=reason)
            return {"ok": True, "reason": reason, "session_info": info}
    except AgentBusyError as e:
        raise _busy_http() from e


@app.delete("/api/sessions")
def sessions_clear() -> dict[str, Any]:
    """Move every saved session except the active one to the recovery folder."""
    svc = service()
    try:
        with svc.state_mutation():
            result = svc.core.clear_saved_sessions()
            return {"ok": True, "job_active": False, **result}
    except AgentBusyError as e:
        raise _busy_http() from e


@app.post("/api/sessions/restore")
def sessions_restore(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Undo a clear: move a trash batch (default the newest) back."""
    svc = service()
    try:
        with svc.state_mutation():
            batch = str(body.get("batch") or "") or None
            restored = SessionStore.restore_from_trash(batch)
            return {"ok": True, "restored": restored}
    except AgentBusyError as e:
        raise _busy_http() from e


@app.get("/api/sessions/{session_id}")
def session_detail(session_id: str) -> dict[str, Any]:
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, f"session not found: {session_id}")
    header = SessionStore.provenance(path)
    meta = SessionMeta.get(session_id)
    try:
        messages = SessionStore.load(path)
    except SessionTooLargeError as e:
        raise HTTPException(413, str(e)) from e
    return {
        "id": session_id,
        "messages": AgentCore.sanitize_messages(messages),
        "preview": SessionStore.preview(path),
        "title": meta.get("title"),
        "pinned": bool(meta.get("pinned", False)),
        "archived": bool(meta.get("archived", False)),
        "cwd": header.get("cwd"),
        "model": header.get("model"),
        "started": header.get("started"),
    }


@app.patch("/api/sessions/{session_id}")
def session_metadata_update(
    session_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Set a session's title, pinned or archived flag."""
    if SessionStore.find(session_id) is None:
        raise HTTPException(404, f"session not found: {session_id}")
    unknown = set(body) - {"title", "pinned", "archived"}
    if unknown:
        raise HTTPException(422, f"unknown session field: {sorted(unknown)[0]}")

    title = body.get("title")
    if title is not None and not isinstance(title, str):
        raise HTTPException(422, "title must be a string")
    for field in ("pinned", "archived"):
        value = body.get(field)
        if value is not None and not isinstance(value, bool):
            raise HTTPException(422, f"{field} must be true or false")

    archived = body.get("archived")
    if archived and session_id == service().core.session.session_id:
        # Archiving the conversation you are in would hide it from the very
        # list it is active in.
        raise HTTPException(409, "start a new session before archiving the active one")

    state = update_session_metadata(
        session_id,
        title=title,
        pinned=body.get("pinned"),
        archived=archived,
    )
    return {"ok": True, "id": session_id, **state}


#: Historical name kept for callers that imported it directly.
session_update = session_metadata_update


@app.post("/api/sessions/{session_id}/resume")
def session_resume(session_id: str) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            result = svc.core.resume_session(session_id)
    except AgentBusyError as e:
        raise _busy_http() from e
    except FileNotFoundError as e:
        raise HTTPException(404, str(e)) from e
    except SessionTooLargeError as e:
        raise HTTPException(413, str(e)) from e
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    return {
        "ok": True,
        "text": result.get("text"),
        "messages": (result.get("data") or {}).get("messages", []),
        "session_info": svc.core.session_info(),
    }


@app.get("/api/git/status")
def git_status(untracked: str = "normal") -> dict[str, Any]:
    """Working-tree status for the Changes panel.

    Sync `def` on purpose: Starlette runs it in the threadpool, so a slow git
    never blocks the event loop or the WebSocket pump. Never gated on `busy` —
    the panel needs to refresh precisely while the agent is editing.
    """
    return gitinfo.status(service().core.cwd, untracked=untracked)


@app.get("/api/git/diff")
def git_diff(
    path: str,
    staged: bool = False,
    context: int = 3,
    max_bytes: int = gitinfo.MAX_DIFF_BYTES,
) -> dict[str, Any]:
    """Unified diff for one file. `path` is a query param because file paths
    contain slashes."""
    return gitinfo.file_diff(
        service().core.cwd,
        path=path,
        staged=staged,
        context=context,
        max_bytes=max(1_000, min(max_bytes, gitinfo.MAX_DIFF_BYTES)),
    )


@app.get("/api/tools")
def list_tools() -> dict[str, Any]:
    registry = service().core.tool_registry
    registry.refresh()
    return {"tools": registry.metadata()}


# -------------------------------------------------------------- LangGraph


def _workflow_failure(exc: WorkflowError) -> HTTPException:
    return HTTPException(422, str(exc))


@app.get("/api/langgraph")
def get_langgraph() -> dict[str, Any]:
    return service().core.langgraph_engine.snapshot()


@app.get("/api/langgraph/workflows")
def get_langgraph_workflows() -> dict[str, Any]:
    engine = service().core.langgraph_engine
    engine.registry.set_cwd(service().core.cwd)
    return {"workflows": engine.registry.list()}


@app.post("/api/langgraph/workflows/validate")
def validate_langgraph_workflow(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    definition = body.get("definition") if isinstance(body.get("definition"), dict) else body
    try:
        normalized = validate_workflow(definition)
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc
    return {
        "valid": True,
        "definition": normalized,
        "digest": hashlib.sha256(
            json.dumps(normalized, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "capabilities": workflow_capabilities(normalized),
    }


@app.post("/api/langgraph/workflows")
def create_langgraph_workflow(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            definition = body.get("definition")
            if not isinstance(definition, dict):
                raise WorkflowError("definition must be an object")
            item = svc.core.langgraph_engine.registry.save(
                definition,
                str(body.get("scope") or "global"),
            )
            svc.queue_event({"type": "workflows_changed", "reason": "saved"})
            return {"ok": True, "workflow": item}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.put("/api/langgraph/workflows/{workflow_id}")
def update_langgraph_workflow(
    workflow_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    definition = body.get("definition")
    if not isinstance(definition, dict):
        raise _workflow_failure(WorkflowError("definition must be an object"))
    definition = {**definition, "id": workflow_id}
    return create_langgraph_workflow({**body, "definition": definition})


@app.post("/api/langgraph/workflows/{workflow_id}/duplicate")
def duplicate_langgraph_workflow(
    workflow_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    svc = service()
    try:
        source = svc.core.langgraph_engine.registry.get(workflow_id)
        name = str(body.get("name") or f"{source['name']} Copy")[:120]
        definition = {
            key: deepcopy(value)
            for key, value in source.items()
            if key in {
                "schema_version", "slug", "name", "description", "supported_modes",
                "revision", "nodes", "edges", "settings",
            }
        }
        definition.update({
            "id": uuid.uuid4().hex,
            "name": name,
            "slug": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:80] or "workflow-copy",
            "revision": 1,
        })
        return create_langgraph_workflow({
            "definition": definition,
            "scope": str(body.get("scope") or "global"),
        })
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.post("/api/langgraph/workflows/{workflow_id}/trust")
def trust_langgraph_workflow(
    workflow_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            item = svc.core.langgraph_engine.registry.trust(
                workflow_id,
                str(body.get("digest") or ""),
            )
            svc.queue_event({"type": "workflows_changed", "reason": "trusted"})
            return {"ok": True, "workflow": item}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.get("/api/langgraph/workflows/{workflow_id}/export")
def export_langgraph_workflow(workflow_id: str) -> dict[str, Any]:
    try:
        item = service().core.langgraph_engine.registry.get(workflow_id)
        return {
            "definition": {
                key: deepcopy(value)
                for key, value in item.items()
                if key in {
                    "schema_version", "id", "slug", "name", "description",
                    "supported_modes", "revision", "nodes", "edges", "settings",
                }
            }
        }
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.delete("/api/langgraph/workflows/{workflow_id}")
def delete_langgraph_workflow(workflow_id: str) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            svc.core.langgraph_engine.registry.delete(workflow_id)
            svc.queue_event({"type": "workflows_changed", "reason": "deleted"})
            return {"ok": True}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.get("/api/langgraph/runs")
def get_langgraph_runs(
    session_id: str = Query("", max_length=200),
    recoverable: bool = False,
) -> dict[str, Any]:
    return {
        "runs": service().core.langgraph_engine.runs.list(
            session_id=session_id,
            recoverable_only=recoverable,
        )
    }


@app.get("/api/langgraph/runs/{run_id}")
def get_langgraph_run(run_id: str) -> dict[str, Any]:
    try:
        return service().core.langgraph_engine.runs.get(run_id)
    except WorkflowError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.post("/api/langgraph/runs/{run_id}/resume", status_code=202)
async def resume_langgraph_run(run_id: str) -> dict[str, Any]:
    svc = service()
    if not svc.start_graph_step(
        asyncio.get_running_loop(),
        _run_graph_operation,
        svc,
        svc.core.langgraph_engine.resume,
        run_id,
        svc.decide,
    ):
        raise _busy_http()
    return {"ok": True, "accepted": True, "run_id": run_id}


@app.post("/api/langgraph/runs/{run_id}/cancel")
def cancel_langgraph_run(run_id: str) -> dict[str, Any]:
    active = service().core.langgraph_engine.active_run_id
    if active != run_id:
        raise HTTPException(409, "that graph run is not active")
    service().core.langgraph_engine.interrupt_active()
    return {"ok": True, "run_id": run_id, "status": "interrupted"}


@app.post("/api/langgraph/runs/{run_id}/resolve-uncertain")
def resolve_uncertain_langgraph_run(run_id: str, body: dict[str, Any]) -> dict[str, Any]:
    try:
        run = service().core.langgraph_engine.runs.resolve_uncertain(
            run_id,
            str(body.get("action") or ""),
        )
        service().queue_event({"type": "graph_recovery_available", "run_id": run_id})
        return run
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


@app.delete("/api/langgraph/runs/{run_id}")
def discard_langgraph_run(run_id: str) -> dict[str, Any]:
    try:
        service().core.langgraph_engine.discard(run_id)
        return {"ok": True}
    except WorkflowError as exc:
        raise _workflow_failure(exc) from exc


def _extension_snapshot(svc: ChatService) -> dict[str, Any]:
    snapshot = svc.core.extensions.snapshot()
    statuses = {item["id"]: item for item in svc.core.mcp.statuses()}
    for server in snapshot["mcp_servers"]:
        server.update(statuses.get(str(server.get("id"))) or {})
        server["has_credentials"] = bool(
            svc.core.extensions.credentials(str(server.get("id") or ""))
        )
    snapshot["pending_updates"] = sum(
        1 for plugin in snapshot["plugins"] if plugin.get("update_available")
    )
    return snapshot


def _announce_extensions(svc: ChatService, reason: str) -> None:
    svc.core.tool_registry.refresh()
    svc.queue_event({"type": "extensions_changed", "reason": reason})


def _extension_failure(exc: ExtensionError) -> HTTPException:
    return HTTPException(422, str(exc))


@app.get("/api/extensions")
def get_extensions() -> dict[str, Any]:
    return _extension_snapshot(service())


@app.get("/api/extensions/catalog")
def get_extension_catalog(
    query: str = Query("", max_length=500),
    marketplace_id: str = Query("", max_length=200),
) -> dict[str, Any]:
    return {
        "entries": service().core.extensions.catalog(query, marketplace_id),
        "marketplace_id": marketplace_id,
    }


@app.get("/api/extensions/catalog/trust")
def inspect_extension_plugin(
    marketplace_id: str = Query(..., max_length=200),
    plugin: str = Query(..., max_length=200),
) -> dict[str, Any]:
    try:
        return service().core.extensions.inspect_catalog_plugin(marketplace_id, plugin)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/marketplaces")
def add_extension_marketplace(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        value = service().core.extensions.add_marketplace(
            str(body.get("source") or ""),
            name=str(body.get("name") or ""),
            ref=str(body.get("ref") or ""),
            sparse_paths=[str(value) for value in body.get("sparse_paths") or []],
        )
        _announce_extensions(service(), "marketplace_added")
        return value
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/marketplaces/{marketplace_id}/refresh")
def refresh_extension_marketplace(marketplace_id: str) -> dict[str, Any]:
    try:
        value = service().core.extensions.refresh_marketplace(marketplace_id)
        _announce_extensions(service(), "marketplace_refreshed")
        return value
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.delete("/api/extensions/marketplaces/{marketplace_id}")
def delete_extension_marketplace(marketplace_id: str) -> dict[str, Any]:
    try:
        service().core.extensions.remove_marketplace(marketplace_id)
        _announce_extensions(service(), "marketplace_removed")
        return {"ok": True}
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/plugins/install")
def install_extension_plugin(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.install_plugin(
                str(body.get("marketplace_id") or ""),
                str(body.get("plugin") or body.get("name") or ""),
                scope=str(body.get("scope") or "global"),
                workspace=str(body.get("workspace") or svc.core.cwd),
                expected_digest=str(body.get("expected_digest") or ""),
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "plugin_installed")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/plugins/enable")
def enable_extension_plugin(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.set_plugin_enabled(
                str(body.get("id") or ""),
                bool(body.get("enabled", True)),
                scope=str(body.get("scope") or "global"),
                workspace=str(body.get("workspace") or svc.core.cwd),
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "plugin_activation_changed")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/plugins/update")
def update_extension_plugin(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.update_plugin(
                str(body.get("id") or ""),
                expected_digest=str(body.get("expected_digest") or ""),
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "plugin_updated")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/plugins/rollback")
def rollback_extension_plugin(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.rollback_plugin(str(body.get("id") or ""))
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "plugin_rolled_back")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.delete("/api/extensions/plugins/{plugin_id:path}")
def uninstall_extension_plugin(plugin_id: str) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            svc.core.extensions.uninstall_plugin(plugin_id)
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "plugin_uninstalled")
            return {"ok": True}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/skills/import")
def import_extension_skill(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.import_skill(
                str(body.get("source") or ""),
                scope=str(body.get("scope") or "global"),
                workspace=str(body.get("workspace") or svc.core.cwd),
            )
            _announce_extensions(svc, "skill_imported")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/skills/enable")
def enable_extension_skill(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.set_skill_enabled(
                str(body.get("id") or ""),
                bool(body.get("enabled", True)),
                scope=str(body.get("scope") or "global"),
                workspace=str(body.get("workspace") or svc.core.cwd),
            )
            _announce_extensions(svc, "skill_activation_changed")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.delete("/api/extensions/skills/{skill_id:path}")
def remove_extension_skill(skill_id: str) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            svc.core.extensions.remove_skill(skill_id)
            _announce_extensions(svc, "skill_removed")
            return {"ok": True}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/mcp")
def upsert_extension_mcp(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.upsert_mcp_server(
                body, server_id=str(body.get("id") or "")
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "mcp_saved")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/mcp/enable")
def enable_extension_mcp(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.set_mcp_enabled(
                str(body.get("id") or ""),
                bool(body.get("enabled", True)),
                scope=str(body.get("scope") or "global"),
                workspace=str(body.get("workspace") or svc.core.cwd),
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "mcp_activation_changed")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/mcp/credentials")
def set_extension_mcp_credentials(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    server_id = str(body.get("id") or "")
    values = body.get("credentials") if isinstance(body.get("credentials"), dict) else {}
    try:
        svc.core.extensions.set_credentials(server_id, values)
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc
    svc.core.mcp.refresh(wait=False)
    svc.queue_event({"type": "mcp_credential_refresh", "server_id": server_id})
    return {"ok": True, "id": server_id, "has_credentials": bool(values)}


@app.post("/api/extensions/mcp/policy")
def set_extension_mcp_policy(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            value = svc.core.extensions.set_mcp_policy(
                str(body.get("id") or ""),
                str(body.get("mode") or "annotations"),
                tool_name=str(body.get("tool") or ""),
            )
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "mcp_policy_changed")
            return value
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.post("/api/extensions/mcp/test")
def test_extension_mcp(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    svc.core.mcp.refresh(wait=True)
    server_id = str(body.get("id") or "")
    svc.core.tool_registry.refresh()
    return {
        "status": svc.core.mcp.status(server_id),
        "tools": [
            item for item in svc.core.tool_registry.metadata()
            if item.get("server_id") == server_id
        ],
    }


@app.post("/api/extensions/mcp/reconnect")
def reconnect_extension_mcp(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    server_id = str(body.get("id") or "")
    try:
        with svc.state_mutation():
            svc.core.mcp.reconnect(server_id, wait=True)
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc
    svc.core.tool_registry.refresh()
    return {
        "status": svc.core.mcp.status(server_id),
        "tools": [
            item for item in svc.core.tool_registry.metadata()
            if item.get("server_id") == server_id
        ],
    }


@app.delete("/api/extensions/mcp/{server_id:path}")
def delete_extension_mcp(server_id: str) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            svc.core.extensions.remove_mcp_server(server_id)
            svc.core.mcp.refresh(wait=False)
            _announce_extensions(svc, "mcp_removed")
            return {"ok": True}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ExtensionError as exc:
        raise _extension_failure(exc) from exc


@app.get("/api/permissions")
def get_permissions() -> dict[str, Any]:
    return service().core.perms.state()


@app.post("/api/permissions")
def set_permissions(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    try:
        with svc.state_mutation():
            mode = str(body.get("mode") or "").strip()
            if mode:
                if mode not in ("ask", "accept_edits", "bypass"):
                    raise HTTPException(422, "mode must be ask, accept_edits or bypass")
                svc.core.perms.set_mode(mode)
                svc.core.config["permission_mode"] = mode
            if body.get("reset"):
                svc.core.perms.reset()
            svc.queue_event({"type": "session_info", **svc.core.session_info()})
            return svc.core.perms.state()
    except AgentBusyError as e:
        raise _busy_http() from e


def _config_state(core: AgentCore) -> dict[str, Any]:
    return {
        "model": core.model,
        "host": core.host,
        "cwd": core.cwd,
        "max_iterations": core.max_iterations,
        # 0 means "follow the environment"; `session_info.context_limit` is the
        # number that setting actually resolved to.
        "context_window": context_window(core.config.get("context_window")),
        "session_info": core.session_info(),
    }


@app.get("/api/config")
def get_config() -> dict[str, Any]:
    return _config_state(service().core)


@app.post("/api/config")
def post_config(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
    # Checked before anything is applied: `set_model` and `set_cwd` both have
    # side effects that persist, and refusing afterwards would leave half the
    # request committed.
    try:
        with svc.state_mutation():
            return _apply_config(svc, body)
    except AgentBusyError as e:
        raise _busy_http() from e


def _apply_config(svc: ChatService, body: dict[str, Any]) -> dict[str, Any]:
    """Apply config after atomically reserving mutable state."""
    model = str(body.get("model") or "").strip()
    cwd = str(body.get("cwd") or "").strip()
    if model:
        svc.core.set_model(model)
    if cwd:
        try:
            svc.core.set_cwd(cwd)
        except ValueError as e:
            raise HTTPException(422, str(e)) from e
    if "context_window" in body:
        requested = body.get("context_window")
        resolved = context_window(requested)
        # Rejected rather than quietly ignored: a caller sending 32 has almost
        # certainly written the window in thousands, and silently running at
        # Ollama's own choice would look like the setting had been accepted.
        if resolved <= 0 and non_negative_int(requested) > 0:
            raise HTTPException(
                422,
                f"context_window must be at least {MINIMUM_CONTEXT_WINDOW} tokens, "
                "or 0 to let Ollama size the window",
            )
        svc.core.config["context_window"] = resolved
        # Both the window asked for and the compaction budget come off this, so
        # it has to be recomputed before the next turn rather than at next
        # startup.
        svc.core.refresh_context_limit()
        save_config(svc.core.config)
        svc.emit({"type": "session_info", **svc.core.session_info()})
    return _config_state(svc.core)


@app.post("/api/context/reload")
def reload_project_context() -> dict[str, Any]:
    """Reload AGENTS.md/compatible project context after an editor save."""
    svc = service()
    try:
        with svc.state_mutation():
            svc.core.reload_context()
            svc.core.reset_system_message()
            svc.queue_event({"type": "session_info", **svc.core.session_info()})
            return {
                "ok": True,
                "file": svc.core.project_context[0] if svc.core.project_context else None,
            }
    except AgentBusyError as exc:
        raise _busy_http() from exc


# ---------------------------------------------------------------- WebSocket


async def _event_pump(svc: ChatService, ws: WebSocket) -> None:
    try:
        while True:
            event = await svc.queue.get()
            await ws.send_json(event)
    except (WebSocketDisconnect, RuntimeError):
        pass


def _run_slash(svc: ChatService, text: str) -> None:
    """Worker-thread entry for slash commands; emits slash_result at the end."""
    result = svc.core.handle_slash(text, svc.decide)
    svc._on_core_event({"type": "slash_result", **result})


def _run_user_turn(
    svc: ChatService,
    text: str,
    just_chat: bool,
    attachments: list[dict[str, str]] | None = None,
) -> None:
    """Worker entry that makes the UI's chat-only boundary explicit."""
    svc.core.run_turn(
        text,
        svc.decide,
        allow_tools=not just_chat,
        attachments=attachments,
    )


def _run_graph_turn(
    svc: ChatService,
    text: str,
    mode: str,
    workflow_id: str,
) -> None:
    try:
        svc.core.langgraph_engine.start(text, mode, workflow_id, svc.decide)
    except WorkflowError as exc:
        _report_graph_failure(svc, exc)


def _run_independent_graph(
    svc: ChatService,
    text: str,
    mode: str,
    workflow_id: str,
) -> None:
    try:
        workflow = svc.core.langgraph_engine.registry.get(workflow_id, require_trust=True)
        if mode not in workflow["supported_modes"]:
            raise WorkflowError(f"{workflow['name']} does not support {mode.title()} mode")
        svc.core.new_session(reason="workflow_run")
        svc.core.langgraph_engine.start(text, mode, workflow_id, svc.decide)
    except WorkflowError as exc:
        _report_graph_failure(svc, exc)


def _run_graph_operation(
    svc: ChatService,
    operation: Any,
    run_id: str,
    *args: Any,
) -> None:
    try:
        result = operation(run_id, *args)
        if isinstance(result, tuple) and result and result[0] is False:
            raise WorkflowError("that workflow interruption is no longer pending")
    except WorkflowError as exc:
        _report_graph_failure(svc, exc, run_id)


def _report_graph_failure(svc: ChatService, error: Exception, run_id: str = "") -> None:
    message = svc.core.langgraph_engine._redact(str(error), run_id) if run_id else str(error)[:4000]
    svc.core._emit({"type": "error", "message": message, **({"run_id": run_id} if run_id else {})})
    if run_id:
        try:
            run = svc.core.langgraph_engine.runs.get(run_id)
            svc.core._emit({
                "type": "graph_run_state",
                "run_id": run_id,
                "status": run["status"],
                "error": message,
            })
        except WorkflowError:
            pass
    svc.core._emit({
        "type": "turn_done",
        "reason": "error",
        "duration_ms": 0,
        **({"run_id": run_id} if run_id else {}),
    })


def _validated_chat_attachments(value: Any) -> list[dict[str, str]]:
    if value in (None, []):
        return []
    if not isinstance(value, list) or len(value) > MAX_CHAT_IMAGE_ATTACHMENTS:
        raise ValueError("A chat message can include up to 10 image attachments.")
    output: list[dict[str, str]] = []
    total_bytes = 0
    for item in value:
        if not isinstance(item, dict):
            raise ValueError("An image attachment is malformed.")
        mime_type = str(item.get("mime_type") or "").lower()
        data = str(item.get("data") or "")
        if mime_type not in CHAT_IMAGE_MIME_TYPES or not data:
            raise ValueError("That image format is not supported.")
        try:
            decoded = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ValueError("An image attachment is malformed.") from exc
        if len(decoded) > MAX_CHAT_IMAGE_BYTES:
            raise ValueError("An image attachment is larger than 15 MB.")
        total_bytes += len(decoded)
        if total_bytes > MAX_CHAT_IMAGE_TOTAL_BYTES:
            raise ValueError("The image attachments are larger than 25 MB in total.")
        output.append({
            "name": str(item.get("name") or "image")[:255],
            "mime_type": mime_type,
            "data": data,
        })
    return output


async def _handle_client_message(svc: ChatService, msg: dict[str, Any]) -> None:
    mtype = msg.get("type")
    core = svc.core
    loop = asyncio.get_running_loop()
    if mtype == "user_message":
        text = str(msg.get("text", "")).strip()
        if not text:
            return
        if len(text) > MAX_USER_MESSAGE_CHARS:
            _command_error(svc, str(mtype), "Message is too large to process safely.")
            return
        mode = str(msg.get("mode") or "").strip().lower()
        if mode not in {"", "ask", "plan", "build"}:
            _command_error(svc, str(mtype), "Unknown conversation mode.")
            return
        just_chat = mode == "ask"
        try:
            attachments = _validated_chat_attachments(msg.get("attachments"))
        except ValueError as exc:
            _command_error(svc, str(mtype), str(exc))
            return
        if attachments and not just_chat:
            _command_error(svc, str(mtype), "Message attachments require Chat mode.")
            return
        engine = str(msg.get("engine") or "classic").strip().lower()
        workflow_id = str(msg.get("workflow_id") or "").strip()
        if engine not in {"classic", "langgraph"}:
            _command_error(svc, str(mtype), "Unknown execution engine.")
            return
        if just_chat and engine != "classic":
            _command_error(svc, str(mtype), "Just Chat cannot run workflows.")
            return
        if engine == "langgraph":
            if mode not in {"plan", "build"} or not workflow_id:
                _command_error(svc, str(mtype), "LangGraph requires Plan or Build mode and a workflow.")
                return
            call, args = _run_graph_turn, (svc, text, mode, workflow_id)
        else:
            call, args = (
                (_run_slash, (svc, text))
                if text.startswith("/") and not just_chat
                else (_run_user_turn, (svc, text, just_chat, attachments))
            )
        if not svc.start_turn(loop, call, *args):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "permission_decision":
        request_id = str(msg.get("request_id", ""))
        decision = str(msg.get("decision", "deny"))
        if svc.answer_permission(request_id, decision):
            return
        run_id = core.langgraph_engine.active_run_id
        if run_id and not svc.start_graph_step(
            loop,
            _run_graph_operation,
            svc,
            core.langgraph_engine.record_decision,
            run_id,
            request_id,
            decision,
            svc.decide,
        ):
            _command_error(svc, str(mtype), "The workflow is already resuming.")
    elif mtype == "graph_review_decision":
        run_id = str(msg.get("run_id") or core.langgraph_engine.active_run_id)
        if not run_id or not svc.start_graph_step(
            loop,
            _run_graph_operation,
            svc,
            core.langgraph_engine.record_decision,
            run_id,
            str(msg.get("request_id") or ""),
            str(msg.get("decision") or "reject"),
            svc.decide,
        ):
            _command_error(svc, str(mtype), "The workflow review cannot be resumed right now.")
    elif mtype == "graph_credentials":
        run_id = str(msg.get("run_id") or "")
        bindings = msg.get("bindings") or []
        if not isinstance(bindings, list) or len(bindings) > 32:
            _command_error(svc, str(mtype), "Provider bindings are malformed.")
            return
        if not svc.start_graph_step(
            loop,
            _run_graph_operation,
            svc,
            core.langgraph_engine.provide_credentials,
            run_id,
            bindings,
            svc.decide,
        ):
            _command_error(svc, str(mtype), "The workflow is already resuming.")
    elif mtype == "graph_resume":
        run_id = str(msg.get("run_id") or "")
        if not run_id or not svc.start_graph_step(
            loop,
            _run_graph_operation,
            svc,
            core.langgraph_engine.resume,
            run_id,
            svc.decide,
        ):
            _command_error(svc, str(mtype), "The workflow cannot be resumed right now.")
    elif mtype == "workflow_run":
        text = str(msg.get("text") or "").strip()
        mode = str(msg.get("mode") or "build").strip().lower()
        workflow_id = str(msg.get("workflow_id") or "").strip()
        if not text or mode not in {"plan", "build"} or not workflow_id:
            _command_error(svc, str(mtype), "A workflow run needs a goal, mode, and workflow.")
            return
        if not svc.start_turn(loop, _run_independent_graph, svc, text, mode, workflow_id):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "interrupt":
        if not core.langgraph_engine.interrupt_active():
            core.interrupt()
            svc.deny_all_pending()  # unblock a permission wait so the turn can end
    elif mtype == "retry_last":
        if not svc.start_turn(loop, core.retry_last, svc.decide):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "new_session":
        try:
            with svc.state_mutation():
                reason = str(msg.get("reason") or "new_session")
                core.new_session(reason=reason)
        except AgentBusyError:
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "set_model":
        model = str(msg.get("model", "")).strip()
        if not model:
            return
        try:
            with svc.state_mutation():
                names = [
                    item.get("name")
                    for item in core.client.list_models()
                    if item.get("name")
                ]
                match = next((name for name in names if name == model), None) or next(
                    (name for name in names if model in name),
                    None,
                )
                if not match:
                    _command_error(svc, str(mtype), f"model '{model}' not installed")
                    return
                core.set_model(match)
        except AgentBusyError:
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
        except OllamaError as e:
            _command_error(svc, str(mtype), str(e))
    elif mtype == "set_cwd":
        path = str(msg.get("path", "")).strip()
        try:
            with svc.state_mutation():
                core.set_cwd(path)
        except AgentBusyError:
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
        except ValueError as e:
            _command_error(svc, str(mtype), str(e))
    elif mtype == "set_permission_mode":
        mode = str(msg.get("mode", "")).strip()
        try:
            with svc.state_mutation():
                if mode in ("ask", "accept_edits", "bypass"):
                    core.perms.set_mode(mode)
                    core.config["permission_mode"] = mode
                    svc.queue_event({"type": "session_info", **core.session_info()})
        except AgentBusyError:
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "clear":
        try:
            with svc.state_mutation():
                core.new_session(reason="clear_chat")
                svc.queue_event({
                    "type": "slash_result",
                    "command": "clear",
                    "text": "Conversation cleared.",
                })
        except AgentBusyError:
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "compact":
        if not svc.start_turn(loop, _run_slash, svc, "/compact"):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "resume":
        session_id = str(msg.get("session_id", "")).strip()
        if not session_id:
            _command_error(svc, str(mtype), "resume requires a session_id")
            return
        if not svc.start_turn(loop, _run_slash, svc, f"/resume {session_id}"):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "terminal_run":
        # Outside every `busy` guard: the console and the chat run side by side.
        command = str(msg.get("command", ""))
        if len(command) > MAX_TERMINAL_COMMAND_CHARS:
            svc.queue_event({
                "type": "terminal_error",
                "run_id": str(msg.get("run_id") or ""),
                "code": "too_large",
                "message": "command is too large to run safely",
            })
            return
        try:
            svc.terminal.start(
                command,
                cwd=str(msg.get("cwd") or core.cwd),
                run_id=str(msg.get("run_id") or ""),
                timeout=int(msg.get("timeout") or 0),
                # The console is independent from chat state, so capture the
                # session it started in. A later New Session must not move its
                # completion record into the replacement transcript.
                record=core.session.append,
            )
        except TerminalRejected:
            pass  # start() already emitted terminal_error
    elif mtype == "terminal_input":
        svc.terminal.send_input(
            str(msg.get("run_id", "")),
            str(msg.get("text", "")),
            newline=bool(msg.get("newline", True)),
        )
    elif mtype == "terminal_close_stdin":
        svc.terminal.close_stdin(str(msg.get("run_id", "")))
    elif mtype == "terminal_cancel":
        svc.terminal.cancel(str(msg.get("run_id", "")), force=bool(msg.get("force", False)))
    elif mtype == "ping":
        svc.queue_event({"type": "pong"})
    else:
        _command_error(svc, str(mtype or "unknown"), f"unknown message type: {mtype}")


@app.websocket("/ws/chat")
async def ws_chat(ws: WebSocket) -> None:
    # Same-origin rule as the HTTP routes: a browser page must never be able
    # to open the agent socket. WebSocket handshakes always carry Origin when
    # they come from a page.
    origin = ws.headers.get("origin")
    if origin and origin not in _allowed_origins():
        await ws.close(code=1008, reason="cross-origin connections are not allowed")
        return
    token = str(getattr(app.state, "auth_token", "") or "")
    if token and ws.headers.get("x-locus-token") != token:
        await ws.close(code=1008, reason="local agent authentication failed")
        return
    await ws.accept()
    svc = service()
    previous_ws = svc.ws
    previous_pump = svc.event_pump
    # Publish the replacement before closing the old socket. Its finally block
    # can now tell it is stale and cannot interrupt the replacement's turn.
    svc.ws = ws
    svc.event_pump = None
    if previous_pump is not None:
        previous_pump.cancel()
    if previous_ws is not None and previous_ws is not ws:  # single-client app: replace
        try:
            await previous_ws.close()
        except Exception:  # noqa: BLE001
            pass
    svc.loop = asyncio.get_running_loop()
    await ws.send_json({"type": "session_info", **svc.core.session_info()})
    # A console run survives a dropped socket — killing a build because the
    # laptop slept is worse than the state it costs to replay it.
    await ws.send_json({"type": "terminal_state", "runs": svc.terminal.snapshot()})
    for event in svc.terminal.attach():
        await ws.send_json(event)
    pump = asyncio.create_task(_event_pump(svc, ws))
    svc.event_pump = pump
    try:
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict):
                await _handle_client_message(svc, msg)
            else:
                _command_error(svc, "invalid", "WebSocket messages must be JSON objects")
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - e.g. invalid JSON from client
        pass
    finally:
        pump.cancel()
        if svc.event_pump is pump:
            svc.event_pump = None
        if svc.ws is ws:  # a newer connection may already have replaced us
            svc.ws = None
            svc.core.interrupt()
            svc.deny_all_pending()


def _is_loopback_bind(host: str) -> bool:
    """Whether a server bind target is restricted to this machine."""
    if host.strip().lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


# -------------------------------------------------------------------- main


def build_service(
    model: str = "",
    cwd: str | None = None,
    skip_permissions: bool = False,
    remote_base_url: str = "",
    remote_model: str = "",
) -> ChatService:
    """Create the core + service, tolerating an unreachable model backend."""
    core = AgentCore(model=model, cwd=cwd, skip_permissions=skip_permissions)
    if remote_base_url:
        core.use_remote(
            base_url=remote_base_url,
            api_key=remote_api_key_from_env() or None,
            model=remote_model or model,
        )
    try:
        warning = core.ensure_model()
        if warning:
            print(f"warning: {warning}", file=sys.stderr)
    except OllamaError as e:
        label = "endpoint" if core.provider == "remote" else "Ollama"
        print(f"warning: {label} not ready ({e}); /api/health will report it", file=sys.stderr)
    core.messages = [core.system_message()]
    svc = ChatService(core)
    core.mcp.refresh(wait=False)
    return svc


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="ollama-code-server",
        description="REST + WebSocket server for the ollama-code GUI.",
    )
    parser.add_argument("--port", type=int, default=8791, help="port to listen on (default: 8791)")
    parser.add_argument("--host", default="127.0.0.1", help="host to bind (default: 127.0.0.1)")
    parser.add_argument("--model", default="", help="Ollama model to use")
    parser.add_argument("--cwd", default="", help="working directory for the agent (default: server cwd)")
    parser.add_argument("--dangerously-skip-permissions", action="store_true",
                        help="auto-allow every tool call")
    parser.add_argument("--allow-origin", action="append", default=[],
                        help="permit a browser Origin (repeatable). Off by default.")
    parser.add_argument("--remote-url", default="",
                        help="OpenAI-compatible endpoint to use instead of local Ollama "
                             "(Hugging Face Inference Endpoint, vLLM, TGI, …)")
    parser.add_argument("--remote-model", default="",
                        help="model name to request from --remote-url")
    args = parser.parse_args(argv)

    app.state.allowed_origins = set(args.allow_origin)
    app.state.auth_token = os.environ.pop("LOCUS_AGENT_TOKEN", "").strip()
    if not _is_loopback_bind(args.host) and not app.state.auth_token:
        parser.error(
            "a non-loopback --host requires LOCUS_AGENT_TOKEN authentication"
        )
    app.state.service = build_service(
        model=args.model,
        cwd=args.cwd or None,
        skip_permissions=args.dangerously_skip_permissions,
        remote_base_url=args.remote_url,
        remote_model=args.remote_model,
    )
    core = app.state.service.core
    where = core.host if core.provider == "remote" else "local Ollama"
    print(f"ollama-code {__version__} on http://{args.host}:{args.port}  "
          f"(model: {core.model or '?'} via {where}, cwd: {core.cwd})", file=sys.stderr)
    # A short graceful-shutdown window: the app restarts the agent on relaunch,
    # and a slow exit would keep the port bound and stall the next start.
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="warning",
        timeout_graceful_shutdown=2,
        ws_max_size=2 * 1024 * 1024,
    )


if __name__ == "__main__":
    main()
