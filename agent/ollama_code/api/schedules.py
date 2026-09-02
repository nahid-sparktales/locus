"""Scheduled and companion chat dispatch routes."""

import hashlib
import re
import threading
import uuid
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..runstore import RunStoreError
from ..schedules import timezone as schedule_timezone
from ..sessions import SessionMeta, SessionStore
from ..worktrees import (
    TaskCheckout,
    TaskCheckoutStore,
    WorktreeError,
    is_git_workspace,
)
from .dependencies import get_service
from .event_triggers import _detach_agent_session

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")


def _schedule_workspace(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise HTTPException(422, "workspace_root is required")
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise HTTPException(422, "the scheduled workspace is no longer available")
    return str(path)


def _validate_schedule_payload(
    value: dict[str, Any],
    *,
    existing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = dict(value)
    if "workspace_root" in payload:
        payload["workspace_root"] = _schedule_workspace(payload["workspace_root"])
    workspace_root = str(
        payload.get("workspace_root")
        or (existing or {}).get("workspace_root")
        or ""
    )
    environment = str(
        payload.get("execution_environment")
        or (existing or {}).get("execution_environment")
        or "local"
    )
    if environment == "worktree" and (
        not workspace_root or not is_git_workspace(workspace_root)
    ):
        raise HTTPException(422, "scheduled worktrees require a Git repository")
    return payload


def _scheduled_chat_title(schedule: dict[str, Any], scheduled_for: float) -> str:
    zone = schedule_timezone(str(schedule["timezone"]))
    value = datetime.fromtimestamp(scheduled_for, zone).strftime("%b %d, %Y %H:%M")
    return f"{schedule['name']} · {value.replace(' 0', ' ')}"


class _OccurrenceSkipped(Exception):
    """The dedicated chat was busy, so this occurrence was recorded and skipped."""


def _checkout_task_id(schedule_id: str, workspace_root: str) -> str:
    """A worktree id the checkout store accepts, stable for the schedule.

    The workspace is part of the id so that pointing a schedule at another
    repository takes a fresh checkout and leaves the old one recoverable
    rather than silently reusing a checkout of the wrong tree.
    """
    cleaned = "".join(ch if ch.isalnum() or ch in "_-" else "-" for ch in schedule_id)
    digest = hashlib.sha256(workspace_root.encode("utf-8")).hexdigest()[:8]
    return f"schedule-{cleaned}"[:110] + f"-{digest}"


def _schedule_session_id(schedule_id: str) -> str | None:
    """The dedicated chat every run of this schedule continues, if it exists."""
    for session_id, entry in SessionMeta.all().items():
        if (
            entry.get("agent_trigger_id") == schedule_id
            and entry.get("agent_primary")
            and SessionStore.path_for(session_id) is not None
        ):
            return session_id
    return None


def _local_metadata(workspace_root: str) -> dict[str, Any]:
    return {
        "workspace_root": workspace_root,
        "execution_path": workspace_root,
        "environment": {"type": "local", "isolation": "local"},
        "task": None,
    }


def _checkout_metadata(record: TaskCheckout) -> dict[str, Any]:
    return {
        "workspace_root": record.workspace_root,
        "execution_path": record.execution_path,
        "task": record.as_dict(),
        "environment": {
            "type": "worktree",
            "isolation": "managed_worktree",
            "worktree_id": record.id,
            "starting_ref": record.starting_ref,
        },
    }


def _schedule_checkout(schedule: dict[str, Any], *, session_id: str | None) -> TaskCheckout:
    """The one worktree a scheduled agent runs in, created or repaired.

    A schedule keeps a single checkout rather than one per run, which makes it
    durable state: it is marked permanent so pruning leaves it alone, and it is
    restored when an archive or an older prune has already taken it away.
    """
    workspace_root = _schedule_workspace(schedule["workspace_root"])
    task_id = _checkout_task_id(str(schedule["id"]), workspace_root)
    record = TaskCheckoutStore.load(task_id)
    if record is None:
        # A creation the app did not finish leaves a directory that would
        # refuse every later attempt at this stable id.
        TaskCheckoutStore.discard_unreadable(workspace_root, task_id)
        record = TaskCheckoutStore.create(workspace_root, task_id, session_id=session_id)
    elif not Path(record.execution_path).is_dir():
        record = TaskCheckoutStore.restore(task_id)
    if not record.permanent or (session_id and record.session_id != session_id):
        record.permanent = True
        if session_id:
            record.session_id = session_id
        record.save()
    return record


def _release_checkout(metadata: dict[str, Any], *, keep: str) -> None:
    """Let pruning reclaim a checkout the agent has moved away from."""
    task = metadata.get("task")
    task_id = str(task.get("id") or "") if isinstance(task, dict) else ""
    if not task_id or task_id == keep:
        return
    record = TaskCheckoutStore.load(task_id)
    if record is not None and record.permanent:
        record.permanent = False
        record.save()


def _schedule_location(
    schedule: dict[str, Any], *, session_id: str, metadata: dict[str, Any]
) -> dict[str, Any]:
    """Where the agent's runs execute, kept in step with the schedule.

    Every dispatch reads the workspace and checkout from the chat, so an edit
    that changed either would otherwise leave the agent working in the place
    it was created while the editor reported the new one.
    """
    workspace_root = _schedule_workspace(schedule["workspace_root"])
    if str(schedule["execution_environment"]) != "worktree":
        _release_checkout(metadata, keep="")
        if (
            str(metadata.get("workspace_root") or "") == workspace_root
            and str(metadata.get("execution_path") or "") == workspace_root
            and not metadata.get("task")
        ):
            return {}
        return _local_metadata(workspace_root)
    record = _schedule_checkout(schedule, session_id=session_id)
    _release_checkout(metadata, keep=record.id)
    return _checkout_metadata(record)


def _refresh_schedule_checkout(session_id: str, metadata: dict[str, Any]) -> dict[str, Any]:
    """Start a scheduled run from today's workspace, not the day it was made.

    One lasting checkout would otherwise replay the commit that was current
    when the schedule was created. Anything the agent left uncommitted is
    kept: only a clean checkout is rebuilt.
    """
    task = metadata.get("task")
    task_id = str(task.get("id") or "") if isinstance(task, dict) else ""
    if not task_id:
        return metadata
    record = TaskCheckoutStore.load(task_id)
    if record is None or not Path(record.execution_path).is_dir():
        return metadata
    try:
        patch, _ = record.patch()
    except WorktreeError:
        # Unreadable work is still work: keep the checkout as it is rather
        # than rebuilding over it.
        return metadata
    if patch.strip():
        return metadata
    refreshed = TaskCheckoutStore.refresh_from_workspace(task_id)
    refreshed.permanent = True
    refreshed.session_id = session_id
    refreshed.save()
    return SessionMeta.update(session_id, **_checkout_metadata(refreshed))


def _ensure_schedule_session(schedule: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Return the schedule's dedicated chat, creating it on first use.

    A scheduled agent, like an event agent, owns one lasting conversation that
    every run continues, so the person reads a history rather than a scatter
    of single-run chats. It is created with the schedule so Agents mode shows
    the agent before its first run, and its name, route and workspace follow
    the schedule's.
    """
    schedule_id = str(schedule["id"])
    name = str(schedule["name"])
    provider = str(schedule["provider"])
    model = str(schedule["model"])
    account_id = str(schedule.get("provider_account_id") or "")
    workspace_root = _schedule_workspace(schedule["workspace_root"])
    identity: dict[str, Any] = {
        "title": name,
        "agent_name": name,
        "provider": provider,
        "model": model,
        "provider_account_id": account_id or None,
        "team": (
            {"id": schedule.get("team_id"), "name": schedule.get("team_name")}
            if schedule["runner"] == "team"
            else None
        ),
    }

    existing = _schedule_session_id(schedule_id)
    if existing is not None:
        location = _schedule_location(
            schedule, session_id=existing, metadata=SessionMeta.get(existing)
        )
        return existing, SessionMeta.update(existing, **identity, **location)

    # The checkout comes first: a worktree that cannot be made must not leave
    # an untitled chat behind in the workspace.
    record = (
        _schedule_checkout(schedule, session_id=None)
        if str(schedule["execution_environment"]) == "worktree"
        else None
    )
    session = SessionStore(workspace_root, model, provider, account_id=account_id)
    session_id = session.session_id
    if record is not None:
        record.session_id = session_id
        record.save()
    SessionMeta.update(
        session_id,
        **identity,
        **(_checkout_metadata(record) if record is not None else _local_metadata(workspace_root)),
        schedule_id=schedule_id,
        agent_trigger_id=schedule_id,
        agent_primary=True,
    )
    _detach_agent_session(session_id, workspace_root)
    return session_id, SessionMeta.get(session_id)


def _record_skip(store: Any, occurrence: dict[str, Any], session_id: str) -> None:
    """Note an overlapping occurrence without marking the agent as failing.

    Claiming advances the cadence before the chat is known to be free, and for
    a schedule that runs once that also switches it off. A skip there would
    drop the only run and leave the agent reading as though a person had
    paused it, so the slot goes back and the next tick tries again.
    """
    store.finish_schedule_occurrence(
        str(occurrence["id"]),
        state="skipped",
        session_id=session_id,
        error="Skipped: the previous run in this agent's chat was still in progress.",
    )
    schedule = store.schedule(str(occurrence["schedule_id"])) or {}
    if (
        str(occurrence.get("trigger") or "") == "due"
        and not schedule.get("enabled")
        and schedule.get("next_run_at") is None
    ):
        store.rearm_schedule_slot(
            str(occurrence["schedule_id"]),
            next_run_at=float(occurrence["scheduled_for"]),
        )


def _queue_scheduled_run(
    store: Any,
    run_id: str,
    occurrence: dict[str, Any],
    session_id: str,
    **fields: Any,
) -> dict[str, Any]:
    """Reserve the run, or skip when something reached the chat first.

    The check and the reservation share the store lock, so a due tick and a
    Run Now that arrive together cannot both queue a turn into the one chat.
    """
    try:
        return store.queue_run_if_idle(run_id, session_id=session_id, **fields)
    except RunStoreError as exc:
        if str(exc) != "the chat is busy":
            raise
        _record_skip(store, occurrence, session_id)
        raise _OccurrenceSkipped() from None


def _session_summary(session_id: str) -> dict[str, Any]:
    summary = next(
        (
            item
            for item in SessionStore.summaries(limit=500, include_archived=True)
            if item["id"] == session_id
        ),
        None,
    )
    if summary is None:
        raise HTTPException(500, "the agent chat could not be created")
    return summary


def _companion_chat_title(prompt: str) -> str:
    first_line = " ".join(prompt.split())
    return (first_line[:72].rstrip() or "Mobile chat") + " · Mobile"


def _dispatch_companion_chat(
    service: ChatService,
    body: dict[str, Any],
) -> dict[str, Any]:
    """Create a durable mobile run without changing the active session."""
    store = service.run_store
    request_id = str(body.get("request_id") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", request_id):
        raise HTTPException(422, "request_id is required")
    run_id = uuid.uuid5(uuid.NAMESPACE_URL, f"locus:companion:{request_id}").hex
    existing = store.run(run_id)
    if existing is not None:
        return {"ok": True, "claimed": False, "run": existing}

    prompt = str(body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(422, "prompt is required")
    if len(prompt) > 240_000:
        raise HTTPException(413, "prompt is too large")
    mode = str(body.get("mode") or "work").strip().lower()
    # "build" is the retired GSD mode, kept so existing schedule rows still load.
    if mode not in {"ask", "work", "plan", "grill", "build"}:
        raise HTTPException(422, "mode must be ask, work, plan, or grill")

    requested_session_id = str(body.get("session_id") or "").strip()
    task: TaskCheckout | None = None
    if requested_session_id:
        path = SessionStore.path_for(requested_session_id)
        if path is None:
            raise HTTPException(404, "chat not found")
        session_id = requested_session_id
        header = SessionStore.header(path)
        meta = SessionMeta.get(session_id)
        workspace_root = str(meta.get("workspace_root") or header.get("cwd") or "")
        if not workspace_root or not Path(workspace_root).is_dir():
            raise HTTPException(409, "the chat workspace is unavailable")
        execution_path = str(meta.get("execution_path") or workspace_root)
        environment = (
            "worktree"
            if str((meta.get("environment") or {}).get("type")) == "worktree"
            else "local"
        )
        provider = str(header.get("provider") or body.get("provider") or "ollama")
        account = str(header.get("account") or body.get("provider_account_id") or "")
        model = str(header.get("model") or body.get("model") or "")
    else:
        workspace_root = _schedule_workspace(body.get("workspace_root"))
        environment = str(body.get("execution_environment") or "local")
        if environment not in {"local", "worktree"}:
            raise HTTPException(422, "execution_environment must be local or worktree")
        if environment == "worktree" and not is_git_workspace(workspace_root):
            raise HTTPException(422, "mobile worktrees require a Git repository")
        provider = str(body.get("provider") or "ollama").strip().lower()
        if provider not in {"ollama", "remote", "chatgpt"}:
            raise HTTPException(422, "provider is unavailable")
        account = str(body.get("provider_account_id") or "").strip()
        model = str(body.get("model") or "").strip()
        if not model:
            raise HTTPException(422, "model is required")
        session = SessionStore(workspace_root, model, provider, account)
        session_id = session.session_id
        execution_path = workspace_root
        metadata: dict[str, Any] = {
            "title": _companion_chat_title(prompt),
            "workspace_root": workspace_root,
            "execution_path": workspace_root,
            "environment": {"type": "local", "isolation": "local"},
            "created_by": "companion",
        }
        if environment == "worktree":
            try:
                task = TaskCheckoutStore.create(
                    workspace_root,
                    run_id,
                    session_id=session_id,
                )
            except WorktreeError as exc:
                raise HTTPException(409, str(exc)) from exc
            execution_path = task.execution_path
            metadata.update(
                {
                    "workspace_root": task.workspace_root,
                    "execution_path": task.execution_path,
                    "task": task.as_dict(),
                    "environment": {
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": task.id,
                        "starting_ref": task.starting_ref,
                    },
                }
            )
        SessionMeta.update(session_id, **metadata)

    manifest = {
        "companion": True,
        "mode": mode,
        "runner": "solo",
        "provider": provider,
        "provider_account_id": account,
        "model": model,
    }
    try:
        run = store.queue_run(
            run_id,
            session_id=session_id,
            workspace_root=workspace_root,
            execution_path=execution_path,
            request=prompt,
            run_kind="solo",
            execution_environment=environment,
            manifest=manifest,
        )
    except (OSError, RunStoreError) as exc:
        if task is not None:
            try:
                TaskCheckoutStore.cleanup(task.id)
            except WorktreeError:
                pass
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "claimed": True, "run": run}


_DISPATCH_LOCKS: dict[str, threading.Lock] = {}
_DISPATCH_LOCKS_GUARD = threading.Lock()


def _dispatch_lock(schedule_id: str) -> threading.Lock:
    with _DISPATCH_LOCKS_GUARD:
        return _DISPATCH_LOCKS.setdefault(schedule_id, threading.Lock())


def _dispatch_schedule(
    service: ChatService,
    schedule_id: str,
    *,
    trigger: str,
    request_id: str = "",
) -> dict[str, Any]:
    """Run one occurrence of a schedule, one dispatch at a time.

    A due tick and a Run Now can arrive together, and both rebuild and reserve
    the agent's single chat and checkout. Without this lock the second would
    find the worktree mid-rebuild and pause the whole agent.
    """
    with _dispatch_lock(schedule_id):
        return _dispatch_claimed_schedule(
            service, schedule_id, trigger=trigger, request_id=request_id
        )


def _dispatch_claimed_schedule(
    service: ChatService,
    schedule_id: str,
    *,
    trigger: str,
    request_id: str = "",
) -> dict[str, Any]:
    store = service.run_store
    try:
        schedule, occurrence, claimed = store.claim_schedule_occurrence(
            schedule_id,
            trigger=trigger,
            request_id=request_id,
        )
    except RunStoreError as exc:
        status = 404 if str(exc) == "schedule not found" else 409
        raise HTTPException(status, str(exc)) from exc

    if not claimed:
        run_id = str(occurrence.get("run_id") or "")
        run = store.run(run_id) if run_id else None
        if run is None:
            raise HTTPException(409, "this schedule occurrence is already being dispatched")
        return {
            "ok": True,
            "claimed": False,
            "schedule": schedule,
            "occurrence": occurrence,
            "run": run,
        }

    session_id = ""
    run_id = str(occurrence["id"])
    try:
        workspace_root = _schedule_workspace(schedule["workspace_root"])
        environment = str(schedule["execution_environment"])
        if environment == "worktree" and not is_git_workspace(workspace_root):
            raise WorktreeError("scheduled worktrees require a Git repository")

        session_id, metadata = _ensure_schedule_session(schedule)
        if store.session_has_active_run(session_id):
            # The previous occurrence is still running in this chat. Record the
            # skip against this occurrence and leave the schedule enabled: the
            # next occurrence runs as usual, and an overlap is not a failure of
            # the agent. Stacking a second turn would send it into the worker
            # mid-turn.
            _record_skip(store, occurrence, session_id)
            raise _OccurrenceSkipped()
        if environment == "worktree":
            metadata = _refresh_schedule_checkout(session_id, metadata)
        execution_path = str(metadata.get("execution_path") or workspace_root)
        if not Path(execution_path).is_dir():
            raise HTTPException(409, "the agent's checkout is unavailable")

        manifest = {
            "scheduled": True,
            "schedule_id": schedule_id,
            "occurrence_id": occurrence["id"],
            "mode": schedule["mode"],
            "runner": schedule["runner"],
            # `solo_swarm` is the durable compatibility marker for a Solo run
            # that may delegate. All Solo schedules are adaptive now.
            "solo_swarm": schedule["runner"] != "team",
            "provider": schedule["provider"],
            "provider_account_id": schedule.get("provider_account_id") or "",
            "model": schedule["model"],
            "timezone": schedule["timezone"],
        }
        run = _queue_scheduled_run(
            store,
            run_id,
            occurrence,
            session_id,
            team_id=str(schedule.get("team_id") or ""),
            team_name=str(schedule.get("team_name") or ""),
            workspace_root=str(metadata.get("workspace_root") or workspace_root),
            execution_path=execution_path,
            request=str(schedule["prompt"]),
            run_kind="team" if schedule["runner"] == "team" else "solo",
            execution_environment=environment,
            manifest=manifest,
            schedule_id=schedule_id,
            occurrence_id=str(occurrence["id"]),
            scheduled_for=float(occurrence["scheduled_for"]),
        )
        occurrence = store.finish_schedule_occurrence(
            str(occurrence["id"]),
            state="queued",
            session_id=session_id,
            run_id=run_id,
        )
        return {
            "ok": True,
            "claimed": True,
            "schedule": store.schedule(schedule_id),
            "occurrence": occurrence,
            "run": run,
        }
    except _OccurrenceSkipped:
        raise HTTPException(
            409,
            f"skipped this run: the previous run in {schedule['name']}'s chat is still in progress",
        ) from None
    except (HTTPException, WorktreeError, OSError, RunStoreError) as exc:
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        try:
            store.finish_schedule_occurrence(
                str(occurrence["id"]),
                state="failed",
                session_id=session_id,
                error=str(detail),
            )
            if isinstance(exc, (HTTPException, WorktreeError)):
                store.pause_schedule(schedule_id, str(detail))
        except RunStoreError:
            pass
        status = exc.status_code if isinstance(exc, HTTPException) else 409
        raise HTTPException(status, str(detail)) from exc


_ADOPTION_LOCK = threading.Lock()
_ADOPTED_SCHEDULES: set[str] = set()


def _adopt_pre_agent_schedules(schedules: list[dict[str, Any]]) -> None:
    """Give schedules made before they were agents their dedicated chat.

    Updating the app is then enough for them to appear in Agents mode, and
    the chats their earlier runs left behind become that agent's side
    conversations instead of loose chats in the workspace. Each schedule is
    adopted once per run of the backend, under a lock so two overlapping
    listings cannot both create a chat for one schedule.
    """
    pending = [
        schedule
        for schedule in schedules
        if str(schedule.get("id") or "") and str(schedule["id"]) not in _ADOPTED_SCHEDULES
    ]
    if not pending:
        return
    with _ADOPTION_LOCK:
        entries = SessionMeta.all()
        primary = {
            str(entry.get("agent_trigger_id")): session_id
            for session_id, entry in entries.items()
            if entry.get("agent_primary") and entry.get("agent_trigger_id")
        }
        for schedule in pending:
            schedule_id = str(schedule["id"])
            try:
                if primary.get(schedule_id) is None:
                    _ensure_schedule_session(schedule)
                _adopt_earlier_run_chats(schedule_id, str(schedule["name"]), entries)
            except (HTTPException, WorktreeError, RunStoreError, OSError):
                # Listing must not fail because one schedule could not be
                # adopted; the next listing tries again.
                continue
            _ADOPTED_SCHEDULES.add(schedule_id)


def _adopt_earlier_run_chats(
    schedule_id: str, name: str, entries: dict[str, dict[str, Any]]
) -> None:
    """Group the single-run chats older builds made under their agent."""
    for session_id, entry in entries.items():
        if (
            str(entry.get("schedule_id") or "") == schedule_id
            and not entry.get("agent_trigger_id")
            and SessionStore.path_for(session_id) is not None
        ):
            SessionMeta.update(session_id, agent_trigger_id=schedule_id, agent_name=name)


def schedule_list(service: ServiceDependency) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    schedules = store.schedules()
    if not store.read_only:
        _adopt_pre_agent_schedules(schedules)
    return {"schedules": schedules, "read_only": store.read_only}


def schedule_create(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    try:
        schedule = store.create_schedule(_validate_schedule_payload(body))
    except RunStoreError as exc:
        raise HTTPException(422, str(exc)) from exc
    try:
        _ensure_schedule_session(schedule)
    except (HTTPException, WorktreeError, OSError) as exc:
        # A schedule without its chat is not an agent; do not leave half of one.
        try:
            store.delete_schedule(str(schedule["id"]))
        except RunStoreError:
            pass
        detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
        raise HTTPException(409, f"the agent chat could not be created: {detail}") from exc
    return schedule


def schedule_update(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    existing = store.schedule(schedule_id)
    if existing is None:
        raise HTTPException(404, "schedule not found")
    try:
        payload = _validate_schedule_payload(body, existing=existing)
    except RunStoreError as exc:
        raise HTTPException(422, str(exc)) from exc
    proposed = {**existing, **payload}
    moved = (
        str(proposed["workspace_root"]) != str(existing["workspace_root"])
        or str(proposed["execution_environment"]) != str(existing["execution_environment"])
    )
    # The chat moves first: a move that cannot be made must leave the schedule
    # exactly as it was, rather than pointing somewhere its runs cannot go.
    # Anything else — renaming, pausing, changing the prompt — stays possible
    # even when the chat cannot be rebuilt right now.
    try:
        _ensure_schedule_session(proposed)
    except (HTTPException, WorktreeError, RunStoreError, OSError) as exc:
        if moved:
            detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
            raise HTTPException(409, str(detail)) from exc
    try:
        updated = store.update_schedule(schedule_id, payload)
    except RunStoreError as exc:
        status = 404 if str(exc) == "schedule not found" else 422
        raise HTTPException(status, str(exc)) from exc
    return updated


def schedule_task_create(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Create a side conversation beneath a scheduled agent.

    It carries the agent's identity, workspace, and model but never receives a
    scheduled run; those continue the dedicated chat.
    """
    _require_capability("durable_runs")
    schedule = service.run_store.schedule(schedule_id)
    if schedule is None:
        raise HTTPException(404, "schedule not found")
    workspace_root = _schedule_workspace(schedule["workspace_root"])
    provider = str(schedule["provider"])
    model = str(schedule["model"])
    account_id = str(schedule.get("provider_account_id") or "")
    title = " ".join(str(body.get("name") or "New chat").split())[:120] or "New chat"
    session = SessionStore(workspace_root, model, provider, account_id=account_id)
    session_id = session.session_id
    SessionMeta.update(
        session_id,
        title=title,
        workspace_root=workspace_root,
        execution_path=workspace_root,
        environment={"type": "local", "isolation": "local"},
        provider=provider,
        model=model,
        provider_account_id=account_id or None,
        schedule_id=schedule_id,
        agent_trigger_id=schedule_id,
        agent_name=str(schedule["name"]),
    )
    _detach_agent_session(session_id, workspace_root)
    return {"ok": True, "session": _session_summary(session_id), "created": True}


def schedule_delete(schedule_id: str, service: ServiceDependency) -> dict[str, Any]:
    _require_capability("durable_runs")
    session_id = _schedule_session_id(schedule_id)
    if session_id is not None:
        # The agent's checkout was kept out of pruning's reach while it
        # existed; with the agent gone it is ordinary again.
        _release_checkout(SessionMeta.get(session_id), keep="")
    try:
        service.run_store.delete_schedule(schedule_id)
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc
    return {"ok": True, "id": schedule_id}


def schedule_occurrence_list(
    schedule_id: str,
    service: ServiceDependency,
    limit: int = Query(default=20, ge=1, le=100),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    store = service.run_store
    if store.schedule(schedule_id) is None and not store.schedule_occurrences(
        schedule_id,
        limit=1,
    ):
        raise HTTPException(404, "schedule not found")
    return {"occurrences": store.schedule_occurrences(schedule_id, limit=limit)}


def schedule_pause(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    try:
        return service.run_store.pause_schedule(
            schedule_id,
            str(body.get("reason") or "The schedule needs attention."),
        )
    except RunStoreError as exc:
        raise HTTPException(404, str(exc)) from exc


def schedule_dispatch(
    schedule_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    _require_capability("durable_runs")
    trigger = str(body.get("trigger") or "manual")
    if trigger not in {"due", "manual"}:
        raise HTTPException(422, "trigger must be due or manual")
    return _dispatch_schedule(
        service,
        schedule_id,
        trigger=trigger,
        request_id=str(body.get("request_id") or ""),
    )


def companion_chat_dispatch(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Internal loopback API used only by the authenticated native gateway."""
    _require_capability("durable_runs")
    return _dispatch_companion_chat(service, body)


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/schedules", schedule_list, methods=["GET"])
    router.add_api_route("/api/schedules", schedule_create, methods=["POST"])
    router.add_api_route(
        "/api/schedules/{schedule_id}", schedule_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}", schedule_delete, methods=["DELETE"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/occurrences",
        schedule_occurrence_list,
        methods=["GET"],
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/pause", schedule_pause, methods=["POST"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/dispatch", schedule_dispatch, methods=["POST"]
    )
    router.add_api_route(
        "/api/schedules/{schedule_id}/tasks", schedule_task_create, methods=["POST"]
    )
    router.add_api_route(
        "/api/companion/chats", companion_chat_dispatch, methods=["POST"]
    )


__all__ = ["register_routes"]
