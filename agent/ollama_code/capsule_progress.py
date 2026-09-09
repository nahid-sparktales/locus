"""Durable capsule attempts and recovery of verified, dependency-aware progress."""
from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from typing import Any

from .task_state import TaskStateError, TaskStateStore, TaskVerifier, digest, encoded, fingerprints


def workspace_state(root: str) -> dict:
    """Capture local inputs, respecting Git ignores; never follow directory links."""
    result = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=root,
                            capture_output=True, timeout=20)
    if result.returncode == 0:
        paths = [p for p in result.stdout.decode(errors="strict").split("\0") if p]
    else:
        paths = []
        for directory, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if d not in {".git", ".venv", "node_modules", "__pycache__", ".build"}]
            paths.extend(str((Path(directory) / f).relative_to(root)) for f in files)
            if len(paths) > 4096:
                break
    if len(paths) > 4096:
        raise TaskStateError("This workspace exceeds the capsule recovery snapshot limit (4,096 files). Use a smaller workspace.")
    return fingerprints(root, paths)


def step_signature(capsule: dict, step: dict) -> str:
    return digest({"request": capsule["request"], "constraints": capsule["plan"].get("constraints", []),
                   "decisions": capsule["plan"].get("decisions", []), "step": step})


def declared_files(step: dict) -> list[str]:
    return list(dict.fromkeys([*step.get("files", []), *step.get("inputs", []), *step.get("outputs", []),
        *[p for c in step.get("acceptance_checks", []) for p in [*c.get("files", []), *([c["path"]] if c.get("path") else [])]]]))


def attribute_step_usage(value: dict, identifier: str) -> None:
    step = value["steps"].get(identifier)
    if step is None:
        return
    # The attempt total owns the allowance. Step totals attribute its spend
    # without counting verification-only retries or earlier steps twice.
    baseline = step.get("attempt_usage_before", {})
    previous = step.get("usage_before", {})
    step["usage"] = {key: previous.get(key, 0) + max(number - baseline.get(key, 0), 0)
                     for key, number in value["usage"].items()}


class CapsuleProgressStore:
    def __init__(self, runs: Any):
        self.runs = runs

    def get(self, identifier: str) -> dict | None:
        import json
        with self.runs._connect(readonly=True) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='capsule_attempts'").fetchone():
                return None
            row = db.execute("SELECT payload FROM capsule_attempts WHERE id=?", (identifier,)).fetchone()
            return json.loads(row[0]) if row else None

    def list(self, capsule_id: str) -> list[dict]:
        import json

        from .runstore import _alive
        if not hasattr(self.runs, "_connect"):
            return []
        with self.runs._connect(readonly=True) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='capsule_attempts'").fetchone():
                return []
            values = [json.loads(row[0]) for row in db.execute("SELECT payload FROM capsule_attempts WHERE capsule_id=? ORDER BY updated_at DESC", (capsule_id,))]
        for value in values:
            if value.get("state") == "running" and not _alive(value.get("owner_pid", 0)):
                value.update(state="paused", reason="Execution was interrupted. Review saved progress before resuming.")
            if value.get("pending_usage"):
                value["reason"] = "Previous model usage is unsettled. Review the interrupted call and its allowance."
            if value.get("uncertain_action"):
                action = value["uncertain_action"]
                value["reason"] = f"The outcome of {action['tool']} in {action.get('step_id') or 'review repair'} is uncertain. Inspect its result before resuming."
        return values

    def save(self, value: dict, *, claiming: bool = False) -> None:
        import json

        from .runstore import _alive
        if self.runs.read_only:
            raise TaskStateError("Capsule progress storage is read-only.")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM capsule_attempts WHERE id=?", (value["id"],)).fetchone()
            previous = json.loads(row[0]) if row else None
            if claiming and previous and previous.get("state") == "running" and _alive(previous.get("owner_pid", 0)):
                raise TaskStateError("This capsule attempt is already running.")
            if not claiming and previous and previous.get("active_run_id") != value["active_run_id"]:
                raise TaskStateError("A newer run owns this capsule attempt.")
            db.execute("INSERT INTO capsule_attempts VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at",
                       (value["id"], value["capsule_id"], encoded(value), time.time()))

    def accept(self, identifier: str, capsule_id: str, revision: int | None = None) -> dict:
        value = self.get(identifier)
        if not value or value["capsule_id"] != capsule_id or value["state"] != "needs_review":
            raise TaskStateError("Only a capsule result needing review can be accepted.")
        if revision is not None and value["revision"] != revision:
            raise TaskStateError("The result belongs to an older plan. Retry checks against the current revision.")
        if value.get("uncertain_action") or value.get("pending_usage"):
            raise TaskStateError("An uncertain action must be reconciled before accepting this result.")
        value.update(state="completed", verification_status="accepted", accepted_at=time.time(),
                     reason="Accepted by the user; not machine verified.")
        self.save(value)
        return value

    def resolve_action(self, identifier: str, capsule_id: str, action_id: str, note: str) -> dict:
        value = self.get(identifier)
        from .runstore import _alive
        if not value or value["capsule_id"] != capsule_id or value["state"] == "running" and _alive(value.get("owner_pid", 0)):
            raise TaskStateError("Pause this attempt before recording a reviewed action.")
        action = value.get("uncertain_action")
        if not action or action.get("id") != action_id or not isinstance(note, str) or not note.strip() or len(note) > 8000:
            raise TaskStateError("Describe the observed outcome of this specific action before continuing.")
        value.setdefault("reviewed_actions", []).append({**action, "outcome": note, "reviewed_at": time.time(),
            "instruction": "The user inspected this action. Do not replay it; continue from the observed outcome."})
        value.pop("uncertain_action", None)
        value.update(state="paused", reason="Action outcome recorded. Resume will inspect existing progress.")
        self.save(value)
        return value

    def resolve_usage(self, identifier: str, capsule_id: str, usage: dict) -> dict:
        import math

        from .runstore import _alive
        value = self.get(identifier)
        if (not value or value["capsule_id"] != capsule_id or not value.get("pending_usage")
                or value["state"] == "running" and _alive(value.get("owner_pid", 0))):
            raise TaskStateError("Only interrupted, unsettled usage can be reviewed.")
        previous = value.get("usage", {})
        for key in ("model_calls", "metered_tokens", "estimated_cost"):
            number = usage.get(key) if isinstance(usage, dict) else None
            if (type(number) not in {float, int} or not math.isfinite(number)
                    or number < previous.get(key, 0)
                    or key != "estimated_cost" and number != int(number)):
                raise TaskStateError("Reviewed totals must include all previously recorded usage.")
        value["usage_reviews"] = [*value.get("usage_reviews", []), {"previous": previous,
            "usage": usage, "accepted_at": time.time(), "source": "human_review"}]
        value["usage"] = {key: usage[key] for key in ("model_calls", "metered_tokens", "estimated_cost")}
        attribute_step_usage(value, value["pending_usage"].get("step_id", ""))
        value.pop("pending_usage", None)
        value.update(state="paused", reason="Reviewed usage saved. Resume keeps these totals and the original remaining allowance.")
        self.save(value)
        return value


class CapsuleRuntime:
    def __init__(self, svc: Any, capsule: dict, run_id: str, resume: str | None = None):
        self.svc, self.core, self.capsule, self.run_id = svc, svc.core, capsule, run_id
        self.store = CapsuleProgressStore(svc.run_store)
        self.tasks = TaskStateStore(svc.run_store)
        self.step_id = ""
        self.checks_only = False
        self.settled = False
        self.before: dict = {}
        root = str(Path(self.core.cwd).resolve())
        if resume:
            if not isinstance(resume, str) or len(resume) > 200:
                raise TaskStateError("Resume needs a valid saved attempt reference.")
            value = self.store.get(resume)
            if not value or value["capsule_id"] != capsule["id"] or value["execution_path"] != root:
                raise TaskStateError("Resume must use this capsule's original execution checkout.")
            if value.get("state") == "completed":
                raise TaskStateError("This attempt is complete. Start another execution explicitly.")
            if value.get("pending_usage"):
                raise TaskStateError("Previous model usage is unsettled. This attempt cannot silently reset its allowance.")
            if value.get("uncertain_action"):
                raise TaskStateError("An action's outcome is uncertain. Review its result before resuming; it will not be replayed.")
            self.value = value
            self._reconcile()
        else:
            expected = {f["path"]: f for f in capsule.get("source_fingerprints", [])}
            if fingerprints(root, list(expected)) != expected:
                raise TaskStateError("The execution checkout differs from the saved plan. Update the plan before running.")
            self.value = {"id": run_id, "capsule_id": capsule["id"], "schema_version": 1,
                "revision": capsule["revision"], "plan_signature": digest(capsule["plan"]), "execution_path": root, "steps": {}, "usage": {},
                "expected_files": expected, "run_ids": [], "verification_status": "pending", "stage": "implementation"}
        self.value.update(active_run_id=run_id, owner_pid=os.getpid(), state="running", reason="", revision=capsule["revision"])
        self.value["run_ids"].append(run_id)
        self.store.save(self.value, claiming=True)
        try:
            self.tasks.ensure(f"capsule:{self.value['id']}:final", request=capsule["request"], revision=capsule["revision"],
                              workspace=self.core.workspace_root, execution=root, plan=capsule["plan"],
                              session_id=getattr(getattr(self.core, "session", None), "session_id", ""))
        except Exception:
            self.value["state"] = "paused"
            self.store.save(self.value)
            raise
        self.emit()

    def _reconcile(self) -> None:
        value = self.value
        if value["revision"] != self.capsule["revision"] and value.get("plan_signature") != digest(self.capsule["plan"]):
            value.pop("pending_corrections", None)
        expected = value.get("expected_files", {})
        observed = fingerprints(value["execution_path"], list(expected))
        changed = {p for p in expected if expected[p] != observed[p]}
        steps = self.definitions()
        value["steps"] = {k: v for k, v in value["steps"].items() if k in {s["id"] for s in steps}}
        invalid, touched = set(), set(changed)
        # A partial step owns its captured post-state, but has no verification
        # receipt. It is continued by inspection, never skipped as complete.
        for step in steps:
            previous = value["steps"].get(step["id"])
            if not previous or previous.get("signature") != step_signature(self.capsule, step):
                invalid.add(step["id"])
        if value.get("expected_workspace") is not None and workspace_state(value["execution_path"]) != value["expected_workspace"]:
            invalid.update(key for key, step in value["steps"].items() if step.get("workspace_scope"))
        while True:
            prior = set(invalid)
            for step in steps:
                previous = value["steps"].get(step["id"], {})
                files = set(declared_files(step)) | set(previous.get("files", [])) | set(previous.get("changed_files", []))
                if files & touched or set(step.get("dependencies", [])) & invalid or step["id"] in invalid:
                    invalid.add(step["id"])
                    touched.update(files)
            if prior == invalid:
                break
        for identifier, step in value["steps"].items():
            if identifier not in invalid and step["state"] == "verified":
                step["validated_revision"] = self.capsule["revision"]
        for identifier in invalid:
            if identifier in value["steps"]:
                value["steps"][identifier]["state"] = "pending"
        if invalid or changed:
            value["stage"] = "implementation"
            value["verification_status"] = "pending"
        value["expected_files"] = observed
        value["plan_signature"] = digest(self.capsule["plan"])

    def context(self) -> dict:
        return {"request": self.capsule["request"], "plan": self.capsule["plan"], "attempt_id": self.value["id"],
                "steps": {k: {"state": v["state"], "reason": v.get("reason", "")} for k, v in self.value["steps"].items()},
                "usage": self.value["usage"], "corrections": self.value.get("corrections", []),
                "reviewed_actions": self.value.get("reviewed_actions", [])}

    def correction(self, text: str, identifier: str) -> None:
        if identifier in {item["id"] for item in self.value.get("corrections", [])}:
            return
        self.value.setdefault("corrections", []).append({"id": identifier, "text": text})
        self.value["pending_corrections"] = True
        self.store.save(self.value)
        task = self.tasks.get(f"capsule:{self.value['id']}:final")
        if task:
            task["inputs"] = [*task.get("inputs", []), {"id": identifier, "text": text}]
            task.update(verification_status="pending", evidence_ids=[])
            self.tasks.save(task, expected_revision=task["revision"])

    def emit(self) -> None:
        self.svc.emit({"type": "capsule_progress", "capsule_id": self.capsule["id"], "attempt": self.value})

    @property
    def completed(self) -> set[str]:
        if self.checks_only:
            return {s["id"] for s in self.definitions()}
        return {key for key, step in self.value["steps"].items() if step["state"] == "verified" or self.checks_only or self.value.get("stage") == "review"}

    def start_step(self, identifier: str) -> None:
        self.assert_plan_current()
        self.step_id = identifier
        self.before = workspace_state(self.core.cwd)
        step = self.definition(identifier)
        previous_usage = self.value["steps"].get(identifier, {}).get("usage", {})
        self.value["steps"][identifier] = {"state": "running", "signature": step_signature(self.capsule, step),
            "dependencies": step.get("dependencies", []), "files": declared_files(step), "before": self.before,
            "inputs": step.get("inputs", []), "outputs": step.get("outputs", []),
            "usage": dict(previous_usage), "usage_before": dict(previous_usage),
            "attempt_usage_before": dict(self.value.get("usage", {})),
            "started_at": time.time()}
        self.store.save(self.value)
        self.emit()

    def definition(self, identifier: str) -> dict:
        return next((s for s in self.definitions() if s["id"] == identifier),
                    {"id": identifier, "title": identifier, "files": [], "acceptance_checks": []})

    def definitions(self) -> list[dict]:
        return self.capsule["plan"].get("step_details") or [
            {"id": f"step-{index + 1}", "title": title, "instructions": title,
             "dependencies": [], "files": [], "checks": []}
            for index, title in enumerate(self.capsule["plan"].get("steps", []))]

    def assert_plan_current(self) -> None:
        from .capsules import CapsuleStore
        current = CapsuleStore(self.core.workspace_root).get(self.capsule["id"])
        if current["revision"] != self.capsule["revision"]:
            raise TaskStateError("The capsule changed during execution. Resume against the current plan before continuing.")

    def finish_step(self, identifier: str, decider: Any) -> dict:
        self.assert_plan_current()
        if self.value.get("uncertain_action"):
            raise TaskStateError("An action remains uncertain; verification cannot clear it.")
        step = self.definition(identifier)
        task_id = f"capsule:{self.value['id']}:{identifier}"
        self.tasks.ensure(task_id, request=step.get("title", identifier), revision=self.capsule["revision"],
                          workspace=self.core.workspace_root, execution=self.core.cwd, plan=step, include_reusable=False)
        checked = TaskVerifier(self.tasks, task_id, self.core, self.run_id).verify(
            step.get("acceptance_checks", []), decider, fallback="; ".join(step.get("checks", [])) or step.get("title", identifier))
        self.assert_plan_current()
        after = workspace_state(self.core.cwd)
        changed = {p for p in self.before.keys() | after.keys() if self.before.get(p) != after.get(p)}
        receipt = self.value["steps"][identifier]
        observed_inputs = []
        for path in self.core.tool_ctx.read_files:
            try:
                observed_inputs.append(str(Path(path).resolve().relative_to(Path(self.core.cwd).resolve())))
            except ValueError:
                continue
        receipt["files"] = sorted(set(receipt.get("files", [])) | set(observed_inputs))
        receipt["workspace_scope"] = any(c["kind"] == "command" and not c.get("files") for c in checked["checks"])
        receipt.update(state="verified" if checked["verification_status"] == "passed" else checked["verification_status"],
                       evidence_ids=checked["evidence_ids"], changed_files=sorted(changed | set(receipt.get("changed_files", []))), reason=checked["verification_reason"])
        self.value["expected_files"].update(fingerprints(self.core.cwd, list(changed | set(receipt["files"]))))
        if any(s.get("workspace_scope") for s in self.value["steps"].values()):
            self.value["expected_workspace"] = after
        self.store.save(self.value)
        self.emit()
        self.step_id = ""
        return checked

    def start_model_work(self, usage: dict, profile: Any) -> None:
        self.value["pending_usage"] = {"base": usage, "step_id": self.step_id, "metered": profile.metering == "metered",
            "input_price": profile.input_cost_per_million, "output_price": profile.output_cost_per_million}
        self.store.save(self.value)

    def observe_usage(self, event: dict) -> None:
        pending = self.value.get("pending_usage")
        if not pending:
            return
        base = pending["base"]
        prompt, completion = int(event.get("prompt_tokens") or 0), int(event.get("completion_tokens") or 0)
        usage = {"model_calls": base.get("model_calls", 0) + int(event.get("model_calls") or 0),
            "metered_tokens": base.get("metered_tokens", 0) + (prompt + completion if pending["metered"] else 0),
            "estimated_cost": base.get("estimated_cost", 0) + ((prompt * (pending["input_price"] or 0) + completion * (pending["output_price"] or 0)) / 1000000 if pending["metered"] else 0)}
        self.value["usage"] = {key: max(number, self.value.get("usage", {}).get(key, 0)) for key, number in usage.items()}
        attribute_step_usage(self.value, self.step_id)
        self.store.save(self.value)

    def finish_model_work(self, usage: dict) -> None:
        self.value["usage"] = usage
        attribute_step_usage(self.value, self.step_id)
        self.value.pop("pending_usage", None)
        self.store.save(self.value)

    def action_started(self, identifier: str, tool: str, arguments: dict | None = None, summary: str = "") -> None:
        signature = digest({"tool": tool, "arguments": arguments})
        if any(action.get("argument_hash") == signature for action in self.value.get("reviewed_actions", [])):
            raise TaskStateError("This interrupted action was already reviewed. Its identical invocation will not be replayed.")
        self.value["uncertain_action"] = {"id": identifier, "tool": tool, "step_id": self.step_id,
                                          "argument_hash": signature, "summary": summary}
        self.store.save(self.value)

    def action_finished(self, identifier: str, result: str) -> None:
        if self.value.get("uncertain_action", {}).get("id") != identifier:
            return
        if result.startswith("Error") or any(word in result.lower() for word in ("unconfirmed", "uncertain", "disconnected", "connection lost", "timed out", "timeout")):
            return
        self.value.pop("uncertain_action", None)
        self.store.save(self.value)

    def final_check(self, decider: Any) -> dict:
        self.assert_plan_current()
        self.value["stage"] = "review"
        if self.value.get("uncertain_action") or self.value.get("pending_usage"):
            self.value.update(verification_status="needs_review", reason="An action or model call remains unsettled. Review its recorded outcome before completing this capsule.")
            self.store.save(self.value)
            self.emit()
            return self.value
        self.value["verification_status"] = "checking"
        self.store.save(self.value)
        self.emit()
        expected = self.value.get("expected_files", {})
        observed = fingerprints(self.core.cwd, list(expected))
        changed = {p for p in expected if expected[p] != observed[p]}
        workspace_changed = (self.value.get("expected_workspace") is not None
                             and workspace_state(self.core.cwd) != self.value["expected_workspace"])
        for definition in self.definitions():
            if definition["id"] not in self.value["steps"]:
                if self.checks_only:
                    self.start_step(definition["id"])
                else:
                    raise TaskStateError("The capsule has implementation steps that have not run.")
        for step_id in list(self.value["steps"]):
            step = self.value["steps"][step_id]
            affected = bool(changed & (set(step.get("files", [])) | set(step.get("changed_files", []))))
            if step["state"] != "verified" or self.checks_only or affected or workspace_changed and step.get("workspace_scope"):
                self.before = workspace_state(self.core.cwd)
                self.finish_step(step_id, decider)
        self.value.pop("recheck_after_repair", None)
        identifier = f"capsule:{self.value['id']}:final"
        self.tasks.ensure(identifier, request=self.capsule["request"], revision=self.capsule["revision"],
            workspace=self.core.workspace_root, execution=self.core.cwd, plan=self.capsule["plan"])
        checks = self.capsule["plan"].get("acceptance_checks", [])
        if checks or (self.tasks.get(identifier) or {}).get("reusable_checks"):
            checked = TaskVerifier(self.tasks, identifier, self.core, self.run_id).verify(checks, decider)
            status, reason = checked["verification_status"], checked["verification_reason"]
        else:
            status, reason = "passed", ""
        if any(s["state"] != "verified" for s in self.value["steps"].values()) or not self.value["steps"]:
            if status == "passed":
                status = "failed" if any(s["state"] == "failed" for s in self.value["steps"].values()) else "needs_review"
                reason = "; ".join(s.get("reason", "") for s in self.value["steps"].values() if s["state"] != "verified") or "Some implementation steps have no passing recorded acceptance checks."
        if self.value.get("pending_corrections"):
            status, reason = "needs_review", "User corrections were applied after the saved plan. Review their coverage or revise the plan's acceptance checks."
        self.assert_plan_current()
        self.value.update(verification_status=status, reason=reason)
        self.store.save(self.value)
        self.emit()
        return self.value

    def settle(self, state: str, usage: dict | None = None, *, emit: bool = True) -> None:
        if usage is not None:
            self.value["usage"] = usage
        if self.step_id and self.step_id in self.value["steps"]:
            self.value["steps"][self.step_id]["state"] = "paused"
            try:
                after = workspace_state(self.core.cwd)
                changed = {p for p in self.before.keys() | after.keys() if self.before.get(p) != after.get(p)}
                self.value["expected_files"].update(fingerprints(self.core.cwd, list(changed)))
                self.value["steps"][self.step_id]["changed_files"] = sorted(changed)
            except (OSError, ValueError):
                pass
        status = self.value.get("verification_status")
        if state == "completed":
            try:
                self.assert_plan_current()
                expected = self.value.get("expected_files", {})
                changed = fingerprints(self.core.cwd, list(expected)) != expected
                if self.value.get("expected_workspace") is not None:
                    changed = changed or workspace_state(self.core.cwd) != self.value["expected_workspace"]
                if changed:
                    raise TaskStateError("Files changed after the final checks. Retry checks before completing this capsule.")
            except (ValueError, OSError) as exc:
                self.value.update(verification_status="pending", reason=str(exc))
                state, status = "paused", "pending"
        if state == "completed" and (self.value.get("uncertain_action") or self.value.get("pending_usage")):
            self.value["verification_status"] = status = "needs_review"
            self.value["reason"] = "An action or model call remains unsettled."
        if state == "completed" and status != "passed":
            state = "needs_review" if status != "failed" else "paused"
        if status == "needs_review" and self.value.get("stage") == "review":
            state = "needs_review"
        self.value["state"] = state
        self.store.save(self.value)
        self.settled = True
        if emit:
            self.emit()
