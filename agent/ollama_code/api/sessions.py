"""Chat session and folder organization routes."""

import sqlite3
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import AgentBusyError, ChatService
from ..core import AgentCore
from ..session_runtime import session_has_active_run, transcript_index
from ..sessions import (
    ChatOrganizationStore,
    SessionMeta,
    SessionStore,
    SessionTooLargeError,
    update_session_metadata,
)
from ..transcript_search import TranscriptSearchError
from ..worktrees import (
    TaskCheckout,
    TaskCheckoutStore,
    WorktreeError,
    is_git_workspace,
)
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def _require_capability(name: str) -> None:
    if not capability_enabled(name):
        raise HTTPException(404, f"capability is disabled: {name}")


def _session_has_active_run(service: ChatService, session_id: str) -> bool:
    return session_has_active_run(service.run_store, session_id)


def sessions(
    service: ServiceDependency,
    include_archived: bool = False,
    limit: int = Query(100, ge=1, le=500),
    query: str = Query("", max_length=500),
) -> dict[str, Any]:
    return {
        "sessions": SessionStore.summaries(
            limit=limit,
            include_archived=include_archived,
            query=query,
        ),
        "current": service.core.session.session_id,
    }


def chat_folders(workspace: str = Query("", max_length=4096)) -> dict[str, Any]:
    snapshot = ChatOrganizationStore.snapshot(workspace or None)
    return {"version": snapshot["version"], "folders": snapshot["folders"]}


def chat_folder_create(
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    workspace = body.get("workspace")
    name = body.get("name")
    if not isinstance(workspace, str) or not workspace.strip():
        raise HTTPException(422, "workspace is required")
    if not isinstance(name, str):
        raise HTTPException(422, "folder name must be a string")
    parent_id = body.get("parent_id")
    if parent_id is not None and not isinstance(parent_id, str):
        raise HTTPException(422, "parent_id must be a string or null")
    index = body.get("index")
    if index is not None and (not isinstance(index, int) or index < 0):
        raise HTTPException(422, "index must be a non-negative integer")
    try:
        folder = ChatOrganizationStore.create_folder(workspace, name, parent_id, index)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "folder": folder}


def chat_folder_update(
    folder_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    unknown = set(body) - {"name", "parent_id", "index"}
    if unknown:
        raise HTTPException(422, f"unknown folder field: {sorted(unknown)[0]}")
    name = body.get("name")
    if name is not None and not isinstance(name, str):
        raise HTTPException(422, "folder name must be a string")
    parent_value: str | None | object = ...
    if "parent_id" in body:
        parent_value = body.get("parent_id")
        if parent_value is not None and not isinstance(parent_value, str):
            raise HTTPException(422, "parent_id must be a string or null")
    index = body.get("index")
    if index is not None and (not isinstance(index, int) or index < 0):
        raise HTTPException(422, "index must be a non-negative integer")
    try:
        folder = ChatOrganizationStore.update_folder(
            folder_id,
            name=name,
            parent_id=parent_value,
            index=index,
        )
    except KeyError as exc:
        raise HTTPException(404, "folder not found") from exc
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "folder": folder}


def chat_folder_delete(folder_id: str) -> dict[str, Any]:
    try:
        result = ChatOrganizationStore.delete_folder(folder_id)
    except KeyError as exc:
        raise HTTPException(404, "folder not found") from exc
    return {"ok": True, **result}


def sessions_search(
    query: str = Query(min_length=1, max_length=500),
    limit: int = Query(20, ge=1, le=50),
) -> dict[str, Any]:
    _require_capability("transcript_search")
    try:
        return transcript_index().search(query, limit=limit)
    except TranscriptSearchError as exc:
        raise HTTPException(422, str(exc)) from exc


def session_new(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Start a fresh saved session, preserving the previous transcript on disk."""
    try:
        with service.state_mutation():
            reason = str(body.get("reason") or "new_session")
            cwd_value = body.get("cwd")
            if cwd_value is not None and not isinstance(cwd_value, str):
                raise HTTPException(422, "cwd must be a string")
            raw_environment = body.get("environment")
            if raw_environment is not None and raw_environment not in {"local", "worktree"}:
                raise HTTPException(422, "environment must be local or worktree")
            environment = str(raw_environment or "local")
            base_ref = body.get("base_ref", "HEAD")
            if not isinstance(base_ref, str) or len(base_ref) > 240:
                raise HTTPException(422, "base_ref must be a Git ref")
            retention_limit = body.get("worktree_retention_limit", 15)
            if not isinstance(retention_limit, int) or not 0 <= retention_limit <= 100:
                raise HTTPException(422, "worktree_retention_limit must be between 0 and 100")
            if service.current_task is not None:
                try:
                    service.core.leave_task_checkout(service.current_task.workspace_root)
                except ValueError:
                    pass
                service.current_task = None
            info = service.core.new_session(reason=reason, cwd=str(cwd_value or "") or None)
            session_id = str(info.get("session_id") or "")
            workspace_root = service.core.workspace_root
            if environment == "worktree":
                if not is_git_workspace(workspace_root):
                    raise HTTPException(422, "worktree chats require a Git repository")
                task = TaskCheckoutStore.create(
                    workspace_root,
                    session_id,
                    base_ref=base_ref,
                    session_id=session_id,
                )
                service.current_task = task
                service.core.enter_task_checkout(
                    task.execution_path,
                    task.workspace_root,
                    task.as_dict(),
                )
                SessionMeta.update(
                    session_id,
                    task=task.as_dict(),
                    workspace_root=task.workspace_root,
                    execution_path=task.execution_path,
                    environment={
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": task.id,
                        "starting_ref": task.starting_ref,
                    },
                )
                if retention_limit > 0:
                    TaskCheckoutStore.prune(
                        limit=retention_limit,
                        protected_ids={task.id},
                    )
                info = service.core.session_info()
            else:
                SessionMeta.update(
                    session_id,
                    workspace_root=workspace_root,
                    execution_path=workspace_root,
                    environment={"type": "local", "isolation": "local"},
                )
            return {"ok": True, "reason": reason, "session_info": info}
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc


def sessions_clear(service: ServiceDependency) -> dict[str, Any]:
    """Move every saved session except the active one to the recovery folder."""
    active_session = service.core.session.session_id
    if any(
        path.stem != active_session
        and _session_has_active_run(service, path.stem)
        for path in SessionStore.list_sessions()
    ):
        raise HTTPException(409, "wait for background chats to stop before clearing sessions")
    try:
        with service.state_mutation():
            result = service.core.clear_saved_sessions()
            try:
                transcript_index().delete_all()
            except (OSError, sqlite3.DatabaseError):
                pass
            return {"ok": True, "job_active": False, **result}
    except AgentBusyError as exc:
        raise _busy_http() from exc


def session_delete(session_id: str, service: ServiceDependency) -> dict[str, Any]:
    """Move one chat to recovery, replacing it first when it is active."""
    if SessionStore.path_for(session_id) is None:
        raise HTTPException(404, f"session not found: {session_id}")
    if _session_has_active_run(service, session_id):
        raise HTTPException(409, "wait for this chat to stop before deleting it")
    try:
        with service.state_mutation():
            deleted_active = session_id == service.core.session.session_id
            replacement = None
            if deleted_active:
                replacement = service.core.new_session(reason="deleted_active")
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
    except AgentBusyError as exc:
        raise _busy_http() from exc


def sessions_restore(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Move a recovery batch, defaulting to the newest, back into sessions."""
    try:
        with service.state_mutation():
            batch = str(body.get("batch") or "") or None
            restored_ids = SessionStore.restore_from_trash_details(batch)
            return {
                "ok": True,
                "restored": len(restored_ids),
                "session_ids": restored_ids,
            }
    except AgentBusyError as exc:
        raise _busy_http() from exc


def session_detail(session_id: str) -> dict[str, Any]:
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, f"session not found: {session_id}")
    header = SessionStore.provenance(path)
    meta = SessionMeta.get(session_id)
    try:
        messages = SessionStore.load(path)
    except SessionTooLargeError as exc:
        raise HTTPException(413, str(exc)) from exc
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


def session_export_data(
    session_id: str,
    include_reasoning: bool = False,
    include_tool_details: bool = False,
    include_attachments: bool = True,
) -> dict[str, Any]:
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, f"session not found: {session_id}")
    provenance = SessionStore.provenance(path)
    meta = SessionMeta.get(session_id)
    try:
        messages = SessionStore.export_messages(
            path,
            include_reasoning=include_reasoning,
            include_tool_details=include_tool_details,
            include_attachments=include_attachments,
        )
    except SessionTooLargeError as exc:
        raise HTTPException(413, str(exc)) from exc
    return {
        "id": session_id,
        "title": meta.get("title") or SessionStore.preview(path),
        "cwd": provenance.get("cwd"),
        "model": provenance.get("model"),
        "provider": provenance.get("provider"),
        "started": provenance.get("started"),
        "messages": messages,
    }


def session_organization_update(
    session_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    unknown = set(body) - {"folder_id", "index"}
    if unknown:
        raise HTTPException(422, f"unknown organization field: {sorted(unknown)[0]}")
    folder_id = body.get("folder_id")
    if folder_id is not None and not isinstance(folder_id, str):
        raise HTTPException(422, "folder_id must be a string or null")
    index = body.get("index")
    if index is not None and (not isinstance(index, int) or index < 0):
        raise HTTPException(422, "index must be a non-negative integer")
    try:
        placement = ChatOrganizationStore.move_session(session_id, folder_id, index)
    except KeyError as exc:
        raise HTTPException(404, "session not found") from exc
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "placement": placement}


def session_organization(session_id: str) -> dict[str, Any]:
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, "session not found")
    placement = ChatOrganizationStore.placement(session_id)
    if placement is None:
        workspace = str(SessionStore.header(path).get("cwd") or "")
        placement = {
            "session_id": session_id,
            "workspace": (
                ChatOrganizationStore._canonical_workspace(workspace)
                if workspace
                else ""
            ),
            "folder_id": None,
            "order": 0,
        }
    return {"ok": True, "placement": placement}


def session_duplicate(
    session_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    mode = str(body.get("mode") or "conversation")
    if mode not in {"conversation", "worktree"}:
        raise HTTPException(422, "mode must be conversation or worktree")
    source_path = SessionStore.path_for(session_id)
    if source_path is None:
        raise HTTPException(404, f"session not found: {session_id}")
    if _session_has_active_run(service, session_id) or (
        session_id == service.core.session.session_id and service.busy
    ):
        raise HTTPException(409, "wait for this chat to stop before duplicating it")
    source_meta = SessionMeta.get(session_id)
    source_task: TaskCheckout | None = None
    if mode == "worktree":
        if source_meta.get("archived"):
            raise HTTPException(409, "restore the source chat before duplicating its worktree")
        task_value = source_meta.get("task")
        task_id = str(task_value.get("id") or "") if isinstance(task_value, dict) else ""
        source_task = TaskCheckoutStore.load(task_id) if task_id else None
        if source_task is None or not Path(source_task.execution_path).is_dir():
            raise HTTPException(409, "restore the source worktree before duplicating it")
    clone: SessionStore | None = None
    child: TaskCheckout | None = None
    try:
        clone = SessionStore.duplicate(source_path)
        title = str(source_meta.get("title") or SessionStore.preview(source_path)).strip()
        fields: dict[str, Any] = {
            "title": f"{title} Copy"[:120],
            "team": source_meta.get("team"),
        }
        workspace = str(SessionStore.header(source_path).get("cwd") or "")
        if mode == "worktree" and source_task is not None:
            child = TaskCheckoutStore.fork(
                source_task,
                f"duplicate-{uuid.uuid4().hex}",
            )
            child.session_id = clone.session_id
            child.state = "queued"
            child.save()
            fields.update(
                {
                    "task": child.as_dict(),
                    "workspace_root": child.workspace_root,
                    "execution_path": child.execution_path,
                    "environment": {
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": child.id,
                        "starting_ref": child.starting_ref,
                    },
                }
            )
        else:
            fields.update(
                {
                    "workspace_root": workspace,
                    "execution_path": workspace,
                    "environment": {"type": "local", "isolation": "local"},
                }
            )
        SessionMeta.update(clone.session_id, **fields)
        ChatOrganizationStore.clone_placement(session_id, clone.session_id)
    except (OSError, ValueError, WorktreeError, SessionTooLargeError) as exc:
        if child is not None:
            try:
                TaskCheckoutStore.snapshot_and_remove(child.id)
            except WorktreeError:
                pass
        if clone is not None:
            clone.path.unlink(missing_ok=True)
            SessionMeta.forget([clone.session_id])
            ChatOrganizationStore.detach_sessions([clone.session_id])
        status = 413 if isinstance(exc, SessionTooLargeError) else 409
        raise HTTPException(status, str(exc)) from exc
    summary = next(
        (
            item
            for item in SessionStore.summaries(limit=500, include_archived=True)
            if item["id"] == clone.session_id
        ),
        None,
    )
    return {"ok": True, "session": summary, "mode": mode}


def session_metadata_update(
    session_id: str,
    service: ServiceDependency,
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
    if archived and session_id == service.core.session.session_id:
        raise HTTPException(409, "start a new session before archiving the active one")
    if archived and _session_has_active_run(service, session_id):
        raise HTTPException(409, "wait for this chat to stop before archiving it")

    state = update_session_metadata(
        session_id,
        title=title,
        pinned=body.get("pinned"),
        archived=archived,
    )
    meta = SessionMeta.get(session_id)
    task_value = meta.get("task")
    task_id = str(task_value.get("id") or "") if isinstance(task_value, dict) else ""
    task = TaskCheckoutStore.load(task_id) if task_id else None
    if task is not None and isinstance(body.get("pinned"), bool):
        task.pinned = bool(body["pinned"])
        task.save()
        SessionMeta.update(session_id, task=task.as_dict())
    if task is not None and archived and Path(task.execution_path).is_dir():
        try:
            snapshot = TaskCheckoutStore.snapshot_and_remove(task.id)
            SessionMeta.update(session_id, task=snapshot["task"])
        except WorktreeError as exc:
            raise HTTPException(409, str(exc)) from exc
    return {"ok": True, "id": session_id, **state}


session_update = session_metadata_update


def session_resume(session_id: str, service: ServiceDependency) -> dict[str, Any]:
    try:
        with service.state_mutation():
            result = service.core.resume_session(session_id)
            meta = SessionMeta.get(session_id)
            task_value = meta.get("task")
            task_id = str(task_value.get("id") or "") if isinstance(task_value, dict) else ""
            task = TaskCheckoutStore.load(task_id) if task_id else None
            environment = meta.get("environment")
            is_worktree = isinstance(environment, dict) and (
                environment.get("type") == "worktree"
                or environment.get("isolation") == "managed_worktree"
            )
            service.current_task = task if is_worktree else None
            if task is not None and is_worktree:
                if not Path(task.execution_path).is_dir():
                    raise HTTPException(
                        409,
                        "the chat worktree is archived and must be restored",
                    )
                service.core.enter_task_checkout(
                    task.execution_path,
                    task.workspace_root,
                    task.as_dict(),
                )
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except FileNotFoundError as exc:
        raise HTTPException(404, str(exc)) from exc
    except SessionTooLargeError as exc:
        raise HTTPException(413, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    path = SessionStore.path_for(session_id)
    activity = SessionStore.agent_activity(path) if path is not None else {"activities": []}
    return {
        "ok": True,
        "text": result.get("text"),
        "messages": (result.get("data") or {}).get("messages", []),
        "session_info": service.core.session_info(),
        "agent_activities": activity["activities"],
        "orchestration_state": activity.get("orchestration_state"),
        "orchestration_run_id": activity.get("run_id"),
        "worker_id": activity.get("worker_id"),
    }


def session_handoff(
    session_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Move an idle chat and its code between Local and a managed worktree."""
    target = body.get("environment")
    if target not in {"local", "worktree"}:
        raise HTTPException(422, "environment must be local or worktree")
    try:
        with service.state_mutation():
            if service.core.session.session_id != session_id:
                service.core.resume_session(session_id)
            meta = SessionMeta.get(session_id)
            workspace_root = str(
                meta.get("workspace_root")
                or SessionStore.header(
                    SessionStore.path_for(session_id)  # type: ignore[arg-type]
                ).get("cwd")
                or ""
            )
            if not workspace_root or not Path(workspace_root).is_dir():
                raise HTTPException(409, "the chat's local workspace is unavailable")
            task_value = meta.get("task")
            task_id = str(task_value.get("id") or "") if isinstance(task_value, dict) else ""
            task = TaskCheckoutStore.load(task_id) if task_id else None
            result: dict[str, Any] = {"applied": False, "paths": []}
            if target == "local":
                if task is not None and Path(task.execution_path).is_dir():
                    result = task.apply()
                service.core.leave_task_checkout(workspace_root)
                service.current_task = None
                SessionMeta.update(
                    session_id,
                    task=task.as_dict() if task else task_value,
                    workspace_root=workspace_root,
                    execution_path=workspace_root,
                    environment={
                        "type": "local",
                        "isolation": "local",
                        "worktree_id": task.id if task else "",
                    },
                )
            else:
                if not is_git_workspace(workspace_root):
                    raise HTTPException(422, "worktree chats require a Git repository")
                if task is None:
                    task = TaskCheckoutStore.create(
                        workspace_root,
                        session_id,
                        base_ref=str(body.get("base_ref") or "HEAD"),
                        session_id=session_id,
                    )
                else:
                    task = TaskCheckoutStore.refresh_from_workspace(task.id)
                service.current_task = task
                service.core.enter_task_checkout(
                    task.execution_path,
                    task.workspace_root,
                    task.as_dict(),
                )
                SessionMeta.update(
                    session_id,
                    task=task.as_dict(),
                    workspace_root=task.workspace_root,
                    execution_path=task.execution_path,
                    environment={
                        "type": "worktree",
                        "isolation": "managed_worktree",
                        "worktree_id": task.id,
                        "starting_ref": task.starting_ref,
                    },
                )
            return {
                "ok": True,
                "environment": target,
                "session_info": service.core.session_info(),
                "task": task.as_dict() if task else None,
                **result,
            }
    except AgentBusyError as exc:
        raise _busy_http() from exc
    except WorktreeError as exc:
        raise HTTPException(409, str(exc)) from exc
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(422, str(exc)) from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/sessions", sessions, methods=["GET"])
    router.add_api_route("/api/chat-folders", chat_folders, methods=["GET"])
    router.add_api_route("/api/chat-folders", chat_folder_create, methods=["POST"])
    router.add_api_route(
        "/api/chat-folders/{folder_id}", chat_folder_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/chat-folders/{folder_id}", chat_folder_delete, methods=["DELETE"]
    )
    router.add_api_route("/api/sessions/search", sessions_search, methods=["GET"])
    router.add_api_route("/api/sessions/new", session_new, methods=["POST"])
    router.add_api_route("/api/sessions", sessions_clear, methods=["DELETE"])
    router.add_api_route("/api/sessions/{session_id}", session_delete, methods=["DELETE"])
    router.add_api_route("/api/sessions/restore", sessions_restore, methods=["POST"])
    router.add_api_route("/api/sessions/{session_id}", session_detail, methods=["GET"])
    router.add_api_route(
        "/api/sessions/{session_id}/export-data", session_export_data, methods=["GET"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/organization",
        session_organization_update,
        methods=["PATCH"],
    )
    router.add_api_route(
        "/api/sessions/{session_id}/organization", session_organization, methods=["GET"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/duplicate", session_duplicate, methods=["POST"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}", session_metadata_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/resume", session_resume, methods=["POST"]
    )
    router.add_api_route(
        "/api/sessions/{session_id}/handoff", session_handoff, methods=["POST"]
    )


__all__ = [
    "register_routes",
    "session_detail",
    "session_metadata_update",
    "session_new",
    "sessions_clear",
]
