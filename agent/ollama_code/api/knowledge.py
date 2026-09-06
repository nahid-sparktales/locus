"""Workspace knowledge indexing and retrieval routes."""

import tempfile
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request

from ..capabilities import enabled as capability_enabled
from ..chat_service import ChatService
from ..document_extract import MAX_SOURCE_BYTES
from ..document_library import DocumentError, DocumentStore
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
    result = store.configure(
        enabled=enabled,
        embedding_model=embedding_model,
        ollama_host=ollama_host,
        exclusions=exclusions,
        documents_enabled=body.get("documents_enabled") if isinstance(body.get("documents_enabled"), bool) else None,
    )
    if body.get("documents_enabled") is False or body.get("enabled") is False:
        DocumentStore(str(store.root)).cancel_persistent()
    return result


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


def _documents(service: ChatService, workspace: str) -> DocumentStore:
    store = _knowledge_store(service, workspace)
    return DocumentStore(str(store.root))


def document_list(service: ServiceDependency, workspace: str = Query(default=""), limit: int = Query(default=100, ge=1, le=500), offset: int = Query(default=0, ge=0), query: str = Query(default="", max_length=512)) -> dict[str, Any]:
    return _documents(service, workspace).documents(limit=limit, offset=offset, query=query)


def document_jobs(service: ServiceDependency, workspace: str = Query(default=""), limit: int = Query(default=100, ge=1, le=500)) -> dict[str, Any]:
    return {"jobs": _documents(service, workspace).jobs(limit=limit)}


def document_submit(service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        languages = body.get("ocr_languages") or []
        if not isinstance(languages, list) or any(not isinstance(item, str) for item in languages):
            raise DocumentError("OCR languages must be a list of language identifiers.")
        if "persistent" in body and not isinstance(body["persistent"], bool):
            raise DocumentError("persistent must be true or false.")
        return {"job": _documents(service, str(body.get("workspace") or "")).submit(
            str(body.get("path") or ""), persistent=body.get("persistent", True),
            ocr_mode=str(body.get("ocr_mode") or "auto"), ocr_languages=languages,
        )}
    except (DocumentError, OSError) as exc:
        raise HTTPException(422, str(exc)) from exc


async def document_upload(request: Request, service: ServiceDependency, workspace: str = Query(default=""), filename: str = Query(min_length=1, max_length=255), persistent: bool = Query(default=False), ocr_mode: str = Query(default="auto")) -> dict[str, Any]:
    store = _documents(service, workspace)
    size = 0
    try:
        with tempfile.NamedTemporaryFile(dir=store.job_directory, prefix="upload-", delete=True) as handle:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_SOURCE_BYTES:
                    raise HTTPException(413, "Document exceeds the 100 MB limit.")
                handle.write(chunk)
            handle.flush()
            # Copying a bounded file belongs off the asyncio request loop.
            from starlette.concurrency import run_in_threadpool
            job = await run_in_threadpool(store.submit_upload, Path(handle.name), filename, persistent=persistent, ocr_mode=ocr_mode)
            return {"job": job}
    except (DocumentError, OSError) as exc:
        raise HTTPException(422, str(exc)) from exc


def document_job(job_id: str, service: ServiceDependency, workspace: str = Query(default="")) -> dict[str, Any]:
    try:
        return {"job": _documents(service, workspace).job(job_id)}
    except DocumentError as exc:
        raise HTTPException(404, str(exc)) from exc


def document_result(job_id: str, service: ServiceDependency, workspace: str = Query(default="")) -> dict[str, Any]:
    try:
        return _documents(service, workspace).result(job_id)
    except DocumentError as exc:
        raise HTTPException(409, str(exc)) from exc


def document_cancel(job_id: str, service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        return {"job": _documents(service, str(body.get("workspace") or "")).cancel(job_id)}
    except DocumentError as exc:
        raise HTTPException(404, str(exc)) from exc


def document_exclude(document_id: str, service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, Any]:
    try:
        if not isinstance(body.get("excluded"), bool):
            raise DocumentError("excluded must be true or false.")
        return {"ok": True, "document": _documents(service, str(body.get("workspace") or "")).exclude(document_id, body["excluded"])}
    except DocumentError as exc:
        raise HTTPException(422, str(exc)) from exc


def document_delete(document_id: str, service: ServiceDependency, workspace: str = Query(default="")) -> dict[str, Any]:
    try:
        _documents(service, workspace).remove(document_id)
        return {"ok": True}
    except DocumentError as exc:
        raise HTTPException(404, str(exc)) from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/documents", document_list, methods=["GET"])
    router.add_api_route("/api/documents/{document_id}", document_delete, methods=["DELETE"])
    router.add_api_route("/api/documents/{document_id}/exclude", document_exclude, methods=["POST"])
    router.add_api_route("/api/document-jobs", document_jobs, methods=["GET"])
    router.add_api_route("/api/document-jobs", document_submit, methods=["POST"])
    router.add_api_route("/api/document-jobs/upload", document_upload, methods=["POST"])
    router.add_api_route("/api/document-jobs/{job_id}", document_job, methods=["GET"])
    router.add_api_route("/api/document-jobs/{job_id}/result", document_result, methods=["GET"])
    router.add_api_route("/api/document-jobs/{job_id}/cancel", document_cancel, methods=["POST"])
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
