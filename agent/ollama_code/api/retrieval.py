"""Content-free adaptive retrieval inspection with current-access redaction."""
from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query
from locus_memory.errors import MemoryEngineError

from ..agent_profile_runtime import saved_memory_agent
from ..capabilities import enabled as capability_enabled
from ..knowledge import KnowledgeError, KnowledgeStore
from ..memory_adapter import ensure_memory_adapter
from .continuity import ServiceDependency
from .memory_inspector import _access, _agents, _current_agent, _run, _saved_owner

_SOURCES = {"memory", "workspace", "documents", "code"}
_PHASES = {"retrieved", "submitted", "skipped", "uncertain", "failed"}
_CODE = re.compile(r"^[a-zA-Z0-9_.:-]{1,120}$")
_HASH = re.compile(r"^[a-fA-F0-9]{64}$")


def _number(value: Any, *, integer: bool = False) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return 0
    return max(0, int(value) if integer else value)


def _codes(values: Any) -> list[str]:
    return [value for value in values[:80] if isinstance(value, str) and _CODE.fullmatch(value)] \
        if isinstance(values, list) else []


def _list(value: Any) -> list:
    return value if isinstance(value, list) else []


def _locator(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}
    result = {}
    if value.get("kind") in {"line", "page", "pdf", "paragraph", "sheet"}:
        result["kind"] = value["kind"]
    for name in ("line_start", "line_end", "page", "page_start", "page_end",
                 "paragraph_start", "paragraph_end"):
        if type(value.get(name)) is int and value[name] >= 1:
            result[name] = value[name]
    if type(value.get("page_index")) is int and value["page_index"] >= 0:
        result["page_index"] = value["page_index"]
    for name in ("sheet", "cell_range"):
        if isinstance(value.get(name), str):
            result[name] = value[name][:256]
    bounds = value.get("bounds")
    if (isinstance(bounds, list) and len(bounds) == 4
            and all(type(number) in (int, float) and math.isfinite(number) for number in bounds)):
        result["bounds"] = bounds
    return result


def _file_permission(service, run, agent_id, configuration) -> bool:
    if not configuration.capability_policy.workspace_read:
        return False
    owner = _saved_owner(run, agent_id)
    current_id, _ = _current_agent(service)
    if owner and owner != current_id:
        try:
            _, target = saved_memory_agent(owner)
            return target.capability_policy.workspace_read
        except ValueError:
            return False
    return True


def retrieval_trace(service: ServiceDependency, run_id: str = Query(min_length=1)) -> dict[str, Any]:
    run = _run(service, run_id)
    _, configuration = _current_agent(service)
    policies = _agents(service, run)
    adapter = None
    store = None
    settings = None
    if configuration.capability_policy.workspace_read and capability_enabled("workspace_knowledge"):
        try:
            store = KnowledgeStore(service.core.workspace_root or service.core.cwd)
            settings = store.settings()
        except (KnowledgeError, OSError):
            pass
    access_cache = {}
    file_permissions = {}
    traces = []
    after = 0
    last_seq = run.get("last_seq")
    while True:
        events = service.run_store.events(run_id, after_seq=after, limit=500)
        if not events:
            break
        previous = after
        for event in events:
            sequence = _number(event.get("seq"), integer=True)
            after = max(after, sequence)
            if isinstance(last_seq, int) and sequence > last_seq:
                break
            raw = event.get("trace")
            if event.get("type") != "retrieval_trace" or not isinstance(raw, dict):
                continue
            agent_id = str(raw.get("agent_id") or "")
            if agent_id not in policies or raw.get("phase") not in _PHASES:
                continue
            if agent_id not in file_permissions:
                file_permissions[agent_id] = _file_permission(service, run, agent_id, configuration)
            selected = []
            unavailable = _number(raw.get("unavailable_items"), integer=True)
            for item in _list(raw.get("selected"))[:80]:
                if not isinstance(item, dict):
                    continue
                kind = item.get("kind")
                identifier = str(item.get("id") or "")[:256]
                if kind == "memory":
                    try:
                        if adapter is None:
                            adapter = ensure_memory_adapter(service.core)
                        if agent_id not in access_cache:
                            access_cache[agent_id] = _access(service, adapter, agent_id, policies[agent_id], run)
                        access, scopes = access_cache[agent_id]
                        if not scopes or not identifier:
                            unavailable += 1
                            continue
                        record = adapter.engine.get(access, identifier)
                        if not record.scope.constraints and "personal" not in scopes:
                            unavailable += 1
                            continue
                        selected.append({"kind": "memory", "id": identifier,
                                         "revision": _number(item.get("revision"), integer=True)})
                    except (MemoryEngineError, OSError):
                        unavailable += 1
                elif kind in {"workspace", "documents", "code"}:
                    path = item.get("path")
                    allowed = file_permissions[agent_id] and settings and settings["enabled"]
                    relative = Path(path) if isinstance(path, str) else Path("/")
                    allowed = allowed and not relative.is_absolute() and ".." not in relative.parts
                    if allowed and store is not None:
                        source = store.root / relative
                        allowed = (source.is_file()
                                   and (kind != "documents" or settings["documents_enabled"])
                                   and store._eligible(source, settings["exclusions"], settings["documents_enabled"]))
                    if not allowed:
                        unavailable += 1
                        continue
                    selected_item = {"kind": kind, "id": identifier, "path": relative.as_posix(),
                                     "locator": _locator(item.get("locator"))}
                    digest = item.get("content_hash") or item.get("hash")
                    if isinstance(digest, str) and _HASH.fullmatch(digest):
                        selected_item["content_hash"] = digest
                    selected.append(selected_item)
            omitted = []
            for item in _list(raw.get("omitted"))[:80]:
                if isinstance(item, dict) and _CODE.fullmatch(str(item.get("reason") or "")):
                    omitted.append({"reason": item["reason"], "count": _number(item.get("count"), integer=True)})
            traces.append({
                "id": str(raw.get("id") or f"retrieval-{sequence}")[:256],
                "seq": sequence,
                "turn_id": str(raw.get("turn_id") or "")[:256], "agent_id": agent_id,
                "round": _number(raw.get("round"), integer=True), "phase": raw["phase"],
                "sources": [source for source in _list(raw.get("sources"))
                            if isinstance(source, str) and source in _SOURCES],
                "selected": selected, "omitted": omitted, "fallbacks": _codes(raw.get("fallbacks")),
                "duration_ms": _number(raw.get("duration_ms")),
                "packed_bytes": _number(raw.get("packed_bytes"), integer=True),
                "unavailable_items": unavailable,
            })
        if after <= previous or len(events) < 500 or isinstance(last_seq, int) and after >= last_seq:
            break
    return {"traces": traces, "note": "Retrieved or submitted evidence is not proof the model used it. Source text and query text are not retained in retrieval traces."}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/retrieval/trace", retrieval_trace, methods=["GET"])
