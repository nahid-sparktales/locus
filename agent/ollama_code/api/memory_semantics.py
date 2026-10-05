"""User selection of optional installed local embeddings; no automatic model pulls."""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Body, HTTPException
from locus_memory.errors import ProviderError

from ..chat_service import AgentBusyError
from ..config import load_config, save_config
from ..memory_adapter import MemoryAdapter
from ..memory_embeddings import (
    PROVIDER_NAME,
    LocalOllamaEmbeddings,
    installed_memory_models,
    local_origin,
)
from .continuity import ServiceDependency


def semantic_settings(service: ServiceDependency, host: str | None = None):
    config = load_config()
    model = str(config.get("memory_embedding_model") or "")
    host = host or str(config.get("memory_embedding_host") or "http://127.0.0.1:11434")
    try:
        models, error = installed_memory_models(host), None
    except ProviderError as exc:
        models, error = [], str(exc)
    return {"model": model, "host": host, "models": models, "error": error}


def update_semantic_settings(service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)):
    model = body.get("model", "")
    host = body.get("host", "http://127.0.0.1:11434")
    if not isinstance(model, str) or not isinstance(host, str):
        raise HTTPException(422, "Choose an installed model and loopback host.")
    try:
        host = local_origin(host)
        provider = LocalOllamaEmbeddings(model.strip(), host=host) if model.strip() else None
    except ProviderError as exc:
        raise HTTPException(422, str(exc)) from exc
    try:
        with service.state_mutation():
            old = service.memory_adapter
            with old._lock:
                if old._maintaining:
                    raise HTTPException(409, "Memory maintenance is running; retry after it finishes.")
                # Build a fresh adapter before discarding any active object. It is still lazy;
                # override its injected host providers with the just-validated selection.
                replacement = MemoryAdapter(app_dir=old.app_dir, edition=old.edition, mode=old.mode,
                    archive=old.archive, schedule=old.schedule, hold_profile_lease=True)
                replacement._host_capabilities.providers = {PROVIDER_NAME: provider} if provider else {}
                config = load_config()
                config.update(memory_embedding_model=model.strip(), memory_embedding_host=host)
                save_config(config)
                persisted = load_config()
                if (persisted.get("memory_embedding_model") != model.strip()
                        or persisted.get("memory_embedding_host") != host):
                    replacement.close()
                    raise HTTPException(500, "Could not save memory embedding settings.")
                old.on_scope_change(service.core, "semantic provider settings changed")
                old.close()
                service.memory_adapter = replacement
                service.core.memory_adapter = replacement
                service.core.config.update(memory_embedding_model=model.strip(), memory_embedding_host=host)
    except AgentBusyError as exc:
        raise HTTPException(409, "Finish or interrupt the current turn before changing memory settings.") from exc
    return semantic_settings(service)


def register_routes(router: APIRouter):
    router.add_api_route("/api/memory/semantic-settings", semantic_settings, methods=["GET"])
    router.add_api_route("/api/memory/semantic-settings", update_semantic_settings, methods=["POST"])
