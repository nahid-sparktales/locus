"""Feature-owned execution runtime for evaluation suites."""

from __future__ import annotations

import subprocess
import threading
import time
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


def run_evaluation_suite(
    parent: ChatService,
    suite: dict[str, Any],
    manifest: dict[str, Any],
    manifests: dict[str, dict[str, Any]],
    evaluation_id: str,
    team_runner: EvaluationTeamRunner,
) -> None:
    """Execute evaluation cases in disposable task checkouts.

    The source workspace is only read while each baseline is captured. The
    evaluation owns a separate AgentCore/session and never exposes Apply.
    """
    from .reusable_checks import ReusableCheckStore
    from .sessions import SessionMeta
    metadata = SessionMeta.get(parent.core.session.session_id)
    frozen_checks = ReusableCheckStore(parent.run_store).freeze(suite["workspace_root"], suite["workspace_root"], agent_id=str(metadata.get("agent_profile_id") or metadata.get("agent_trigger_id") or parent.core.session.session_id))
    store = EvaluationStore(parent.run_store)
    parent.emit({
        "type": "evaluation_started", "evaluation_id": evaluation_id,
        "suite_id": suite["id"], "case_count": len(suite["cases"]) * int(suite.get("repetitions", 1)),
    })
    parent.active_evaluation_id = evaluation_id
    try:
        repeated = [(repetition, case) for repetition in range(int(suite.get("repetitions", 1))) for case in suite["cases"]]
        for index, (repetition, case) in enumerate(repeated):
            run_id = f"eval-{evaluation_id[:12]}-{index + 1}"
            task_id = run_id
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
                store.finish_result(result_id, {"state": "failed", "execution_outcome": "failed", "failure_category": "configuration", "error": str(exc)})
                continue
            if parent.core._interrupt.is_set():
                parent.run_store.set_state(run_id, "interrupted")
                store.finish_result(result_id, {"state": "interrupted", "execution_outcome": "interrupted", "failure_category": "cancelled_before_start", "repetition": repetition + 1})
                continue
            configuration = configuration_snapshot(parent.core, case, selected)
            started = time.monotonic()
            parent.emit({
                "type": "evaluation_case_started", "evaluation_id": evaluation_id,
                "suite_id": suite["id"], "case_id": case["id"],
                "case_index": index, "run_id": run_id,
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
                fixture_task = TaskCheckoutStore.load(fixture_id) if fixture_id else None
                task = (
                    TaskCheckoutStore.replay(fixture_task, task_id)
                    if fixture_task is not None
                    else TaskCheckoutStore.create(str(suite["workspace_root"]), task_id)
                )
                task.state = "running"
                task.save()
                import copy
                evaluation_core = AgentCore(
                    model=parent.core.model,
                    cwd=task.execution_path,
                    skip_permissions=True,
                    config=copy.deepcopy(parent.core.config),
                )
                evaluation_core.configure_agent(parent.core.agent_configuration.structured())
                parent.active_evaluation_core = evaluation_core
                evaluation_core.tool_registry.computer_enabled = False
                # A browser reaches further than computer control does, and a
                # suite that can wander the web is not a fixture any more.
                evaluation_core.tool_registry.browser_enabled = False
                evaluation_core.tool_registry.notes_enabled = False
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
                evaluation_service.core.codex_manager = parent.codex
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
                    if not (read_only and suite.get("read_only_mcp")):
                        profile_value["mcp_policy"] = {}
                    profile_values.append(profile_value)
                if profile_values:
                    case_manifest["profiles"] = profile_values
                target = str(case.get("target") or "team")
                configuration = configuration_snapshot(parent.core, case, case_manifest)
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
                        rubric_result = TeamOrchestrator(
                            parent.emit,
                            evaluation_core._should_stop_stream,
                            run_store=parent.run_store,
                        ).evaluate_rubric(
                            run_id, judge, judge_team.budget,
                            case=case, output=output, diff_text=patch_text, evidence=grade,
                        )
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
                if not succeeded:
                    parent.run_store.set_state(run_id, "failed")
                failed_run = parent.run_store.run(run_id) or {}
                failed_usage = failed_run.get("usage") or {}
                from .task_journal import TaskJournal
                from .task_usage_ledger import UsageLedger
                accounting = UsageLedger(TaskJournal.for_owner(parent.run_store, "run:" + run_id)).summary()
                judging_accounting = UsageLedger(TaskJournal.for_owner(parent.run_store, "run:" + run_id + ":judge")).summary()
                value = store.finish_result(result_id, {
                    "state": "ungraded" if succeeded else "failed", "error": str(exc),
                    "execution_outcome": "completed" if succeeded else "failed", "grading_outcome": "ungraded", **grade,
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
                    "failure_category": "timeout" if timed_out.is_set() else "runtime",
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
                parent.active_evaluation_core = None
                if evaluation_core is not None:
                    evaluation_core.mcp.close()
        results = store.results(str(suite["id"]))
        parent.emit({
            "type": "evaluation_completed", "evaluation_id": evaluation_id,
            "suite_id": suite["id"], "summary": summarize_results(results),
            "state": "interrupted" if parent.core._interrupt.is_set() else "completed",
        })
    finally:
        parent.active_evaluation_id = None
        parent.active_evaluation_core = None
        parent.core._interrupt.clear()


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
