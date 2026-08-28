"""Workspace knowledge indexing and retrieval routes."""

from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..knowledge import KnowledgeError, KnowledgeStore
from ..knowledge_runtime import knowledge_store
from ..memory import MemoryError
from ..memory_runtime import memory_vault, memory_workspace
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _knowledge_store(service: ChatService, workspace: str = "") -> KnowledgeStore:
    if not capability_enabled("workspace_knowledge"):
        raise HTTPException(404, "capability is disabled: workspace_knowledge")
    try:
        return knowledge_store(service, workspace)
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


def knowledge_status(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    return _knowledge_store(service, workspace).settings()


def knowledge_settings(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    store = _knowledge_store(service, str(body.get("workspace") or ""))
    enabled = body.get("enabled") if isinstance(body.get("enabled"), bool) else None
    embedding_model = (
        str(body.get("embedding_model") or "") if "embedding_model" in body else None
    )
    ollama_host = str(body.get("ollama_host") or "") if "ollama_host" in body else None
    if "exclusions" in body and not isinstance(body.get("exclusions"), list):
        raise HTTPException(422, "knowledge exclusions must be a list of glob patterns")
    exclusions = (
        [str(item) for item in body.get("exclusions") or []]
        if "exclusions" in body
        else None
    )
    return store.configure(
        enabled=enabled,
        embedding_model=embedding_model,
        ollama_host=ollama_host,
        exclusions=exclusions,
    )


def knowledge_reindex(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    return _knowledge_store(service, str(body.get("workspace") or "")).reindex()


def knowledge_changes(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    store = _knowledge_store(service, str(body.get("workspace") or ""))
    raw = body.get("paths")
    if not isinstance(raw, list):
        raise HTTPException(422, "paths must be an array")
    return store.reindex(changed_paths=[str(item) for item in raw[:5_000]])


def knowledge_search(
    service: ServiceDependency,
    query: str = Query(min_length=1, max_length=2_000),
    workspace: str = Query(default=""),
    limit: int = Query(default=8, ge=1, le=20),
) -> dict[str, Any]:
    try:
        return {"results": _knowledge_store(service, workspace).search(query, limit=limit)}
    except KnowledgeError as exc:
        raise HTTPException(422, str(exc)) from exc


def knowledge_memories(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    return {
        "memories": memory_vault(target).list(
            workspace=target,
            status="approved",
            scopes=["workspace"],
        )
    }


def knowledge_memory_create(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        target = memory_workspace(service, str(body.get("workspace") or ""))
        memory = memory_vault(target).save(
            {**body, "scope": "workspace", "status": "approved"},
            workspace=target,
        )
        return {"ok": True, "memory": memory}
    except (KnowledgeError, MemoryError) as exc:
        raise HTTPException(422, str(exc)) from exc


def knowledge_memory_update(
    memory_id: str,
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        target = memory_workspace(service, str(body.get("workspace") or ""))
        memory = memory_vault(target).save(
            {**body, "scope": "workspace", "status": "approved"},
            memory_id,
            workspace=target,
        )
        return {"ok": True, "memory": memory}
    except (KnowledgeError, MemoryError) as exc:
        raise HTTPException(422, str(exc)) from exc


def knowledge_memory_delete(
    memory_id: str,
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    if not memory_vault(target).delete(memory_id):
        raise HTTPException(404, "workspace memory not found")
    return {"ok": True, "id": memory_id}


def knowledge_delete_all(
    service: ServiceDependency,
    workspace: str = Query(default=""),
) -> dict[str, Any]:
    target = memory_workspace(service, workspace)
    _knowledge_store(service, target).delete_all()
    memory_vault(target).delete_all(workspace=target, scopes=["workspace"])
    return {"ok": True}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/knowledge/status", knowledge_status, methods=["GET"])
    router.add_api_route("/api/knowledge/settings", knowledge_settings, methods=["POST"])
    router.add_api_route("/api/knowledge/reindex", knowledge_reindex, methods=["POST"])
    router.add_api_route("/api/knowledge/changes", knowledge_changes, methods=["POST"])
    router.add_api_route("/api/knowledge/search", knowledge_search, methods=["GET"])
    router.add_api_route("/api/knowledge/memories", knowledge_memories, methods=["GET"])
    router.add_api_route(
        "/api/knowledge/memories", knowledge_memory_create, methods=["POST"]
    )
    router.add_api_route(
        "/api/knowledge/memories/{memory_id}", knowledge_memory_update, methods=["PUT"]
    )
    router.add_api_route(
        "/api/knowledge/memories/{memory_id}", knowledge_memory_delete, methods=["DELETE"]
    )
    router.add_api_route("/api/knowledge", knowledge_delete_all, methods=["DELETE"])
