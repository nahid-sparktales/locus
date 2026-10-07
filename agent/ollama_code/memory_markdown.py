"""Editable Markdown content with the engine retaining scope and lifecycle authority.

Call ``reconcile`` before reads and after writes, using a trusted user access
context and the host's selected scope names. Files are authoritative edits to
their last rendered records, not a second unreviewed recall layer. The SQLite
baseline stores only identifiers, revisions and hashes; plaintext lives in the
Markdown files. A durable projection journal makes interrupted file writes safe.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import tempfile
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from locus_memory import policy
from locus_memory.compat.legacy_vault import legacy_agent_hash
from locus_memory.errors import MemoryEngineError, NotFound
from locus_memory.models import (
    Actor,
    CandidateProposal,
    Correction,
    ForgetTarget,
    Lifecycle,
    Operation,
    RememberRequest,
    Scope,
    SourceRef,
    StatementBasis,
)

_KINDS = frozenset({"preference", "fact", "decision", "constraint", "relationship", "summary"})
_LIFECYCLES = (Lifecycle.APPROVED, Lifecycle.CANDIDATE, Lifecycle.STALE)
_MARKER = re.compile(r"<!-- locus-memory (\{[^\n]*\}) -->\n## ([^\n]+)\n(.*?)\n<!-- /locus-memory -->", re.S)
_GUIDE = "<!-- Edit notes below; append a new note as plain Markdown. Keep existing record markers. -->"
_MAX_BYTES = 8 * 1024 * 1024
_LOCKS: dict[str, threading.RLock] = {}
_LOCKS_GUARD = threading.Lock()
_HELD = threading.local()


class MarkdownMemoryError(MemoryEngineError):
    code = "markdown_memory_conflict"


def storage_status(engine_or_root: Any) -> dict[str, Any]:
    root = Path(engine_or_root) if isinstance(engine_or_root, (str, os.PathLike)) else Path(engine_or_root.root).parent / "memories"
    return {"storage_format": "markdown", "storage_root": str(root),
            "encrypted": False, "lifecycle_index_encrypted": True,
            "cipher": "plaintext Markdown; AES-256-GCM history/index",
            "personal_file": str(root / "USER.md")}


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


@contextlib.contextmanager
def storage_lock(root: Path):
    """Serialize cooperating threads/processes without following a lock symlink."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink():
        raise MarkdownMemoryError("The memory directory must not be a symbolic link.")
    with _LOCKS_GUARD:
        lock = _LOCKS.setdefault(str(root.resolve()), threading.RLock())
    with lock:
        held = getattr(_HELD, "paths", set())
        identity = str(root.resolve())
        if identity in held:
            yield
            return
        descriptor = os.open(root / ".markdown.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            _HELD.paths = held | {identity}
            yield
        finally:
            _HELD.paths = held
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)


def _read(path: Path) -> str | None:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise MarkdownMemoryError("A memory document is not a regular file.")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(_MAX_BYTES + 1)
        if len(raw) > _MAX_BYTES:
            raise MarkdownMemoryError("A memory document exceeds the size limit.")
        return raw.decode("utf-8")
    finally:
        os.close(descriptor)


def _atomic_write(path: Path, text: str, expected: str | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink():
        raise MarkdownMemoryError("A memory document directory must not be a symbolic link.")
    descriptor, temporary = tempfile.mkstemp(prefix=".memory-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        # An editor does not participate in our lock. Never replace a file
        # changed while its database edits or output were being prepared.
        if _read(path) != expected:
            raise MarkdownMemoryError("A memory document changed during synchronization; retry after reviewing it.")
        os.replace(temporary, path)
        folder = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(folder)
        finally:
            os.close(folder)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@dataclass(frozen=True)
class _Document:
    relative: str
    scope: Scope
    pending: bool
    label: str


def _documents(access, scopes) -> dict[str, _Document]:
    selected = frozenset(scopes)
    if not selected <= {"personal", "workspace", "agent"}:
        raise MarkdownMemoryError("The selected memory scopes are invalid.")
    groups: list[tuple[str, Scope, str, str]] = []
    if "personal" in selected:
        groups.append(("", Scope.global_(), "USER.md", "User memory"))
    if "workspace" in selected:
        for project in sorted(access.grants.projects):
            folder = project if re.fullmatch(r"[A-Za-z0-9_-]{1,128}", project) else _hash(project)
            groups.append(("workspaces/" + folder + "/", Scope.of(project=project), "MEMORY.md", "Workspace memory"))
        for target in sorted(access.grants.legacy_targets):
            if not target.startswith("workspace:"):
                continue
            project = "ws-" + target.split(":", 1)[1][:32]
            if project not in access.grants.projects:
                groups.append(("workspaces/" + _hash(target) + "/", Scope.of(legacy_target=target), "MEMORY.md", "Workspace memory"))
    if "agent" in selected:
        for agent in sorted(access.grants.agents):
            groups.append(("agents/" + _hash(agent)[:32] + "/", Scope.of(agent=agent), "MEMORY.md", "Agent memory"))
        bound = {"agent:" + legacy_agent_hash(agent) for agent in access.grants.agents}
        for target in sorted(access.grants.legacy_targets):
            if target.startswith("agent:") and target not in bound:
                groups.append(("agents/" + _hash(target)[:32] + "/", Scope.of(legacy_target=target), "MEMORY.md", "Agent memory"))
    result = {}
    for prefix, scope, filename, label in groups:
        policy.require_scope(access, scope)
        for name, pending in ((filename, False), ("PENDING.md", True)):
            relative = prefix + name
            result[relative] = _Document(relative, scope, pending, "Pending memory" if pending else label)
    return result


def _record_document(record, documents, access) -> str | None:
    if record.kind.value not in _KINDS or record.lifecycle not in _LIFECYCLES:
        return None
    scope = record.scope
    legacy = scope.get("legacy_target")
    # Compatibility records and newly created engine records share a document
    # only when the host supplied both corresponding grants.
    if legacy and len(scope.constraints) == 1:
        if legacy.startswith("workspace:"):
            project = "ws-" + legacy.split(":", 1)[1][:32]
            if project in access.grants.projects:
                scope = Scope.of(project=project)
        elif legacy.startswith("agent:"):
            for agent in access.grants.agents:
                if legacy == "agent:" + legacy_agent_hash(agent):
                    scope = Scope.of(agent=agent)
                    break
    for relative, document in documents.items():
        if scope == document.scope and (record.lifecycle == Lifecycle.CANDIDATE) == document.pending:
            return relative
    return None


def _records(engine, access, documents) -> dict[str, dict[str, Any]]:
    grouped = {relative: {} for relative in documents}
    offset = 0
    while True:
        rows = engine.list(access, lifecycles=_LIFECYCLES, limit=1000, offset=offset)
        for record in rows:
            relative = _record_document(record, documents, access)
            if relative is not None:
                grouped[relative][record.id] = record
        if len(rows) < 1000:
            return grouped
        offset += len(rows)


def _body_hash(title: str, content: str, kind: str) -> str:
    return _hash(json.dumps([title.replace("\n", " ").strip() or "Memory", content.strip(), kind], ensure_ascii=False))


def _baseline(records) -> dict:
    return {identifier: {"revision": record.revision, "hash": _body_hash(record.title, record.content, record.kind.value)}
            for identifier, record in records.items()}


def _render(document, records) -> str:
    blocks = ["# " + document.label, _GUIDE]
    for record in sorted(records.values(), key=lambda item: (item.created_at, item.id)):
        # Marker-looking text must not turn a record's body into a second record.
        content = record.content.replace("&lt;!--", "&amp;lt;!--").replace("<!-- locus-memory", "&lt;!-- locus-memory").replace("<!-- /locus-memory", "&lt;!-- /locus-memory")
        title = record.title.replace("\n", " ").strip() or "Memory"
        marker = json.dumps({"id": record.id, "kind": record.kind.value}, separators=(",", ":"))
        blocks.append(f"<!-- locus-memory {marker} -->\n## {title}\n{content}\n<!-- /locus-memory -->")
    return "\n\n".join(blocks) + "\n"


def _parse(text: str, document) -> tuple[dict[str, dict], str]:
    if "\x00" in text or re.search(r"(?m)^(?:<<<<<<<|=======|>>>>>>>)", text):
        raise MarkdownMemoryError("A memory document contains invalid text or an unresolved merge conflict.")
    records = {}
    for match in _MARKER.finditer(text):
        try:
            metadata = json.loads(match[1])
        except ValueError as exc:
            raise MarkdownMemoryError("A memory record marker is malformed.") from exc
        if (not isinstance(metadata, dict) or set(metadata) != {"id", "kind"}
                or not isinstance(metadata["id"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", metadata["id"])
                or not isinstance(metadata["kind"], str) or metadata["kind"] not in _KINDS or metadata["id"] in records):
            raise MarkdownMemoryError("A memory record marker is invalid or duplicated.")
        content = match[3].strip().replace("&lt;!-- locus-memory", "<!-- locus-memory").replace("&lt;!-- /locus-memory", "<!-- /locus-memory").replace("&amp;lt;!--", "&lt;!--")
        if not content:
            raise MarkdownMemoryError("An empty memory block must be removed, including its markers.")
        records[metadata["id"]] = {**metadata, "title": match[2].strip(), "content": content}
    remainder = _MARKER.sub("", text)
    if "locus-memory" in remainder:
        raise MarkdownMemoryError("A memory document has an incomplete record marker.")
    lines = [line for line in remainder.splitlines() if line not in ("# " + document.label, _GUIDE)]
    return records, "\n".join(lines).strip()


def _state_key(root, relative) -> str:
    return _hash(str(root.resolve()) + "\x00" + relative)


def _load_state(partition, key) -> dict:
    with partition.db.read() as conn:
        row = conn.execute("SELECT state FROM locus_markdown_state WHERE file_key=?", (key,)).fetchone()
    try:
        return json.loads(row[0]) if row else {}
    except ValueError as exc:
        raise MarkdownMemoryError("The memory document baseline is unavailable.") from exc


def _save_state(partition, key, state) -> None:
    with partition.db.write() as conn:
        conn.execute("INSERT INTO locus_markdown_state(file_key,state) VALUES(?,?) ON CONFLICT(file_key) DO UPDATE SET state=excluded.state",
                     (key, json.dumps(state, sort_keys=True)))


def _file_status(path, document) -> dict:
    scope_name = "personal" if document.scope.is_global else "agent" if document.relative.startswith("agents/") else "workspace"
    return {"path": str(path), "scope": scope_name, "status": "pending" if document.pending else "approved"}


def reconcile(engine, access, *, scopes=("personal", "workspace", "agent"), root: Path | str | None = None) -> dict[str, Any]:
    """Import scoped file edits, then durably project the current engine records.

    Missing previously rendered files and simultaneous database/file edits fail
    closed. Remove a record's complete block to forget it. Newly appended text
    is one new note; PENDING.md additions and edits never approve a candidate.
    """
    policy.require(access, Operation.READ)
    if access.actor != Actor.USER:
        raise MarkdownMemoryError("Markdown reconciliation requires the host's user access context.")
    root = Path(root) if root is not None else Path(engine.root).parent / "memories"
    result = {**storage_status(root), "files": [], "created": 0, "updated": 0, "deleted": 0}
    documents = _documents(access, scopes)
    if not documents:
        return result
    try:
        with storage_lock(root):
            partition = engine.partition_context(access.partition).partition
            with partition.db.write() as conn:
                conn.execute("CREATE TABLE IF NOT EXISTS locus_markdown_state (file_key TEXT PRIMARY KEY, state TEXT NOT NULL)")
            grouped = _records(engine, access, documents)
            prepared = []
            # Validate every selected file before changing any record. This also
            # prevents moving a pending block to MEMORY.md from approving it.
            for relative, document in documents.items():
                path = root / relative
                if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
                    raise MarkdownMemoryError("A memory document directory must not be a symbolic link.")
                key = _state_key(root, relative)
                state = _load_state(partition, key)
                text = _read(path)
                if text is None and state and (state.get("file_hash") or state.get("pending", {}).get("input_hash") is not None):
                    raise MarkdownMemoryError("A previously saved memory document is missing; restore it before recalling memory.")
                disk_hash = None if text is None else _hash(text)
                journal = state.get("pending") or {}
                if journal.get("output_hash") is not None and disk_hash == journal["output_hash"]:
                    state = {"records": journal["records"], "file_hash": disk_hash}
                    _save_state(partition, key, state)
                    journal = {}
                if journal and disk_hash != journal.get("input_hash"):
                    raise MarkdownMemoryError("A memory document changed while an earlier synchronization was unfinished.")
                blocks, addition = _parse(text, document) if text is not None else ({}, "")
                baseline = state.get("records", {})
                current = grouped[relative]
                if state.get("file_hash") is not None and not journal and state["file_hash"] == disk_hash and baseline == _baseline(current):
                    result["files"].append(_file_status(path, document))
                    continue
                desired = journal.get("desired", {})
                actions = []
                for identifier, block in blocks.items():
                    hashed = _body_hash(block["title"], block["content"], block["kind"])
                    before = baseline.get(identifier)
                    record = current.get(identifier)
                    if record is None:
                        try:
                            elsewhere = engine.get(access, identifier)
                        except NotFound:
                            elsewhere = None
                        if elsewhere is not None:
                            if before and before["hash"] == hashed:
                                continue  # approved, expired or superseded through the engine
                            raise MarkdownMemoryError("A memory record was moved outside its scope or review state.")
                        if before:
                            if before["hash"] == hashed:
                                continue  # database forget wins over an unchanged old file
                            raise MarkdownMemoryError("A deleted memory was also edited in Markdown.")
                        if document.pending:
                            raise MarkdownMemoryError("An unknown pending record must be added as a new note without record markers.")
                        # Caller-chosen ids let the signed deletion ledger refuse
                        # restored old blocks, even on a fresh Markdown baseline.
                        request = RememberRequest(content=block["content"], title=block["title"], kind=block["kind"], scope=document.scope, memory_id=identifier)
                        actions.append(("create", identifier, request))
                    else:
                        current_hash = _body_hash(record.title, record.content, record.kind.value)
                        if record.kind.value != block["kind"]:
                            raise MarkdownMemoryError("A memory record's type cannot be changed through its marker.")
                        if hashed == current_hash:
                            continue
                        if before and hashed == before["hash"]:
                            continue  # database-only update; refresh the projection
                        if before and record.revision != before["revision"] and desired.get(identifier) != current_hash:
                            raise MarkdownMemoryError("Both the memory and its Markdown text changed; resolve the conflict before recall.")
                        if before is None and text is not None:
                            raise MarkdownMemoryError("An existing memory has conflicting Markdown content without an editing baseline.")
                        actions.append(("update", identifier, (Correction(content=block["content"], title=block["title"], reason="Edited in memory Markdown"), record.revision)))
                    desired[identifier] = hashed
                for identifier, before in baseline.items():
                    if identifier not in blocks and identifier in current:
                        if current[identifier].revision != before["revision"]:
                            raise MarkdownMemoryError("A memory removed from Markdown was changed elsewhere; resolve the conflict before recall.")
                        actions.append(("delete", identifier, current[identifier].revision))
                if addition:
                    identifier = journal.get("addition_id") or "m-" + uuid.uuid4().hex
                    kind = "preference" if document.scope.is_global else "fact"
                    title = addition.splitlines()[0].lstrip("#- ")[:160] or "Memory"
                    if document.pending:
                        request = CandidateProposal(content=addition, title=title, kind=kind, scope=document.scope,
                            basis=StatementBasis.USER_STATED, proposer="markdown-user",
                            sources=(SourceRef("document", "markdown-" + identifier, actor=Actor.USER, fingerprint=_hash(addition)),))
                        actions.append(("propose", identifier, request))
                    else:
                        request = RememberRequest(content=addition, title=title, kind=kind, scope=document.scope, memory_id=identifier)
                        if identifier not in current:
                            actions.append(("create", identifier, request))
                    desired[identifier] = _body_hash(title, addition, kind)
                else:
                    identifier = None
                for action, _, _ in actions:
                    policy.require(access, {"delete": Operation.FORGET, "create": Operation.WRITE, "update": Operation.WRITE, "propose": Operation.PROPOSE}[action])
                prepared.append((document, path, key, state, text, actions, desired, identifier))
            for document, path, key, state, text, actions, desired, addition_id in prepared:
                state["pending"] = {"input_hash": None if text is None else _hash(text), "desired": desired, "addition_id": addition_id}
                _save_state(partition, key, state)
                for action, identifier, request in actions:
                    if action == "delete":
                        if engine.get(access, identifier).revision != request:
                            raise MarkdownMemoryError("A memory removed from Markdown changed during synchronization.")
                        engine.forget(access, ForgetTarget("memory", identifier))
                        result["deleted"] += 1
                    elif action == "update":
                        correction, revision = request
                        engine.correct(access, identifier, correction, expected_revision=revision)
                        result["updated"] += 1
                    elif action == "create":
                        engine.remember(access, request)
                        result["created"] += 1
                    else:
                        engine.propose(access, request, idempotency_key="markdown-" + identifier)
                        result["created"] += 1
                records = _records(engine, access, documents)[document.relative]
                output = _render(document, records)
                baseline = _baseline(records)
                state["pending"].update(output_hash=_hash(output), records=baseline)
                _save_state(partition, key, state)
                if text != output:
                    _atomic_write(path, output, text)
                _save_state(partition, key, {"file_hash": _hash(output), "records": baseline})
                result["files"].append(_file_status(path, document))
        return result
    except MarkdownMemoryError:
        raise
    except (OSError, UnicodeError, ValueError) as exc:
        raise MarkdownMemoryError("A memory document could not be read or synchronized; its contents were preserved.") from exc
