"""Task identity, immutable plans and execution-owned progress, across run owners."""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .task_state import TaskStateError, digest, encoded, fingerprints


def initialize_schema(db):
    db.executescript("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS task_links (
            owner TEXT PRIMARY KEY, task_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS task_plans (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, revision INTEGER NOT NULL,
            hash TEXT NOT NULL, execution_path TEXT NOT NULL, payload TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS task_observations (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, run_id TEXT NOT NULL,
            kind TEXT NOT NULL, payload TEXT NOT NULL, created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS task_observations_task ON task_observations(task_id, created_at);
        CREATE TABLE IF NOT EXISTS task_milestones (
            task_id TEXT NOT NULL, fingerprint TEXT NOT NULL, run_id TEXT NOT NULL,
            kind TEXT NOT NULL, payload TEXT NOT NULL, created_at REAL NOT NULL,
            PRIMARY KEY(task_id, fingerprint)
        );
        CREATE TABLE IF NOT EXISTS task_reviews (
            run_id TEXT PRIMARY KEY, payload TEXT NOT NULL
        );
        UPDATE schema_meta SET version=15 WHERE singleton=1;
        COMMIT;
    """)


class TaskJournal:
    def __init__(self, runs, task_id: str, run_id: str = ""):
        self.runs, self.task_id, self.run_id = runs, task_id, run_id

    @classmethod
    def bind(cls, runs, run: dict):
        manifest = run.get("manifest") or {}
        if manifest.get("identity_mode"):
            return None
        owners = ["run:" + run["id"]]
        capsule = manifest.get("capsule") or manifest.get("capsule_context") or {}
        if capsule.get("id"):
            owners.append("capsule:" + capsule["id"])
        if manifest.get("goal_id"):
            owners.append("goal:" + manifest["goal_id"])
        if run.get("session_id"):
            owners.append("session:" + run["session_id"])
        with runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            found = [db.execute("SELECT task_id FROM task_links WHERE owner=?", (o,)).fetchone() for o in owners]
            task_id = next((r[0] for r in found if r), owners[-1])
            for owner in owners:
                db.execute("INSERT OR IGNORE INTO task_links VALUES(?,?)", (owner, task_id))
        return cls(runs, task_id, run["id"])

    @classmethod
    def for_owner(cls, runs, owner: str):
        with runs._connect(readonly=True) as db:
            row = db.execute("SELECT task_id FROM task_links WHERE owner=?", (owner,)).fetchone()
        return cls(runs, row[0] if row else owner)

    def observe(self, identifier: str, kind: str, payload: dict):
        with self.runs._connect() as db:
            db.execute("INSERT OR IGNORE INTO task_observations VALUES(?,?,?,?,?,?)",
                       (identifier, self.task_id, self.run_id, kind, encoded(payload), time.time()))

    def milestone(self, kind: str, evidence: dict) -> bool:
        # The digest deliberately excludes run IDs, timestamps and model prose.
        with self.runs._connect() as db:
            return db.execute("INSERT OR IGNORE INTO task_milestones VALUES(?,?,?,?,?,?)",
                              (self.task_id, digest([kind, evidence]), self.run_id, kind,
                               encoded(evidence), time.time())).rowcount == 1

    def artifact_progress(self, before: dict, after: dict, declared):
        # Seed initial states so toggling back cannot reset inactivity.
        for path in sorted(set(before) | set(after)):
            if path not in declared:
                continue
            old, new = before.get(path), after.get(path)
            old_id = "artifact-state:" + digest([self.task_id, path, old])
            new_id = "artifact-state:" + digest([self.task_id, path, new])
            self.observe(old_id, "artifact_state", {"path": path, "state": old})
            with self.runs._connect() as db:
                fresh = db.execute("INSERT OR IGNORE INTO task_observations VALUES(?,?,?,?,?,?)",
                    (new_id, self.task_id, self.run_id, "artifact_state", encoded({"path": path, "state": new}), time.time())).rowcount
            if fresh and old != new:
                self.milestone("artifact_changed", {"path": path, "state": new})

    def save_plan(self, plan: dict, execution_path: str) -> dict:
        root = str(Path(execution_path).resolve())
        content = {k: v for k, v in plan.items() if k not in {"approval_reference", "revision"}}
        identifier = str(content["id"])
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            prior = db.execute("SELECT * FROM task_plans WHERE id=?", (identifier,)).fetchone()
            if prior:
                if prior["hash"] != digest(content) or prior["execution_path"] != root or prior["task_id"] != self.task_id:
                    raise TaskStateError("A saved plan is immutable. Submit a new plan revision.")
                revision = prior["revision"]
            else:
                revision = db.execute("SELECT COALESCE(MAX(revision),0)+1 FROM task_plans WHERE task_id=?", (self.task_id,)).fetchone()[0]
                declared = set(content.get("files", []))
                for step in content.get("step_details", []):
                    declared.update(step.get("inputs", []))
                    declared.update(step.get("files", []))
                sources = fingerprints(root, sorted(declared))
                db.execute("INSERT INTO task_plans VALUES(?,?,?,?,?,?,?)", (
                    identifier, self.task_id, revision, digest(content), root, encoded(content), time.time()))
                db.execute("INSERT INTO task_observations VALUES(?,?,?,?,?,?)", (
                    "plan-sources:" + identifier, self.task_id, self.run_id, "plan_sources", encoded(sources), time.time()))
        return {"id": identifier, "revision": revision, "content_hash": digest(content), "execution_path": root}

    def approved_plan(self, reference: dict, execution_path: str, *, validate_sources: bool = True) -> dict:
        with self.runs._connect(readonly=True) as db:
            row = db.execute("SELECT * FROM task_plans WHERE id=? AND task_id=?", (reference.get("id"), self.task_id)).fetchone()
            latest = db.execute("SELECT MAX(revision) FROM task_plans WHERE task_id=?", (self.task_id,)).fetchone()[0]
            source_row = db.execute("SELECT payload FROM task_observations WHERE id=? AND task_id=?", ("plan-sources:" + str(reference.get("id")), self.task_id)).fetchone()
        if (not row or row["revision"] != reference.get("revision") or latest != row["revision"]
                or row["hash"] != reference.get("content_hash")
                or row["execution_path"] != str(Path(execution_path).resolve())
                or reference.get("execution_path") != row["execution_path"]):
            raise TaskStateError("The approved plan or execution location changed. Refresh the plan before executing.")
        if source_row and validate_sources:
            sources = json.loads(source_row[0])
            if fingerprints(execution_path, list(sources)) != sources:
                raise TaskStateError("The approved plan's source files changed. Refresh the plan before executing.")
        return json.loads(row["payload"])

    def source_finding(self, receipt_id: str, requirement: str, quote: str, task: dict):
        requirements = [*task.get("requirements", []), *[c["requirement"] for c in task.get("checks", [])]]
        if requirement not in requirements or not quote.strip():
            raise TaskStateError("A finding must address a saved requirement and cite observed source text.")
        if task.get("id"):
            from .task_state import TaskStateStore
            matching = {c["id"]: c for c in task.get("checks", []) if c["requirement"] == requirement}
            latest = {r["check_id"]: r for r in TaskStateStore(self.runs).receipts(task["id"])}
            for identifier, check in matching.items():
                passed = latest.get(identifier, {})
                if (passed.get("state") == "passed" and passed.get("check_hash") == digest(check)
                        and passed.get("revision") == task.get("revision")
                        and fingerprints(passed["execution_path"], list(passed["fingerprints"])) == passed["fingerprints"]):
                    raise TaskStateError("This requirement already has current passing evidence.")
        with self.runs._connect(readonly=True) as db:
            row = db.execute("SELECT payload FROM task_observations WHERE id=? AND task_id=? AND kind='tool'", (receipt_id, self.task_id)).fetchone()
        receipt = json.loads(row[0]) if row else {}
        local = receipt.get("fingerprints") or {}
        source = receipt.get("source") or {}
        if (not receipt.get("ok") or receipt.get("tool") not in {"read_file", "web_fetch", "fetch_url", "grep"}
                or receipt.get("source_stable") is False
                or quote not in receipt.get("result", "") or not (local or source)
                or local and fingerprints(receipt["execution_path"], list(local)) != local):
            raise TaskStateError("The source receipt is absent, stale, or does not contain the finding.")
        if task.get("verification_status") == "passed":
            raise TaskStateError("This requirement is already resolved.")
        return self.milestone("source_finding", {"requirement": requirement, "source": local or source})

    def snapshot(self) -> dict[str, Any]:
        with self.runs._connect(readonly=True) as db:
            plans = db.execute("SELECT * FROM task_plans WHERE task_id=? ORDER BY revision DESC LIMIT 1", (self.task_id,)).fetchall()
            progress = db.execute("SELECT kind,payload,created_at FROM task_milestones WHERE task_id=? ORDER BY created_at DESC LIMIT 100", (self.task_id,)).fetchall()
            receipts = db.execute("SELECT id,payload FROM task_observations WHERE task_id=? AND kind='tool' ORDER BY created_at DESC LIMIT 100", (self.task_id,)).fetchall()
            links = [r[0] for r in db.execute("SELECT owner FROM task_links WHERE task_id=?", (self.task_id,))]
        plan = json.loads(plans[0]["payload"]) if plans else None
        if plan is not None:
            plan["approval_reference"] = {"id": plans[0]["id"], "revision": plans[0]["revision"],
                                          "content_hash": plans[0]["hash"], "execution_path": plans[0]["execution_path"]}
        return {"id": self.task_id, "plan": plan,
                "progress": [{"kind": r[0], "evidence": json.loads(r[1]), "created_at": r[2]} for r in progress],
                "receipts": [{"id": r[0], **json.loads(r[1])} for r in receipts], "links": links}
