"""Execution-scoped goal authority shared by a coordinator and its workers.

The durable store owns transitions. This adapter never creates a goal, never
claims a continuation, and never gives child agents authority to finish one.
"""
from __future__ import annotations

import json
import re
import threading
import time
import uuid
from typing import Any

from .goals import GoalBudgetExceeded, GoalError, GoalStore
from .task_state import CHECK_SCHEMA, TaskStateStore, TaskVerifier, normalize_checks

GOAL_CONTRACT = (
    "This task has an explicitly enabled persistent goal. Call get_goal to read "
    "its objective, saved progress and remaining budgets. Continue useful work toward "
    "that objective. Before ending, call update_goal with continue and a concrete "
    "next_step, complete only with evidence that every requirement was verified, or "
    "blocked with the specific external blocker. A final answer alone does not "
    "complete the goal. Supply acceptance_checks when reporting complete: each needs id, kind, "
    "requirement and its file path/value or command. Supported kinds are file_exists, file_contains, "
    "json_value, command and human_review. Locus runs these checks through existing permissions. "
    "Prose is not proof; uncheckable requirements need human_review. Never claim completion just because a budget is nearly "
    "exhausted. User steering preserves the objective unless the user changes it."
)

GOAL_TOOL_SCHEMAS = [
    {"type": "function", "function": {
        "name": "get_goal", "description": "Read this task's explicitly enabled persistent goal and remaining budgets.",
        "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
    }},
    {"type": "function", "function": {
        "name": "update_goal", "description": "Record verified goal progress; completion is committed only after all work has settled.",
        "parameters": {"type": "object", "properties": {
            "status": {"type": "string", "enum": ["continue", "complete", "blocked"]},
            "summary": {"type": "string"},
            "evidence": {"type": "array", "items": {"type": "string"}},
            "next_step": {"type": "string"}, "blocker": {"type": "string"},
            "acceptance_checks": {"type": "array", "items": CHECK_SCHEMA},
        }, "required": ["status", "summary", "evidence"], "additionalProperties": False},
    }},
]
GOAL_TOOL_NAMES = frozenset({"get_goal", "update_goal"})


def validate_goal_report(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) - {"status", "summary", "evidence", "next_step", "blocker", "acceptance_checks"}:
        raise GoalError("The goal report must contain only status, summary, evidence, next_step and blocker.")
    if value.get("status") not in {"continue", "complete", "blocked"}:
        raise GoalError("The goal report has an invalid status.")
    for key in ("summary",):
        if not isinstance(value.get(key), str) or not value[key].strip():
            raise GoalError(f"The goal report needs a nonempty {key}.")
    evidence = value.get("evidence")
    if not isinstance(evidence, list) or len(evidence) > 64 or any(
        not isinstance(item, str) or not item.strip() or len(item) > 8_000 for item in evidence
    ):
        raise GoalError("Goal evidence must be a bounded list of nonempty strings.")
    required = {"continue": "next_step", "blocked": "blocker"}.get(value["status"])
    for key in ("next_step", "blocker"):
        if key in value and (not isinstance(value[key], str) or len(value[key]) > 16_000):
            raise GoalError(f"Goal {key} must be a bounded string.")
    if required and not str(value.get(required) or "").strip():
        raise GoalError(f"Goal {value['status']} requires {required}.")
    if value["status"] == "complete" and not evidence:
        raise GoalError("Goal completion requires verification evidence.")
    if len(value["summary"]) > 16_000:
        raise GoalError("The goal summary is too long.")
    if "acceptance_checks" in value:
        normalize_checks(value["acceptance_checks"])
    return {"status": value["status"], "summary": value["summary"].strip(),
            "evidence": list(evidence), "next_step": value.get("next_step", "").strip(),
            "blocker": value.get("blocker", "").strip()}


class GoalRuntime:
    def __init__(self, store: GoalStore, goal: dict[str, Any], run_id: str, *, emit=None):
        self.store, self.goal_id, self.run_id = store, str(goal["id"]), run_id
        self.revision = int(goal.get("run_revision", goal["revision"]))
        self.emit = emit or (lambda _event: None)
        self.stop_reason = ""
        self._guard = threading.RLock()
        self._finished: dict[str, Any] | None = None
        self._checked_at = 0.0
        self._control_stopped = False
        self._native_baselines: dict[str, tuple[int, int]] = {}
        self._waits: dict[str, str] = {}
        self._invalid_report = False
        self.core = None
        self.verification_decider = None

    def should_stop(self) -> bool:
        # Streaming callbacks can run once per token. Poll user controls at a
        # bounded cadence; admission and writes still validate transactionally.
        with self._guard:
            now = time.monotonic()
            if now - self._checked_at >= 0.2:
                self._checked_at = now
                goal = self.snapshot()
                # Queuing user input invalidates reports, but an in-flight
                # provider request must settle normally. Only execution
                # controls (pause/edit/cancel/resume) revoke its authority.
                self._control_stopped = (goal.get("status") != "active"
                                         or int(goal.get("execution_revision", goal["revision"])) > self.revision)
            return self._control_stopped or self.stop_reason in {
                "limit_reached", "goal_unavailable", "waiting_input", "invalid_goal_report",
                "usage_unavailable",
            }

    def snapshot(self) -> dict[str, Any]:
        goal = self.store.get(self.goal_id)
        if not goal:
            raise GoalError("The persistent goal is no longer available.")
        return goal

    def tool(self, name: str, arguments: dict[str, Any]) -> str:
        try:
            if name == "get_goal":
                if arguments:
                    raise GoalError("get_goal accepts no arguments.")
                return json.dumps(self.snapshot(), ensure_ascii=False)
            if name != "update_goal":
                raise GoalError("Unknown goal tool.")
            goal = self.submit_report(arguments)
            stale = int(goal["revision"]) != self.revision
            return json.dumps({"ok": not stale, "goal": goal, "message": (
                "New user input changed the goal's report revision. This report was discarded; the queued turn will reconsider completion."
                if stale else "Progress saved; final status is checked at the run boundary."
            )}, ensure_ascii=False)
        except (GoalError, ValueError, TypeError) as error:
            if name == "update_goal":
                self._invalid_report = True
            return f"Error: {error}"

    def submit_report(self, value: Any) -> dict[str, Any]:
        report = validate_goal_report(value)
        if self.core is not None and report["status"] != "complete" and "acceptance_checks" in value:
            state_store = TaskStateStore(self.store.run_store)
            saved = state_store.get("goal:" + self.goal_id)
            if saved and saved["revision"] == self.revision:
                incoming = normalize_checks(value["acceptance_checks"])
                by_id = {c["id"]: c for c in incoming}
                for prior in saved.get("checks", []) if saved.get("checks_revision") == self.revision else []:
                    if prior["id"] in by_id and by_id[prior["id"]] != prior:
                        raise ValueError("Revise the goal before replacing a declared acceptance check.")
                    if prior["id"] not in by_id:
                        incoming.append(prior)
                saved.update(checks=incoming, checks_revision=self.revision)
                state_store.save(saved, expected_revision=self.revision)
        if self.core is not None and report["status"] == "complete" and self.snapshot()["revision"] == self.revision:
            state_store = TaskStateStore(self.store.run_store)
            saved = state_store.get("goal:" + self.goal_id) or {}
            checks = value.get("acceptance_checks", saved.get("checks", []))
            checked = TaskVerifier(state_store, "goal:" + self.goal_id, self.core, self.run_id).verify(
                checks, self.verification_decider, fallback=self.snapshot()["objective"])
            if checked["verification_status"] == "failed":
                report.update(status="continue", next_step="Repair the failing acceptance checks: " + checked["verification_reason"])
        try:
            goal = self.store.report(self.goal_id, self.run_id, self.revision, **report)
        except GoalError:
            goal = self.snapshot()
            if not (goal.get("status") == "active" and int(goal["revision"]) != self.revision
                    and int(goal.get("execution_revision", goal["revision"])) <= self.revision):
                raise
            # A queued direction supersedes this run's proposal without making
            # its already-settled execution an invalid-report failure.
        self._invalid_report = False
        self.emit({"type": "goal_snapshot", "goal": goal})
        return goal

    def reserve(self) -> str:
        if self.stop_reason:
            raise GoalError("The goal needs attention before another model request.")
        identifier = uuid.uuid4().hex
        try:
            self.store.reserve_usage(self.goal_id, self.run_id, identifier)
        except GoalBudgetExceeded:
            self.stop_reason = "limit_reached"
            raise
        except GoalError:
            self.stop_reason = "goal_unavailable"
            raise
        return identifier

    def settle(self, identifier: str, response: Any = None, *, model_calls: int = 1,
               prompt_tokens: int | None = None, completion_tokens: int | None = None,
               tokens_known: bool = True, model_calls_known: bool = True) -> None:
        if response is not None and not (getattr(response, "prompt_eval_count", 0) or getattr(response, "eval_count", 0)):
            tokens_known = False
        self.store.settle_usage(self.goal_id, self.run_id, identifier,
            model_calls=max(model_calls, 1),
            prompt_tokens=max(int(prompt_tokens if prompt_tokens is not None else getattr(response, "prompt_eval_count", 0)), 0),
            completion_tokens=max(int(completion_tokens if completion_tokens is not None else getattr(response, "eval_count", 0)), 0),
            tokens_known=tokens_known, model_calls_known=model_calls_known)
        if not tokens_known or not model_calls_known:
            current = self.snapshot()
            if (not tokens_known and current.get("token_budget") is not None
                    or not model_calls_known and current.get("model_call_budget") is not None):
                self.stop_reason = "usage_unavailable"

    def start_action(self, identifier: str, tool: str) -> None:
        self.store.start_action(self.goal_id, self.run_id, identifier, tool=tool)

    def finish_action(self, identifier: str, *, ok: bool, result: str = "") -> None:
        if not ok and re.search(r"timed?\s*out|timeout|disconnected|connection (?:lost|closed)|unconfirmed|uncertain", result, re.IGNORECASE):
            # Native brokers and command tools return some transport failures
            # as text. A timeout does not prove the mutation did not happen.
            self.stop_reason = "goal_unavailable"
            return
        self.store.finish_action(self.goal_id, self.run_id, identifier, ok=ok)

    def begin_wait(self, identifier: str, kind: str) -> None:
        marker = f"wait:{kind}:{identifier}"
        self.start_action(marker, f"waiting_for_{kind}")
        self._waits[identifier] = marker

    def end_wait(self, identifier: str) -> None:
        marker = self._waits.pop(identifier, None)
        if marker:
            self.finish_action(marker, ok=True)

    def finish(self, reason: str) -> dict[str, Any]:
        with self._guard:
            if self._finished is None:
                if self._invalid_report and not self.stop_reason:
                    self.stop_reason = "invalid_goal_report"
                self._finished = self.store.reconcile_run(self.goal_id, self.run_id,
                    outcome=reason, reason=self.stop_reason)
            return self._finished

    def run_native(self, call, *, usage_baseline: tuple[int, int] = (0, 0), **kwargs):
        """Meter one native request, including its incremental internal calls.

        Native helpers report model-call usage after the call. Keep the request
        reservation open until transport completion so a crash cannot erase an
        unknown in-flight request or silently resume it.
        """
        identifier = self.reserve()
        thread_id = str(kwargs.get("thread_id") or "")
        with self._guard:
            baseline = self._native_baselines.get(thread_id, usage_baseline)
        counts = {"model_calls": 0, "prompt_tokens": 0, "completion_tokens": 0}
        observed: set[tuple[int, int]] = set()
        last_total = baseline
        known_usage = False
        original = kwargs.get("event_handler")
        original_stop = kwargs.get("should_interrupt")
        kwargs["should_interrupt"] = lambda: self.should_stop() or bool(original_stop and original_stop())
        def observe(event):
            nonlocal last_total, baseline, known_usage
            if event.get("method") == "thread/tokenUsage/updated":
                usage = (event.get("params") or {}).get("tokenUsage") or {}
                total = usage.get("total") or {}
                current_total = (max(int(total.get("inputTokens") or 0), 0),
                                 max(int(total.get("outputTokens") or 0), 0))
                if any(current_total) and current_total not in observed:
                    observed.add(current_total)
                    # A first lower total is the helper's existing compaction
                    # convention. Later lower totals may be replayed events;
                    # retaining the high-water mark prevents rebilling.
                    if not known_usage and (current_total[0] < baseline[0] or current_total[1] < baseline[1]):
                        baseline = (0, 0)
                        last_total = (0, 0)
                    if current_total[0] >= last_total[0] and current_total[1] >= last_total[1]:
                        delta = (current_total[0] - last_total[0], current_total[1] - last_total[1])
                        if any(delta):
                            counts["model_calls"] += 1
                        last_total = current_total
                        known_usage = True
                        counts["prompt_tokens"] = max(current_total[0] - baseline[0], 0)
                        counts["completion_tokens"] = max(current_total[1] - baseline[1], 0)
                        self.store.checkpoint_usage(self.goal_id, self.run_id, identifier,
                            **{**counts, "model_calls": max(counts["model_calls"], 1)})
                        current = self.snapshot()
                        call_budget, token_budget = current.get("model_call_budget"), current.get("token_budget")
                        if ((call_budget is not None and current["model_calls"] >= call_budget)
                                or (token_budget is not None and current["prompt_tokens"] + current["completion_tokens"] >= token_budget)):
                            self.stop_reason = "limit_reached"
            if original:
                original(event)
        kwargs["event_handler"] = observe
        result = call(**kwargs)
        if known_usage and (counts["prompt_tokens"] or counts["completion_tokens"]):
            self.settle(identifier, **counts)
            with self._guard:
                self._native_baselines[thread_id] = last_total
        else:
            # Transport completion is known; absent usage is not zero usage.
            # Only a corresponding explicit allowance requires a pause.
            self.settle(identifier, tokens_known=False, model_calls_known=False)
        return result



def bind_goal_runtime(service: Any, run_id: str, *, coordinator: bool = True,
                      mode: str = "work", excluded: bool = False) -> GoalRuntime | None:
    """Bind only a persisted goal/run link; a model can never opt itself in."""
    record = service.run_store.run(run_id) or {}
    manifest = record.get("manifest") or {}
    if not manifest.get("goal_id"):
        return None
    store = GoalStore(service.run_store)
    goal = store.for_run(run_id)
    if not goal:
        raise GoalError("This run has no trusted goal admission.")
    # Register a failure boundary before validating the executor. If a saved
    # route cannot bind, its durable goal must stop rather than retain an
    # unreconciled run forever. Tools are installed only after validation.
    runtime = GoalRuntime(store, {**goal, "run_revision": int(manifest.get("goal_revision") or 0)},
                          run_id, emit=service.emit)
    service.goal_runtime = runtime
    runtime.stop_reason = "goal_unavailable"
    if (excluded or mode not in {"work", "build"} or record.get("schedule_id")
            or any(manifest.get(key) for key in ("capsule", "capsule_context", "event_delivery_id", "workflow_execution_id"))):
        raise GoalError("Persistent goals require an ordinary Work task.")
    if goal["session_id"] != service.core.session.session_id:
        raise GoalError("This goal belongs to a different chat.")
    store.bind(str(goal["id"]), run_id, int(manifest.get("goal_revision") or 0))
    runtime.stop_reason = ""
    attach_goal_runtime(service.core, runtime, coordinator=coordinator)
    return runtime


def attach_goal_runtime(core: Any, runtime: GoalRuntime | None, *, coordinator: bool = False) -> None:
    core.goal_runtime = runtime
    if runtime is not None:
        runtime.core = core
        goal = runtime.snapshot()
        TaskStateStore(runtime.store.run_store).ensure("goal:" + runtime.goal_id,
            request=goal["objective"], revision=runtime.revision,
            workspace=core.workspace_root, execution=core.cwd, session_id=core.session.session_id,
            plan=core.tool_ctx.plan_document)
    core.tool_ctx.goal = runtime.tool if runtime is not None and coordinator else None
    core.tool_registry.goal_enabled = runtime is not None and coordinator
