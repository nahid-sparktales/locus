"""Cross-session context, memory, and skill-observation routes."""

import re
import uuid
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..continuity import ContinuityError, ContinuityStore
from ..knowledge import KnowledgeError, KnowledgeStore
from ..knowledge_runtime import knowledge_store
from ..memory import MemoryError
from ..memory_runtime import memory_vault, memory_workspace
from ..sessions import SessionStore, SessionTooLargeError, strip_prompt_decoration
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _knowledge_store(service: ChatService, workspace: str = "") -> KnowledgeStore:
    if not capability_enabled("workspace_knowledge"):
        raise HTTPException(404, "capability is disabled: workspace_knowledge")
    try:
        return knowledge_store(service, workspace)
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


def _continuity_store() -> ContinuityStore:
    try:
        return ContinuityStore()
    except (ContinuityError, MemoryError) as exc:
        raise HTTPException(422, str(exc)) from exc


def context_snapshots(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    limit: int = Query(default=50, ge=1, le=100),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        return {"snapshots": _continuity_store().list_snapshots(target, limit=limit)}
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc


def context_snapshot_update(
    snapshot_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    if not isinstance(body.get("pinned"), bool):
        raise HTTPException(422, "pinned must be a boolean")
    try:
        snapshot = _continuity_store().set_snapshot_pinned(
            snapshot_id, target, bool(body["pinned"])
        )
    except ContinuityError as exc:
        raise HTTPException(404, str(exc)) from exc
    return {"ok": True, "snapshot": snapshot}


def context_snapshot_delete(
    snapshot_id: str,
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        deleted = _continuity_store().delete_snapshot(snapshot_id, target)
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc
    if not deleted:
        raise HTTPException(404, "context snapshot not found")
    return {"ok": True}


def context_snapshots_clear(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        return {"ok": True, "deleted": _continuity_store().clear_snapshots(target)}
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc


def skill_observations(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    status: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        return {
            "observations": _continuity_store().list_observations(
                target, status=status
            )
        }
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc


def skill_observation_update(
    observation_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    try:
        observation = _continuity_store().set_observation_status(
            observation_id, target, str(body.get("status") or "")
        )
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"ok": True, "observation": observation}


def skill_observation_delete(
    observation_id: str,
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        deleted = _continuity_store().delete_observation(observation_id, target)
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc
    if not deleted:
        raise HTTPException(404, "skill observation not found")
    return {"ok": True}


def skill_observation_export(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        return _continuity_store().export_observations(target)
    except ContinuityError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_status(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    return memory_vault(target).status(workspace=target, agent_id=agent_id)


def memory_list(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
    status: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    return {
        "memories": memory_vault(target).list(
            workspace=target, agent_id=agent_id, status=status
        )
    }


def memory_create(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    try:
        memory = memory_vault(target).save(
            body,
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
            default_status="approved",
        )
        memory_vault(target).record_event(
            "approval" if memory["status"] == "approved" else "proposal",
            "accepted",
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
            session_id=str(body.get("source_session_id") or ""),
            run_id=str(body.get("source_run_id") or ""),
            memory_id=memory["id"],
        )
        return {"ok": True, "memory": memory}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_delete_all(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    count = memory_vault(target).delete_all(workspace=target, agent_id=agent_id)
    return {"ok": True, "deleted": count}


def memory_update(
    memory_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    try:
        memory = memory_vault(target).save(
            body,
            memory_id,
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
        )
        return {"ok": True, "memory": memory}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_approve(
    memory_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    try:
        memory = memory_vault(target).approve(
            memory_id,
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
            resolution=str(body.get("resolution") or "keep_both"),
        )
        memory_vault(target).record_event(
            "approval",
            "accepted",
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
            memory_id=memory_id,
        )
        return {"ok": True, "memory": memory}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_delete(
    memory_id: str,
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
    outcome: str = Query(default="delete"),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    vault = memory_vault(target)
    if not vault.delete(memory_id):
        raise HTTPException(404, "memory not found")
    vault.record_event(
        "rejection" if outcome == "reject" else "deletion",
        "recorded",
        workspace=target,
        agent_id=agent_id,
        memory_id=memory_id,
    )
    return {"ok": True, "id": memory_id}


def memory_search(
    service: ServiceDependency,
    query: str = Query(min_length=1, max_length=2_000),
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
    limit: int = Query(default=8, ge=1, le=20),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    try:
        knowledge = _knowledge_store(service, target).settings()
        vault = memory_vault(target)
        results = vault.search(
            query,
            workspace=target,
            agent_id=agent_id,
            limit=limit,
            embedding_model=str(knowledge.get("embedding_model") or ""),
            ollama_host=str(
                knowledge.get("ollama_host") or "http://127.0.0.1:11434"
            ),
        )
        vault.record_event(
            "recall",
            "matched" if results else "empty",
            workspace=target,
            agent_id=agent_id,
            reason_code="approved_only",
        )
        return {"results": results}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_export(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    return memory_vault(target).export(workspace=target, agent_id=agent_id)


def memory_import(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    document = body.get("document")
    if not isinstance(document, dict):
        raise HTTPException(422, "memory import requires a document")
    try:
        count = memory_vault(target).import_values(
            document,
            workspace=target,
            agent_id=str(body.get("agent_id") or "primary"),
        )
        return {"ok": True, "imported": count}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_feedback(
    memory_id: str,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        vault = memory_vault()
        memory = vault.feedback(memory_id, str(body.get("outcome") or ""))
        vault.record_event(
            "feedback",
            "recorded",
            memory_id=memory_id,
            reason_code=str(body.get("outcome") or "")[:128],
        )
        return {"ok": True, "memory": memory}
    except MemoryError as exc:
        raise HTTPException(422, str(exc)) from exc


def memory_maintenance(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    target = memory_workspace(service, str(body.get("workspace") or ""))
    return memory_vault(target).maintain(
        workspace=target,
        agent_id=str(body.get("agent_id") or "primary"),
    )


def memory_diagnostics(
    service: ServiceDependency,
    workspace: str = Query(default=""),
    agent_id: str = Query(default="primary"),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    report = memory_vault(target).diagnostics(workspace=target, agent_id=agent_id)
    try:
        knowledge = _knowledge_store(service, target).settings()
    except (KnowledgeError, OSError):
        knowledge = {}
    tool_context = service.core.tool_ctx
    scopes = list(tool_context.memory_scopes)
    service.core.tool_registry.refresh()
    proposal_tool_available = any(
        str(item.get("name") or "") == "propose_memory"
        for item in service.core.tool_registry.metadata()
    )
    return {
        **report,
        "proposal_policy": (
            "enabled" if tool_context.memory_proposals_enabled else "disabled"
        ),
        "enabled_scopes": scopes,
        "propose_memory_available": bool(
            proposal_tool_available
            and tool_context.memory_proposals_enabled
            and scopes
        ),
        "indexed_files": int(knowledge.get("document_count") or 0),
        "search_chunks": int(knowledge.get("chunk_count") or 0),
        "embedding_model": str(knowledge.get("embedding_model") or ""),
        "embedding_error": str(knowledge.get("last_error") or ""),
    }


def memory_reprocess(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Analyze one retained chat into review-only candidates without tool payloads."""
    session_id = str(body.get("session_id") or "")
    path = SessionStore.path_for(session_id)
    if path is None:
        raise HTTPException(404, "session not found")
    target = memory_workspace(service, str(body.get("workspace") or ""))
    agent_id = str(body.get("agent_id") or "primary")
    try:
        messages = SessionStore.load(path)
    except SessionTooLargeError as exc:
        raise HTTPException(413, str(exc)) from exc
    run_id = uuid.uuid4().hex
    store = service.run_store
    provenance = SessionStore.provenance(path)
    store.start_run(
        run_id,
        session_id=session_id,
        workspace_root=target,
        execution_path=target,
        request="Analyze selected chat for memory",
        state="running",
        run_kind="memory_review",
        execution_environment="local",
        manifest={
            "provider": str(provenance.get("provider") or ""),
            "model": str(provenance.get("model") or ""),
        },
    )
    store.append_event(
        run_id, {"type": "memory_review_started", "state": "running"}
    )
    cues = re.compile(
        r"\b(?:remember|always|never|prefer|preference|decided|decision|"
        r"do not|don't|must|should use|confirmed|that worked|fixed|resolved)\b",
        re.IGNORECASE,
    )
    secret = re.compile(
        r"(?i)(?:api[_-]?key|authorization|password|secret|bearer\s+[A-Za-z0-9])"
    )
    candidates: list[dict[str, Any]] = []
    vault = memory_vault(target)
    existing_content = {
        re.sub(r"\s+", " ", str(item.get("content") or "").strip()).casefold()
        for item in vault.list(workspace=target, agent_id=agent_id)
    }
    for message in messages:
        if str(message.get("role") or "") != "user":
            continue
        # Stored work turns may contain the app's mode/context wrapper. Keep
        # only the original request so selected files and attachment text can
        # never become a candidate through reprocessing.
        text = strip_prompt_decoration(str(message.get("content") or "")).strip()
        if (
            not text
            or len(text) > 4_000
            or not cues.search(text)
            or secret.search(text)
        ):
            continue
        content = re.sub(r"\s+", " ", text)[:2_000]
        normalized = content.casefold()
        if normalized in existing_content:
            vault.record_event(
                "proposal",
                "deduplicated",
                workspace=target,
                agent_id=agent_id,
                session_id=session_id,
                run_id=run_id,
                reason_code="existing_memory",
            )
            continue
        try:
            candidate = vault.save(
                {
                    "title": "From selected chat",
                    "content": content,
                    "reason": (
                        "Explicit durable wording found during selected-chat review."
                    ),
                    "scope": "workspace",
                    "status": "candidate",
                    "kind": "preference",
                    "confidence": 0.8,
                    "source_session_id": session_id,
                    "source_run_id": run_id,
                },
                workspace=target,
                agent_id=agent_id,
                default_status="candidate",
            )
        except MemoryError:
            continue
        vault.record_event(
            "proposal",
            "accepted",
            workspace=target,
            agent_id=agent_id,
            session_id=session_id,
            run_id=run_id,
            memory_id=candidate["id"],
        )
        candidates.append(candidate)
        existing_content.add(normalized)
        if len(candidates) >= 20:
            break
    store.append_event(
        run_id,
        {
            "type": "memory_review_completed",
            "state": "completed",
            "candidate_count": len(candidates),
            "outcome": (
                "candidates_created" if candidates else "no_durable_memories"
            ),
        },
    )
    store.set_state(run_id, "completed", recoverable=False)
    return {
        "ok": True,
        "run_id": run_id,
        "state": "completed",
        "candidate_count": len(candidates),
        "memories": candidates,
    }


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/context-snapshots", context_snapshots, methods=["GET"])
    router.add_api_route(
        "/api/context-snapshots/{snapshot_id}",
        context_snapshot_update,
        methods=["PUT"],
    )
    router.add_api_route(
        "/api/context-snapshots/{snapshot_id}",
        context_snapshot_delete,
        methods=["DELETE"],
    )
    router.add_api_route(
        "/api/context-snapshots", context_snapshots_clear, methods=["DELETE"]
    )
    router.add_api_route("/api/skill-observations", skill_observations, methods=["GET"])
    router.add_api_route(
        "/api/skill-observations/{observation_id}",
        skill_observation_update,
        methods=["PUT"],
    )
    router.add_api_route(
        "/api/skill-observations/{observation_id}",
        skill_observation_delete,
        methods=["DELETE"],
    )
    router.add_api_route(
        "/api/skill-observations/export",
        skill_observation_export,
        methods=["GET"],
    )
    router.add_api_route("/api/memory/status", memory_status, methods=["GET"])
    router.add_api_route("/api/memory", memory_list, methods=["GET"])
    router.add_api_route("/api/memory", memory_create, methods=["POST"])
    router.add_api_route("/api/memory", memory_delete_all, methods=["DELETE"])
    router.add_api_route("/api/memory/{memory_id}", memory_update, methods=["PUT"])
    router.add_api_route(
        "/api/memory/{memory_id}/approve", memory_approve, methods=["POST"]
    )
    router.add_api_route(
        "/api/memory/{memory_id}", memory_delete, methods=["DELETE"]
    )
    router.add_api_route("/api/memory/search", memory_search, methods=["GET"])
    router.add_api_route("/api/memory/export", memory_export, methods=["GET"])
    router.add_api_route("/api/memory/import", memory_import, methods=["POST"])
    router.add_api_route(
        "/api/memory/{memory_id}/feedback", memory_feedback, methods=["POST"]
    )
    router.add_api_route(
        "/api/memory/maintenance/run", memory_maintenance, methods=["POST"]
    )
    router.add_api_route(
        "/api/memory/diagnostics", memory_diagnostics, methods=["GET"]
    )
    router.add_api_route("/api/memory/reprocess", memory_reprocess, methods=["POST"])


__all__ = ["register_routes"]
