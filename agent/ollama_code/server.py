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
import ipaddress
import logging
import os
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeout
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from threading import RLock
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from . import __version__, gitinfo, proxy
from .capabilities import enabled as capability_enabled
from .capabilities import snapshot as capability_snapshot
from .config import (
    MAX_ITERATIONS_CEILING,
    MINIMUM_CONTEXT_WINDOW,
    context_window,
    non_negative_int,
    remote_api_key_from_env,
    save_config,
)
from .core import AgentCore
from .evaluations import (
    EvaluationError,
    EvaluationStore,
    compare_results,
    grade_case,
    summarize_results,
)
from .extensions import ExtensionError
from .knowledge import KnowledgeError, KnowledgeStore
from .ollama import OllamaError, effective_context_length
from .orchestration import (
    GLOBAL_MODEL_SCHEDULER,
    OrchestrationError,
    TeamOrchestrator,
    TeamPreparation,
    client_for_profile,
    orchestration_fingerprint,
    parse_manifest,
)
from .runstore import RunStore, RunStoreError
from .sessions import (
    MAX_SESSION_LINE_BYTES,
    SessionMeta,
    SessionStore,
    SessionTooLargeError,
    update_session_metadata,
)
from .telemetry import TelemetryError, send_otlp
from .terminal import TerminalManager, TerminalRejected
from .worktrees import TaskCheckout, TaskCheckoutStore, WorktreeError

logger = logging.getLogger(__name__)

#: Tools whose success means files on disk may have changed.
_MUTATING_TOOLS = {"write_file", "edit_file", "multi_edit", "bash"}
MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024
MAX_USER_MESSAGE_CHARS = 1_000_000
#: Code points are not bytes: a message at the limit above made entirely of
#: 4-byte characters encodes to 4 MB, and the transcript reader skips any line
#: over MAX_SESSION_LINE_BYTES — so the turn would be written and then be
#: unreadable on restore. Held below that limit to leave room for the record's
#: own JSON envelope. Only reachable since the WebSocket frame cap was raised
#: to admit image attachments; the old 2 MiB frame was the accidental bound.
MAX_USER_MESSAGE_BYTES = MAX_SESSION_LINE_BYTES // 2
MAX_TERMINAL_COMMAND_CHARS = 65_536
MAX_CHAT_IMAGE_ATTACHMENTS = 10
MAX_CHAT_IMAGE_BYTES = 15 * 1024 * 1024
MAX_CHAT_IMAGE_TOTAL_BYTES = 25 * 1024 * 1024
CHAT_IMAGE_MIME_TYPES = {"image/png", "image/jpeg", "image/gif", "image/webp"}
#: The WebSocket frame has to hold the largest message the chat endpoint says
#: it accepts. Attachments arrive base64-encoded — a 4/3 expansion — inside a
#: JSON envelope, so a cap below that is enforced by the transport as a 1009
#: close *before* the validators below can run, and the user loses the socket
#: instead of being told the image was too large. Derived rather than written
#: as a literal so the two limits cannot drift apart again.
MAX_WS_MESSAGE_BYTES = (MAX_CHAT_IMAGE_TOTAL_BYTES * 4) // 3 + MAX_HTTP_BODY_BYTES


class ChatService:
    """Holds the core plus the state needed to bridge it to a WebSocket."""

    #: Whether provider changes may reach out to discover a context window.
    #: A class attribute so a whole test session can switch probing off in one
    #: place, rather than each fixture remembering to — and rather than the suite
    #: discovering the default by making real requests to a real endpoint.
    background_probes = True

    def __init__(self, core: AgentCore) -> None:
        self.core = core
        self.worker_id = uuid.uuid4().hex
        self.loop: asyncio.AbstractEventLoop | None = None
        self.queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.ws: WebSocket | None = None
        self.event_pump: asyncio.Task[Any] | None = None
        self.pending_permissions: dict[str, Future[str]] = {}
        self.pending_computer_actions: dict[str, Future[dict[str, Any]]] = {}
        self.pending_dispatch_decisions: dict[str, Future[dict[str, Any]]] = {}
        self.pending_dispatch_plans: dict[str, dict[str, Any]] = {}
        self.turn_future: Any = None
        self._terminal_events = 0
        self.active_orchestrator: TeamOrchestrator | None = None
        self.active_team: TeamPreparation | None = None
        self.active_run_id: str | None = None
        self.cancel_requested_runs: set[str] = set()
        self.pause_requested = False
        self.active_evaluation_id: str | None = None
        self.active_evaluation_core: AgentCore | None = None
        self.current_task: TaskCheckout | None = None
        self.run_store = RunStore()
        self.core.mcp.task_store = self.run_store
        self.core.mcp.context_provider = self.mcp_context
        self.recoverable_runs = self.run_store.mark_abandoned(
            GLOBAL_MODEL_SCHEDULER.has_active_lease
        )
        self.run_store.prune()
        for expired_task_id in EvaluationStore(
            self.run_store
        ).expired_successful_task_ids():
            try:
                TaskCheckoutStore.cleanup(expired_task_id)
            except WorktreeError:
                # Missing/in-use fixtures remain visible in their evaluation
                # result and can be cleaned explicitly later.
                pass
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

    def resolve_context_limit_soon(self) -> None:
        """Ask the core to settle its window off-thread, if probing is allowed."""
        if self.background_probes:
            self.core.resolve_context_limit_soon()

    def mcp_context(self) -> dict[str, str]:
        return {
            "run_id": self.active_run_id or "",
            "job_id": "writer" if self.active_team is not None else "",
            "tool_call_id": self.core.active_tool_call_id,
        }

    # -- core event bridge (called from the worker thread) --
    def emit(self, event: dict[str, Any]) -> None:
        event_type = str(event.get("type") or "")
        if event_type == "turn_done":
            self._terminal_events += 1
        if event_type == "session_info":
            event = dict(event)
            event.setdefault("worker_id", self.worker_id)
            event.setdefault("process_id", os.getpid())
        if event_type.startswith(("agent_job_", "orchestration_", "scheduler_lease", "mcp_task_")) \
                or event_type == "dispatch_plan":
            event = dict(event)
            event.setdefault("worker_id", self.worker_id)
        run_id = str(event.get("run_id") or self.active_run_id or "")
        persisted_types = {
            "message_start", "message_end", "tool_call_proposed", "permission_request",
            "tool_result", "steer_ack", "steer_applied", "computer_action_request",
            "workspace_changed", "note", "error", "dispatch_plan",
            "orchestration_checkpoint", "dispatch_plan_ready",
        }
        durable_agent_event = (
            event_type.startswith("agent_job_") and event_type != "agent_job_stream"
        )
        if run_id and (
            event_type in persisted_types
            or durable_agent_event
            or event_type.startswith(("orchestration_", "scheduler_lease", "mcp_task_"))
        ):
            event = dict(event)
            event.setdefault("run_id", run_id)
            try:
                event = self.run_store.append_event(run_id, event)
            except (RunStoreError, sqlite3.DatabaseError, OSError) as exc:
                # Run history is observability, not execution authority. A
                # damaged or temporarily locked history store must never stop
                # an otherwise healthy agent turn.
                event = {**event, "persistence_error": str(exc)}
        if event_type in {"agent_job_started", "agent_job_completed", "dispatch_plan"} \
                or event_type.startswith("orchestration_") \
                or event_type.startswith("scheduler_lease") \
                or event_type.startswith("mcp_task_"):
            # Separate append-only records keep the main transcript format
            # compatible. Route credentials and provider signatures never
            # enter these events.
            self.core.session.append({"type": "agent_activity", "event": event})
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
            self.emit(follow_up)

    def checkpoint(self, kind: str, state: dict[str, Any]) -> dict[str, Any] | None:
        run_id = self.active_run_id
        if not run_id:
            return None
        checkpoint = self.run_store.checkpoint(run_id, kind, state)
        self.emit({
            "type": "orchestration_checkpoint",
            "run_id": run_id,
            "checkpoint": checkpoint,
            "state": str(state.get("state") or "running"),
        })
        return checkpoint

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

    def execute_computer(
        self,
        tool: str,
        arguments: dict[str, Any],
        request_id: str,
    ) -> str:
        """Bridge one worker-thread tool call to the native Swift broker.

        Requests are strictly one-result-per-id. The worker stays blocked until
        Swift answers, Stop cancels it, or the 60-second protocol timeout wins.
        """
        if not self.core.tool_registry.computer_enabled:
            return "Error: native computer control is disabled."
        future: Future[dict[str, Any]] = Future()
        self.pending_computer_actions[request_id] = future
        self.emit({
            "type": "computer_action_request",
            "request_id": request_id,
            "tool": tool,
            "arguments": arguments,
            "timeout_ms": 60_000,
        })
        try:
            result = future.result(timeout=60)
        except FutureTimeout:
            return "Error: native computer action timed out after 60 seconds."
        finally:
            self.pending_computer_actions.pop(request_id, None)
        error = str(result.get("error") or "").strip()
        if error:
            return f"Error: {error}"
        text = str(result.get("text") or "").strip()
        screenshot = result.get("screenshot")
        if isinstance(screenshot, dict):
            detail = str(screenshot.get("description") or "target-window screenshot")
            accepted = self.core.accept_computer_screenshot(screenshot)
            suffix = (
                f"Screenshot observation available: {detail}"
                if accepted
                else "This route is using Accessibility text only for this session."
            )
            text = f"{text}\n\n{suffix}".strip()
        return text or "Computer action completed."

    def answer_computer(self, request_id: str, result: dict[str, Any]) -> bool:
        future = self.pending_computer_actions.get(request_id)
        if future is None or future.done():
            return False
        future.set_result(result)
        return True

    def cancel_all_computer_actions(self) -> None:
        for future in list(self.pending_computer_actions.values()):
            if not future.done():
                future.set_result({"error": "cancelled by the user"})

    def request_dispatch_approval(
        self, run_id: str, plan: dict[str, Any]
    ) -> dict[str, Any]:
        future: Future[dict[str, Any]] = Future()
        self.pending_dispatch_decisions[run_id] = future
        self.pending_dispatch_plans[run_id] = dict(plan)
        try:
            self.run_store.set_state(run_id, "waiting_dispatch_approval", recoverable=True)
            self.emit({
                "type": "dispatch_plan_ready", "run_id": run_id,
                "state": "waiting_dispatch_approval", "plan": plan,
            })
            checkpoint_state: dict[str, Any] = {
                "state": "waiting_dispatch_approval", "plan": plan,
                "baseline_tree": self.current_task.baseline_tree
                if self.current_task is not None else "",
            }
            record = self.run_store.run(run_id) or {}
            try:
                _, team, profiles, _ = parse_manifest(record.get("manifest"))
                checkpoint_state["orchestration_fingerprint"] = orchestration_fingerprint(
                    team, profiles,
                )
            except OrchestrationError:
                # The pending decision remains usable in-process. A restart
                # will surface a repair checklist instead of reusing an
                # unverifiable checkpoint.
                checkpoint_state["orchestration_fingerprint"] = "unavailable"
            self.checkpoint("dispatch_waiting", checkpoint_state)
            return future.result()
        finally:
            self.pending_dispatch_decisions.pop(run_id, None)
            self.pending_dispatch_plans.pop(run_id, None)

    def answer_dispatch(self, run_id: str, decision: dict[str, Any]) -> bool:
        future = self.pending_dispatch_decisions.get(run_id)
        if future is None or future.done():
            return False
        future.set_result(decision)
        return True

    def cancel_dispatch_decisions(self) -> None:
        for future in list(self.pending_dispatch_decisions.values()):
            if not future.done():
                future.set_result({"action": "cancel"})

    @property
    def busy(self) -> bool:
        with self._state_guard:
            worker_busy = self.turn_future is not None and not self.turn_future.done()
            return self._state_mutating or worker_busy

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
            ):
                return False
            name = str(getattr(call, "__name__", ""))
            steerable = name in {"_run_user_turn", "_run_team_turn", "retry_last_response"}
            if steerable:
                # Stop belongs to the turn it interrupted. Team dispatch uses
                # the flag before AgentCore.run_turn (which clears it for solo
                # turns), so carrying it forward makes the next team request
                # terminate immediately after a successful cancellation.
                self.core._interrupt.clear()
                self.core.begin_steerable_turn()
            terminal_before = self._terminal_events
            try:
                self.turn_future = loop.run_in_executor(None, call, *args)
            except Exception:
                if steerable:
                    self.core.end_steerable_turn()
                raise
            def observe_completion(future: asyncio.Future[Any]) -> None:
                if future.cancelled():
                    return
                exception = future.exception()
                if exception is None:
                    return
                logger.error(
                    "turn worker failed unexpectedly",
                    exc_info=(type(exception), exception, exception.__traceback__),
                )
                # Most turn paths publish their own terminal boundary. This is
                # the last-resort guard for errors outside those paths, so the
                # UI cannot remain on Running after the worker has exited.
                if self._terminal_events == terminal_before:
                    self.core.end_steerable_turn()
                    self.emit({
                        "type": "error",
                        "message": (
                            "The run stopped because of an internal error. "
                            "Nothing is still running; you can retry it."
                        ),
                    })
                    self.emit({"type": "turn_done", "reason": "error", "duration_ms": 0})

            self.turn_future.add_done_callback(observe_completion)
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


def _configured_parent_pid() -> int:
    """Return the Locus parent PID, or 0 for standalone/CLI servers."""
    try:
        value = int(os.environ.get("LOCUS_PARENT_PID", "0"))
    except ValueError:
        return 0
    return value if value > 1 and value != os.getpid() else 0


async def _watch_parent(expected_pid: int) -> None:
    """Stop an app-owned server after Locus disappears unexpectedly."""
    while True:
        await asyncio.sleep(1)
        # macOS reparents an orphan to launchd (PID 1). Checking the direct
        # parent avoids signalling an unrelated process if a PID is reused.
        if os.getppid() != expected_pid:
            os.kill(os.getpid(), signal.SIGTERM)
            return


@asynccontextmanager
async def lifespan(app: FastAPI):
    parent_pid = _configured_parent_pid()
    parent_watch = asyncio.create_task(_watch_parent(parent_pid)) if parent_pid else None
    try:
        yield
    finally:
        if parent_watch is not None:
            parent_watch.cancel()
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


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")


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
        "capabilities": capability_snapshot(),
    }


@app.get("/api/provider")
def get_provider() -> dict[str, Any]:
    return service().core.provider_state()


# ---------------------------------------------------------- Workspace knowledge


def _knowledge_store(workspace: str = "") -> KnowledgeStore:
    _require_capability("workspace_knowledge")
    target = workspace.strip() or service().core.workspace_root or service().core.cwd
    try:
        return KnowledgeStore(target)
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.get("/api/knowledge/status")
def knowledge_status(workspace: str = Query(default="")) -> dict[str, Any]:
    return _knowledge_store(workspace).settings()


@app.post("/api/knowledge/settings")
def knowledge_settings(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    store = _knowledge_store(str(body.get("workspace") or ""))
    enabled = body.get("enabled") if isinstance(body.get("enabled"), bool) else None
    embedding_model = (
        str(body.get("embedding_model") or "") if "embedding_model" in body else None
    )
    ollama_host = str(body.get("ollama_host") or "") if "ollama_host" in body else None
    if "exclusions" in body and not isinstance(body.get("exclusions"), list):
        raise HTTPException(422, "knowledge exclusions must be a list of glob patterns")
    exclusions = (
        [str(item) for item in body.get("exclusions") or []]
        if "exclusions" in body else None
    )
    return store.configure(
        enabled=enabled, embedding_model=embedding_model, ollama_host=ollama_host,
        exclusions=exclusions,
    )


@app.post("/api/knowledge/reindex")
def knowledge_reindex(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    store = _knowledge_store(str(body.get("workspace") or ""))
    return store.reindex()


@app.post("/api/knowledge/changes")
def knowledge_changes(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    store = _knowledge_store(str(body.get("workspace") or ""))
    raw = body.get("paths")
    if not isinstance(raw, list):
        raise HTTPException(422, "paths must be an array")
    return store.reindex(changed_paths=[str(item) for item in raw[:5_000]])


@app.get("/api/knowledge/search")
def knowledge_search(
    query: str = Query(min_length=1, max_length=2_000),
    workspace: str = Query(default=""),
    limit: int = Query(default=8, ge=1, le=20),
) -> dict[str, Any]:
    try:
        return {"results": _knowledge_store(workspace).search(query, limit=limit)}
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.get("/api/knowledge/memories")
def knowledge_memories(workspace: str = Query(default="")) -> dict[str, Any]:
    return {"memories": _knowledge_store(workspace).list_memories()}


@app.post("/api/knowledge/memories")
def knowledge_memory_create(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        memory = _knowledge_store(str(body.get("workspace") or "")).save_memory(body)
        return {"ok": True, "memory": memory}
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.put("/api/knowledge/memories/{memory_id}")
def knowledge_memory_update(
    memory_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    try:
        memory = _knowledge_store(str(body.get("workspace") or "")).save_memory(body, memory_id)
        return {"ok": True, "memory": memory}
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.delete("/api/knowledge/memories/{memory_id}")
def knowledge_memory_delete(memory_id: str, workspace: str = Query(default="")) -> dict[str, Any]:
    if not _knowledge_store(workspace).delete_memory(memory_id):
        raise HTTPException(404, "workspace memory not found")
    return {"ok": True, "id": memory_id}


@app.delete("/api/knowledge")
def knowledge_delete_all(workspace: str = Query(default="")) -> dict[str, Any]:
    _knowledge_store(workspace).delete_all()
    return {"ok": True}


# ------------------------------------------------------------ Durable MCP tasks


@app.get("/api/mcp/tasks")
def mcp_task_list(
    run_id: str = Query(default=""), nonterminal: bool = Query(default=False)
) -> dict[str, Any]:
    _require_capability("modern_mcp")
    return {
        "tasks": service().run_store.mcp_tasks(
            run_id=run_id, nonterminal=nonterminal,
        )
    }


@app.post("/api/mcp/tasks/{task_id}/lookup")
def mcp_task_lookup(task_id: str) -> dict[str, Any]:
    _require_capability("modern_mcp")
    try:
        return {"ok": True, **service().core.mcp.lookup_task(task_id)}
    except ExtensionError as exc:
        raise HTTPException(409, str(exc)) from exc


@app.post("/api/mcp/tasks/{task_id}/cancel")
def mcp_task_cancel(task_id: str) -> dict[str, Any]:
    _require_capability("modern_mcp")
    try:
        return {"ok": True, **service().core.mcp.cancel_task(task_id)}
    except ExtensionError as exc:
        raise HTTPException(409, str(exc)) from exc


# --------------------------------------------------------------- Evaluations


def _evaluation_store() -> EvaluationStore:
    _require_capability("evaluations")
    return EvaluationStore(service().run_store)


@app.get("/api/evaluations")
def evaluation_list(workspace: str = Query(default="")) -> dict[str, Any]:
    return {"suites": _evaluation_store().list_suites(workspace)}


@app.post("/api/evaluations")
def evaluation_create(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        return {"ok": True, "suite": _evaluation_store().save_suite(body)}
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.get("/api/evaluations/{suite_id}")
def evaluation_detail(suite_id: str) -> dict[str, Any]:
    suite = _evaluation_store().get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    results = _evaluation_store().results(suite_id)
    return {
        "suite": suite, "results": results,
        "summary": summarize_results(results), "comparison": compare_results(results),
    }


@app.get("/api/evaluations/{suite_id}/comparison")
def evaluation_comparison(suite_id: str) -> dict[str, Any]:
    if _evaluation_store().get_suite(suite_id) is None:
        raise HTTPException(404, "evaluation suite not found")
    results = _evaluation_store().results(suite_id)
    return {"suite_id": suite_id, "configurations": compare_results(results)}


@app.get("/api/evaluations/{suite_id}/export")
def evaluation_export(suite_id: str, include_results: bool = Query(default=False)) -> dict[str, Any]:
    suite = _evaluation_store().get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    export: dict[str, Any] = {"schema_version": 1, "suite": suite}
    if include_results:
        export["results"] = _evaluation_store().results(suite_id)
    return export


@app.put("/api/evaluations/{suite_id}")
def evaluation_update(
    suite_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    try:
        return {"ok": True, "suite": _evaluation_store().save_suite(body, suite_id)}
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.delete("/api/evaluations/{suite_id}")
def evaluation_delete(suite_id: str) -> dict[str, Any]:
    if not _evaluation_store().delete_suite(suite_id):
        raise HTTPException(404, "evaluation suite not found")
    return {"ok": True, "id": suite_id}


@app.post("/api/evaluations/{suite_id}/grade")
def evaluation_grade(
    suite_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    suite = _evaluation_store().get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    case_id = str(body.get("case_id") or "")
    case = next((item for item in suite["cases"] if item["id"] == case_id), None)
    if case is None:
        raise HTTPException(404, "evaluation case not found")
    checkout = str(body.get("checkout") or "")
    source_root = Path(suite["workspace_root"]).resolve()
    checkout_path = Path(checkout).resolve()
    if checkout_path != source_root or str(case.get("mode")) != "read_only":
        # Managed evaluation checkouts live outside the source root; require a
        # known TaskCheckout record instead of accepting arbitrary paths.
        task_id = str(body.get("task_id") or "")
        task = TaskCheckoutStore.load(task_id) if task_id else None
        if task is None or Path(task.execution_path).resolve() != checkout_path:
            raise HTTPException(422, "checkout is not a managed evaluation task")
    try:
        result = grade_case(
            case, checkout, str(body.get("output") or ""),
            [str(item) for item in body.get("changed_paths") or []],
        )
    except EvaluationError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"case_id": case_id, **result}


@app.post("/api/evaluations/{suite_id}/run")
async def evaluation_run(
    suite_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    svc = service()
    suite = _evaluation_store().get_suite(suite_id)
    if suite is None:
        raise HTTPException(404, "evaluation suite not found")
    manifest = body.get("manifest")
    raw_manifests = body.get("manifests")
    manifests = {
        str(team_id): dict(value)
        for team_id, value in raw_manifests.items()
        if str(team_id) and isinstance(value, dict)
    } if isinstance(raw_manifests, dict) else {}
    if len(manifests) > 32:
        raise HTTPException(422, "an evaluation run may reference at most 32 teams")
    needs_team = any(str(case.get("target") or "team") == "team" for case in suite["cases"])
    missing_team = any(
        str(case.get("target") or "team") == "team"
        and not (
            isinstance(manifest, dict)
            or str(case.get("team_id") or "") in manifests
            or (not str(case.get("team_id") or "") and len(manifests) == 1)
        )
        for case in suite["cases"]
    )
    if needs_team and missing_team:
        raise HTTPException(422, "team evaluation cases require a configured team manifest")
    if not isinstance(manifest, dict):
        manifest = {}
    if svc.busy:
        raise _busy_http()
    loop = asyncio.get_running_loop()
    evaluation_id = uuid.uuid4().hex
    if not svc.start_turn(
        loop, _run_evaluation_suite, svc, suite, dict(manifest), manifests, evaluation_id,
    ):
        raise _busy_http()
    return {"ok": True, "evaluation_id": evaluation_id, "state": "queued"}


@app.post("/api/evaluations/runs/{evaluation_id}/cancel")
def evaluation_cancel(evaluation_id: str) -> dict[str, Any]:
    svc = service()
    if svc.active_evaluation_id != evaluation_id:
        raise HTTPException(409, "that evaluation is not currently running")
    svc.core.interrupt()
    if svc.active_evaluation_core is not None:
        svc.active_evaluation_core.interrupt()
    return {"ok": True, "evaluation_id": evaluation_id, "state": "cancelling"}


def _run_evaluation_suite(
    parent: ChatService,
    suite: dict[str, Any],
    manifest: dict[str, Any],
    manifests: dict[str, dict[str, Any]],
    evaluation_id: str,
) -> None:
    """Execute evaluation cases in disposable task checkouts.

    The source workspace is only read while each baseline is captured. The
    evaluation owns a separate AgentCore/session and never exposes Apply.
    """
    store = EvaluationStore(parent.run_store)
    parent.emit({
        "type": "evaluation_started", "evaluation_id": evaluation_id,
        "suite_id": suite["id"], "case_count": len(suite["cases"]),
    })
    parent.active_evaluation_id = evaluation_id
    try:
        for index, case in enumerate(suite["cases"]):
            if parent.core._interrupt.is_set():
                break
            run_id = f"eval-{evaluation_id[:12]}-{index + 1}"
            task_id = run_id
            result_id = store.start_result(str(suite["id"]), str(case["id"]), run_id)
            started = time.monotonic()
            parent.emit({
                "type": "evaluation_case_started", "evaluation_id": evaluation_id,
                "suite_id": suite["id"], "case_id": case["id"],
                "case_index": index, "run_id": run_id,
            })
            evaluation_core: AgentCore | None = None
            timeout_timer: threading.Timer | None = None
            timed_out = threading.Event()
            try:
                fixture = case.get("baseline_fixture")
                fixture_id = (
                    str(fixture.get("task_id") or "")
                    if isinstance(fixture, dict) else ""
                )
                fixture_task = TaskCheckoutStore.load(fixture_id) if fixture_id else None
                task = (
                    TaskCheckoutStore.replay(fixture_task, task_id)
                    if fixture_task is not None
                    else TaskCheckoutStore.create(str(suite["workspace_root"]), task_id)
                )
                task.state = "running"
                task.save()
                evaluation_core = AgentCore(
                    model=parent.core.model,
                    cwd=task.execution_path,
                    skip_permissions=True,
                    config=parent.core.config,
                )
                parent.active_evaluation_core = evaluation_core
                evaluation_core.tool_registry.computer_enabled = False
                read_only = str(case.get("mode") or "write") == "read_only"
                evaluation_core.evaluation_read_only = read_only
                evaluation_core.tool_registry.set_mcp_agent_policy(
                    {},
                    access_ceiling="read_only" if read_only else "workspace_write",
                    role="evaluation",
                )
                evaluation_service = ChatService(evaluation_core)
                evaluation_service.run_store = parent.run_store
                evaluation_service.core.mcp.task_store = parent.run_store
                evaluation_service.current_task = task
                evaluation_service.core.enter_task_checkout(
                    task.execution_path, task.workspace_root, task.as_dict(),
                )
                requested_team = str(case.get("team_id") or "")
                selected_manifest = manifests.get(requested_team)
                if selected_manifest is None and not requested_team and len(manifests) == 1:
                    selected_manifest = next(iter(manifests.values()))
                case_manifest = dict(selected_manifest or manifest)
                case_manifest["run_id"] = run_id
                team_value = dict(case_manifest.get("team") or {})
                team_value["use_managed_worktree"] = True
                if isinstance(case.get("budget"), dict):
                    team_value["budget"] = dict(case["budget"])
                case_manifest["team"] = team_value
                # Evaluation tools are local-only: computer control and
                # mutating MCP access stay absent even when a profile normally
                # allows them. A read-only suite may retain explicit MCP
                # allowlists, which are still annotation-gated by the runtime.
                profile_values = []
                for raw_profile in case_manifest.get("profiles") or []:
                    profile_value = dict(raw_profile)
                    if not (read_only and suite.get("read_only_mcp")):
                        profile_value["mcp_policy"] = {}
                    profile_values.append(profile_value)
                if profile_values:
                    case_manifest["profiles"] = profile_values
                target = str(case.get("target") or "team")
                timeout_seconds = int(case.get("timeout_seconds") or 1_800)

                def timeout_case(
                    timeout_event: threading.Event = timed_out,
                    case_core: AgentCore = evaluation_core,
                ) -> None:
                    timeout_event.set()
                    case_core.interrupt()

                timeout_timer = threading.Timer(timeout_seconds, timeout_case)
                timeout_timer.daemon = True
                timeout_timer.start()
                if target == "solo":
                    parent.run_store.start_run(
                        run_id,
                        session_id=evaluation_core.session.session_id,
                        workspace_root=task.workspace_root,
                        execution_path=task.execution_path,
                        task_id=task.id,
                        request=str(case["prompt"]),
                        state="running",
                    )
                    evaluation_service.active_run_id = run_id
                    evaluation_core.client = parent.core.client
                    evaluation_core.provider = parent.core.provider
                    evaluation_core.host = parent.core.host
                    evaluation_core.model = parent.core.model
                    budget = case.get("budget") if isinstance(case.get("budget"), dict) else {}
                    evaluation_core.max_iterations = min(
                        evaluation_core.max_iterations,
                        int(budget.get("max_model_calls") or evaluation_core.max_iterations),
                    )
                    parent.emit({
                        "type": "scheduler_lease_waiting", "run_id": run_id,
                        "agent_id": "solo-evaluation",
                        "active_leases": GLOBAL_MODEL_SCHEDULER.active_count,
                    })
                    with GLOBAL_MODEL_SCHEDULER.lease(
                        run_id, evaluation_core._should_stop_stream,
                    ) as lease_id:
                        parent.emit({
                            "type": "scheduler_lease_acquired", "run_id": run_id,
                            "agent_id": "solo-evaluation", "lease_id": lease_id,
                            "active_leases": GLOBAL_MODEL_SCHEDULER.active_count,
                        })
                        heartbeat_stop = threading.Event()

                        def heartbeat(stop_event: threading.Event = heartbeat_stop) -> None:
                            while not stop_event.wait(10):
                                if not GLOBAL_MODEL_SCHEDULER.heartbeat(lease_id):
                                    return

                        heartbeat_thread = threading.Thread(
                            target=heartbeat, name="locus-evaluation-lease", daemon=True,
                        )
                        heartbeat_thread.start()
                        try:
                            evaluation_core.run_turn(
                                str(case["prompt"]), lambda *_: "deny", allow_tools=True,
                            )
                        finally:
                            heartbeat_stop.set()
                            parent.emit({
                                "type": "scheduler_lease_released", "run_id": run_id,
                                "agent_id": "solo-evaluation", "lease_id": lease_id,
                            })
                    solo_reason = str(evaluation_core.last_turn_result.get("reason") or "")
                    parent.run_store.set_state(
                        run_id,
                        "completed" if solo_reason in {"complete", "max_iterations"} else "failed",
                    )
                    evaluation_service.active_run_id = None
                else:
                    _run_team_turn(evaluation_service, str(case["prompt"]), case_manifest)
                run = parent.run_store.run(run_id) or {}
                patch_text, current_tree = task.patch()
                changed = _evaluation_changed_paths(task, current_tree)
                output = next((
                    str(message.get("content") or "")
                    for message in reversed(evaluation_core.messages)
                    if message.get("role") == "assistant"
                ), "")
                grade = grade_case(case, task.execution_path, output, changed)
                succeeded = str(run.get("state") or "") == "completed"
                rubric_result: dict[str, Any] | None = None
                if grade["deterministic_passed"] and str(case.get("rubric") or "").strip():
                    judge_id = str(case.get("judge_profile_id") or "")
                    if judge_id and case_manifest.get("profiles"):
                        _, judge_team, judge_profiles, _ = parse_manifest(case_manifest)
                        judge = judge_profiles.get(judge_id)
                        if judge is None or judge.role != "reviewer":
                            raise EvaluationError(
                                "the evaluation judge must be an eligible reviewer profile"
                            )
                        rubric_result = TeamOrchestrator(
                            parent.emit,
                            evaluation_core._should_stop_stream,
                            run_store=parent.run_store,
                        ).evaluate_rubric(
                            run_id, judge, judge_team.budget,
                            case=case, output=output, diff_text=patch_text, evidence=grade,
                        )
                rubric_passed = rubric_result is None or (
                    float(rubric_result["score"]) >= float(case.get("passing_score") or 80)
                )
                passed = (
                    not timed_out.is_set()
                    and succeeded
                    and bool(grade["deterministic_passed"])
                    and rubric_passed
                )
                usage = run.get("usage") if isinstance(run.get("usage"), dict) else {}
                model_calls = int(
                    usage.get("model_calls")
                    or evaluation_core.last_turn_result.get("model_calls")
                    or 0
                )
                value = store.finish_result(result_id, {
                    "state": "passed" if passed else "failed",
                    **grade,
                    "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
                    "model_calls": model_calls,
                    "prompt_tokens": evaluation_core.total_prompt_tokens,
                    "completion_tokens": evaluation_core.total_completion_tokens,
                    "estimated_cost": float(usage.get("estimated_cost") or 0),
                    "output": output,
                    "rubric_score": rubric_result["score"] if rubric_result else None,
                    "rubric_reason": rubric_result["reason"] if rubric_result else "",
                    "rubric_subjective": bool(rubric_result),
                    "patch_bytes": len(patch_text.encode("utf-8", errors="surrogateescape")),
                    "task_id": task_id,
                    "target": target,
                    "team_id": str(
                        case.get("team_id")
                        or (case_manifest.get("team") or {}).get("id")
                        or ""
                    ),
                    "retries": sum(
                        max(int(attempt.get("attempt") or 1) - 1, 0)
                        for attempt in run.get("attempts") or []
                    ),
                    "failure_category": "" if passed else (
                        "timeout" if timed_out.is_set() else
                        "provider_or_runtime" if not succeeded else
                        "deterministic_assertion" if not grade["deterministic_passed"] else
                        "subjective_rubric"
                    ),
                })
                if target == "team" and case_manifest.get("profiles"):
                    _, _, evaluation_profiles, _ = parse_manifest(case_manifest)
                    quality = float(
                        rubric_result["score"] if rubric_result else (100 if passed else 0)
                    )
                    for attempt in run.get("attempts") or []:
                        agent = evaluation_profiles.get(str(attempt.get("agent_id") or ""))
                        result = attempt.get("result") if isinstance(attempt.get("result"), dict) else {}
                        if agent is None:
                            continue
                        estimated_cost = (
                            int(result.get("prompt_tokens") or 0) * agent.input_cost_per_million
                            + int(result.get("completion_tokens") or 0)
                            * agent.output_cost_per_million
                        ) / 1_000_000
                        parent.run_store.record_routing_sample(
                            agent.id,
                            tags=[str(item) for item in case.get("tags") or []],
                            quality=quality,
                            reliable=succeeded and not bool(result.get("error")),
                            latency_ms=int(result.get("elapsed_ms") or value["duration_ms"]),
                            estimated_cost=estimated_cost,
                            local=agent.route.get("provider") == "ollama",
                            evaluation=True,
                        )
                parent.emit({
                    "type": "evaluation_case_completed",
                    "evaluation_id": evaluation_id,
                    "suite_id": suite["id"], "case_id": case["id"],
                    "run_id": run_id, "result": value,
                })
            except (
                EvaluationError, InterruptedError, WorktreeError, OrchestrationError, OSError,
            ) as exc:
                value = store.finish_result(result_id, {
                    "state": "failed", "error": str(exc),
                    "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
                    "target": str(case.get("target") or "team"),
                    "team_id": str(case.get("team_id") or ""),
                    "failure_category": "timeout" if timed_out.is_set() else "runtime",
                })
                parent.emit({
                    "type": "evaluation_case_completed", "evaluation_id": evaluation_id,
                    "suite_id": suite["id"], "case_id": case["id"],
                    "run_id": run_id, "result": value,
                })
            finally:
                if timeout_timer is not None:
                    timeout_timer.cancel()
                parent.active_evaluation_core = None
                if evaluation_core is not None:
                    evaluation_core.mcp.close()
        results = store.results(str(suite["id"]))
        parent.emit({
            "type": "evaluation_completed", "evaluation_id": evaluation_id,
            "suite_id": suite["id"], "summary": summarize_results(results),
            "state": "interrupted" if parent.core._interrupt.is_set() else "completed",
        })
    finally:
        parent.active_evaluation_id = None
        parent.active_evaluation_core = None
        parent.core._interrupt.clear()


def _evaluation_changed_paths(task: TaskCheckout, current_tree: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", task.baseline_tree, current_tree, "--"],
        cwd=task.execution_path, capture_output=True, timeout=120, check=False,
    )
    if result.returncode != 0:
        raise WorktreeError(result.stderr.decode("utf-8", errors="replace").strip())
    return [
        item.decode("utf-8", errors="replace")
        for item in result.stdout.split(b"\0") if item
    ]


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
        svc.resolve_context_limit_soon()
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
            published_context_window=body.get("published_context_window"),
        )
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    if body.get("verify"):
        try:
            svc.core.client.check()
        except OllamaError as e:
            raise HTTPException(502, str(e)) from e
    svc.resolve_context_limit_soon()
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
        # The window this model is really running in, not the one it was
        # trained for. The GUI meters against this, and metering against the
        # trained window reads reassuringly low right up to the point where
        # replies start getting truncated. 0 still means "not known", which is
        # the honest answer for a model that is not loaded and for an endpoint
        # that says nothing about itself.
        #
        # A configured window only describes the model the agent is actually
        # running: `num_ctx` is sent for that one alone, so claiming the rest
        # run in it too would be a guess about models nobody has loaded.
        if is_ollama:
            trained = svc.core.client.context_length(name)
            model_configured = configured if name == svc.core.model else 0
            window = effective_context_length(
                resident.get(name, 0), trained, model_configured
            )
            if window <= 0:
                # Measured on an earlier run and remembered since. Still an
                # observation, and it keeps the meter alive for a model Ollama
                # has evicted rather than blanking it every five idle minutes.
                window = svc.core.remembered_model_window(name)
        else:
            # Whatever the endpoint stated about itself, parsed out of the
            # listing this call already fetched — no extra request, and no
            # `/api/show`, which a remote client cannot answer. Zeroing this was
            # why a hosted account could never fill the meter from the model
            # list, only from session_info.
            window = int(m.get("context_length") or 0)
            trained = int(m.get("trained_context_length") or 0) or window
            if name == svc.core.model:
                window = svc.core.context_limit or window
            if window <= 0:
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
            cwd_value = body.get("cwd")
            if cwd_value is not None and not isinstance(cwd_value, str):
                raise HTTPException(422, "cwd must be a string")
            info = svc.core.new_session(reason=reason, cwd=str(cwd_value or "") or None)
            return {"ok": True, "reason": reason, "session_info": info}
    except AgentBusyError as e:
        raise _busy_http() from e
    except ValueError as e:
        raise HTTPException(422, str(e)) from e


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


@app.delete("/api/sessions/{session_id}")
def session_delete(session_id: str) -> dict[str, Any]:
    """Move one chat to recovery, replacing it first when it is active."""
    svc = service()
    if SessionStore.path_for(session_id) is None:
        raise HTTPException(404, f"session not found: {session_id}")
    try:
        with svc.state_mutation():
            deleted_active = session_id == svc.core.session.session_id
            replacement = None
            if deleted_active:
                replacement = svc.core.new_session(reason="deleted_active")
            count, recovery_path = SessionStore.move_to_trash([session_id])
            if count != 1:
                raise HTTPException(500, "the chat could not be moved to recovery")
            return {
                "ok": True,
                "id": session_id,
                "trash_batch": Path(recovery_path).name,
                "deleted_active": deleted_active,
                "replacement_session_info": replacement,
            }
    except AgentBusyError as e:
        raise _busy_http() from e


@app.post("/api/sessions/restore")
def sessions_restore(body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    """Undo a clear: move a trash batch (default the newest) back."""
    svc = service()
    try:
        with svc.state_mutation():
            batch = str(body.get("batch") or "") or None
            restored_ids = SessionStore.restore_from_trash_details(batch)
            return {
                "ok": True,
                "restored": len(restored_ids),
                "session_ids": restored_ids,
            }
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
    activity = SessionStore.agent_activity(path)
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
        "task": meta.get("task"),
        "team": meta.get("team"),
        "workspace_root": meta.get("workspace_root"),
        "execution_path": meta.get("execution_path"),
        "environment": meta.get("environment"),
        "agent_activities": activity["activities"],
        "orchestration_state": activity.get("orchestration_state"),
        "orchestration_run_id": activity.get("run_id"),
        "worker_id": activity.get("worker_id"),
    }


# ------------------------------------------------------- Durable orchestrations


@app.get("/api/orchestrations")
def orchestration_list(
    session_id: str = Query(default="", max_length=160),
    limit: int = Query(default=100, ge=1, le=500),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service().run_store
    if session_id and not store.list_runs(session_id=session_id, limit=1):
        path = SessionStore.path_for(session_id)
        if path is not None:
            snapshot = SessionStore.agent_activity(path)
            header = SessionStore.header(path)
            store.import_legacy_snapshot(
                session_id, snapshot, workspace_root=str(header.get("cwd") or ""),
            )
    return {
        "runs": store.list_runs(session_id=session_id, limit=limit),
        "read_only": store.read_only,
    }


@app.get("/api/orchestrations/{run_id}")
def orchestration_detail(run_id: str) -> dict[str, Any]:
    _require_capability("durable_runs")
    value = service().run_store.run(run_id)
    if value is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    return value


@app.patch("/api/orchestrations/{run_id}")
def orchestration_update(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("durable_runs")
    if not isinstance(body.get("pinned"), bool):
        raise HTTPException(422, "pinned must be a boolean")
    try:
        return service().run_store.set_pinned(run_id, bool(body["pinned"]))
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.get("/api/orchestrations/{run_id}/events")
def orchestration_events(
    run_id: str,
    after_seq: int = Query(default=0, ge=0),
    limit: int = Query(default=5_000, ge=1, le=10_000),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service().run_store
    if store.run(run_id) is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    events = store.events(run_id, after_seq=after_seq, limit=limit)
    return {
        "run_id": run_id,
        "after_seq": after_seq,
        "events": events,
        "last_seq": int(events[-1].get("seq") or after_seq) if events else after_seq,
    }


@app.get("/api/orchestrations/{run_id}/export")
def orchestration_export(
    run_id: str,
    include_content: bool = Query(default=False),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return service().run_store.export(run_id, include_content=include_content)
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.post("/api/orchestrations/{run_id}/otlp")
def orchestration_otlp(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return send_otlp(
            service().run_store,
            run_id,
            str(body.get("endpoint") or ""),
            authorization=str(body.get("authorization") or ""),
            include_content=bool(body.get("include_content")),
        )
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc
    except TelemetryError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.post("/api/orchestrations/{run_id}/pause")
def orchestration_pause(run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service()
    if svc.active_run_id != run_id or not svc.busy:
        raise HTTPException(409, "that orchestration is not actively running")
    svc.pause_requested = True
    svc.run_store.set_state(
        run_id, "pausing", recoverable=False,
        reason="Waiting for the next safe boundary before pausing.",
    )
    svc.core.interrupt()
    svc.deny_all_pending()
    svc.cancel_all_computer_actions()
    svc.cancel_dispatch_decisions()
    svc.core.mcp.cancel_pending_inputs()
    svc.emit({
        "type": "orchestration_pause_requested", "run_id": run_id,
        "state": "pausing",
    })
    return {"ok": True, "run_id": run_id, "state": "pausing"}


@app.post("/api/orchestrations/{run_id}/cancel")
def orchestration_cancel(run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service()
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    terminal_states = {"cancelled", "completed", "failed", "interrupted", "discarded"}
    if str(record.get("state") or "") in terminal_states:
        return {"ok": True, "run_id": run_id, "state": str(record["state"])}
    if svc.active_run_id != run_id or not svc.busy:
        owner = str(record.get("worker_id") or "")
        if owner and owner != svc.worker_id:
            raise HTTPException(409, "that orchestration is active in another worker")
        raise HTTPException(409, "that orchestration is not actively running")
    svc.pause_requested = False
    svc.cancel_requested_runs.add(run_id)
    svc.core.interrupt()
    svc.deny_all_pending()
    svc.cancel_all_computer_actions()
    svc.cancel_dispatch_decisions()
    svc.core.mcp.cancel_pending_inputs()
    svc.run_store.set_state(run_id, "cancelled", recoverable=False)
    return {"ok": True, "run_id": run_id, "state": "cancelled"}


@app.post("/api/orchestrations/{run_id}/discard")
def orchestration_discard(run_id: str) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service()
    if svc.active_run_id == run_id and svc.busy:
        raise HTTPException(409, "stop the active orchestration before discarding it")
    try:
        return {"ok": True, "run": svc.run_store.discard(run_id)}
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.post("/api/orchestrations/{run_id}/dispatch-decision")
def orchestration_dispatch_decision(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    _require_capability("adaptive_routing")
    action = str(body.get("action") or "cancel")
    if action not in {"run", "redispatch", "cancel"}:
        raise HTTPException(422, "action must be run, redispatch, or cancel")
    decision: dict[str, Any] = {"action": action}
    if isinstance(body.get("plan"), dict):
        decision["plan"] = body["plan"]
    if not service().answer_dispatch(run_id, decision):
        raise HTTPException(409, "that dispatch plan is no longer waiting")
    return {"ok": True, "run_id": run_id, "action": action}


async def _resume_orchestration(
    run_id: str,
    body: dict[str, Any],
    *,
    action: str,
) -> dict[str, Any]:
    _require_capability("recovery_controls")
    svc = service()
    record = svc.run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    if svc.busy:
        raise _busy_http()
    manifest = body.get("manifest")
    if not isinstance(manifest, dict):
        raise HTTPException(422, "resume requires the current in-memory team manifest")
    manifest = dict(manifest)
    if action in {"resume", "retry", "reassign"}:
        manifest["run_id"] = run_id
    else:
        manifest["run_id"] = uuid.uuid4().hex
    checkpoint = record.get("checkpoint")
    if action in {"resume", "retry", "reassign"}:
        if not isinstance(checkpoint, dict):
            raise HTTPException(409, "this run has no stable checkpoint to resume")
        manifest["_resume"] = checkpoint.get("state") or {}
        manifest["_resume_from_run_id"] = run_id
    if action == "retry":
        job_id = str(body.get("job_id") or "")
        if not job_id:
            raise HTTPException(422, "job_id is required")
        manifest["_retry_job"] = job_id
    if action == "reassign":
        job_id = str(body.get("job_id") or "")
        agent_id = str(body.get("agent_id") or "")
        if not job_id or not agent_id:
            raise HTTPException(422, "job_id and agent_id are required")
        manifest["_reassign"] = {"job_id": job_id, "agent_id": agent_id}
    task_id = str(record.get("task_id") or "")
    source_task = TaskCheckoutStore.load(task_id) if task_id else None
    if action in {"resume", "retry", "reassign", "replay"} and task_id and source_task is None:
        raise HTTPException(409, "the managed checkout for this run is missing")
    checkpoint_state = (
        checkpoint.get("state") if isinstance(checkpoint, dict)
        and isinstance(checkpoint.get("state"), dict) else {}
    )
    expected_baseline = str(checkpoint_state.get("baseline_tree") or "")
    if source_task is not None and expected_baseline \
            and source_task.baseline_tree != expected_baseline:
        raise HTTPException(409, "the managed checkout no longer matches its recovery baseline")
    task = source_task
    if action == "replay" and source_task is not None:
        task = TaskCheckoutStore.replay(source_task, str(manifest["run_id"]))
    elif action == "duplicate":
        task = None
        svc.current_task = None
        try:
            svc.core.leave_task_checkout(str(record.get("workspace_root") or ""))
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc
    if task is not None:
        svc.current_task = task
        svc.core.enter_task_checkout(task.execution_path, task.workspace_root, task.as_dict())
    request_text = str(record.get("request") or "")
    if not request_text:
        raise HTTPException(409, "the original request is unavailable")
    loop = asyncio.get_running_loop()
    if not svc.start_turn(loop, _run_team_turn, svc, request_text, manifest):
        raise _busy_http()
    return {
        "ok": True,
        "action": action,
        "source_run_id": run_id,
        "run_id": str(manifest["run_id"]),
        "state": "queued",
    }


@app.post("/api/orchestrations/{run_id}/resume")
async def orchestration_resume(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    return await _resume_orchestration(run_id, body, action="resume")


@app.post("/api/orchestrations/{run_id}/recovery-assessment")
def orchestration_recovery_assessment(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    """Validate reusable state without making a provider call or changing the run."""
    _require_capability("recovery_controls")
    record = service().run_store.run(run_id)
    if record is None:
        raise HTTPException(404, f"orchestration not found: {run_id}")
    repairs: list[str] = []
    checkpoint = record.get("checkpoint")
    state = checkpoint.get("state") if isinstance(checkpoint, dict) else None
    if record.get("legacy"):
        repairs.append("Legacy imported runs are inspectable but not replayable.")
    if not isinstance(state, dict):
        repairs.append("No stable checkpoint is available.")
        state = {}
    task_id = str(record.get("task_id") or "")
    task = TaskCheckoutStore.load(task_id) if task_id else None
    if task_id and task is None:
        repairs.append("The managed checkout is missing.")
    expected_baseline = str(state.get("baseline_tree") or "")
    if task is not None and expected_baseline and task.baseline_tree != expected_baseline:
        repairs.append("The private task baseline changed.")
    manifest = body.get("manifest")
    if not isinstance(manifest, dict):
        repairs.append("The current team profiles and credentials are required.")
    else:
        try:
            _, team, profiles, _ = parse_manifest(manifest)
            expected = str(state.get("orchestration_fingerprint") or "")
            if not expected or expected == "unavailable":
                repairs.append("The checkpoint has no verifiable team fingerprint.")
            elif orchestration_fingerprint(team, profiles) != expected:
                repairs.append("The team or profile configuration changed.")
        except OrchestrationError as exc:
            repairs.append(str(exc))
    reusable = [
        str(result.get("job_id") or "") for result in state.get("results") or []
        if isinstance(result, dict) and str(result.get("job_id") or "")
    ]
    return {
        "run_id": run_id,
        "can_resume": not repairs,
        "repair_checklist": repairs,
        "reusable_job_ids": reusable,
        "writer_continuation": bool(task is not None),
    }


@app.post("/api/orchestrations/{run_id}/jobs/{job_id}/retry")
async def orchestration_retry_job(
    run_id: str, job_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    return await _resume_orchestration(run_id, {**body, "job_id": job_id}, action="retry")


@app.post("/api/orchestrations/{run_id}/jobs/{job_id}/reassign")
async def orchestration_reassign_job(
    run_id: str, job_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    return await _resume_orchestration(run_id, {**body, "job_id": job_id}, action="reassign")


@app.post("/api/orchestrations/{run_id}/replay")
async def orchestration_replay(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    return await _resume_orchestration(run_id, body, action="replay")


@app.post("/api/orchestrations/{run_id}/duplicate")
async def orchestration_duplicate(
    run_id: str, body: dict[str, Any] = Body(default_factory=dict)
) -> dict[str, Any]:
    return await _resume_orchestration(run_id, body, action="duplicate")


@app.get("/api/tasks/{task_id}")
def task_detail(task_id: str) -> dict[str, Any]:
    """Return task metadata and its complete baseline-relative binary patch."""
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    try:
        patch, tree = task.patch()
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {
        "ok": True,
        "task": task.as_dict(),
        "tree": tree,
        "patch": patch,
        "patch_bytes": len(patch.encode("utf-8", errors="surrogateescape")),
    }


@app.post("/api/tasks/{task_id}/apply")
def task_apply(task_id: str) -> dict[str, Any]:
    """Apply only after a complete dry run; leave source changes unstaged."""
    svc = service()
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    try:
        with svc.state_mutation():
            result = task.apply()
            if svc.current_task and svc.current_task.id == task.id:
                svc.current_task = task
                svc.core.task_metadata = task.as_dict()
            svc.queue_event({
                "type": "task_applied",
                "task": task.as_dict(),
                **result,
            })
            return {"task": task.as_dict(), **result}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


@app.delete("/api/tasks/{task_id}")
def task_cleanup(task_id: str) -> dict[str, Any]:
    """Explicitly remove a managed task checkout without touching its workspace."""
    svc = service()
    task = TaskCheckoutStore.load(task_id)
    if task is None:
        raise HTTPException(404, f"task not found: {task_id}")
    if svc.busy:
        raise _busy_http()
    try:
        with svc.state_mutation():
            if svc.current_task and svc.current_task.id == task_id:
                svc.core.leave_task_checkout(task.workspace_root)
                svc.current_task = None
            return TaskCheckoutStore.cleanup(task_id)
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


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
            meta = SessionMeta.get(session_id)
            task_value = meta.get("task")
            task_id = str(task_value.get("id") or "") if isinstance(task_value, dict) else ""
            task = TaskCheckoutStore.load(task_id) if task_id else None
            svc.current_task = task
            if task is not None:
                svc.core.enter_task_checkout(
                    task.execution_path,
                    task.workspace_root,
                    task.as_dict(),
                )
    except AgentBusyError as e:
        raise _busy_http() from e
    except FileNotFoundError as e:
        raise HTTPException(404, str(e)) from e
    except SessionTooLargeError as e:
        raise HTTPException(413, str(e)) from e
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    path = SessionStore.path_for(session_id)
    activity = SessionStore.agent_activity(path) if path is not None else {"activities": []}
    return {
        "ok": True,
        "text": result.get("text"),
        "messages": (result.get("data") or {}).get("messages", []),
        "session_info": svc.core.session_info(),
        "agent_activities": activity["activities"],
        "orchestration_state": activity.get("orchestration_state"),
        "orchestration_run_id": activity.get("run_id"),
        "worker_id": activity.get("worker_id"),
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
    if "max_iterations" in body:
        requested = body.get("max_iterations")
        resolved = non_negative_int(requested)
        # Rejected rather than coerced, for the same reason as the window above:
        # this setting has no visible effect until a turn happens to reach it,
        # so a silently altered value would be discovered days later, as a
        # turn that stops early for no stated reason.
        if resolved <= 0 or resolved > MAX_ITERATIONS_CEILING:
            raise HTTPException(
                422,
                f"max_iterations must be between 1 and {MAX_ITERATIONS_CEILING}",
            )
        svc.core.max_iterations = resolved
        svc.core.config["max_iterations"] = resolved
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
            if event.get("type") in {"turn_done", "slash_result"}:
                # Once a terminal event reaches the client, the turn slot must
                # already accept the next message. This makes Stop & Send and
                # ordinary queue draining deterministic rather than a race
                # against the executor future's final callback.
                future = svc.turn_future
                if future is not None and not future.done():
                    await asyncio.shield(future)
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


def _run_team_turn(svc: ChatService, text: str, manifest: dict[str, Any]) -> None:
    """Run specialists, one permission-controlled writer, review, and synthesis."""
    core = svc.core
    started = time.monotonic()
    terminal_reason = "complete"
    core._suppress_turn_done = True
    run_id = str(manifest.get("run_id") or uuid.uuid4().hex)
    svc.active_run_id = run_id
    svc.pause_requested = False
    stage = "validating the team setup"
    try:
        run_id, team, _, _ = parse_manifest(manifest)
        svc.run_store.start_run(
            run_id,
            session_id=core.session.session_id,
            team_id=team.id,
            team_name=team.name,
            worker_id=svc.worker_id,
            workspace_root=core.workspace_root,
            execution_path=core.cwd,
            task_id=svc.current_task.id if svc.current_task else "",
            request=text,
            manifest=manifest,
            state="dispatching",
        )
        # Persist the visible request before dispatch can spend minutes on
        # specialists. This makes a brand-new background task immediately
        # addressable in the sidebar. Internal writer prompts stay in memory.
        if not isinstance(manifest.get("_resume"), dict):
            core._add_message({"role": "user", "content": text})
        workspace_root = core.workspace_root
        if team.use_managed_worktree and svc.current_task is None \
                and _is_git_workspace(workspace_root):
            task = TaskCheckoutStore.create(workspace_root, run_id)
            task.state = "running"
            task.save()
            svc.current_task = task
            svc.run_store.update_task(run_id, task.as_dict())
            core.enter_task_checkout(task.execution_path, task.workspace_root, task.as_dict())
            SessionMeta.update(
                core.session.session_id,
                task=task.as_dict(),
                team={"id": team.id, "name": team.name},
                workspace_root=task.workspace_root,
                execution_path=task.execution_path,
                environment={"isolation": "managed_worktree"},
            )
            svc.emit({"type": "task_ready", "task": task.as_dict(), "state": "running"})

        stage = "preparing the dispatch plan"
        orchestrator = TeamOrchestrator(
            svc.emit,
            core._should_stop_stream,
            run_store=svc.run_store,
            approve_dispatch=svc.request_dispatch_approval,
        )
        svc.active_orchestrator = orchestrator
        prepared: TeamPreparation | None = None
        request = text
        for _round in range(team.budget.max_rounds):
            try:
                resume_state = manifest.get("_resume")
                if isinstance(resume_state, dict) and not resume_state.get("restart_dispatch"):
                    prepared = orchestrator.resume_preparation(
                        request, core.cwd, manifest, resume_state,
                    )
                else:
                    prepared = orchestrator.prepare(request, core.cwd, manifest)
                break
            except InterruptedError:
                if core._interrupt.is_set():
                    raise
                if not core._apply_pending_steers():
                    raise
                update = str(core.messages[-1].get("content") or "")
                request = f"{text}\n\nUser steering update:\n{update}"
                svc.emit({
                    "type": "orchestration_state",
                    "run_id": run_id,
                    "state": "dispatching",
                    "message": "Replanning with the user's steering update",
                })
        if prepared is None:
            raise OrchestrationError("the orchestration-round budget ended before dispatch completed")
        svc.active_team = prepared
        svc.checkpoint(
            "dispatch_complete", _team_checkpoint_state(prepared, "running", svc.current_task)
        )

        stage = "starting the writer"
        route_snapshot = _install_writer_route(core, prepared)
        try:
            stage = "running the writer"
            _run_team_writer(
                svc,
                orchestrator,
                prepared,
                prepared.writer_prompt,
                persisted_user_text=(
                    "[Resumed team run]" if isinstance(manifest.get("_resume"), dict) else text
                ),
                job_id="writer",
                goal=prepared.original_request,
                reserve_model_calls=2,
            )
            terminal_reason = str(core.last_turn_result.get("reason") or "complete")
            if terminal_reason not in {"complete", "max_iterations"}:
                raise InterruptedError(terminal_reason)
            svc.checkpoint(
                "writer_complete", _team_checkpoint_state(prepared, "reviewing", svc.current_task)
            )

            stage = "reviewing the changes"
            core.begin_steerable_turn()
            diff_text = _task_diff(svc, core.workspace_root, core.cwd)
            test_evidence = _latest_assistant_output(core)
            try:
                reviews = orchestrator.review(
                    prepared, diff_text, test_evidence=test_evidence,
                )
            except InterruptedError:
                if core._interrupt.is_set() or not core._apply_pending_steers():
                    raise
                update = str(core.messages[-1].get("content") or "")
                svc.emit({
                    "type": "orchestration_state",
                    "run_id": run_id,
                    "state": "dispatching",
                    "message": "Replanning remaining work after steering",
                })
                prepared = orchestrator.prepare(
                    f"{text}\n\nUser steering update:\n{update}",
                    core.cwd,
                    manifest,
                )
                _run_team_writer(
                    svc,
                    orchestrator,
                    prepared,
                    prepared.writer_prompt,
                    persisted_user_text="[Team steering update]",
                    job_id="writer-steered",
                    goal="Apply the user's steering update to the existing task changes",
                    reserve_model_calls=2,
                )
                diff_text = _task_diff(svc, core.workspace_root, core.cwd)
                reviews = orchestrator.review(
                    prepared,
                    diff_text,
                    test_evidence=_latest_assistant_output(core),
                )
            svc.checkpoint(
                "review_complete",
                _team_checkpoint_state(
                    prepared, "reviewing", svc.current_task, reviews=reviews,
                ),
            )
            revision = _revision_request(reviews)
            if revision and prepared.team.budget.max_rounds > 1 and not core._interrupt.is_set():
                _run_team_writer(
                    svc,
                    orchestrator,
                    prepared,
                    "Team review found issues that must be resolved before handoff. Verify each finding "
                    "against the workspace, make warranted revisions, and rerun focused tests.\n\n"
                    + revision,
                    persisted_user_text="[Team review requested a revision]",
                    job_id="writer-revision",
                    goal="Resolve verified reviewer findings and rerun focused tests",
                    reserve_model_calls=1,
                )
                terminal_reason = str(core.last_turn_result.get("reason") or "complete")
                diff_text = _task_diff(svc, core.workspace_root, core.cwd)
                svc.checkpoint(
                    "revision_complete",
                    _team_checkpoint_state(
                        prepared, "reviewing", svc.current_task, reviews=reviews,
                    ),
                )

            stage = "preparing the final handoff"
            core.begin_steerable_turn()
            synthesis = orchestrator.synthesize(prepared, reviews, diff_text)
            if synthesis and not core._interrupt.is_set():
                svc.emit({"type": "message_start", "agent": "dispatcher"})
                svc.emit({"type": "token", "text": synthesis, "agent": "dispatcher"})
                svc.emit({"type": "message_end", "agent": "dispatcher"})
                core._add_message({"role": "assistant", "content": synthesis})
                svc.checkpoint(
                    "synthesis_complete",
                    _team_checkpoint_state(
                        prepared, "completed", svc.current_task, reviews=reviews,
                    ),
                )
        finally:
            _restore_writer_route(core, route_snapshot)

        if svc.current_task is not None:
            patch_text, tree = svc.current_task.patch()
            svc.emit({
                "type": "task_changes",
                "task_id": svc.current_task.id,
                "tree": tree,
                "has_changes": bool(patch_text),
                "patch_bytes": len(patch_text.encode("utf-8", errors="surrogateescape")),
            })
        svc.emit({
            "type": "orchestration_completed",
            "run_id": prepared.run_id,
            "state": "completed",
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
            "usage": orchestrator.usage(),
        })
    except InterruptedError:
        cancelled = run_id in svc.cancel_requested_runs
        terminal_reason = "cancelled" if cancelled else "interrupted"
        paused = svc.pause_requested
        if paused and prepared is not None:
            svc.checkpoint(
                "paused",
                _team_checkpoint_state(prepared, "paused", svc.current_task),
            )
            svc.emit({
                "type": "orchestration_paused", "run_id": run_id,
                "state": "paused",
            })
        elif paused:
            _, paused_team, paused_profiles, _ = parse_manifest(manifest)
            svc.checkpoint("paused_before_dispatch", {
                "state": "paused",
                "restart_dispatch": True,
                "orchestration_fingerprint": orchestration_fingerprint(
                    paused_team, paused_profiles,
                ),
                "baseline_tree": svc.current_task.baseline_tree
                if svc.current_task is not None else "",
            })
            svc.emit({
                "type": "orchestration_paused", "run_id": run_id,
                "state": "paused",
            })
        svc.emit({
            "type": "orchestration_completed",
            "run_id": str(manifest.get("run_id") or ""),
            "state": "paused" if paused else terminal_reason,
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        })
        svc.run_store.set_state(
            run_id,
            "paused" if paused else terminal_reason,
            # A user cancellation is final even when the run reached a
            # checkpoint before Stop was pressed. Advertising that checkpoint
            # as recoverable is what allowed the cancelled approval to be
            # offered again after reconnecting.
            recoverable=paused or (
                not cancelled and svc.run_store.latest_checkpoint(run_id) is not None
            ),
            reason=(
                "Paused by the user." if paused
                else "Cancelled by the user." if cancelled
                else "The run was interrupted."
            ),
        )
    except (OrchestrationError, WorktreeError, OllamaError, ValueError) as exc:
        terminal_reason = "error"
        svc.emit({"type": "error", "message": str(exc)})
        svc.emit({
            "type": "orchestration_completed",
            "run_id": str(manifest.get("run_id") or ""),
            "state": "failed",
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        })
    except Exception as exc:  # noqa: BLE001 - terminal guard for worker failures
        terminal_reason = "error"
        logger.exception("team run failed unexpectedly while %s", stage)
        svc.emit({
            "type": "error",
            "message": (
                f"The team run stopped unexpectedly while {stage}. "
                "Nothing is still running; you can retry it."
            ),
            "error_type": type(exc).__name__,
        })
        svc.emit({
            "type": "orchestration_completed",
            "run_id": run_id,
            "state": "failed",
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        })
    finally:
        if svc.current_task is not None:
            task_state = {
                "complete": "completed",
                "max_iterations": "completed",
                "interrupted": "interrupted",
                "cancelled": "cancelled",
            }.get(terminal_reason, "failed")
            svc.current_task.state = task_state
            svc.current_task.save()
            core.task_metadata = svc.current_task.as_dict()
            SessionMeta.update(
                core.session.session_id,
                task=svc.current_task.as_dict(),
            )
            svc.emit({
                "type": "task_state",
                "task": svc.current_task.as_dict(),
                "state": task_state,
            })
        core._suppress_turn_done = False
        core.end_steerable_turn()
        svc.active_orchestrator = None
        svc.active_team = None
        svc.emit({
            "type": "turn_done",
            "reason": terminal_reason,
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        })
        core._emit_info()
        svc.active_run_id = None
        svc.cancel_requested_runs.discard(run_id)
        svc.pause_requested = False


def _team_checkpoint_state(
    prepared: TeamPreparation,
    state: str,
    task: TaskCheckout | None,
    *,
    reviews: list[Any] | None = None,
) -> dict[str, Any]:
    return {
        "state": state,
        "run_id": prepared.run_id,
        "request": prepared.original_request,
        "workspace": prepared.workspace,
        "plan": prepared.plan.structured(),
        "results": [result.structured() for result in prepared.results],
        "reviews": [result.structured() for result in reviews or []],
        "writer_id": prepared.writer.id,
        "team_id": prepared.team.id,
        "orchestration_fingerprint": orchestration_fingerprint(
            prepared.team, prepared.profiles,
        ),
        "baseline_tree": task.baseline_tree if task is not None else "",
    }


def _run_team_writer(
    svc: ChatService,
    orchestrator: TeamOrchestrator,
    prepared: TeamPreparation,
    prompt: str,
    *,
    persisted_user_text: str,
    job_id: str,
    goal: str,
    reserve_model_calls: int = 0,
) -> None:
    """Run the only mutation-capable member under both permission and call budgets."""
    core = svc.core
    remaining = orchestrator.remaining_model_calls(prepared.team.budget)
    if remaining <= 0:
        raise OrchestrationError("team model-call budget exhausted before the writer ran")
    model_call_limit = max(remaining - max(reserve_model_calls, 0), 1)
    started = time.monotonic()
    prompt_before = core.total_prompt_tokens
    completion_before = core.total_completion_tokens
    route = prepared.writer.route
    svc.emit({
        "type": "agent_job_started",
        "run_id": prepared.run_id,
        "job_id": job_id,
        "agent_id": prepared.writer.id,
        "agent_name": prepared.writer.name,
        "role": prepared.writer.role,
        "provider": str(route.get("account_label") or route.get("provider") or ""),
        "model": prepared.writer.model,
        "goal": goal[:2_000],
        "state": "running",
    })
    with orchestrator.writer_slot(prepared.run_id, prepared.writer):
        core.run_turn(
            prompt,
            svc.decide,
            allow_tools=True,
            persisted_user_text=persisted_user_text,
            model_call_limit=model_call_limit,
            persist_user_message=False,
        )
    prompt_tokens = max(core.total_prompt_tokens - prompt_before, 0)
    completion_tokens = max(core.total_completion_tokens - completion_before, 0)
    model_calls = int(core.last_turn_result.get("model_calls") or 0)
    orchestrator.account_writer_usage(
        prepared.writer,
        prepared.team.budget,
        model_calls,
        prompt_tokens,
        completion_tokens,
    )
    assistant = next(
        (message for message in reversed(core.messages) if message.get("role") == "assistant"),
        {},
    )
    output = str(assistant.get("content") or "")[:120_000]
    reasoning = str(assistant.get("_display_reasoning") or "")[:120_000]
    svc.emit({
        "type": "agent_job_completed",
        "run_id": prepared.run_id,
        "state": "completed",
        "result": {
            "job_id": job_id,
            "agent_id": prepared.writer.id,
            "agent_name": prepared.writer.name,
            "role": prepared.writer.role,
            "output": output,
            "reasoning_text": reasoning,
            "evidence": [],
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "elapsed_ms": max(int((time.monotonic() - started) * 1_000), 0),
            "error": "",
        },
        "usage": orchestrator.usage(),
    })


def _latest_assistant_output(core: AgentCore) -> str:
    """Return bounded writer verification evidence for the read-only reviewer."""
    assistant = next(
        (message for message in reversed(core.messages) if message.get("role") == "assistant"),
        {},
    )
    return str(assistant.get("content") or "")[:120_000]


def _install_writer_route(core: AgentCore, prepared: TeamPreparation) -> dict[str, Any]:
    """Temporarily route AgentCore through the selected writer without persistence."""
    snapshot = {
        "client": core.client,
        "provider": core.provider,
        "host": core.host,
        "model": core.model,
        "config": dict(core.config),
        "context_limit": core.context_limit,
        "context_source": core._context_source,
        "context_requested": core._context_requested,
        "context_for": core._context_limit_for,
        "mcp_policy": core.tool_registry.mcp_agent_policy_snapshot(),
    }
    client = client_for_profile(prepared.writer)
    core.client = client
    core.model = prepared.writer.model
    core.host = client.host
    core.provider = "ollama" if prepared.writer.route.get("provider") == "ollama" else "remote"
    core.config["remote_account_label"] = str(
        prepared.writer.route.get("account_label") or prepared.writer.name
    ) if core.provider == "remote" else ""
    core.context_limit = 0
    core._context_source = "unknown"
    core._context_requested = 0
    core._context_limit_for = ""
    access_ceiling = (
        "read_only" if bool(getattr(core, "evaluation_read_only", False))
        else prepared.writer.access_ceiling
    )
    core.tool_registry.set_mcp_agent_policy(
        prepared.writer.mcp_policy,
        access_ceiling=access_ceiling,
        role=prepared.writer.role,
    )
    core._emit_info()
    return snapshot


def _restore_writer_route(core: AgentCore, snapshot: dict[str, Any]) -> None:
    core.client = snapshot["client"]
    core.provider = snapshot["provider"]
    core.host = snapshot["host"]
    core.model = snapshot["model"]
    core.config = snapshot["config"]
    core.context_limit = snapshot["context_limit"]
    core._context_source = snapshot["context_source"]
    core._context_requested = snapshot["context_requested"]
    core._context_limit_for = snapshot["context_for"]
    policy, access_ceiling, role = snapshot["mcp_policy"]
    core.tool_registry.set_mcp_agent_policy(
        policy, access_ceiling=access_ceiling, role=role,
    )
    core._emit_info()


def _is_git_workspace(workspace: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=workspace,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
        check=False,
    )
    return result.returncode == 0


def _task_diff(svc: ChatService, workspace_root: str, execution_path: str) -> str:
    if svc.current_task is not None:
        return svc.current_task.patch()[0]
    result = subprocess.run(
        ["git", "diff", "--binary", "--full-index", "HEAD", "--"],
        cwd=execution_path or workspace_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
        check=False,
    )
    return result.stdout[:2_000_000]


def _revision_request(reviews: list[Any]) -> str:
    revisions: list[str] = []
    for review in reviews:
        text = str(review.output or "").strip()
        lowered = text.lower().replace(" ", "")
        if '"verdict":"revise"' in lowered or text.lower().startswith("revise"):
            revisions.append(text)
    return "\n\n".join(revisions)[:80_000]


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
        if len(text) > MAX_USER_MESSAGE_CHARS \
                or len(text.encode("utf-8")) > MAX_USER_MESSAGE_BYTES:
            _command_error(svc, str(mtype), "Message is too large to process safely.")
            return
        mode = str(msg.get("mode") or "").strip().lower()
        if mode not in {"", "ask", "work", "plan", "build"}:
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
        team_manifest = msg.get("team")
        if team_manifest is not None and (just_chat or text.startswith("/") or attachments):
            _command_error(svc, str(mtype), "Team routing requires an ordinary Work message.")
            return
        if team_manifest is not None and not isinstance(team_manifest, dict):
            _command_error(svc, str(mtype), "The team manifest is malformed.")
            return
        if text.startswith("/") and not just_chat:
            call, args = _run_slash, (svc, text)
        elif team_manifest is not None:
            call, args = _run_team_turn, (svc, text, team_manifest)
        else:
            call, args = _run_user_turn, (svc, text, just_chat, attachments)
        if not svc.start_turn(loop, call, *args):
            _command_error(svc, str(mtype), "Agent is busy — press Stop first.")
    elif mtype == "permission_decision":
        svc.answer_permission(
            str(msg.get("request_id", "")),
            str(msg.get("decision", "deny")),
        )
    elif mtype == "dispatch_decision":
        run_id = str(msg.get("run_id") or "")
        action = str(msg.get("action") or "cancel")
        if action not in {"run", "redispatch", "cancel"}:
            _command_error(svc, "dispatch_decision", "Unknown dispatch decision.")
            return
        plan = msg.get("plan")
        decision = {"action": action}
        if isinstance(plan, dict):
            decision["plan"] = plan
        if not svc.answer_dispatch(run_id, decision):
            _command_error(svc, "dispatch_decision", "That dispatch plan is no longer waiting.")
    elif mtype == "steer":
        text = str(msg.get("text") or "").strip()
        if not text:
            _command_error(svc, "steer", "A steering message cannot be empty.")
            return
        if len(text) > MAX_USER_MESSAGE_CHARS \
                or len(text.encode("utf-8")) > MAX_USER_MESSAGE_BYTES:
            _command_error(svc, "steer", "Message is too large to process safely.")
            return
        if not svc.busy:
            _command_error(svc, "steer", "There is no active turn to steer.")
            return
        state = core.steer(text)
        if state is None:
            _command_error(svc, "steer", "The active turn is already stopping.")
            return
        svc.queue_event({"type": "steer_ack", "text": text, "state": state})
    elif mtype == "set_computer_control":
        if svc.busy:
            _command_error(svc, "set_computer_control", "Wait for the active turn to finish.")
            return
        enabled = bool(msg.get("enabled")) and bool(msg.get("native_available"))
        core.tool_registry.computer_enabled = enabled
        core.computer_executor = svc.execute_computer if enabled else None
        svc.queue_event({"type": "computer_control_status", "enabled": enabled})
    elif mtype == "computer_action_result":
        request_id = str(msg.get("request_id") or "")
        raw = msg.get("result")
        result = raw if isinstance(raw, dict) else {"error": "invalid native result"}
        # Stop, timeout, or reconnect may have cancelled the request while the
        # native broker was unwinding. Late/duplicate results are harmless and
        # intentionally ignored.
        svc.answer_computer(request_id, result)
    elif mtype == "mcp_input_response":
        request_id = str(msg.get("request_id") or "")
        action = str(msg.get("action") or "cancel")
        content = msg.get("content") if isinstance(msg.get("content"), dict) else {}
        if action not in {"accept", "decline", "cancel"}:
            _command_error(svc, "mcp_input_response", "Unknown MCP input decision.")
            return
        if not core.mcp.answer_elicitation(request_id, action, content):
            _command_error(svc, "mcp_input_response", "That MCP input request is no longer waiting.")
    elif mtype == "interrupt":
        core.interrupt()
        if svc.active_evaluation_core is not None:
            svc.active_evaluation_core.interrupt()
        svc.deny_all_pending()  # unblock a permission wait so the turn can end
        svc.cancel_all_computer_actions()
        svc.cancel_dispatch_decisions()
        core.mcp.cancel_pending_inputs()
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
    await ws.send_json({
        "type": "session_info",
        **svc.core.session_info(),
        "worker_id": svc.worker_id,
        "process_id": os.getpid(),
    })
    for run in svc.recoverable_runs:
        await ws.send_json({
            "type": "orchestration_recovery_available",
            "run": run,
        })
    svc.recoverable_runs = []
    for run_id, plan in list(svc.pending_dispatch_plans.items()):
        await ws.send_json({
            "type": "dispatch_plan_ready",
            "run_id": run_id,
            "state": "waiting_dispatch_approval",
            "plan": plan,
        })
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
            svc.cancel_all_computer_actions()
            svc.cancel_dispatch_decisions()
            svc.core.mcp.cancel_pending_inputs()


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
    # A hosted endpoint has to be asked what window it serves, and that is HTTP.
    # Off-thread, so startup is not held up by an endpoint that is slow to answer
    # a question nothing is waiting on yet.
    svc.resolve_context_limit_soon()
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
    # Both secrets the app injects are consumed before uvicorn starts and
    # before any outbound request could fire. The proxy credential arrives on
    # stdin — never in the environment, whose exec-time copy stays readable
    # through `ps -E` however thoroughly it is popped — and is folded into
    # this process's proxy URLs; sanitized_child_environment keeps it out of
    # everything spawned. The auth token is popped, which is weaker but is the
    # existing contract for it.
    proxy.activate_from_env()
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
        ws_max_size=MAX_WS_MESSAGE_BYTES,
    )


if __name__ == "__main__":
    main()
