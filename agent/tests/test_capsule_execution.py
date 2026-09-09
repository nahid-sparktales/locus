"""Capsule routing tests use fakes; no provider is contacted."""
from __future__ import annotations

import asyncio
import copy
import json
import threading
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from ollama_code import server
from ollama_code.api import runs as runs_api
from ollama_code.capsule_execution import execution_manifest, review_request, run_capsule_request
from ollama_code.capsules import CapsuleStore
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.ollama import ToolCall
from ollama_code.orchestration import (
    AgentResult,
    TeamOrchestrator,
    ordered_writer_jobs,
    parse_manifest,
    validate_dispatch_plan,
)
from ollama_code.runstore import RunStore
from ollama_code.tools import ToolContext, _impl_submit_plan


@pytest.fixture
def capsule_setup(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "main.py").write_text("original")
    payload = {
        "title": "A saved change", "request": "Implement the planned feature",
        "plan": {"id": "plan-one", "title": "Plan", "summary": "A precise change", "steps": ["Change", "Test"],
                 "tests": ["Run meaningful tests"], "constraints": ["Preserve the public API"], "decisions": ["Reuse main.py"],
                 "step_details": [
                     {"id": "change", "title": "Change", "instructions": "Add the function", "files": ["main.py"], "checks": ["Inspect changes"]},
                     {"id": "test", "title": "Test", "instructions": "Add regression tests", "files": ["test_main.py"], "checks": ["Run tests"]},
                 ]},
        "recipe": {"planner_profile_id": "premium-planner", "executor_profile_id": "worker", "reviewer_profile_id": "reviewer"},
    }

    def profile(identifier, model, route, access="read_only"):
        return {"id": identifier, "name": identifier, "model": model, "role": "generalist",
                "access_ceiling": access, "route": route, "metering": "metered",
                "input_cost_per_million": 2, "output_cost_per_million": 4}

    profiles = [
        profile("premium-planner", "premium-only-model", {"provider": "remote", "base_url": "https://premium.invalid/v1", "api_key": "premium-only-key"}),
        profile("worker", "worker-model", {"provider": "remote", "base_url": "https://worker.invalid/v1", "api_key": "worker-key"}, "workspace_write"),
        profile("reviewer", "review-model", {"provider": "remote", "base_url": "https://review.invalid/v1", "api_key": "review-key"}),
    ]
    store = CapsuleStore(str(workspace))
    return workspace, store, store.create(payload), profiles


def _service(workspace):
    events = []
    runs = RunStore(workspace.parent / "routing-runs.sqlite3")
    runs.run = lambda _run_id: {"state": "completed"}
    service = SimpleNamespace(
        core=SimpleNamespace(workspace_root=str(workspace), cwd=str(workspace), identity_mode=False,
                             session=SimpleNamespace(append_strict=lambda _: None)),
        run_store=runs,
        emit=events.append,
    )
    return service, events


def _context(capsule, profiles, stage="execute"):
    return {"id": capsule["id"], "revision": capsule["revision"], "stage": stage, "profiles": profiles}


def _no_model(*_args, **_kwargs):
    pytest.fail("this path must not call any model or dispatcher")


def test_execution_uses_exact_worker_and_reviewer_routes_without_planner(capsule_setup):
    _, _, capsule, profiles = capsule_setup
    original_profiles = copy.deepcopy(profiles)
    manifest = execution_manifest(capsule, profiles, "execute-one")
    by_id = {profile["id"]: profile for profile in manifest["profiles"]}
    assert by_id["worker"]["route"] == profiles[1]["route"]
    assert by_id["capsule-reviewer"]["route"] == profiles[2]["route"]
    assert by_id["capsule-coordinator"]["route"] == profiles[1]["route"]
    assert "premium-only" not in json.dumps(manifest)
    assert "premium-planner" not in by_id
    assert profiles == original_profiles
    assert manifest["team"]["budget"]["max_model_calls"] == 60
    assert manifest["team"]["budget"]["max_concurrent_calls"] == 1
    assert manifest["team"]["budget"]["max_rounds"] == 3
    _, team, parsed, forced = parse_manifest(manifest)
    plan = validate_dispatch_plan(manifest["_capsule_plan"], team, parsed, forced)
    assert [job.id for job in ordered_writer_jobs(plan)] == ["change", "test"]
    assert plan.jobs[1].dependencies == ("change",)
    assert "Preserve the public API" in plan.jobs[0].goal
    assert "Run meaningful tests" in plan.jobs[0].goal


@pytest.mark.parametrize("route", [
    {"provider": "chatgpt", "account_id": "subscription-account"},
    {"provider": "ollama", "host": "http://127.0.0.1:11434"},
    {"provider": "remote", "account_kind": "kimi_code", "base_url": "https://subscription.invalid/v1", "api_key": "subscription-key"},
])
def test_subscription_and_local_profiles_do_not_inherit_api_metering(capsule_setup, route):
    _, _, capsule, profiles = capsule_setup
    profiles[1]["route"] = route
    manifest = execution_manifest(capsule, profiles, "subscription-run")
    for profile in manifest["profiles"][:2]:
        assert profile["metering"] == "self_hosted"
        assert "input_cost_per_million" not in profile
        assert "output_cost_per_million" not in profile
    assert manifest["profiles"][2]["metering"] == "metered"


def test_saved_plan_prepare_and_synthesis_never_dispatch_or_synthesize_with_model(capsule_setup, monkeypatch):
    workspace, _, capsule, profiles = capsule_setup
    manifest = execution_manifest(capsule, profiles, "prepared-run")
    orchestrator = TeamOrchestrator(lambda _event: None, lambda: False)
    monkeypatch.setattr(orchestrator, "_dispatch", _no_model)
    monkeypatch.setattr(orchestrator, "_dispatch_with_status", _no_model)
    monkeypatch.setattr(orchestrator, "_call_agent", _no_model)
    prepared = orchestrator.prepare("Implement", str(workspace), manifest)
    assert [job.id for job in prepared.plan.jobs] == ["change", "test"]
    monkeypatch.setattr(orchestrator, "_parallel_results", _no_model)
    summary = orchestrator.synthesize(prepared, [], "Done")
    assert "capsule" in summary.lower()


def test_dag_is_topologically_sorted_before_serializing_writes(capsule_setup):
    _, _, capsule, profiles = capsule_setup
    details = capsule["plan"]["step_details"]
    details[0]["dependencies"] = ["test"]
    details[1]["dependencies"] = []
    manifest = execution_manifest(capsule, profiles, "reordered-run")
    assert [job["id"] for job in manifest["_capsule_plan"]["jobs"]] == ["test", "change"]


@pytest.mark.parametrize("fault", ["missing_worker", "missing_reviewer", "readonly_worker"])
def test_bad_selected_routes_never_fallback_to_planner(capsule_setup, fault):
    _, _, capsule, profiles = capsule_setup
    if fault == "missing_worker":
        profiles.pop(1)
    elif fault == "missing_reviewer":
        profiles.pop(2)
    else:
        profiles[1]["access_ceiling"] = "read_only"
    with pytest.raises(ValueError):
        execution_manifest(capsule, profiles, "invalid-run")


def test_stale_sources_fail_before_model_call_or_run_reservation(capsule_setup):
    workspace, store, capsule, profiles = capsule_setup
    (workspace / "main.py").write_text("changed after review")
    service, events = _service(workspace)
    run_capsule_request(service, "Implement", _context(capsule, profiles), [], None, "stale-run", run_user=_no_model, run_team=_no_model)
    assert events[0]["type"] == "error"
    assert "source files changed" in events[0]["message"]
    assert events[-1]["type"] == "turn_done"
    assert store.get(capsule["id"])["runs"] == []


@pytest.mark.parametrize("stage", ["plan", "review", "escalate"])
def test_author_review_and_escalation_use_readonly_solo_with_saved_call_budget(capsule_setup, stage):
    workspace, store, capsule, profiles = capsule_setup
    service, events = _service(workspace)
    calls = []
    run_capsule_request(service, "Review plan", {**_context(capsule, profiles, stage), "call_limit": 99}, [], {"name": "Chosen account"}, "stage-run", run_user=lambda *args: calls.append(args), run_team=_no_model)
    assert len(calls) == 1
    args = calls[0]
    assert args[5] == "plan"
    assert args[7] is False  # automatic Solo delegation is disabled
    assert args[9] == 12  # saved recipe wins over a caller override
    assert store.get(capsule["id"])["runs"][0]["state"] == "completed"
    assert events[0]["type"] == "capsule_stage"


def test_escalation_limit_prevents_additional_planner_calls(capsule_setup):
    workspace, store, capsule, profiles = capsule_setup
    service, events = _service(workspace)
    store.record_run(capsule["id"], "prior-escalation", "escalate", "completed")
    run_capsule_request(service, "Ask planner again", _context(capsule, profiles, "escalate"), [], None, "extra-escalation", run_user=_no_model, run_team=_no_model)
    assert "limit" in events[0]["message"]
    assert len(store.get(capsule["id"])["runs"]) == 1


def test_execution_status_can_finish_after_user_saves_new_capsule_revision(capsule_setup):
    workspace, store, capsule, profiles = capsule_setup
    service, events = _service(workspace)

    def run_team(*_args):
        store.update(capsule["id"], {"title": "Next version"}, expected_revision=1)

    run_capsule_request(service, "Implement", _context(capsule, profiles), [], None, "finishing-run", run_user=_no_model, run_team=run_team)
    assert not [event for event in events if event["type"] == "error"]
    linked = store.get(capsule["id"])["runs"][0]
    assert linked["revision"] == 1
    assert linked["state"] == "completed"


def test_rejected_execution_records_failed_link_instead_of_running_forever(capsule_setup):
    workspace, store, capsule, profiles = capsule_setup
    service, events = _service(workspace)

    def reject(*_args):
        raise ValueError("execution route unavailable")

    run_capsule_request(service, "Implement", _context(capsule, profiles), [], None, "rejected-run", run_user=_no_model, run_team=reject)
    assert events[-1]["type"] == "turn_done"
    assert store.get(capsule["id"])["runs"][0]["state"] == "failed"


def test_missing_workspace_reports_terminal_error_before_model(tmp_path):
    service, events = _service(tmp_path / "missing")
    run_capsule_request(service, "Plan", {"stage": "plan"}, [], None, "missing-root", run_user=_no_model, run_team=_no_model)
    assert events[0]["type"] == "error"
    assert events[-1]["type"] == "turn_done"


def test_websocket_capsule_boundary_preserves_context_and_disables_solo_swarm(capsule_setup):
    workspace, _, capsule, profiles = capsule_setup
    service, _ = _service(workspace)
    accepted = []
    queued = []
    service.start_turn = lambda _loop, call, *args: accepted.append((call, args)) or True
    service.queue_event = queued.append
    context = _context(capsule, profiles)
    asyncio.run(server._handle_client_message(service, {"type": "user_message", "text": "Implement", "mode": "work", "capsule_context": context, "run_id": "routed-run", "request_id": "routed-run", "solo_swarm": {"enabled": True}}))
    assert len(accepted) == 1
    call, args = accepted[0]
    assert call == server._run_user_turn
    assert args[6] == "routed-run"
    assert args[7] is False
    assert args[-1] == context
    assert queued[-1]["type"] == "turn_accepted"


@pytest.mark.parametrize("overrides", [{"team": {}}, {"capsule_context": []}, {"text": "/reset"}])
def test_websocket_rejects_capsule_mode_collisions(capsule_setup, overrides):
    workspace, _, capsule, profiles = capsule_setup
    service, _ = _service(workspace)
    events = []
    service.start_turn = _no_model
    service.queue_event = events.append
    message = {"type": "user_message", "text": "Implement", "capsule_context": _context(capsule, profiles), **overrides}
    asyncio.run(server._handle_client_message(service, message))
    assert events[-1]["type"] == "command_error"


def test_rich_submit_plan_emits_files_dependencies_and_decisions(capsule_setup):
    workspace, _, capsule, _ = capsule_setup
    core = AgentCore(cwd=str(workspace), config={"model": "test-model", "auto_compact": False})
    events = []
    core.on_event(events.append)
    try:
        result = core._run_tool_call(ToolCall("submit_plan", capsule["plan"]), None)
        assert "Plan submitted" in result
        ready = next(event for event in events if event["type"] == "plan_ready")
        assert ready["plan"]["step_details"] == capsule["plan"]["step_details"]
        assert ready["plan"]["constraints"] == capsule["plan"]["constraints"]
        assert ready["plan"]["tests"] == capsule["plan"]["tests"]
    finally:
        core.close()


def test_invalid_rich_submit_plan_keeps_previous_reviewed_plan(capsule_setup):
    workspace, _, capsule, _ = capsule_setup
    context = ToolContext(cwd=str(workspace))
    context.plan_document = {"id": "earlier-plan"}
    plan = copy.deepcopy(capsule["plan"])
    plan["step_details"][0]["files"] = ["../outside.py"]
    assert _impl_submit_plan(plan, context).startswith("Error:")
    assert context.plan_document == {"id": "earlier-plan"}


@pytest.mark.parametrize("output,error", [
    ("", "provider timed out"), ("Looks good", ""), ('{"verdict":"maybe"}', ""),
])
def test_unavailable_or_unstructured_review_cannot_count_as_approval(output, error):
    with pytest.raises(ValueError, match="review"):
        review_request([SimpleNamespace(output=output, error=error)])


def test_review_verdict_preserves_requested_repairs():
    approved = SimpleNamespace(output='{"verdict":"approved","findings":[]}', error="")
    repair = SimpleNamespace(output='{"verdict":"revise","revision_request":"Fix the missing regression test"}', error="")
    assert review_request([approved]) == ""
    assert "missing regression test" in review_request([approved, repair])


@pytest.fixture
def repair_pipeline(capsule_setup, monkeypatch):
    workspace, store, capsule, profiles = capsule_setup
    core = AgentCore(cwd=str(workspace), config={"model": "test-model", "auto_compact": False})
    service = ChatService(core)
    events = []
    original_emit = service.emit

    def emit(event):
        events.append(event)
        original_emit(event)

    monkeypatch.setattr(service, "emit", emit)
    monkeypatch.setattr(server, "_automatic_memory_context", lambda *_args, **_kwargs: "")
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *_args, **_kwargs: "")
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(server, "_task_diff", lambda *_args, **_kwargs: "diff evidence")
    monkeypatch.setattr(server, "_install_writer_route", lambda _core, writer: writer.id)
    monkeypatch.setattr(server, "_restore_writer_route", lambda *_args: None)
    monkeypatch.setattr(TeamOrchestrator, "_dispatch", _no_model)
    monkeypatch.setattr(TeamOrchestrator, "_call_agent", _no_model)
    scenario = {"verdicts": ["revise", "approved"], "repair_reason": "complete", "repair_error": False, "review_calls": 1}
    writes = []
    reviews = []

    def writer(_service, orchestrator, prepared, profile, prompt, **options):
        is_repair = "-repair-" in options["job_id"]
        available = orchestrator.remaining_model_calls(prepared.team.budget)
        writes.append({"repair": is_repair, "limit": options["model_call_limit"], "available": available, "profile": profile.id, "prompt": prompt})
        if is_repair and scenario["repair_error"]:
            raise RuntimeError("fake provider failure")
        assert 1 <= options["model_call_limit"] <= available
        if is_repair:
            assert options["model_call_limit"] < available, "the final review must retain one model call"
        orchestrator.account_writer_usage(profile, prepared.team.budget, 1, 0, 0)
        core.last_turn_result = {"reason": scenario["repair_reason"] if is_repair else "complete", "model_calls": 1}
        return AgentResult(options["job_id"], profile.id, profile.name, profile.role, "Verified implementation", [], 0, 0, 1)

    def review(orchestrator, prepared, _diff, test_evidence=""):
        profile = prepared.profiles["capsule-reviewer"]
        orchestrator.account_writer_usage(profile, prepared.team.budget, scenario["review_calls"], 0, 0)
        verdicts = scenario["verdicts"]
        verdict = verdicts[min(len(reviews), len(verdicts) - 1)]
        reviews.append(verdict)
        content = "invalid reviewer output" if verdict == "malformed" else json.dumps({"verdict": verdict, "revision_request": "Add missing regression coverage"})
        return [AgentResult("review", profile.id, profile.name, "reviewer", content, [], 0, 0, 1)]

    monkeypatch.setattr(server, "_run_team_writer", writer)
    monkeypatch.setattr(TeamOrchestrator, "review", review)

    def run(*, call_limit=60, repair_limit=2, run_id="repair-loop-run"):
        current = store.get(capsule["id"])
        current = store.update(current["id"], {"recipe": {**current["recipe"], "execution_call_limit": call_limit, "max_repair_attempts": repair_limit}}, expected_revision=current["revision"])
        manifest = execution_manifest(current, profiles, run_id)
        server._run_team_turn(service, "Implement the saved plan", manifest)
        return service.run_store.run(run_id), store.get(capsule["id"])

    yield SimpleNamespace(run=run, scenario=scenario, writes=writes, reviews=reviews, events=events)
    core.close()


def test_team_capsule_repairs_verified_findings_and_persists_each_attempt(repair_pipeline):
    pipeline = repair_pipeline
    pipeline.scenario["verdicts"] = ["revise", "revise", "approved"]
    run, capsule = pipeline.run()
    assert run["state"] == "completed", pipeline.events
    assert pipeline.reviews == ["revise", "revise", "approved"]
    repair_writes = [write for write in pipeline.writes if write["repair"]]
    assert len(repair_writes) == 2
    assert all(write["profile"] == "worker" for write in repair_writes)
    assert all("missing regression coverage" in write["prompt"] for write in repair_writes)
    assert [link["state"] for link in capsule["runs"]] == ["completed", "completed"]
    assert all(link["stage"] == "repair" for link in capsule["runs"])
    assert run["usage"]["model_calls"] == 7


@pytest.mark.parametrize("call_limit,repair_limit,reason", [(5, 2, "model_call_budget"), (60, 0, "review_required")])
def test_team_capsule_stops_before_repair_when_allowance_is_exhausted(repair_pipeline, call_limit, repair_limit, reason):
    pipeline = repair_pipeline
    if call_limit == 5:
        pipeline.scenario["review_calls"] = 2
    run, capsule = pipeline.run(call_limit=call_limit, repair_limit=repair_limit)
    assert run["state"] == "paused", pipeline.events
    assert not any(write["repair"] for write in pipeline.writes)
    assert capsule["runs"] == []
    assert any(event.get("reason") == reason for event in pipeline.events)


def test_team_capsule_cannot_reset_repair_allowance_with_new_execution(repair_pipeline):
    pipeline = repair_pipeline
    pipeline.scenario["verdicts"] = ["revise"]
    first, capsule = pipeline.run(repair_limit=1, run_id="first-execution")
    assert first["state"] == "paused", pipeline.events
    assert len(capsule["runs"]) == 1
    second, capsule = pipeline.run(repair_limit=1, run_id="second-execution")
    assert second["state"] == "paused", pipeline.events
    assert len(capsule["runs"]) == 1
    assert sum(write["repair"] for write in pipeline.writes) == 1


def test_team_capsule_malformed_review_pauses_without_implementing_or_approving(repair_pipeline):
    pipeline = repair_pipeline
    pipeline.scenario["verdicts"] = ["malformed"]
    run, capsule = pipeline.run()
    assert run["state"] == "paused", pipeline.events
    assert capsule["runs"] == []
    assert not any(event.get("type") == "orchestration_completed" for event in pipeline.events)


def test_team_capsule_partial_repair_stays_paused_and_is_not_rereviewed(repair_pipeline):
    pipeline = repair_pipeline
    pipeline.scenario["repair_reason"] = "model_call_budget"
    run, capsule = pipeline.run()
    assert run["state"] == "paused", pipeline.events
    assert [link["state"] for link in capsule["runs"]] == ["paused"]
    assert pipeline.reviews == ["revise"]


def test_team_capsule_failed_repair_does_not_leave_running_attempt(repair_pipeline):
    pipeline = repair_pipeline
    pipeline.scenario["repair_error"] = True
    run, capsule = pipeline.run()
    assert run["state"] == "failed", pipeline.events
    assert [link["state"] for link in capsule["runs"]] == ["failed"]


def test_planner_clarification_chain_has_distinct_usage_runs_without_new_escalation(capsule_setup):
    workspace, store, capsule, profiles = capsule_setup
    store.record_run(capsule["id"], "original-escalation", "escalate", "completed")
    service, events = _service(workspace)
    service.core.session = SimpleNamespace(session_id="task-one")
    service.run_store.run = lambda _id: {"state": "completed", "session_id": "task-one", "workspace_root": str(workspace)}
    calls = []
    context = {**_context(capsule, profiles, "escalate"), "continuation_of_run_id": "original-escalation"}
    run_capsule_request(service, "Use the existing API", context, [], None, "clarification-one", run_user=lambda *args: calls.append(args), run_team=_no_model)
    assert len(calls) == 1
    assert calls[0][9] == 12
    links = store.get(capsule["id"])["runs"]
    assert len(links) == 2
    assert links[-1]["continuation_of_run_id"] == "original-escalation"
    assert links[-1]["escalation_root_run_id"] == "original-escalation"
    assert links[-1]["state"] == "completed"
    run_capsule_request(service, "Second answer", {**context, "continuation_of_run_id": "clarification-one"}, [], None, "clarification-two", run_user=lambda *args: calls.append(args), run_team=_no_model)
    assert len(calls) == 2
    assert store.get(capsule["id"])["runs"][-1]["escalation_root_run_id"] == "original-escalation"
    events.clear()
    run_capsule_request(service, "New unrelated planner request", _context(capsule, profiles, "escalate"), [], None, "new-escalation", run_user=_no_model, run_team=_no_model)
    assert "limit" in events[0]["message"]


@pytest.mark.parametrize("fault", ["session", "workspace", "running", "wrong_stage", "wrong_revision", "unlinked", "duplicate_child", "reuse_run_id"])
def test_clarification_cannot_bypass_parent_task_stage_revision_or_single_use(capsule_setup, fault):
    workspace, store, capsule, profiles = capsule_setup
    stage = "review" if fault == "wrong_stage" else "escalate"
    if fault != "unlinked":
        store.record_run(capsule["id"], "parent-run", stage, "completed")
    service, events = _service(workspace)
    service.core.session = SimpleNamespace(session_id="task-one")
    prior = {"state": "running" if fault == "running" else "completed", "session_id": "task-other" if fault == "session" else "task-one", "workspace_root": str(workspace.parent if fault == "workspace" else workspace)}
    service.run_store.run = lambda _id: prior
    if fault == "wrong_revision":
        capsule = store.update(capsule["id"], {"title": "Revised plan"}, expected_revision=1)
    elif fault == "duplicate_child":
        store.record_run(capsule["id"], "first-child", "escalate", "completed", continuation_of_run_id="parent-run", reserve=True)
    context = {**_context(capsule, profiles, "escalate"), "continuation_of_run_id": "parent-run"}
    run_id = "parent-run" if fault == "reuse_run_id" else "rejected-clarification"
    run_capsule_request(service, "Answer", context, [], None, run_id, run_user=_no_model, run_team=_no_model)
    assert events[0]["type"] == "error"
    assert events[-1]["type"] == "turn_done"


def test_single_step_capsule_reserves_only_actual_writer_and_reviewer_calls(capsule_setup, monkeypatch):
    _, _, capsule, profiles = capsule_setup
    capsule["plan"]["step_details"] = capsule["plan"]["step_details"][:1]
    capsule["plan"]["steps"] = capsule["plan"]["steps"][:1]
    capsule["recipe"]["execution_call_limit"] = 1
    capsule["recipe"].pop("reviewer_profile_id")
    manifest = execution_manifest(capsule, profiles, "one-call")
    orchestrator = TeamOrchestrator(lambda _event: None, lambda: False)
    monkeypatch.setattr(orchestrator, "_dispatch", _no_model)
    monkeypatch.setattr(orchestrator, "_call_agent", _no_model)
    prepared = orchestrator.prepare("Implement", "/tmp", manifest)
    assert prepared.team.budget.max_model_calls == 1
    core = SimpleNamespace(_interrupt=threading.Event(), last_turn_result={})
    service = SimpleNamespace(core=core, current_task=None, checkpoint=lambda *_args: None)
    monkeypatch.setattr(server, "_install_writer_route", lambda *_args: None)
    monkeypatch.setattr(server, "_restore_writer_route", lambda *_args: None)

    def write(_svc, _orchestrator, _prepared, writer, _prompt, **options):
        assert options["model_call_limit"] == 1
        core.last_turn_result = {"reason": "complete", "model_calls": 1}
        orchestrator.account_writer_usage(writer, prepared.team.budget, 1, 0, 0)
        return AgentResult(options["job_id"], writer.id, writer.name, writer.role, "Done", [], 0, 0, 1)

    monkeypatch.setattr(server, "_run_team_writer", write)
    server._run_prepared_writers(service, orchestrator, prepared, first_persisted_user_text="Implement")
    assert prepared.completed_writer_job_ids == {"change"}
    assert orchestrator.usage()["model_calls"] == 1
    capsule["recipe"]["reviewer_profile_id"] = "reviewer"
    with pytest.raises(ValueError, match="at least 2 model calls"):
        execution_manifest(capsule, profiles, "too-small")
    capsule["recipe"]["execution_call_limit"] = 2
    assert execution_manifest(capsule, profiles, "two-calls")["team"]["budget"]["max_model_calls"] == 2


@pytest.mark.parametrize("action", ["resume", "retry", "reassign", "replay", "duplicate", "run_with_locus"])
@pytest.mark.parametrize("identity", ["manifest", "team_id"])
@pytest.mark.parametrize("body", [{}, {"manifest": {"team": {"id": "replacement-team"}, "profiles": []}}])
def test_generic_recovery_cannot_drop_stored_capsule_identity(monkeypatch, action, identity, body):
    record = {
        "id": "capsule-run", "state": "paused", "recoverable": True, "request": "Saved work",
        "manifest": {"capsule": {"id": "saved", "revision": 1}} if identity == "manifest" else {},
        "team_id": "capsule-saved" if identity == "team_id" else "legacy-team",
    }
    service = SimpleNamespace(run_store=SimpleNamespace(run=lambda _id: record), busy=False, start_turn=_no_model)
    monkeypatch.setattr(runs_api, "_require_capability", lambda _name: None)
    with pytest.raises(HTTPException) as error:
        asyncio.run(runs_api._resume_orchestration(service, _no_model, record["id"], body, action=action))
    assert error.value.status_code == 409
    assert "Open Task Capsules" in error.value.detail


def test_generic_team_resume_keeps_existing_checkpoint_path(monkeypatch, tmp_path):
    from ollama_code.runstore import RunStore

    record = {
        "id": "ordinary-run", "state": "paused", "recoverable": True, "request": "Ordinary team work",
        "manifest": {"team": {"id": "team-one"}}, "team_id": "team-one", "checkpoint": {"state": {"plan": {"jobs": []}}},
    }
    store = RunStore(tmp_path / "ordinary-run.sqlite3")
    store.start_run(record["id"], state="paused", request=record["request"],
                    manifest=record["manifest"], team_id=record["team_id"])
    store.checkpoint(record["id"], "stable", record["checkpoint"]["state"])
    store.set_state(record["id"], "paused", recoverable=True)
    starts = []
    service = SimpleNamespace(run_store=store, busy=False,
                              start_turn=lambda _loop, runner, *args: starts.append((runner, args)) or True)
    monkeypatch.setattr(runs_api, "_require_capability", lambda _name: None)
    response = asyncio.run(runs_api._resume_orchestration(service, _no_model, record["id"], {"manifest": {"team": {"id": "team-one"}}}, action="resume"))
    assert response["state"] == "queued"
    assert starts[0][1][-1]["_resume"] == record["checkpoint"]["state"]
