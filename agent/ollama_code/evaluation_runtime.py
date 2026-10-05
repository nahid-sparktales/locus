"""Feature-owned execution runtime for evaluation suites."""

from __future__ import annotations

import copy
import subprocess
import threading
import time
from pathlib import Path
from collections.abc import Callable
from typing import Any

from .chat_service import ChatService
from .core import AgentCore
from .evaluations import (
    EvaluationError,
    EvaluationStore,
    configuration_fingerprint,
    configuration_snapshot,
    grade_case,
    summarize_results,
)
from .orchestration import (
    GLOBAL_MODEL_SCHEDULER,
    TeamOrchestrator,
    parse_manifest,
)
from .proxy import sanitized_child_environment
from .worktrees import TaskCheckout, TaskCheckoutStore, WorktreeError

EvaluationTeamRunner = Callable[[ChatService, str, dict[str, Any]], None]


def _comparison_behavior(value: dict[str, Any], arm: bool | None) -> dict[str, Any]:
    behavior = copy.deepcopy(value)
    policy = behavior.setdefault("memory_policy", {})
    policy["proposals_enabled"] = False
    if arm is False:
        policy.update(recall_enabled=False, search_enabled=False, cross_chat_context_enabled=False)
    return behavior


def run_evaluation_suite(
    parent: ChatService,
    suite: dict[str, Any],
    manifest: dict[str, Any],
    manifests: dict[str, dict[str, Any]],
    evaluation_id: str,
    team_runner: EvaluationTeamRunner,
) -> dict[str, Any]:
    """Execute evaluation cases in disposable task checkouts.

    The source workspace is only read while each baseline is captured. The
    evaluation owns a separate AgentCore/session and never exposes Apply.
    """
    from .reusable_checks import ReusableCheckStore
    from .agent_profile_runtime import trusted_memory_agent
    parent_agent_id, parent_configuration = trusted_memory_agent(parent.core)
    frozen_checks = ReusableCheckStore(parent.run_store).freeze(suite["workspace_root"], suite["workspace_root"], agent_id=parent_agent_id)
    store = EvaluationStore(parent.run_store)
    paired = bool(suite.get("memory_comparison"))
    campaign_owner = "memory-campaign:" + str(suite["id"]) if paired else ""
    if paired:
        from .usage_ledger import UsageLedger
        # Persistent ownership prevents a retry/resume of this suite from resetting its
        # campaign allowance. Every tracked call (including reviews/compaction) shares it.
        UsageLedger(parent.run_store).set_limits(campaign_owner,
            {"max_tokens": int(suite.get("memory_campaign_token_limit") or 250_000),
             "max_estimated_usd": 10.0}, only_if_absent=True)
    baselines: dict[str, TaskCheckout] = {}
    parent.emit({
        "type": "evaluation_started", "evaluation_id": evaluation_id,
        "suite_id": suite["id"], "case_count": len(suite["cases"]) * int(suite.get("repetitions", 1)) * (2 if paired else 1),
    })
    parent.active_evaluation_id = evaluation_id
    cancelled = False
    run_ids: list[str] = []
    expected_cases = len(suite["cases"]) * int(suite.get("repetitions", 1)) * (2 if paired else 1)
    try:
        repeated = [(repetition, case, arm)
                    for repetition in range(int(suite.get("repetitions", 1)))
                    for case_index, case in enumerate(suite["cases"])
                    for arm in (((False, True) if (repetition + case_index) % 2 == 0 else (True, False))
                                if paired else (None,))]
        for index, (repetition, case, memory_arm) in enumerate(repeated):
            run_id = f"eval-{evaluation_id[:12]}-{index + 1}"
            task_id = run_id
            run_ids.append(run_id)
            # Admission precedes the result foreign key, including setup failures.
            parent.run_store.start_run(run_id, request=str(case["prompt"]), state="queued", workspace_root=str(suite["workspace_root"]), run_kind="evaluation")
            requested = str(case.get("team_id") or "")
            selected = manifests.get(requested) or (next(iter(manifests.values())) if not requested and len(manifests) == 1 else manifest)
            try:
                frozen = configuration_fingerprint(parent.core, case, selected, frozen_checks)
                result_id = store.start_result(str(suite["id"]), str(case["id"]), run_id, frozen)
            except Exception as exc:
                result_id = store.start_result(str(suite["id"]), str(case["id"]), run_id)
                parent.run_store.set_state(run_id, "failed")
                value = store.finish_result(result_id, {
                    "state": "failed", "execution_outcome": "failed", "grading_outcome": "ungraded",
                    "failure_category": "configuration", "error": str(exc),
                    "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None,
                    "memory_campaign_id": campaign_owner or None, "learning_enabled": False,
                    "repetition": repetition + 1})
                parent.emit({"type": "evaluation_case_completed", "evaluation_id": evaluation_id,
                             "suite_id": suite["id"], "case_id": case["id"], "run_id": run_id, "result": value})
                continue
            if parent.core._interrupt.is_set():
                parent.run_store.set_state(run_id, "interrupted")
                value = store.finish_result(result_id, {
                    "state": "interrupted", "execution_outcome": "interrupted", "grading_outcome": "ungraded",
                    "failure_category": "cancelled_before_start", "repetition": repetition + 1,
                    "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None,
                    "memory_campaign_id": campaign_owner or None, "learning_enabled": False})
                parent.emit({"type": "evaluation_case_completed", "evaluation_id": evaluation_id,
                             "suite_id": suite["id"], "case_id": case["id"], "run_id": run_id, "result": value})
                continue
            configuration = configuration_snapshot(parent.core, case, selected)
            started = time.monotonic()
            admission_started = time.time()
            parent.emit({
                "type": "evaluation_case_started", "evaluation_id": evaluation_id,
                "suite_id": suite["id"], "case_id": case["id"],
                "case_index": index, "run_id": run_id,
                "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None,
            })
            evaluation_core: AgentCore | None = None
            timeout_timer: threading.Timer | None = None
            timed_out = threading.Event()
            succeeded = False
            grade = {}
            try:
                fixture = case.get("baseline_fixture")
                fixture_id = (
                    str(fixture.get("task_id") or "")
                    if isinstance(fixture, dict) else ""
                )
                fixture_task = (TaskCheckoutStore.load(fixture_id) if fixture_id else
                                baselines.get(str(case["id"])) if paired else None)
                if fixture is not None and (fixture_task is None or
                        Path(fixture_task.workspace_root).resolve() != Path(suite["workspace_root"]).resolve()):
                    raise EvaluationError("saved evaluation baseline is missing or belongs to another workspace")
                task = (
                    TaskCheckoutStore.replay(fixture_task, task_id)
                    if fixture_task is not None
                    else TaskCheckoutStore.create(str(suite["workspace_root"]), task_id)
                )
                if paired:
                    baselines.setdefault(str(case["id"]), task)
                task.state = "running"
                task.save()
                evaluation_core = AgentCore(
                    model=parent.core.model,
                    cwd=task.execution_path,
                    skip_permissions=True,
                    config=copy.deepcopy(parent.core.config),
                )
                evaluation_core.memory_evaluation_disabled = True
                evaluation_core.memory_comparison_arm = memory_arm
                evaluation_core.configure_agent(
                    _comparison_behavior(parent_configuration.structured(), memory_arm),
                    agent_id=parent_agent_id)
                if paired:
                    evaluation_core.usage_owner_task_id = campaign_owner
                # Evaluations observe memory; they must not become new learning evidence.
                evaluation_core.memory_evaluation_disabled = True
                evaluation_core.tool_ctx.memory_proposals_enabled = False
                parent.active_evaluation_core = evaluation_core
                evaluation_core.tool_registry.computer_enabled = False
                # A browser reaches further than computer control does, and a
                # suite that can wander the web is not a fixture any more.
                evaluation_core.tool_registry.browser_enabled = False
                evaluation_core.tool_registry.notes_enabled = False
                evaluation_core.tool_registry.calendar_enabled = False
                evaluation_core.tool_registry.board_enabled = False
                read_only = str(case.get("mode") or "write") == "read_only"
                evaluation_core.evaluation_read_only = read_only
                evaluation_core.tool_registry.set_mcp_agent_policy(
                    {},
                    access_ceiling="read_only" if read_only else "workspace_write",
                    role="evaluation",
                )
                evaluation_service = ChatService(evaluation_core)
                evaluation_service.evaluation_frozen_checks = frozen_checks
                # Evaluations in a dedicated worker share that worker's
                # authenticated proxy; they never launch another App Server.
                evaluation_service.close_codex()
                evaluation_service.codex = parent.codex
                evaluation_service.core.codex_manager = parent.core.codex_manager if parent.core.provider == "claude_plan" else parent.codex
                evaluation_service.claude_for = parent.claude_for
                from .orchestration import configure_claude_manager
                configure_claude_manager(parent.claude_for)
                evaluation_service.run_store = parent.run_store
                evaluation_service.core.usage_store = parent.run_store
                evaluation_service.core.mcp.task_store = parent.run_store
                evaluation_service.current_task = task
                # The per-case service records this case's turn_done spend into
                # the shared store; without the flag those rows land as the
                # user's own "solo" usage on the dashboard.
                evaluation_service.active_evaluation_id = evaluation_id
                evaluation_service.core.enter_task_checkout(
                    task.execution_path, task.workspace_root, task.as_dict(),
                )
                requested_team = str(case.get("team_id") or "")
                selected_manifest = manifests.get(requested_team)
                if selected_manifest is None and not requested_team and len(manifests) == 1:
                    selected_manifest = next(iter(manifests.values()))
                case_manifest = dict(selected_manifest or manifest)
                case_manifest["run_id"] = run_id
                team_value = dict(case_manifest.get("team") or {})
                team_value["use_managed_worktree"] = True
                if isinstance(case.get("budget"), dict):
                    team_value["budget"] = dict(case["budget"])
                case_manifest["team"] = team_value
                # Evaluation tools are local-only: computer control and
                # mutating MCP access stay absent even when a profile normally
                # allows them. A read-only suite may retain explicit MCP
                # allowlists, which are still annotation-gated by the runtime.
                profile_values = []
                for raw_profile in case_manifest.get("profiles") or []:
                    profile_value = dict(raw_profile)
                    profile_value["behavior"] = _comparison_behavior(
                        profile_value.get("behavior") or {}, memory_arm)
                    if not (read_only and suite.get("read_only_mcp")):
                        profile_value["mcp_policy"] = {}
                    profile_values.append(profile_value)
                if profile_values:
                    case_manifest["profiles"] = profile_values
                target = str(case.get("target") or "team")
                configuration = configuration_snapshot(evaluation_core, case, case_manifest)
                timeout_seconds = int(case.get("timeout_seconds") or 1_800)

                def timeout_case(
                    timeout_event: threading.Event = timed_out,
                    case_core: AgentCore = evaluation_core,
                ) -> None:
                    timeout_event.set()
                    case_core.interrupt()

                timeout_timer = threading.Timer(timeout_seconds, timeout_case)
                timeout_timer.daemon = True
                timeout_timer.start()
                setup_ms = max(int((time.monotonic() - started) * 1000), 0)
                execution_started = time.monotonic()
                queue_ms = 0
                if target == "solo":
                    parent.run_store.start_run(
                        run_id,
                        session_id=evaluation_core.session.session_id,
                        workspace_root=task.workspace_root,
                        execution_path=task.execution_path,
                        task_id=task.id,
                        request=str(case["prompt"]),
                        state="running",
                        run_kind="evaluation",
                        execution_environment="worktree",
                        manifest={"memory_agent_id": evaluation_core.agent_id,
                                  "memory_policy": evaluation_core.agent_configuration.structured()["memory_policy"],
                                  "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None},
                    )
                    evaluation_service.active_run_id = run_id
                    from .task_journal import TaskJournal
                    evaluation_core.task_journal = TaskJournal.bind(parent.run_store, parent.run_store.run(run_id))
                    if frozen_checks:
                        from .reusable_check_runtime import RunChecks
                        evaluation_service.reusable_run_checks = RunChecks(evaluation_service, run_id, str(case["prompt"]), frozen=frozen_checks)
                        evaluation_core.before_finalize = evaluation_service.reusable_run_checks.before_finalize
                    evaluation_core.tool_ctx.memory_run_id = run_id
                    evaluation_core.client = parent.core.client
                    evaluation_core.provider = parent.core.provider
                    evaluation_core.host = parent.core.host
                    evaluation_core.model = parent.core.model
                    budget = case.get("budget") if isinstance(case.get("budget"), dict) else {}
                    evaluation_core.max_iterations = min(
                        evaluation_core.max_iterations,
                        int(budget.get("max_model_calls") or evaluation_core.max_iterations),
                    )
                    parent.emit({
                        "type": "scheduler_lease_waiting", "run_id": run_id,
                        "agent_id": "solo-evaluation",
                        "active_leases": GLOBAL_MODEL_SCHEDULER.active_count,
                    })
                    queued_at = time.monotonic()
                    with GLOBAL_MODEL_SCHEDULER.lease(
                        run_id, evaluation_core._should_stop_stream,
                    ) as lease_id:
                        queue_ms = max(int((time.monotonic() - queued_at) * 1000), 0)
                        parent.emit({
                            "type": "scheduler_lease_acquired", "run_id": run_id,
                            "agent_id": "solo-evaluation", "lease_id": lease_id,
                            "active_leases": GLOBAL_MODEL_SCHEDULER.active_count,
                        })
                        heartbeat_stop = threading.Event()

                        def heartbeat(stop_event: threading.Event = heartbeat_stop) -> None:
                            while not stop_event.wait(10):
                                if not GLOBAL_MODEL_SCHEDULER.heartbeat(lease_id):
                                    return

                        heartbeat_thread = threading.Thread(
                            target=heartbeat, name="locus-evaluation-lease", daemon=True,
                        )
                        heartbeat_thread.start()
                        try:
                            from .server import _automatic_memory_context
                            evaluation_core.memory_context = _automatic_memory_context(
                                evaluation_core, str(case["prompt"]),
                                evaluation_core.agent_configuration,
                                just_chat=False, agent_id=evaluation_core.agent_id,
                            )
                            evaluation_core.run_turn(
                                str(case["prompt"]), lambda *_: "deny", allow_tools=True,
                            )
                        finally:
                            heartbeat_stop.set()
                            parent.emit({
                                "type": "scheduler_lease_released", "run_id": run_id,
                                "agent_id": "solo-evaluation", "lease_id": lease_id,
                            })
                    solo_reason = str(evaluation_core.last_turn_result.get("reason") or "")
                    if frozen_checks and evaluation_service.reusable_run_checks.tasks.completion("run:" + run_id)[0] not in {"passed", "not_applicable", "accepted"}:
                        solo_reason = "verification_failed"
                    parent.run_store.set_state(
                        run_id,
                        "completed" if solo_reason == "complete" else "interrupted" if solo_reason in {"interrupted", "cancelled"} else "failed",
                    )
                    evaluation_service.active_run_id = None
                else:
                    team_runner(evaluation_service, str(case["prompt"]), case_manifest)
                if paired:
                    from .usage_ledger import UsageLedger, UsageLimitError
                    refused = UsageLedger(parent.run_store).refusals(campaign_owner, since=admission_started)
                    if refused:
                        # Provider errors may have been caught inside any team/helper core.
                        # A refused call still makes this arm ineligible for comparison.
                        raise UsageLimitError(refused[0]["reason"], category=refused[0]["category"])
                run = parent.run_store.run(run_id) or {}
                verification_started = time.monotonic()
                patch_text, current_tree = task.patch()
                changed = _evaluation_changed_paths(task, current_tree)
                output = next((
                    str(message.get("content") or "")
                    for message in reversed(evaluation_core.messages)
                    if message.get("role") == "assistant"
                ), "")
                grade = grade_case(case, task.execution_path, output, changed)
                succeeded = str(run.get("state") or "") == "completed"
                rubric_result: dict[str, Any] | None = None
                if succeeded and not timed_out.is_set() and grade["deterministic_passed"] and str(case.get("rubric") or "").strip():
                    judge_id = str(case.get("judge_profile_id") or "")
                    if judge_id and case_manifest.get("profiles"):
                        _, judge_team, judge_profiles, _ = parse_manifest(case_manifest)
                        judge = judge_profiles.get(judge_id)
                        if judge is None or judge.role != "reviewer":
                            raise EvaluationError(
                                "the evaluation judge must be an eligible reviewer profile"
                            )
                        judge_runner = TeamOrchestrator(parent.emit,
                            evaluation_core._should_stop_stream, run_store=parent.run_store)
                        from .model_usage import context_for
                        judge_runner.usage_context = context_for(evaluation_core, "review")
                        rubric_result = judge_runner.evaluate_rubric(run_id, judge, judge_team.budget,
                            case=case, output=output, diff_text=patch_text, evidence=grade)
                if paired:
                    from .usage_ledger import UsageLedger, UsageLimitError
                    refused = UsageLedger(parent.run_store).refusals(campaign_owner, since=admission_started)
                    if refused:
                        raise UsageLimitError(refused[0]["reason"], category=refused[0]["category"])
                rubric_required = bool(str(case.get("rubric") or "").strip())
                ungraded = rubric_required and rubric_result is None
                rubric_passed = (not rubric_required) or (rubric_result is not None and (
                    float(rubric_result["score"]) >= float(case.get("passing_score") or 80)
                ))
                passed = (
                    not timed_out.is_set()
                    and succeeded
                    and bool(grade["deterministic_passed"])
                    and rubric_passed
                )
                usage = run.get("usage") if isinstance(run.get("usage"), dict) else {}
                from .task_journal import TaskJournal
                from .task_usage_ledger import UsageLedger as TaskUsageLedger
                task_accounting = TaskUsageLedger(TaskJournal.for_owner(parent.run_store, "run:" + run_id)).summary()
                model_calls = int(
                    usage.get("model_calls")
                    or evaluation_core.last_turn_result.get("model_calls")
                    or 0
                )
                from .usage_ledger import UsageLedger
                accounting = UsageLedger(parent.run_store).summary(run_id=run_id)
                outcome = "timed_out" if timed_out.is_set() else "interrupted" if parent.core._interrupt.is_set() or run.get("state") == "interrupted" else "budget_exhausted" if evaluation_core.last_turn_result.get("reason") in {"max_iterations", "budget_exhausted", "model_call_limit"} else "completed" if succeeded else "failed"
                state = "ungraded" if outcome == "completed" and rubric_required and rubric_result is None else "passed" if passed else "failed" if outcome == "completed" else outcome
                value = store.finish_result(result_id, {
                    "state": state, "execution_outcome": outcome, "repetition": repetition + 1,
                    "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None,
                    "memory_campaign_id": campaign_owner or None, "learning_enabled": False,
                    "rubric_required": rubric_required,
                    "setup_ms": setup_ms, "queue_ms": queue_ms,
                    "execution_ms": max(int((verification_started - execution_started) * 1000) - queue_ms, 0),
                    "verification_ms": max(int((time.monotonic() - verification_started) * 1000), 0),
                    "environment": {"platform": __import__("platform").platform(), "python": __import__("sys").version.split()[0], "baseline_tree": getattr(task, "baseline_tree", ""), "runtime_protocol": 1},
                    "accounting": accounting,
                    "estimated_api_cost": accounting["estimated_api_cost"], "cost_coverage": accounting["cost_coverage"],
                    "grading_outcome": "ungraded" if ungraded else "passed" if passed else "failed",
                    "configuration": configuration,
                    **grade,
                    "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
                    "model_calls": model_calls,
                    "prompt_tokens": evaluation_core.total_prompt_tokens,
                    "completion_tokens": evaluation_core.total_completion_tokens,
                    "estimated_cost": accounting["estimated_api_cost"],
                    "known_cost_subtotal": task_accounting["known_subtotal"], "usage_accounting": task_accounting, "judging": rubric_result,
                    "output": output,
                    "rubric_score": rubric_result["score"] if rubric_result else None,
                    "rubric_reason": rubric_result["reason"] if rubric_result else "",
                    "rubric_subjective": bool(rubric_result),
                    "patch_bytes": len(patch_text.encode("utf-8", errors="surrogateescape")),
                    "task_id": task_id,
                    "target": target,
                    "team_id": str(
                        case.get("team_id")
                        or (case_manifest.get("team") or {}).get("id")
                        or ""
                    ),
                    "retries": sum(
                        max(int(attempt.get("attempt") or 1) - 1, 0)
                        for attempt in run.get("attempts") or []
                    ),
                    "failure_category": "" if passed else (
                        "missing_judgment" if state == "ungraded" else
                        "timeout" if timed_out.is_set() else
                        "budget_exhausted" if outcome == "budget_exhausted" else
                        "provider_or_runtime" if not succeeded else
                        "deterministic_assertion" if not grade["deterministic_passed"] else
                        "ungraded" if ungraded else "subjective_rubric"
                    ),
                })
                if target == "team" and case_manifest.get("profiles"):
                    _, _, evaluation_profiles, _ = parse_manifest(case_manifest)
                    quality = float(
                        rubric_result["score"] if rubric_result else (100 if passed else 0)
                    )
                    for attempt in run.get("attempts") or []:
                        agent = evaluation_profiles.get(str(attempt.get("agent_id") or ""))
                        result = attempt.get("result") if isinstance(attempt.get("result"), dict) else {}
                        if agent is None:
                            continue
                        estimated_cost = (
                            int(result.get("prompt_tokens") or 0) * agent.input_cost_per_million
                            + int(result.get("completion_tokens") or 0)
                            * agent.output_cost_per_million
                        ) / 1_000_000
                        parent.run_store.record_routing_sample(
                            agent.id,
                            tags=[str(item) for item in case.get("tags") or []],
                            quality=quality,
                            reliable=succeeded and not bool(result.get("error")),
                            latency_ms=int(result.get("elapsed_ms") or value["duration_ms"]),
                            estimated_cost=estimated_cost,
                            local=agent.route.get("provider") == "ollama",
                            evaluation=True,
                        )
                parent.emit({
                    "type": "evaluation_case_completed",
                    "evaluation_id": evaluation_id,
                    "suite_id": suite["id"], "case_id": case["id"],
                    "run_id": run_id, "result": value,
                })
            except Exception as exc:
                from .usage_ledger import UsageLimitError
                refusal = isinstance(exc, UsageLimitError) and paired
                refusal_category = str(getattr(exc, "category", "budget_exhausted")) if refusal else ""
                if not succeeded:
                    parent.run_store.set_state(run_id, "failed")
                failed_run = parent.run_store.run(run_id) or {}
                failed_usage = failed_run.get("usage") or {}
                from .task_journal import TaskJournal
                from .task_usage_ledger import UsageLedger
                accounting = UsageLedger(TaskJournal.for_owner(parent.run_store, "run:" + run_id)).summary()
                judging_accounting = UsageLedger(TaskJournal.for_owner(parent.run_store, "run:" + run_id + ":judge")).summary()
                value = store.finish_result(result_id, {
                    "state": "skipped" if refusal else "ungraded" if succeeded else "failed", "error": str(exc),
                    "memory_arm": "on" if memory_arm else "off" if memory_arm is False else None,
                    "memory_campaign_id": campaign_owner or None, "learning_enabled": False,
                    "execution_outcome": "skipped" if refusal else "completed" if succeeded else "failed",
                    "grading_outcome": "ungraded", "repetition": repetition + 1, **grade,
                    "configuration": configuration,
                    "estimated_cost": None,
                    "known_cost_subtotal": accounting["known_subtotal"], "usage_accounting": accounting,
                    "cost_coverage": accounting["coverage"], "judging_usage_accounting": judging_accounting,
                    "model_calls": failed_usage.get("model_calls", 0),
                    "prompt_tokens": evaluation_core.total_prompt_tokens if evaluation_core else 0,
                    "completion_tokens": evaluation_core.total_completion_tokens if evaluation_core else 0,
                    "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
                    "target": str(case.get("target") or "team"),
                    "team_id": str(case.get("team_id") or ""),
                    "failure_category": refusal_category or ("timeout" if timed_out.is_set() else "runtime"),
                    "skip_category": refusal_category or None,
                })
                parent.emit({
                    "type": "evaluation_case_completed", "evaluation_id": evaluation_id,
                    "suite_id": suite["id"], "case_id": case["id"],
                    "run_id": run_id, "result": value,
                })
            finally:
                current_run = parent.run_store.run(run_id) or {}
                if current_run.get("state") in {"queued", "running", "dispatching"}:
                    parent.run_store.set_state(run_id, "interrupted" if parent.core._interrupt.is_set() else "failed")
                if timeout_timer is not None:
                    timeout_timer.cancel()
                    # cancel() does not stop an already-running callback. Wait for its
                    # interrupt before latching cancellation and closing this core.
                    timeout_timer.join()
                cancelled = cancelled or parent.core._interrupt.is_set() or bool(
                    evaluation_core is not None and evaluation_core._interrupt.is_set())
                parent.active_evaluation_core = None
                if evaluation_core is not None:
                    evaluation_core.close()
    finally:
        cancelled = cancelled or parent.core._interrupt.is_set() or bool(
            parent.active_evaluation_core is not None and parent.active_evaluation_core._interrupt.is_set())
        parent.active_evaluation_id = None
        parent.active_evaluation_core = None
        parent.core._interrupt.clear()
    campaign_results = [result for result in store.results(str(suite["id"]))
                        if result.get("run_id") in run_ids]
    result = {"cancelled": cancelled, "expected_cases": expected_cases,
              "actual_cases": len(campaign_results), "results": campaign_results,
              "memory_comparison": paired}
    incomplete = sorted({str(row.get("failure_category") or "ungraded_case")
                         for row in campaign_results
                         if row.get("execution_outcome") != "completed"
                         or row.get("grading_outcome") not in {"passed", "failed"}})
    if cancelled:
        incomplete.append("cancelled")
    if len(campaign_results) != expected_cases:
        incomplete.append("missing_cases")
    if paired:
        from .usage_ledger import UsageLedger
        result["campaign_usage"] = UsageLedger(parent.run_store).summary(task_id=campaign_owner)
        result["paired_outcomes"] = {
            arm: {"passed": sum(row.get("state") == "passed" for row in campaign_results
                                if row.get("memory_arm") == arm),
                  "total": sum(row.get("memory_arm") == arm for row in campaign_results),
                  "graded": sum(row.get("memory_arm") == arm and row.get("grading_outcome") in {"passed", "failed"}
                                and row.get("execution_outcome") == "completed" for row in campaign_results),
                  "skipped": sum(row.get("memory_arm") == arm and row.get("state") == "skipped" for row in campaign_results)}
            for arm in ("on", "off")}
        if result["campaign_usage"]["uncertain_calls"] or result["campaign_usage"]["pending_calls"]:
            incomplete.append("unsettled_usage")
    result["complete"] = not incomplete
    result["incomplete_reason"] = ", ".join(sorted(set(incomplete))) or None
    parent.emit({
        "type": "evaluation_completed", "evaluation_id": evaluation_id,
        "suite_id": suite["id"], "summary": summarize_results(campaign_results),
        "state": "interrupted" if cancelled else "completed" if result["complete"] else "incomplete",
        **{key: value for key, value in result.items() if key != "results"},
    })
    return result


def _evaluation_changed_paths(task: TaskCheckout, current_tree: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", task.baseline_tree, current_tree, "--"],
        cwd=task.execution_path, env=sanitized_child_environment(),
        capture_output=True, timeout=120, check=False,
    )
    if result.returncode != 0:
        raise WorktreeError(result.stderr.decode("utf-8", errors="replace").strip())
    return [
        item.decode("utf-8", errors="replace")
        for item in result.stdout.split(b"\0") if item
    ]


__all__ = ["EvaluationTeamRunner", "run_evaluation_suite"]
