"""Bounded host maintenance for duplicate memories and changing file evidence.

Canonical records, history, encryption and deletion remain package-owned. This
module supplies local file observations and applies the user's maintenance policy.
It never runs a model or changes procedure/episode records.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from collections import defaultdict
from dataclasses import replace
from pathlib import Path
from typing import Any

from locus_memory import policy as authorization
from locus_memory.errors import MemoryEngineError, NotFound, ValidationError
from locus_memory.models import Actor, Lifecycle, MemoryKind, Operation
from locus_memory.repository.scanner import Exclusions, check_repo_path, open_beneath

from .memory import MemoryError

SOURCE_KEY = "locus_sources"
MAX_SOURCE_FILES = 32
MAX_SOURCE_BYTES = 2 * 1024 * 1024
_KINDS = {MemoryKind.PREFERENCE, MemoryKind.FACT, MemoryKind.DECISION,
          MemoryKind.CONSTRAINT, MemoryKind.RELATIONSHIP}
_DEPENDENCIES = ("package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
    "bun.lock", "bun.lockb", "pyproject.toml", "requirements.txt", "uv.lock", "poetry.lock",
    "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "Gemfile", "Gemfile.lock",
    "Package.swift", "Package.resolved")
_DEPENDENCY_FACT = re.compile(
    r"\b(?:dependenc(?:y|ies)|package|lockfile|version|runtime|requires?|installed|"
    r"python|node(?:\.js)?|react|next(?:\.js)?|swift|rust|golang)\b", re.I)
_FILE_TOKEN = re.compile(r"(?<![\w/])(?:[\w@.+-]+/)*[\w@+-]+\.(?:[A-Za-z][A-Za-z0-9_-]*)(?![\w/])")
_EXCLUSIONS = Exclusions()


def _context(vault, workspace, agent_id):
    if not getattr(vault, "engine", None):
        raise MemoryError("Memory intelligence requires the canonical memory store.")
    access, selected = vault._access(workspace, agent_id)
    return access, selected, vault.engine.partition_context(vault.partition)


def _records(vault, workspace, agent_id, limit: int | None = 500, lifecycles=None):
    access, selected, _ = _context(vault, workspace, agent_id)
    remaining = None if limit is None else max(1, int(limit))
    records, offset = [], 0
    while remaining is None or remaining > 0:
        page_size = 1000 if remaining is None else min(remaining, 1000)
        page = vault.engine.list(access, lifecycles=lifecycles or (
            Lifecycle.APPROVED, Lifecycle.CANDIDATE, Lifecycle.STALE, Lifecycle.SUPERSEDED),
            limit=page_size, offset=offset)
        visible = [record for record in page if vault._scope_name(record) in selected]
        records.extend(visible)
        if remaining is not None:
            remaining -= len(visible)
        offset += len(page)
        if len(page) < page_size:
            break
    # Collect before writing: updates change the list order, so interleaving
    # source invalidation with offset pagination could otherwise skip records.
    return records


def _record(vault, memory_id, workspace, agent_id):
    access, selected, _ = _context(vault, workspace, agent_id)
    record = vault.engine.get(access, memory_id)
    if vault._scope_name(record) not in selected:
        raise NotFound("memory not found")
    return record


def _files(record):
    provenance = record.extra.get("legacy_provenance", {})
    binding = provenance.get(SOURCE_KEY, {}) if isinstance(provenance, dict) else {}
    files = binding.get("files", {}) if isinstance(binding, dict) and binding.get("version") == 1 else {}
    return files if isinstance(files, dict) else {}


def source_fingerprints(workspace: str, paths: list[str]) -> dict[str, dict[str, Any]]:
    """Hash bounded files using the package's symlink-safe repository reader."""
    if (not isinstance(paths, (list, tuple)) or len(paths) > MAX_SOURCE_FILES
            or any(not isinstance(path, str) for path in paths)):
        raise MemoryError(f"Choose at most {MAX_SOURCE_FILES} source files.")
    if not workspace or not Path(workspace).is_absolute():
        raise MemoryError("An absolute workspace is required for memory source files.")
    root = str(Path(workspace).resolve())
    result = {}
    for supplied in dict.fromkeys(paths):
        path = check_repo_path(supplied)
        if _EXCLUSIONS.excluded(path):
            raise MemoryError("A source path is excluded from memory.")
        fd = open_beneath(root, path)
        try:
            before = os.fstat(fd)
            if before.st_size > MAX_SOURCE_BYTES:
                raise MemoryError("A memory source exceeds the file size limit.")
            digest, length = hashlib.sha256(), 0
            while chunk := os.read(fd, min(65536, MAX_SOURCE_BYTES + 1 - length)):
                length += len(chunk)
                if length > MAX_SOURCE_BYTES:
                    raise MemoryError("A memory source exceeds the file size limit.")
                digest.update(chunk)
            after = os.fstat(fd)
            if ((before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns) or length != after.st_size):
                raise MemoryError("A memory source changed while being read.")
            result[path] = {"sha256": digest.hexdigest(), "size": length}
        finally:
            os.close(fd)
    return result


def _infer_paths(workspace, record, include_dependencies):
    paths = list(dict.fromkeys(_FILE_TOKEN.findall(record.content)))[:MAX_SOURCE_FILES]
    if include_dependencies is True or (include_dependencies is None and
            record.kind in {MemoryKind.FACT, MemoryKind.DECISION} and _DEPENDENCY_FACT.search(record.content)):
        paths += [path for path in _DEPENDENCIES if path not in paths]
    found = {}
    for path in paths[:MAX_SOURCE_FILES]:
        try:
            found.update(source_fingerprints(workspace, [path]))
        except (MemoryEngineError, MemoryError, OSError):
            continue  # Inferred names must resolve to an allowed, readable local file.
    return found


def _write_sources(vault, record, files, workspace, agent_id, *, state="current", changed_paths=(), stale=False):
    access, selected, ctx = _context(vault, workspace, agent_id)
    authorization.require_author(access)
    core = ctx.services.core
    with ctx.partition.db.write() as conn:
        current = core.load_visible(conn, access, record.id)
        core._check_expected(current, record.revision)
        if vault._scope_name(current) not in selected or current.kind not in _KINDS:
            raise ValidationError("This memory does not support file-source maintenance.")
        if current.lifecycle not in {Lifecycle.CANDIDATE, Lifecycle.APPROVED, Lifecycle.STALE}:
            raise ValidationError("This memory is no longer current.")
        provenance = dict(current.extra.get("legacy_provenance", {}))
        provenance[SOURCE_KEY] = {"version": 1, "files": files, "state": state,
            "checked_at": core.now, "changed_paths": list(changed_paths)}
        lifecycle = Lifecycle.STALE if stale and current.lifecycle == Lifecycle.APPROVED else current.lifecycle
        updated = core.write_internal(conn, replace(current, revision=current.revision + 1,
            updated_at=core.now, lifecycle=lifecycle,
            extra={**current.extra, "legacy_provenance": provenance}),
            change="locus_source_stale" if stale else "locus_source_binding", actor=Actor.HOST,
            expected=current.revision)
        if lifecycle != current.lifecycle:
            core._stale_derived(conn, current.id)
        ctx.partition.event(conn, "source_check", "stale" if stale else "bound")
    return updated


def bind_sources(vault, memory_id: str, paths=None, *, workspace: str, agent_id: str = "primary",
                 include_dependencies: bool | None = None) -> dict:
    """Bind explicit/inferred source files once. Existing baselines need explicit refresh."""
    record = _record(vault, memory_id, workspace, agent_id)
    if _files(record):
        return vault._shape(record)
    if vault._scope_name(record) != "workspace" or record.kind not in _KINDS:
        if paths:
            raise MemoryError("File sources require an ordinary workspace memory.")
        return vault._shape(record)
    if paths is not None:
        files = source_fingerprints(workspace, paths)
        if include_dependencies is True or (include_dependencies is None and
                record.kind in {MemoryKind.FACT, MemoryKind.DECISION} and _DEPENDENCY_FACT.search(record.content)):
            for path, fingerprint in _infer_paths(workspace, record, include_dependencies).items():
                if path not in files and len(files) < MAX_SOURCE_FILES:
                    files[path] = fingerprint
    else:
        files = _infer_paths(workspace, record, include_dependencies)
    if not files:
        return vault._shape(record)
    if len(files) > MAX_SOURCE_FILES:
        raise MemoryError("Too many memory source files.")
    return vault._shape(_write_sources(vault, record, files, workspace, agent_id))


def inspect_staleness(vault, *, workspace: str, agent_id: str = "primary", limit: int | None = None) -> dict:
    """Check every visible source-backed memory before recall; bounds are opt-in."""
    report = {"checked": 0, "marked_stale": 0, "items": []}
    cache = {}
    for record in _records(vault, workspace, agent_id, limit,
                           lifecycles=(Lifecycle.APPROVED, Lifecycle.STALE)):
        files = _files(record)
        if not files or vault._scope_name(record) != "workspace" or record.kind not in _KINDS:
            continue
        if record.lifecycle not in {Lifecycle.APPROVED, Lifecycle.STALE}:
            continue
        report["checked"] += 1
        changed = []
        for path, expected in files.items():
            if path not in cache:
                try:
                    cache[path] = source_fingerprints(workspace, [path])[path]
                except (MemoryEngineError, MemoryError, OSError):
                    cache[path] = None
            if cache[path] != expected:
                changed.append(path)
        if changed and record.lifecycle == Lifecycle.APPROVED:
            try:
                record = _write_sources(vault, record, files, workspace, agent_id,
                    state="stale", changed_paths=changed, stale=True)
                report["marked_stale"] += 1
            except MemoryEngineError:
                # A deletion cannot be recalled. Any other failure must abort
                # this preflight rather than expose the still-approved record.
                try:
                    _record(vault, record.id, workspace, agent_id)
                except NotFound:
                    continue
                raise
        report["items"].append({"id": record.id, "state": "stale" if record.lifecycle == Lifecycle.STALE else "current",
                                "changed_paths": changed})
    return report


def refresh_memory(vault, memory_id: str, *, workspace: str, agent_id: str = "primary",
                   expected_revision: int | None = None) -> dict:
    """User-reviewed confirmation: rebaseline every source, then approve this revision."""
    access, _, ctx = _context(vault, workspace, agent_id)
    authorization.require_reviewer(access, ctx.host)
    record = _record(vault, memory_id, workspace, agent_id)
    if expected_revision is not None and expected_revision != record.revision:
        raise MemoryError("The memory changed; review it again before refreshing.")
    files = _files(record)
    if (not files or vault._scope_name(record) != "workspace" or record.kind not in _KINDS
            or record.lifecycle not in {Lifecycle.APPROVED, Lifecycle.STALE}):
        raise MemoryError("Only current workspace memories with file sources can be refreshed.")
    current = source_fingerprints(workspace, list(files))
    record = _write_sources(vault, record, current, workspace, agent_id)
    result = vault.engine.approve(access, record.id, expected_revision=record.revision,
                                  expected_conflicts=()).record
    return vault._shape(result)


def _normalized_content(text):
    """Only explicit phrase equivalences; never unordered token or embedding similarity."""
    value = re.sub(r"\s+", " ", text.strip()).rstrip(".! ").casefold()
    value = re.sub(r"^(?:please )?remember that ", "", value)
    value = re.sub(r"^(?:i prefer |my preference is )", "preference: ", value)
    if value.startswith("preference: "):
        value = re.sub(r"\b(?:brief|concise) (?:answers|responses)\b", "concise responses", value)
    return value


def _protected(text):
    """Preserve quantities, versions, negation, quoted/code literals and path casing."""
    return (tuple(re.findall(r"[+-]?\d+(?:\.\d+)*(?:[A-Za-z%]+)?", text)),
        tuple(re.findall(r"\b(?:not|never|no|without|cannot|can't|don't|mustn't|shouldn't)\b", text.casefold())),
        tuple(re.findall(r"`[^`]+`|\"[^\"]+\"|[\w./-]+\.[\w./-]+", text)))


def _duplicate_key(record):
    # Session/run identifiers may differ. The source authority and statement basis
    # cannot: a model interpretation never replaces user-attested evidence.
    source_domain = sorted({(source.kind.value, source.actor.value) for source in record.sources
                            if source.kind.value not in {"session", "task_attempt", "user_action"}})
    retention = {key: value for key, value in record.retention.to_dict().items() if key != "pinned"}
    return (record.scope.key(), record.kind.value, record.basis.value,
        json.dumps(source_domain), json.dumps(_files(record), sort_keys=True),
        json.dumps(record.validity.to_dict(), sort_keys=True), json.dumps(retention, sort_keys=True),
        json.dumps(record.confidence.to_dict(), sort_keys=True), _protected(record.content),
        _normalized_content(record.content))


def _merge_pair(vault, keep, duplicate, workspace, agent_id):
    """Supersede under one lock after rechecking both records, preserving lineage."""
    access, selected, ctx = _context(vault, workspace, agent_id)
    authorization.require_reviewer(access, ctx.host)
    core = ctx.services.core
    with ctx.partition.db.write() as conn:
        current = core.load_visible(conn, access, keep.id)
        old = core.load_visible(conn, access, duplicate.id)
        core._check_expected(current, keep.revision)
        core._check_expected(old, duplicate.revision)
        if (any(vault._scope_name(item) not in selected or item.kind not in _KINDS or
                core.effective_lifecycle(item) != Lifecycle.APPROVED for item in (current, old))
                or _duplicate_key(current) != _duplicate_key(old)):
            raise ValidationError("The duplicate memories changed before consolidation.")
        core.write_internal(conn, replace(old, revision=old.revision + 1,
            lifecycle=Lifecycle.SUPERSEDED, updated_at=core.now,
            links=replace(old.links, superseded_by=current.id)),
            change="locus_consolidated_duplicate", actor=Actor.HOST, expected=old.revision)
        current = core.write_internal(conn, replace(current, revision=current.revision + 1,
            updated_at=core.now, links=replace(current.links,
                supersedes=tuple(sorted(set(current.links.supersedes) | {old.id})),
                conflicts_with=tuple(value for value in current.links.conflicts_with if value != old.id))),
            change="locus_consolidated_survivor", actor=Actor.HOST, expected=current.revision)
        core._stale_derived(conn, old.id, exclude={current.id})
        ctx.partition.event(conn, "consolidation", "duplicate_superseded")
    return current


def consolidate_memories(vault, *, workspace: str, agent_id: str = "primary", apply: bool = True,
                         limit: int = 500) -> dict:
    """Consolidate safe exact/phrase duplicates; all original records remain in history."""
    access, _, _ = _context(vault, workspace, agent_id)
    authorization.require_author(access)
    maintenance = replace(access, operations=access.operations | {Operation.MAINTAIN})
    # Reuse package duplicate discovery and its auditable, resumable job record.
    job = vault.engine.consolidate(maintenance, {"max_records": max(1, min(int(limit), 1000)),
                                               "deadline_ms": 100, "summarize": False})
    records = _records(vault, workspace, agent_id, limit, lifecycles=(Lifecycle.APPROVED,))
    groups = defaultdict(list)
    for record in records:
        if record.kind in _KINDS:
            groups[_duplicate_key(record)].append(record)
    report = {"merged": 0, "groups": [], "skipped": 0, "package_job_id": job["job_id"]}
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda item: (not item.pinned, item.created_at, item.id))
        keep, duplicates = members[0], members[1:]
        group = {"keep": keep.id, "duplicates": [item.id for item in duplicates],
                 "reason": "equivalent wording with matching scope and provenance", "applied": []}
        for duplicate in duplicates:
            if apply:
                try:
                    keep = _merge_pair(vault, keep, duplicate, workspace, agent_id)
                    report["merged"] += 1
                    group["applied"].append(duplicate.id)
                except MemoryEngineError:
                    report["skipped"] += 1
        report["groups"].append(group)
    return report
