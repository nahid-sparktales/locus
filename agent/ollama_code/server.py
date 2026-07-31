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
import sys
from concurrent.futures import Future
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
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
from .ollama import OllamaError, effective_context_length
from .sessions import SessionMeta, SessionStore, update_session_metadata
from .terminal import TerminalManager, TerminalRejected


#: Tools whose success means files on disk may have changed.
_MUTATING_TOOLS = {"write_file", "edit_file", "multi_edit", "bash"}


class ChatService:
    """Holds the core plus the state needed to bridge it to a WebSocket."""

    def __init__(self, core: AgentCore) -> None:
        self.core = core
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.ws: WebSocket | None = None
        self.pending_permissions: dict[str, Future[str]] = {}
        self.turn_future: Any = None
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
        return self.turn_future is not None and not self.turn_future.done()

    def queue_event(self, event: dict[str, Any]) -> None:
        self.queue.put_nowait(event)


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # Never leave a console command orphaned by a clean shutdown.
    svc: ChatService | None = getattr(app.state, "service", None)
    if svc is not None:
        svc.terminal.cancel_all(force=True)


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
    if svc.busy:
        raise HTTPException(409, "agent is busy — interrupt the current turn first")
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
def sessions(include_archived: bool = False) -> dict[str, Any]:
    svc = service()
    return {
        "sessions": SessionStore.summaries(limit=100, include_archived=include_archived),
        "current": svc.core.session.session_id,
    }


@app.post("/api/sessions/new")
def session_new(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Start a fresh saved session, preserving the previous transcript on disk."""
    svc = service()
    if svc.busy:
        raise HTTPException(409, "agent is busy — interrupt the current turn first")
    reason = str(body.get("reason") or "new_session")
    info = svc.core.new_session(reason=reason)
    return {"ok": True, "reason": reason, "session_info": info}


@app.delete("/api/sessions")
def sessions_clear() -> dict[str, Any]:
    """Move every saved session except the active one to the recovery folder."""
    svc = service()
    result = svc.core.clear_saved_sessions()
    return {"ok": True, "job_active": svc.busy, **result}


@app.post("/api/sessions/restore")
def sessions_restore(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Undo a clear: move a trash batch (default the newest) back."""
    batch = str(body.get("batch") or "") or None
    restored = SessionStore.restore_from_trash(batch)
    return {"ok": True, "restored": restored}


@app.get("/api/sessions/{session_id}")
def session_detail(session_id: str) -> dict[str, Any]:
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, f"session not found: {session_id}")
    header = SessionStore.provenance(path)
    meta = SessionMeta.get(session_id)
    return {
        "id": session_id,
        "messages": AgentCore.sanitize_messages(SessionStore.load(path)),
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
    if svc.busy:
        raise HTTPException(409, "agent is busy — interrupt the current turn first")
    try:
        result = svc.core.resume_session(session_id)
    except FileNotFoundError as e:
        raise HTTPException(404, str(e)) from e
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
    from .tools import TOOL_SCHEMAS

    return {
        "tools": [
            {
                "name": s["function"]["name"],
                "description": s["function"]["description"],
                "parameters": s["function"]["parameters"],
            }
            for s in TOOL_SCHEMAS
        ]
    }


@app.get("/api/permissions")
def get_permissions() -> dict[str, Any]:
    return service().core.perms.state()


@app.post("/api/permissions")
def set_permissions(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    svc = service()
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
    if "context_window" in body and svc.busy:
        # Changing this mid-turn changes `num_ctx` between two iterations of the
        # same turn, and Ollama reloads the model when the window changes — a
        # stall of tens of seconds, in the middle of the work.
        raise HTTPException(409, "agent is busy — interrupt the current turn first")
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


async def _handle_client_message(svc: ChatService, msg: dict[str, Any]) -> None:
    mtype = msg.get("type")
    core = svc.core
    loop = asyncio.get_running_loop()
    if mtype == "user_message":
        text = str(msg.get("text", "")).strip()
        if not text:
            return
        if svc.busy:
            svc.queue_event({"type": "error", "message": "Agent is busy — press Stop first."})
            return
        if text.startswith("/"):
            svc.turn_future = loop.run_in_executor(None, _run_slash, svc, text)
        else:
            svc.turn_future = loop.run_in_executor(None, core.run_turn, text, svc.decide)
    elif mtype == "permission_decision":
        svc.answer_permission(str(msg.get("request_id", "")), str(msg.get("decision", "deny")))
    elif mtype == "interrupt":
        core.interrupt()
        svc.deny_all_pending()  # unblock a permission wait so the turn can end
    elif mtype == "retry_last":
        if svc.busy:
            svc.queue_event({"type": "error", "message": "Agent is busy — press Stop first."})
            return
        svc.turn_future = loop.run_in_executor(None, core.retry_last, svc.decide)
    elif mtype == "new_session":
        if svc.busy:
            svc.queue_event({"type": "error", "message": "Agent is busy — press Stop first."})
            return
        reason = str(msg.get("reason") or "new_session")
        core.new_session(reason=reason)
    elif mtype == "set_model":
        model = str(msg.get("model", "")).strip()
        if not model:
            return
        try:
            names = [m.get("name") for m in core.client.list_models() if m.get("name")]
        except OllamaError as e:
            svc.queue_event({"type": "error", "message": str(e)})
            return
        match = next((n for n in names if n == model), None) or next(
            (n for n in names if model in n), None
        )
        if not match:
            svc.queue_event({"type": "error", "message": f"model '{model}' not installed"})
            return
        core.set_model(match)
    elif mtype == "set_cwd":
        path = str(msg.get("path", "")).strip()
        try:
            core.set_cwd(path)
        except ValueError as e:
            svc.queue_event({"type": "error", "message": str(e)})
    elif mtype == "set_permission_mode":
        mode = str(msg.get("mode", "")).strip()
        if mode in ("ask", "accept_edits", "bypass"):
            core.perms.set_mode(mode)
            core.config["permission_mode"] = mode
            svc.queue_event({"type": "session_info", **core.session_info()})
    elif mtype == "clear":
        core.new_session(reason="clear_chat")
        svc.queue_event({"type": "slash_result", "command": "clear", "text": "Conversation cleared."})
    elif mtype == "compact":
        if svc.busy:
            svc.queue_event({"type": "error", "message": "Agent is busy — press Stop first."})
            return
        svc.turn_future = loop.run_in_executor(None, _run_slash, svc, "/compact")
    elif mtype == "resume":
        session_id = str(msg.get("session_id", "")).strip()
        if not session_id:
            svc.queue_event({"type": "error", "message": "resume requires a session_id"})
            return
        if svc.busy:
            svc.queue_event({"type": "error", "message": "Agent is busy — press Stop first."})
            return
        svc.turn_future = loop.run_in_executor(None, _run_slash, svc, f"/resume {session_id}")
    elif mtype == "terminal_run":
        # Outside every `busy` guard: the console and the chat run side by side.
        try:
            svc.terminal.start(
                str(msg.get("command", "")),
                cwd=str(msg.get("cwd") or core.cwd),
                run_id=str(msg.get("run_id") or ""),
                timeout=int(msg.get("timeout") or 0),
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
        svc.queue_event({"type": "error", "message": f"unknown message type: {mtype}"})


@app.websocket("/ws/chat")
async def ws_chat(ws: WebSocket) -> None:
    # Same-origin rule as the HTTP routes: a browser page must never be able
    # to open the agent socket. WebSocket handshakes always carry Origin when
    # they come from a page.
    origin = ws.headers.get("origin")
    if origin and origin not in _allowed_origins():
        await ws.close(code=1008, reason="cross-origin connections are not allowed")
        return
    await ws.accept()
    svc = service()
    if svc.ws is not None and svc.ws is not ws:  # single-client app: replace
        try:
            await svc.ws.close()
        except Exception:  # noqa: BLE001
            pass
    svc.ws = ws
    svc.loop = asyncio.get_running_loop()
    while not svc.queue.empty():  # drop events from a previous connection
        svc.queue.get_nowait()
    await ws.send_json({"type": "session_info", **svc.core.session_info()})
    # A console run survives a dropped socket — killing a build because the
    # laptop slept is worse than the state it costs to replay it.
    await ws.send_json({"type": "terminal_state", "runs": svc.terminal.snapshot()})
    for event in svc.terminal.attach():
        await ws.send_json(event)
    pump = asyncio.create_task(_event_pump(svc, ws))
    try:
        while True:
            msg = await ws.receive_json()
            await _handle_client_message(svc, msg)
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - e.g. invalid JSON from client
        pass
    finally:
        pump.cancel()
        if svc.ws is ws:  # a newer connection may already have replaced us
            svc.ws = None
        svc.core.interrupt()
        svc.deny_all_pending()


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
    return ChatService(core)


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
    )


if __name__ == "__main__":
    main()
