"""Versioned, workspace-scoped task plans and their execution references.

Capsules contain user-reviewable instructions and profile identifiers, never
provider configuration. Importing this module and validating a capsule perform
no writes. Actual agent execution belongs to the task runtime.
"""
from __future__ import annotations

import errno
import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from . import paths

SCHEMA_VERSION = 1
MAX_FILES = 256
MAX_FILE_BYTES = 64 * 1024 * 1024
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$")


class CapsuleError(ValueError):
    def __init__(self, message: str, status_code: int = 422) -> None:
        super().__init__(message)
        self.status_code = status_code


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _text(value: Any, name: str, *, required: bool = False, limit: int = 20_000) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str) or len(value) > limit:
        raise CapsuleError(f"{name} must be text of at most {limit} characters")
    text = value.strip()
    if required and not text:
        raise CapsuleError(f"{name} is required")
    return text


def _identifier(value: Any, name: str) -> str:
    text = _text(value, name, required=True, limit=200)
    if not _ID.fullmatch(text):
        raise CapsuleError(f"{name} must be a profile or record identifier")
    return text


def _texts(value: Any, name: str, *, limit: int = 256) -> list[str]:
    if not isinstance(value, list) or len(value) > limit:
        raise CapsuleError(f"{name} must be an array of at most {limit} strings")
    return [_text(item, name, required=True) for item in value]


def _integer(value: Any, name: str, low: int = 1, high: int = 1_000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise CapsuleError(f"{name} must be an integer from {low} to {high}")
    return value


def _relative_file(value: Any) -> str:
    text = _text(value, "step file", required=True, limit=1_024)
    parts = text.split("/")
    if (
        PurePosixPath(text).is_absolute() or "\\" in text or "\x00" in text
        or any(part in {"", ".", ".."} for part in parts)
        or re.match(r"^[A-Za-z]:", text)
    ):
        raise CapsuleError("step files must be relative paths without traversal")
    return text


def normalize_plan(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CapsuleError("plan must be an object")
    result: dict[str, Any] = {
        "id": _identifier(value.get("id") or str(uuid.uuid4()), "plan.id"),
        "title": _text(value.get("title", ""), "plan.title", limit=500),
        "summary": _text(value.get("summary", ""), "plan.summary"),
        "steps": _texts(value.get("steps", []), "plan.steps"),
        "tests": _texts(value.get("tests", []), "plan.tests"),
        "constraints": _texts(value.get("constraints", []), "plan.constraints"),
        "decisions": _texts(value.get("decisions", []), "plan.decisions"),
    }
    raw_details = value.get("step_details", [])
    if not isinstance(raw_details, list) or len(raw_details) > 16:
        raise CapsuleError("plan.step_details must be an array of at most 16 steps")
    details = []
    for item in raw_details:
        if not isinstance(item, dict):
            raise CapsuleError("each plan step must be an object")
        details.append({
            "id": _identifier(item.get("id"), "step.id"),
            "title": _text(item.get("title"), "step.title", required=True, limit=500),
            "instructions": _text(item.get("instructions", ""), "step.instructions"),
            "dependencies": _texts(item.get("dependencies", []), "step.dependencies", limit=128),
            "files": list(dict.fromkeys(_relative_file(path) for path in _texts(item.get("files", []), "step.files"))),
            "checks": _texts(item.get("checks", []), "step.checks"),
        })
    by_id = {item["id"]: item for item in details}
    if len(by_id) != len(details):
        raise CapsuleError("plan step IDs must be unique")
    completed: set[str] = set()
    visiting: set[str] = set()

    def visit(step_id: str) -> None:
        if step_id not in by_id:
            raise CapsuleError(f"unknown step dependency: {step_id}")
        if step_id in visiting:
            raise CapsuleError("plan step dependencies contain a cycle")
        if step_id in completed:
            return
        visiting.add(step_id)
        for dependency in by_id[step_id]["dependencies"]:
            visit(dependency)
        visiting.remove(step_id)
        completed.add(step_id)

    for step_id in by_id:
        visit(step_id)
    result["step_details"] = details
    if len({path for step in details for path in step["files"]}) > MAX_FILES:
        raise CapsuleError(f"a capsule can fingerprint at most {MAX_FILES} files")
    return result


def normalize_recipe(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CapsuleError("recipe must be an object")
    result = {
        name: _identifier(value.get(name), name)
        for name in ("planner_profile_id", "executor_profile_id")
    }
    if value.get("reviewer_profile_id"):
        result["reviewer_profile_id"] = _identifier(value["reviewer_profile_id"], "reviewer_profile_id")
    for name, default, low, high in (
        ("planning_call_limit", 12, 1, 100),
        ("execution_call_limit", 60, 1, 100),
        ("max_repair_attempts", 2, 0, 7),
        ("max_planner_escalations", 1, 0, 10),
    ):
        result[name] = _integer(value.get(name, default), name, low, high)
    cost = value.get("maximum_estimated_cost")
    if cost is not None:
        if isinstance(cost, bool) or not isinstance(cost, (int, float)) or not math.isfinite(cost) or cost < 0:
            raise CapsuleError("maximum_estimated_cost must be a finite nonnegative number")
        result["maximum_estimated_cost"] = float(cost)
    return result


def _fingerprint(root: Path, relative: str) -> dict[str, Any]:
    """Traverse using directory descriptors so symlinks cannot escape scope."""
    relative = _relative_file(relative)
    descriptors: list[int] = []
    try:
        try:
            directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as exc:
            raise CapsuleError("capsule workspace is no longer available safely", 409) from exc
        descriptors.append(directory)
        components = relative.split("/")
        for component in components[:-1]:
            directory = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            descriptors.append(directory)
        file_fd = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        descriptors.append(file_fd)
        before = os.fstat(file_fd)
        if not stat.S_ISREG(before.st_mode):
            raise CapsuleError(f"step file is not a regular file: {relative}")
        if before.st_size > MAX_FILE_BYTES:
            raise CapsuleError(f"step file exceeds the {MAX_FILE_BYTES // 1024 // 1024} MB fingerprint limit: {relative}")
        digest = hashlib.sha256()
        total = 0
        while chunk := os.read(file_fd, 1024 * 1024):
            total += len(chunk)
            if total > MAX_FILE_BYTES:
                raise CapsuleError(f"step file grew beyond the fingerprint limit: {relative}")
            digest.update(chunk)
        after = os.fstat(file_fd)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise CapsuleError(f"step file changed while being fingerprinted: {relative}", 409)
        return {"path": relative, "status": "file", "sha256": digest.hexdigest(), "size": total}
    except FileNotFoundError:
        return {"path": relative, "status": "missing"}
    except OSError as exc:
        if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise CapsuleError(f"step file has a symlink or non-directory parent: {relative}") from exc
        raise CapsuleError(f"step file cannot be read safely: {relative}") from exc
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


class CapsuleStore:
    def __init__(self, workspace_root: str, path: Path | None = None) -> None:
        if not isinstance(workspace_root, str) or not workspace_root.strip():
            raise CapsuleError("workspace_root is required")
        try:
            self.root = Path(workspace_root).expanduser().resolve()
            available = self.root.is_dir()
        except (OSError, ValueError, RuntimeError) as exc:
            raise CapsuleError("workspace_root must be an existing directory") from exc
        if not available:
            raise CapsuleError("workspace_root must be an existing directory")
        self.path = path or paths.APP_DIR / "task-capsules.sqlite3"

    @contextmanager
    def _connection(self, *, write: bool = False) -> Iterator[sqlite3.Connection]:
        if write:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            connection = sqlite3.connect(self.path, timeout=10)
        else:
            connection = sqlite3.connect(self.path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
        connection.row_factory = sqlite3.Row
        try:
            if write:
                connection.executescript("""
                    CREATE TABLE IF NOT EXISTS capsules (
                        id TEXT PRIMARY KEY, workspace TEXT NOT NULL,
                        revision INTEGER NOT NULL, created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS capsule_revisions (
                        capsule_id TEXT NOT NULL, revision INTEGER NOT NULL,
                        payload TEXT NOT NULL, PRIMARY KEY(capsule_id, revision)
                    );
                    CREATE TABLE IF NOT EXISTS capsule_runs (
                        capsule_id TEXT NOT NULL, run_id TEXT NOT NULL,
                        payload TEXT NOT NULL, PRIMARY KEY(capsule_id, run_id)
                    );
                """)
                connection.execute("BEGIN IMMEDIATE")
            yield connection
            if write:
                connection.commit()
        except Exception:
            if write:
                connection.rollback()
            raise
        finally:
            connection.close()

    def _get(self, connection: sqlite3.Connection, capsule_id: str, revision: int | None = None) -> dict[str, Any]:
        _identifier(capsule_id, "capsule_id")
        if revision is not None:
            _integer(revision, "revision", high=2**31 - 1)
        head = connection.execute("SELECT * FROM capsules WHERE id=? AND workspace=?", (capsule_id, str(self.root))).fetchone()
        if head is None:
            raise CapsuleError("capsule not found in this workspace", 404)
        row = connection.execute("SELECT payload FROM capsule_revisions WHERE capsule_id=? AND revision=?", (capsule_id, revision or head["revision"])).fetchone()
        if row is None:
            raise CapsuleError("capsule revision not found", 404)
        result = json.loads(row["payload"])
        result["runs"] = [json.loads(row["payload"]) for row in connection.execute("SELECT payload FROM capsule_runs WHERE capsule_id=? ORDER BY rowid", (capsule_id,))]
        return result

    def get(self, capsule_id: str, revision: int | None = None) -> dict[str, Any]:
        if not self.path.is_file():
            raise CapsuleError("capsule not found in this workspace", 404)
        with self._connection() as connection:
            return self._get(connection, capsule_id, revision)

    def list(self, limit: int = 100) -> list[dict[str, Any]]:
        _integer(limit, "limit", high=500)
        if not self.path.is_file():
            return []
        with self._connection() as connection:
            ids = connection.execute("SELECT id FROM capsules WHERE workspace=? ORDER BY updated_at DESC, id LIMIT ?", (str(self.root), limit)).fetchall()
            return [self._get(connection, row["id"]) for row in ids]

    def _normalize(self, payload: Any) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise CapsuleError("capsule must be an object")
        if "workspace_root" in payload:
            workspace = _text(payload["workspace_root"], "workspace_root", required=True)
            try:
                same_workspace = Path(workspace).expanduser().resolve() == self.root
            except (OSError, ValueError, RuntimeError) as exc:
                raise CapsuleError("workspace_root is invalid") from exc
            if not same_workspace:
                raise CapsuleError("a capsule cannot move to another workspace")
        return {
            "title": _text(payload.get("title"), "title", required=True, limit=500),
            "request": _text(payload.get("request"), "request", required=True, limit=50_000),
            "plan": normalize_plan(payload.get("plan")),
            "recipe": normalize_recipe(payload.get("recipe")),
        }

    def _sources(self, plan: dict[str, Any]) -> list[dict[str, Any]]:
        files = sorted({file for step in plan["step_details"] for file in step["files"]})
        return [_fingerprint(self.root, file) for file in files]

    def create(self, payload: dict[str, Any], *, origin_run: dict[str, Any] | None = None) -> dict[str, Any]:
        clean = self._normalize(payload)
        sources = self._sources(clean["plan"])
        now = _now()
        initial_runs = []
        if origin_run is not None:
            initial_runs.append({
                "run_id": _identifier(origin_run.get("run_id"), "run_id"),
                "stage": "plan", "state": _identifier(origin_run.get("state"), "state"),
                "revision": 1, "updated_at": now,
            })
        result = {**clean, "schema_version": SCHEMA_VERSION, "id": str(uuid.uuid4()), "workspace_root": str(self.root), "revision": 1, "source_fingerprints": sources, "created_at": now, "updated_at": now}
        with self._connection(write=True) as connection:
            connection.execute("INSERT INTO capsules VALUES(?,?,?,?,?)", (result["id"], str(self.root), 1, now, now))
            connection.execute("INSERT INTO capsule_revisions VALUES(?,?,?)", (result["id"], 1, json.dumps(result)))
            for run in initial_runs:
                connection.execute("INSERT INTO capsule_runs VALUES(?,?,?)", (result["id"], run["run_id"], json.dumps(run)))
        return {**result, "runs": initial_runs}

    def update(self, capsule_id: str, payload: dict[str, Any], expected_revision: int) -> dict[str, Any]:
        _integer(expected_revision, "expected_revision", high=2**31 - 1)
        if not isinstance(payload, dict):
            raise CapsuleError("capsule update must be an object")
        current = self.get(capsule_id)
        if current["revision"] != expected_revision:
            raise CapsuleError("capsule changed; reload before saving", 409)
        clean = self._normalize({**current, **payload})
        # A title/recipe change must not silently bless a stale plan. Only an
        # explicitly supplied plan captures a newly reviewed source baseline.
        sources = self._sources(clean["plan"]) if "plan" in payload else current["source_fingerprints"]
        result = {**current, **clean, "revision": expected_revision + 1, "source_fingerprints": sources, "updated_at": _now()}
        result.pop("runs", None)
        with self._connection(write=True) as connection:
            latest = self._get(connection, capsule_id)
            if latest["revision"] != expected_revision:
                raise CapsuleError("capsule changed; reload before saving", 409)
            connection.execute("INSERT INTO capsule_revisions VALUES(?,?,?)", (capsule_id, result["revision"], json.dumps(result)))
            connection.execute("UPDATE capsules SET revision=?, updated_at=? WHERE id=?", (result["revision"], result["updated_at"], capsule_id))
            return {**result, "runs": latest["runs"]}

    def validate(self, capsule_id: str, revision: int | None = None) -> dict[str, Any]:
        capsule = self.get(capsule_id, revision)
        changes = []
        for previous in capsule["source_fingerprints"]:
            try:
                current = _fingerprint(self.root, previous["path"])
                if previous != current:
                    reason = "created" if previous["status"] == "missing" else "deleted" if current["status"] == "missing" else "changed"
                    changes.append({"path": previous["path"], "reason": reason})
            except CapsuleError as exc:
                changes.append({"path": previous["path"], "reason": "unsafe", "detail": str(exc)})
        return {"valid": not changes, "capsule_id": capsule_id, "revision": capsule["revision"], "changes": changes, "checked_files": len(capsule["source_fingerprints"])}

    def record_run(self, capsule_id: str, run_id: str, stage: str, state: str, expected_revision: int | None = None, *, continuation_of_run_id: str | None = None, reserve: bool = False) -> dict[str, Any]:
        run_id = _identifier(run_id, "run_id")
        stage = _identifier(stage, "stage")
        state = _identifier(state, "state")
        if expected_revision is not None:
            _integer(expected_revision, "expected_revision", high=2**31 - 1)
        if continuation_of_run_id is not None:
            continuation_of_run_id = _identifier(continuation_of_run_id, "continuation_of_run_id")
            if stage != "escalate" or continuation_of_run_id == run_id:
                raise CapsuleError("only planner escalation clarification can continue a different run")
        self.get(capsule_id)
        with self._connection(write=True) as connection:
            capsule = self._get(connection, capsule_id)
            if expected_revision is not None and capsule["revision"] != expected_revision:
                raise CapsuleError("capsule changed before execution was linked", 409)
            previous = next((item for item in capsule["runs"] if item["run_id"] == run_id), None)
            if previous and reserve:
                raise CapsuleError("this capsule run was already started", 409)
            if previous and previous["stage"] != stage:
                raise CapsuleError("a linked run cannot change its execution stage")
            parent = None
            if continuation_of_run_id and not previous:
                parent = next((item for item in capsule["runs"] if item["run_id"] == continuation_of_run_id), None)
                if not parent or parent["stage"] != "escalate" or parent["state"] != "completed" or parent["revision"] != capsule["revision"]:
                    raise CapsuleError("clarification must continue a completed planner escalation for this capsule revision", 409)
                if any(item.get("continuation_of_run_id") == continuation_of_run_id for item in capsule["runs"]):
                    raise CapsuleError("this planner clarification was already continued", 409)
            if previous and continuation_of_run_id and previous.get("continuation_of_run_id") != continuation_of_run_id:
                raise CapsuleError("a planner continuation cannot change its parent run")
            limit_key = {"escalate": "max_planner_escalations", "repair": "max_repair_attempts"}.get(stage)
            if not previous and limit_key and parent is None:
                attempts = sum(item["stage"] == stage and not item.get("continuation_of_run_id") for item in capsule["runs"])
                if attempts >= capsule["recipe"][limit_key]:
                    raise CapsuleError(f"capsule {stage} limit has been reached", 409)
            link = {"run_id": run_id, "stage": stage, "state": state, "revision": previous["revision"] if previous else capsule["revision"], "updated_at": _now()}
            if parent is not None:
                link["continuation_of_run_id"] = parent["run_id"]
                link["escalation_root_run_id"] = parent.get("escalation_root_run_id", parent["run_id"])
            elif previous:
                for field in ("continuation_of_run_id", "escalation_root_run_id"):
                    if field in previous:
                        link[field] = previous[field]
            connection.execute("INSERT INTO capsule_runs VALUES(?,?,?) ON CONFLICT(capsule_id,run_id) DO UPDATE SET payload=excluded.payload", (capsule_id, run_id, json.dumps(link)))
            return link
