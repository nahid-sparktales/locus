"""Bounded, task-owned file history with previewed, conflict-aware restoration.

Opaque shell changes are never attributed to a task merely because they occur
between two snapshots. Only the mutation owner supplies capture boundaries.
"""
from __future__ import annotations

import difflib
import hashlib
import json
import os
import stat
import tempfile
import time
import uuid
from pathlib import Path

from .task_state import TaskStateError, encoded, relative_path

MAX_FILES = 4096
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_BATCH_BYTES = 128 * 1024 * 1024


def initialize_schema(db):
    db.executescript("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS task_file_changes (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, run_id TEXT NOT NULL,
            root TEXT NOT NULL, path TEXT NOT NULL, state TEXT NOT NULL,
            payload TEXT NOT NULL, created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS task_file_changes_task ON task_file_changes(task_id, created_at);
        CREATE TABLE IF NOT EXISTS task_restorations (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, state TEXT NOT NULL,
            payload TEXT NOT NULL, created_at REAL NOT NULL
        );
        UPDATE schema_meta SET version=17 WHERE singleton=1;
        COMMIT;
    """)


def reverse_text(before: bytes, after: bytes, current: bytes) -> bytes:
    """Reverse only uniquely anchored changes; ambiguous edits are conflicts."""
    if current == after:
        return before
    if b"\0" in before + after + current:
        raise TaskStateError("Binary file changed after this task edit.")
    try:
        old, new, now = [data.decode("utf-8").splitlines(keepends=True) for data in (before, after, current)]
    except UnicodeDecodeError:
        raise TaskStateError("Binary file changed after this task edit.") from None
    edits = []
    matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
    for tag, i, j, a, b in matcher.get_opcodes():
        if tag == "equal":
            continue
        # Include adjacent unchanged lines to avoid replacing an identical
        # fragment elsewhere in the file. Edits are applied from the bottom.
        left, right = max(a - 2, 0), min(b + 2, len(new))
        anchor = new[left:right]
        locations = [k for k in range(len(now) - len(anchor) + 1) if now[k:k + len(anchor)] == anchor]
        if not anchor or len(locations) != 1:
            raise TaskStateError("Overlapping or ambiguous edits require manual restoration.")
        position = locations[0] + a - left
        edits.append((position, position + b - a, old[i:j]))
    for index, (start, _end, _) in enumerate(sorted(edits)):
        if index and start < sorted(edits)[index - 1][1]:
            raise TaskStateError("Restoration edits overlap.")
    for start, end, replacement in sorted(edits, reverse=True):
        now[start:end] = replacement
    return "".join(now).encode()


class FileHistory:
    def __init__(self, journal, root: str):
        self.journal, self.runs = journal, journal.runs
        self.root = Path(root).resolve()
        self.blobs = Path(self.runs.path).parent / "task-file-history"

    def target(self, path: str) -> Path:
        path = relative_path(path)
        target = self.root / path
        if target.is_symlink() or target.resolve() != target:
            raise TaskStateError("Symlink paths cannot be restored automatically.")
        target.resolve().relative_to(self.root)
        return target

    def put(self, data: bytes) -> str:
        if len(data) > MAX_FILE_BYTES:
            raise TaskStateError("File history is limited to 64 MiB per file.")
        identifier = hashlib.sha256(data).hexdigest()
        with self.runs._connect(readonly=True) as db:
            recorded = [json.loads(r[0]) for r in db.execute("SELECT payload FROM task_file_changes WHERE task_id=?", (self.journal.task_id,))]
        retained = {state["hash"]: state.get("bytes", 0) for item in recorded
                    for state in (item.get("before", {}), item.get("after", {})) if state.get("hash")}
        if identifier not in retained and sum(retained.values()) + len(data) > MAX_BATCH_BYTES:
            raise TaskStateError("This task's 128 MiB captured-content history limit was reached.")
        self.blobs.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination = self.blobs / identifier
        if not destination.exists():
            fd, name = tempfile.mkstemp(dir=self.blobs)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name, destination)
            finally:
                Path(name).unlink(missing_ok=True)
        return identifier

    def read(self, state: dict) -> bytes:
        if not state.get("exists"):
            return b""
        identifier = state["hash"]
        if len(identifier) != 64 or any(c not in "0123456789abcdef" for c in identifier):
            raise TaskStateError("Invalid file history reference.")
        data = (self.blobs / identifier).read_bytes()
        if hashlib.sha256(data).hexdigest() != identifier:
            raise TaskStateError("File history content is damaged.")
        return data

    def capture(self, path: str) -> dict:
        # Read through the same protected directory traversal used for writes.
        # A symlink swap must not capture content outside the execution root.
        relative = relative_path(path)
        descriptors = [os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
        try:
            components = Path(relative).parts
            try:
                for component in components[:-1]:
                    descriptors.append(os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1]))
                descriptor = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptors[-1])
            except FileNotFoundError:
                return {"exists": False}
            with os.fdopen(descriptor, "rb") as stream:
                initial = os.fstat(stream.fileno())
                if not stat.S_ISREG(initial.st_mode) or initial.st_size > MAX_FILE_BYTES:
                    raise TaskStateError("Only regular files up to 64 MiB have restorable history.")
                data = stream.read(MAX_FILE_BYTES + 1)
                final = os.fstat(stream.fileno())
                current = os.stat(components[-1], dir_fd=descriptors[-1], follow_symlinks=False)
            def signature(value):
                return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns
            if signature(initial) != signature(final) or signature(final) != signature(current):
                raise TaskStateError("File changed while its history was captured.")
            return {"exists": True, "hash": self.put(data), "mode": initial.st_mode & 0o777, "bytes": len(data)}
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    def begin(self, invocation: str, paths: list[str]) -> list[str]:
        identifiers = []
        with self.runs._connect() as db:
            count = db.execute("SELECT COUNT(*) FROM task_file_changes WHERE task_id=?", (self.journal.task_id,)).fetchone()[0]
        if count + len(paths) > MAX_FILES:
            self.journal.observe(invocation + ":history-excluded", "restoration_exclusion", {
                "reason": "The 4,096 candidate-file history boundary was reached.", "excluded_count": len(paths)})
            return []
        for path in dict.fromkeys(paths):
            identifier = invocation + ":" + hashlib.sha256(path.encode()).hexdigest()[:20]
            state, payload = "pending", {}
            try:
                payload = {"before": self.capture(path)}
            except (ValueError, OSError) as exc:
                state, payload = "unsupported", {"reason": str(exc)}
            with self.runs._connect() as db:
                db.execute("INSERT OR IGNORE INTO task_file_changes VALUES(?,?,?,?,?,?,?,?)",
                    (identifier, self.journal.task_id, self.journal.run_id, str(self.root), path, state, encoded(payload), time.time()))
            identifiers.append(identifier)
        return identifiers

    def finish(self, identifiers: list[str], *, ok: bool):
        for identifier in identifiers:
            with self.runs._connect() as db:
                row = db.execute("SELECT * FROM task_file_changes WHERE id=? AND task_id=?", (identifier, self.journal.task_id)).fetchone()
                if not row or row["state"] != "pending":
                    continue
                payload = json.loads(row["payload"])
                try:
                    payload["after"] = self.capture(row["path"])
                    state = "captured" if ok else "uncertain"
                    if payload["before"] == payload["after"]:
                        state = "unchanged"
                except (ValueError, OSError) as exc:
                    state, payload["reason"] = "uncertain", str(exc)
                db.execute("UPDATE task_file_changes SET state=?,payload=? WHERE id=?", (state, encoded(payload), identifier))
            if state != "unchanged":
                self.journal.observe(identifier + ":history", "file_change", {"path": row["path"], "state": state})

    def changes(self):
        with self.runs._connect(readonly=True) as db:
            return [{"id": r["id"], "run_id": r["run_id"], "path": r["path"], "state": r["state"],
                     "created_at": r["created_at"], **json.loads(r["payload"])} for r in db.execute(
                "SELECT * FROM task_file_changes WHERE task_id=? AND root=? ORDER BY created_at DESC LIMIT ?",
                (self.journal.task_id, str(self.root), MAX_FILES))]

    def revision(self):
        with self.runs._connect(readonly=True) as db:
            return db.execute("SELECT COUNT(*) FROM task_observations WHERE task_id=?", (self.journal.task_id,)).fetchone()[0]

    def preview(self, change_ids: list[str]):
        if not change_ids or len(change_ids) > MAX_FILES or len(set(change_ids)) != len(change_ids):
            raise TaskStateError("Select a bounded, unique set of file changes.")
        changes = {c["id"]: c for c in self.changes()}
        entries, paths, size = [], set(), 0
        for identifier in change_ids:
            change = changes.get(identifier)
            if not change or change["state"] != "captured" or change["path"] in paths:
                raise TaskStateError("Select one captured change per file.")
            path = change["path"]
            paths.add(path)
            item = {"change_id": identifier, "path": path}
            try:
                current = self.capture(path)
                before, after = change["before"], change["after"]
                if before.get("exists") != after.get("exists") and current != after:
                    raise TaskStateError("A created or deleted file has changed since this task edit.")
                content = reverse_text(self.read(before), self.read(after), self.read(current))
                result = {**before, "hash": self.put(content), "bytes": len(content)} if before.get("exists") else before
                if result.get("exists") and before.get("mode") == after.get("mode"):
                    result["mode"] = current.get("mode", before["mode"])
                elif current.get("mode") != after.get("mode"):
                    raise TaskStateError("File permissions changed after this task edit.")
                size += len(content) + current.get("bytes", 0)
                if size > MAX_BATCH_BYTES:
                    raise TaskStateError("Restoration batches are limited to 128 MiB, including recovery copies.")
                item.update(current=current, result=result, status="ready")
                if b"\0" not in content + self.read(current):
                    item["diff"] = "".join(difflib.unified_diff(self.read(current).decode("utf-8", errors="replace").splitlines(True), content.decode("utf-8", errors="replace").splitlines(True), fromfile=path, tofile=path))[:16000]
            except (ValueError, OSError) as exc:
                item.update(status="conflict", reason=str(exc))
            entries.append(item)
        value = {"token": uuid.uuid4().hex, "root": str(self.root), "revision": self.revision(), "entries": entries}
        with self.runs._connect() as db:
            db.execute("INSERT INTO task_restorations VALUES(?,?,'preview',?,?)", (value["token"], self.journal.task_id, encoded(value), time.time()))
        return value

    def _write(self, path: str, state: dict, *, expected: dict | None = None):
        # Hold directory descriptors through rename, so replacing a parent with
        # a symlink cannot redirect restoration outside its recorded checkout.
        relative = relative_path(path)
        descriptors = [os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
        temporary = ".locus-restore-" + uuid.uuid4().hex
        try:
            components = Path(relative).parts
            for component in components[:-1]:
                try:
                    descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1])
                except FileNotFoundError:
                    os.mkdir(component, dir_fd=descriptors[-1])
                    descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1])
                descriptors.append(descriptor)
            parent = descriptors[-1]
            name = components[-1]
            if state.get("exists"):
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(self.read(state))
                    stream.flush()
                    os.fchmod(stream.fileno(), state.get("mode", 0o600))
                    os.fsync(stream.fileno())
            if expected is not None and self.capture(relative) != expected:
                raise TaskStateError("A file changed immediately before restoration. Its later edits were preserved.")
            if state.get("exists"):
                os.replace(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
            else:
                try:
                    os.unlink(name, dir_fd=parent)
                except FileNotFoundError:
                    pass
            os.fsync(parent)
        finally:
            try:
                os.unlink(temporary, dir_fd=descriptors[-1])
            except FileNotFoundError:
                pass
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    def apply(self, token: str, selected: list[str], revision: int, fingerprints: dict):
        if type(revision) is not int or not isinstance(selected, list) or any(not isinstance(p, str) for p in selected):
            raise TaskStateError("Restoration requires an exact task revision and selected file paths.")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM task_restorations WHERE id=? AND task_id=?", (token, self.journal.task_id)).fetchone()
            if not row or row["state"] != "preview":
                raise TaskStateError("Restoration preview is unavailable or already consumed.")
            value = json.loads(row["payload"])
            if value["root"] != str(self.root) or value["revision"] != revision or self.revision() != revision:
                raise TaskStateError("The task changed. Preview restoration again.")
            entries = [e for e in value["entries"] if e["path"] in selected]
            if not entries or len(entries) != len(set(selected)) or len(selected) != len(set(selected)):
                raise TaskStateError("Select only files from this preview.")
            for entry in entries:
                if entry["status"] != "ready" or fingerprints.get(entry["path"]) != entry["current"] or self.capture(entry["path"]) != entry["current"]:
                    raise TaskStateError("A selected file changed or has a conflict. Nothing was restored.")
            value.update(selected=selected, applied=[])
            db.execute("UPDATE task_restorations SET state='applying',payload=? WHERE id=?", (encoded(value), token))
        try:
            for entry in entries:
                # A second check guards changes after preview admission.
                if self.capture(entry["path"]) != entry["current"]:
                    raise TaskStateError("A file changed during restoration; recovery copies are preserved.")
                self._write(entry["path"], entry["result"], expected=entry["current"])
                value["applied"].append(entry["path"])
                with self.runs._connect() as db:
                    db.execute("UPDATE task_restorations SET payload=? WHERE id=?", (encoded(value), token))
        except Exception:
            with self.runs._connect() as db:
                db.execute("UPDATE task_restorations SET state='needs_recovery' WHERE id=?", (token,))
            raise
        with self.runs._connect() as db:
            db.execute("UPDATE task_restorations SET state='completed' WHERE id=?", (token,))
        self.journal.observe(token, "restoration", {"paths": selected})
        return {"ok": True, "restored": selected, "recovery_token": token}

    def recover(self, token: str):
        """Explicitly revert a completed or interrupted restoration, when safe."""
        with self.runs._connect(readonly=True) as db:
            row = db.execute("SELECT * FROM task_restorations WHERE id=? AND task_id=?", (token, self.journal.task_id)).fetchone()
        if not row or row["state"] not in {"applying", "needs_recovery", "completed"}:
            raise TaskStateError("No recoverable restoration was found.")
        value = json.loads(row["payload"])
        entries = [e for e in value["entries"] if e["path"] in value.get("selected", [])]
        if value["root"] != str(self.root):
            raise TaskStateError("The restoration belongs to another execution location.")
        for entry in entries:
            current = self.capture(entry["path"])
            if current not in (entry["current"], entry["result"]):
                raise TaskStateError("A restored file has additional edits. Recovery requires manual review.")
        for entry in entries:
            if self.capture(entry["path"]) == entry["result"]:
                self._write(entry["path"], entry["current"], expected=entry["result"])
        with self.runs._connect() as db:
            db.execute("UPDATE task_restorations SET state='recovered' WHERE id=?", (token,))
        self.journal.observe(uuid.uuid4().hex, "restoration_recovered", {"token": token})
        return {"ok": True}
