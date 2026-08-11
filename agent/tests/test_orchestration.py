from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from ollama_code.ollama import OllamaError
from ollama_code.orchestration import (
    AgentJob,
    CrossProcessModelCallScheduler,
    ModelCallScheduler,
    OrchestrationError,
    TeamOrchestrator,
    TeamPreparation,
    normalize_dispatch_candidate,
    orchestration_fingerprint,
    ordered_writer_jobs,
    parse_manifest,
    validate_dispatch_plan,
)
from ollama_code.runstore import RunStore
from ollama_code.worktrees import TaskCheckoutStore, WorktreeError


def _profile(agent_id, role, access="read_only"):
    return {
        "id": agent_id,
        "name": agent_id.title(),
        "model": "test-model",
        "role": role,
        "instructions": f"Act as {role}",
        "capabilities": [role],
        "access_ceiling": access,
        "timeout_seconds": 60,
        "token_limit": 20_000,
        "metering": "self_hosted",
        "route": {"provider": "ollama", "host": "http://localhost:11434"},
    }


def _manifest(**team_overrides):
    team = {
        "id": "team-1",
        "name": "Test Team",
        "dispatcher_id": "dispatcher",
        "member_ids": ["dispatcher", "planner", "writer", "reviewer"],
        "default_writer_id": "writer",
        "use_managed_worktree": True,
        "budget": {
            "max_jobs": 4,
            "max_rounds": 3,
            "max_model_calls": 12,
            "max_concurrent_calls": 3,
            "max_metered_tokens": 500_000,
        },
    }
    team.update(team_overrides)
    return {
        "run_id": "run-1",
        "team": team,
        "profiles": [
            _profile("dispatcher", "dispatcher"),
            _profile("planner", "planner"),
            _profile("writer", "implementer", "workspace_write"),
            _profile("reviewer", "reviewer"),
        ],
    }


def _valid_plan():
    return {
        "summary": "Plan then implement and review",
        "jobs": [
            {
                "id": "plan",
                "agent_id": "planner",
                "goal": "Inspect the evidence and plan",
                "dependencies": [],
                "kind": "specialist",
            },
            {
                "id": "write",
                "agent_id": "writer",
                "goal": "Implement the request",
                "dependencies": ["plan"],
                "kind": "writer",
            },
            {
                "id": "review",
                "agent_id": "reviewer",
                "goal": "Review the diff",
                "dependencies": ["write"],
                "kind": "reviewer",
            },
        ],
    }


def test_manifest_and_dispatch_plan_require_a_writer_and_known_members():
    _, team, profiles, forced = parse_manifest(_manifest())
    assert forced is None
    plan = validate_dispatch_plan(_valid_plan(), team, profiles)
    assert [job.kind for job in plan.jobs] == ["specialist", "writer", "reviewer"]

    malformed = _valid_plan()
    malformed["jobs"][1]["agent_id"] = "missing"
    with pytest.raises(OrchestrationError, match="unknown team member"):
        validate_dispatch_plan(malformed, team, profiles)

    no_writer = _valid_plan()
    no_writer["jobs"] = [no_writer["jobs"][0]]
    with pytest.raises(OrchestrationError, match="at least one coding job"):
        validate_dispatch_plan(no_writer, team, profiles)


def test_automatic_call_budget_uses_the_bounded_adaptive_pool():
    manifest = _manifest()
    manifest["team"]["budget"].update({
        "call_budget_mode": "automatic",
        "max_model_calls": 12,
    })

    _, team, _, _ = parse_manifest(manifest)

    assert team.budget.call_budget_mode == "automatic"
    assert team.budget.max_model_calls == 100


def test_multiple_coding_jobs_must_be_write_capable_and_transitively_ordered():
    manifest = _manifest()
    manifest["profiles"].append(
        _profile("ui-writer", "implementer", "computer_control")
    )
    manifest["team"]["member_ids"].append("ui-writer")
    _, team, profiles, _ = parse_manifest(manifest)
    value = _valid_plan()
    value["jobs"].insert(2, {
        "id": "ui",
        "agent_id": "ui-writer",
        "goal": "Implement the UI after the backend contract exists",
        "dependencies": ["write"],
        "kind": "writer",
    })
    value["jobs"][-1]["dependencies"] = ["ui"]

    plan = validate_dispatch_plan(value, team, profiles)
    assert [job.id for job in ordered_writer_jobs(plan)] == ["write", "ui"]

    unordered = json.loads(json.dumps(value))
    unordered["jobs"][2]["dependencies"] = ["plan"]
    with pytest.raises(OrchestrationError, match="every pair of coding jobs"):
        validate_dispatch_plan(unordered, team, profiles)

    read_only_writer = json.loads(json.dumps(value))
    read_only_writer["jobs"][2]["agent_id"] = "planner"
    with pytest.raises(OrchestrationError, match="write-capable"):
        validate_dispatch_plan(read_only_writer, team, profiles)


def test_multi_writer_recovery_skips_completed_coding_jobs(monkeypatch):
    manifest = _manifest()
    manifest["profiles"].append(_profile("ui-writer", "implementer", "workspace_write"))
    manifest["team"]["member_ids"].append("ui-writer")
    _, team, profiles, _ = parse_manifest(manifest)
    value = _valid_plan()
    value["jobs"].insert(2, {
        "id": "ui",
        "agent_id": "ui-writer",
        "goal": "Integrate the UI with the completed backend",
        "dependencies": ["write"],
        "kind": "writer",
    })
    value["jobs"][-1]["dependencies"] = ["ui"]
    plan = validate_dispatch_plan(value, team, profiles)
    completed = {
        "job_id": "write",
        "agent_id": "writer",
        "agent_name": "Writer",
        "role": "implementer",
        "output": "backend contract completed",
        "evidence": [],
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "elapsed_ms": 20,
        "error": "",
        "reasoning_text": "",
    }
    checkpoint = {
        "orchestration_fingerprint": orchestration_fingerprint(team, profiles),
        "plan": plan.structured(),
        "results": [],
        "writer_results": [completed],
        "completed_writer_job_ids": ["write"],
    }
    orchestrator = TeamOrchestrator(lambda _event: None, lambda: False)
    monkeypatch.setattr(orchestrator, "_run_pre_writer_jobs", lambda *_args, **_kwargs: [])

    prepared = orchestrator.resume_preparation(
        "Build it", "/tmp/workspace", manifest, checkpoint,
    )

    assert prepared.completed_writer_job_ids == {"write"}
    assert [job.id for job in prepared.writer_jobs] == ["write", "ui"]
    assert [result.job_id for result in prepared.writer_results] == ["write"]
    assert "ui" in prepared.writer_prompt
    assert "backend contract completed" in prepared.writer_prompt


def test_dispatcher_progress_names_the_model_and_reports_completion(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    expected = validate_dispatch_plan(_valid_plan(), team, profiles)
    monkeypatch.setattr(orchestrator, "_dispatch", lambda *_args, **_kwargs: expected)

    actual = orchestrator._dispatch_with_status(
        "run-1", "Build it", "/tmp/workspace", team, profiles,
        profiles[team.dispatcher_id], forced,
    )

    assert actual == expected
    assert events[0] == {
        "type": "dispatcher_started",
        "run_id": "run-1",
        "agent_id": "dispatcher",
        "agent_name": "Dispatcher",
        "provider": "Local Ollama",
        "model": "test-model",
        "goal": "Creating the team plan",
        "state": "running",
    }
    assert events[-1]["type"] == "dispatcher_completed"
    assert events[-1]["state"] == "completed"
    assert events[-1]["message"] == "Dispatch plan ready"


def test_preview_approves_the_complete_plan_once_before_any_jobs(monkeypatch):
    events = []
    approvals = []
    manifest = _manifest(dispatch_approval_mode="preview")
    _, team, profiles, forced = parse_manifest(manifest)
    plan = validate_dispatch_plan(_valid_plan(), team, profiles, forced)

    def approve(run_id, candidate):
        approvals.append((run_id, candidate))
        return {"action": "run"}

    orchestrator = TeamOrchestrator(
        events.append,
        lambda: False,
        approve_dispatch=approve,
    )
    dispatches = []

    def dispatch_once(*_args, **_kwargs):
        dispatches.append("dispatch")
        return plan

    monkeypatch.setattr(orchestrator, "_dispatch_with_status", dispatch_once)
    monkeypatch.setattr(orchestrator, "_run_pre_writer_jobs", lambda *_args: [])

    prepared = orchestrator.prepare(
        "Build it", "/tmp/workspace", manifest,
    )

    assert dispatches == ["dispatch"]
    assert len(approvals) == 1
    assert approvals[0][0] == "run-1"
    assert [job["id"] for job in approvals[0][1]["jobs"]] == [
        "plan", "write", "review",
    ]
    assert prepared.plan == plan
    assert [event["type"] for event in events].count("dispatch_plan") == 1
    assert events[-1]["type"] == "orchestration_state"
    assert events[-1]["state"] == "running"


def test_dispatch_cancel_does_not_start_repair_or_fallback_calls(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: True)
    calls = []

    def interrupted_call(*_args, **_kwargs):
        calls.append("call")
        raise InterruptedError("orchestration cancelled")

    monkeypatch.setattr(orchestrator, "_raw_call", interrupted_call)

    with pytest.raises(InterruptedError, match="cancelled"):
        orchestrator._dispatch(
            "run-1", "Build it", "/tmp/workspace", team, profiles,
            profiles[team.dispatcher_id], forced,
        )

    assert calls == ["call"]


def test_dispatch_cancel_after_rejection_does_not_start_repair(monkeypatch):
    events = []
    cancelled = False
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: cancelled)
    calls = 0

    def raw_call(*_args, **_kwargs):
        nonlocal calls, cancelled
        calls += 1
        cancelled = True
        return SimpleNamespace(
            tool_calls=[],
            content=json.dumps({"summary": "bad", "jobs": []}),
        )

    monkeypatch.setattr(orchestrator, "_raw_call", raw_call)

    with pytest.raises(InterruptedError, match="cancelled"):
        orchestrator._dispatch(
            "run-1", "Build it", "/tmp/workspace", team, profiles,
            profiles[team.dispatcher_id], forced,
        )

    assert calls == 1
    assert events == []


@pytest.mark.parametrize("wrapped", [
    lambda plan: plan,
    lambda plan: f"```json\n{json.dumps(plan)}\n```",
    lambda plan: f"Candidate follows:\n{json.dumps(plan)}\nEnd candidate.",
    lambda plan: {"plan": plan},
    lambda plan: {
        "function": {
            "name": "submit_dispatch_plan",
            "arguments": json.dumps(plan),
        },
    },
    lambda plan: {"tool": "submit_dispatch_plan", "input": {"plan": plan}},
    lambda plan: {"tool_calls": [{
        "function": {
            "name": "submit_dispatch_plan",
            "arguments": json.dumps(plan),
        },
    }]},
    lambda plan: {"_raw": json.dumps({"arguments": plan})},
])
def test_dispatch_candidate_normalizes_common_vllm_wrappers(wrapped):
    assert normalize_dispatch_candidate(wrapped(_valid_plan())) == _valid_plan()


def test_dispatch_repair_receives_the_candidate_and_exact_validation_error(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    responses = [
        SimpleNamespace(
            tool_calls=[SimpleNamespace(
                name="submit_dispatch_plan",
                arguments={"summary": "bad", "jobs": []},
            )],
            content="",
        ),
        SimpleNamespace(tool_calls=[], content=json.dumps(_valid_plan())),
    ]
    calls = []

    def raw_call(*args, **kwargs):
        calls.append((args, kwargs))
        return responses.pop(0)

    monkeypatch.setattr(orchestrator, "_raw_call", raw_call)

    plan = orchestrator._dispatch(
        "run-1", "Build it", "/tmp/workspace", team, profiles,
        profiles[team.dispatcher_id], forced,
    )

    assert plan.outcome == "repaired"
    assert [job.id for job in plan.jobs] == ["plan", "write", "review"]
    assert len(calls) == 2
    repair_prompt = calls[1][0][2][-1]["content"]
    assert "dispatcher plan has no jobs" in repair_prompt
    assert '"summary":"bad"' in repair_prompt
    assert '"default_writer_id"' not in repair_prompt  # schema, not a manifest rewrite
    assert [event["stage"] for event in events] == ["initial"]
    assert events[0]["will_retry"] is True
    assert "jobs" not in events[0]


def test_dispatch_accepts_a_valid_direct_tool_call_without_repair(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    calls = 0

    def raw_call(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return SimpleNamespace(
            tool_calls=[SimpleNamespace(
                name="submit_dispatch_plan",
                arguments=_valid_plan(),
            )],
            content="",
        )

    monkeypatch.setattr(orchestrator, "_raw_call", raw_call)

    plan = orchestrator._dispatch(
        "run-1", "Build it", "/tmp/workspace", team, profiles,
        profiles[team.dispatcher_id], forced,
    )

    assert plan.outcome == "valid"
    assert calls == 1
    assert events == []


def test_dispatcher_receives_attachments_on_its_user_message(monkeypatch):
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(lambda _event: None, lambda: False)
    seen = []

    def raw_call(run_id, profile, messages, budget, **_kwargs):
        seen.append(messages)
        return SimpleNamespace(
            tool_calls=[SimpleNamespace(
                name="submit_dispatch_plan",
                arguments=_valid_plan(),
            )],
            content="",
        )

    monkeypatch.setattr(orchestrator, "_raw_call", raw_call)
    attachments = [{"name": "bug.png", "mime_type": "image/png", "data": "cG5n"}]

    plan = orchestrator._dispatch(
        "run-1", "Fix the layout in this screenshot", "/tmp/workspace",
        team, profiles, profiles[team.dispatcher_id], forced,
        attachments=attachments,
    )

    assert plan.outcome == "valid"
    user_messages = [m for m in seen[0] if m["role"] == "user"]
    assert user_messages[0]["attachments"] == attachments


def test_dispatch_retries_without_images_when_the_model_rejects_them(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    seen = []

    def raw_call(run_id, profile, messages, budget, **_kwargs):
        seen.append(messages)
        if len(seen) == 1:
            raise OllamaError("this model does not support image input")
        assert not any(message.get("attachments") for message in messages)
        return SimpleNamespace(
            tool_calls=[SimpleNamespace(
                name="submit_dispatch_plan",
                arguments=_valid_plan(),
            )],
            content="",
        )

    monkeypatch.setattr(orchestrator, "_raw_call", raw_call)
    attachments = [{"name": "bug.png", "mime_type": "image/png", "data": "cG5n"}]

    plan = orchestrator._dispatch(
        "run-1", "Fix the layout in this screenshot", "/tmp/workspace",
        team, profiles, profiles[team.dispatcher_id], forced,
        attachments=attachments,
    )

    assert plan.outcome == "valid"
    assert len(seen) == 2
    notes = [event for event in events if event.get("type") == "note"]
    assert any("without the attached images" in str(note["text"]) for note in notes)


def test_dispatch_failed_repair_emits_safe_diagnostics_and_uses_writer(monkeypatch):
    events = []
    _, team, profiles, forced = parse_manifest(_manifest())
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    invalid = {"summary": "bad", "jobs": [], "api_key": "must-not-be-persisted"}
    responses = [
        SimpleNamespace(tool_calls=[], content=json.dumps(invalid)),
        SimpleNamespace(tool_calls=[], content=json.dumps(invalid)),
    ]
    monkeypatch.setattr(orchestrator, "_raw_call", lambda *_a, **_k: responses.pop(0))

    plan = orchestrator._dispatch(
        "run-1", "Build it", "/tmp/workspace", team, profiles,
        profiles[team.dispatcher_id], forced,
    )

    assert plan.outcome == "fallback"
    assert [(job.id, job.agent_id, job.kind) for job in plan.jobs] == [
        ("writer", "writer", "writer"),
    ]
    assert "dispatcher plan has no jobs" in plan.summary
    assert "Writer only" in plan.summary
    diagnostics = [event for event in events if event["type"] == "dispatcher_plan_rejected"]
    assert [event["stage"] for event in diagnostics] == ["initial", "repair"]
    assert [event["will_retry"] for event in diagnostics] == [True, False]
    encoded = json.dumps(diagnostics)
    assert "must-not-be-persisted" not in encoded
    assert "api_key" not in encoded


def test_orchestration_fingerprint_ignores_credentials_but_tracks_models():
    first = _manifest()
    _, team, profiles, _ = parse_manifest(first)
    original = orchestration_fingerprint(team, profiles)

    first["profiles"][0]["route"]["api_key"] = "rotated-secret"
    _, same_team, same_profiles, _ = parse_manifest(first)
    assert orchestration_fingerprint(same_team, same_profiles) == original

    first["profiles"][0]["model"] = "different-model"
    _, changed_team, changed_profiles, _ = parse_manifest(first)
    assert orchestration_fingerprint(changed_team, changed_profiles) != original


def test_maximum_estimated_cost_is_a_hard_run_budget() -> None:
    manifest = _manifest(maximum_estimated_cost=0.001)
    writer = next(item for item in manifest["profiles"] if item["id"] == "writer")
    writer.update({
        "metering": "metered",
        "input_cost_per_million": 2.0,
        "output_cost_per_million": 4.0,
    })
    _, team, profiles, _ = parse_manifest(manifest)
    orchestrator = TeamOrchestrator(lambda _event: None, lambda: False)
    orchestrator.configure_run_budget(team)

    with pytest.raises(OrchestrationError, match="estimated-cost budget"):
        orchestrator.account_writer_usage(
            profiles["writer"], team.budget, 1, 1_000, 0,
        )


def test_synthesis_uses_a_deterministic_handoff_when_budget_is_spent() -> None:
    events = []
    _, team, profiles, _ = parse_manifest(_manifest())
    plan = validate_dispatch_plan(_valid_plan(), team, profiles)
    prepared = TeamPreparation(
        run_id="run-1",
        team=team,
        profiles=profiles,
        plan=plan,
        results=[],
        writer=profiles[team.default_writer_id],
        writer_prompt="write",
        original_request="Build it",
        workspace="/tmp/workspace",
    )
    orchestrator = TeamOrchestrator(events.append, lambda: False)
    orchestrator.account_writer_usage(
        prepared.writer, team.budget, team.budget.max_model_calls, 0, 0,
    )

    result = orchestrator.synthesize(prepared, [], "")

    assert "final dispatcher summary call was skipped" in result
    assert [event["type"] for event in events] == ["note"]


def test_scorecard_uses_bounded_evaluations_and_deterministic_ties(tmp_path) -> None:
    manifest = _manifest(routing_mode="scorecard")
    manifest["team"]["member_ids"].append("planner2")
    manifest["profiles"].append(_profile("planner2", "planner"))
    _, team, profiles, _ = parse_manifest(manifest)
    store = RunStore(tmp_path / "runs.sqlite3")
    for _ in range(4):
        store.record_routing_sample(
            "planner", tags=["planner"], quality=100, reliable=True,
            latency_ms=100, estimated_cost=0, local=True, evaluation=True,
        )
    orchestrator = TeamOrchestrator(
        lambda _event: None, lambda: False, run_store=store,
    )
    limited = orchestrator.scorecard(profiles["planner"], team)
    assert limited["limited_data"] is True
    assert 50 < limited["components"]["quality"] < 100

    plan_value = _valid_plan()
    plan_value["jobs"][0]["agent_id"] = "planner2"
    plan = validate_dispatch_plan(plan_value, team, profiles)
    routed = orchestrator.route_plan("run", plan, team, profiles)
    assert routed.jobs[0].agent_id == "planner"

def test_dispatch_plan_rejects_cycles_order_violations_and_ignored_forced_agent():
    manifest = _manifest()
    manifest["forced_agent_id"] = "reviewer"
    _, team, profiles, forced = parse_manifest(manifest)
    plan = _valid_plan()
    plan["jobs"][0]["dependencies"] = ["write"]
    plan["jobs"][1]["dependencies"] = ["plan"]
    with pytest.raises(OrchestrationError, match="specialists may depend only"):
        validate_dispatch_plan(plan, team, profiles, forced)

    plan = _valid_plan()
    plan["jobs"] = plan["jobs"][:2]
    with pytest.raises(OrchestrationError, match="forced agent"):
        validate_dispatch_plan(plan, team, profiles, forced)


def test_manifest_allows_multiple_writers_and_rejects_missing_credentials_and_limits():
    manifest = _manifest()
    manifest["profiles"].append(_profile("writer-2", "implementer", "workspace_write"))
    manifest["team"]["member_ids"].append("writer-2")
    _, team, profiles, _ = parse_manifest(manifest)
    assert profiles[team.default_writer_id].can_write
    assert sum(profile.can_write for profile in profiles.values()) == 2

    bad_lead = _manifest(default_writer_id="planner")
    with pytest.raises(OrchestrationError, match="lead writer must be write-capable"):
        parse_manifest(bad_lead)

    manifest = _manifest()
    manifest["profiles"][1]["route"] = {
        "provider": "remote",
        "base_url": "https://provider.example/v1",
    }
    with pytest.raises(OrchestrationError, match="credentials"):
        parse_manifest(manifest)

    with pytest.raises(OrchestrationError, match="max_jobs"):
        parse_manifest(_manifest(budget={"max_jobs": 99}))


def test_dispatch_plan_rejects_an_insufficient_multi_writer_call_budget():
    manifest = _manifest(budget={
        "max_jobs": 4,
        "max_rounds": 2,
        "max_model_calls": 4,
        "max_concurrent_calls": 2,
        "max_metered_tokens": 500_000,
    })
    _, team, profiles, _ = parse_manifest(manifest)
    with pytest.raises(OrchestrationError, match="at least 6 model calls"):
        validate_dispatch_plan(_valid_plan(), team, profiles)


def test_model_scheduler_caps_concurrency_and_round_robins_waiting_runs():
    scheduler = ModelCallScheduler(limit=1, lease_seconds=30)
    order = []
    gate = threading.Event()

    def first():
        with scheduler.lease("chat-a"):
            order.append("a1")
            gate.wait(2)

    def waiter(run, label):
        with scheduler.lease(run):
            order.append(label)

    leader = threading.Thread(target=first)
    leader.start()
    while scheduler.active_count != 1:
        time.sleep(0.01)
    threads = [
        threading.Thread(target=waiter, args=("chat-a", "a2")),
        threading.Thread(target=waiter, args=("chat-b", "b1")),
    ]
    for thread in threads:
        thread.start()
    time.sleep(0.05)
    gate.set()
    leader.join()
    for thread in threads:
        thread.join()
    assert order == ["a1", "b1", "a2"]
    assert scheduler.active_count == 0


def test_cross_process_scheduler_instances_share_leases_and_reap_expiry(tmp_path):
    path = tmp_path / "leases.sqlite3"
    first = CrossProcessModelCallScheduler(limit=1, lease_seconds=30, path=path)
    second = CrossProcessModelCallScheduler(limit=1, lease_seconds=30, path=path)
    entered = threading.Event()
    release = threading.Event()
    order = []

    def hold():
        with first.lease("chat-a"):
            order.append("a")
            entered.set()
            release.wait(2)

    def follow():
        entered.wait(2)
        with second.lease("chat-b"):
            order.append("b")

    one = threading.Thread(target=hold)
    two = threading.Thread(target=follow)
    one.start()
    two.start()
    assert entered.wait(2)
    time.sleep(0.1)
    assert order == ["a"]
    release.set()
    one.join()
    two.join()
    assert order == ["a", "b"]
    assert first.active_count == 0


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, capture_output=True, check=True
    )
    return result.stdout.strip()


def _repository(path: Path) -> Path:
    path.mkdir()
    _git(path, "init")
    _git(path, "config", "user.name", "Test")
    _git(path, "config", "user.email", "test@example.com")
    (path / "tracked.txt").write_text("base\n")
    _git(path, "add", "tracked.txt")
    _git(path, "commit", "-m", "base")
    return path


def test_managed_worktree_captures_dirty_baseline_and_applies_only_task_delta(
    tmp_path, monkeypatch
):
    from ollama_code import worktrees

    source = _repository(tmp_path / "source")
    (source / "tracked.txt").write_text("dirty baseline\n")
    (source / "untracked.txt").write_text("private baseline\n")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")

    task = TaskCheckoutStore.create(str(source), "task-1")
    assert task.state == "queued"
    checkout = Path(task.execution_path)
    assert (checkout / "tracked.txt").read_text() == "dirty baseline\n"
    assert (checkout / "untracked.txt").read_text() == "private baseline\n"
    assert task.patch()[0] == ""

    (checkout / "tracked.txt").write_text("team result\n")
    (checkout / "binary.dat").write_bytes(b"\x00\x01\x02\xff")
    patch, _ = task.patch()
    assert "tracked.txt" in patch and "binary.dat" in patch

    result = task.apply()
    assert result["applied"] is True
    assert (source / "tracked.txt").read_text() == "team result\n"
    assert (source / "binary.dat").read_bytes() == b"\x00\x01\x02\xff"
    assert _git(source, "status", "--porcelain")  # left unstaged and uncommitted
    assert task.apply()["applied"] is False
    assert TaskCheckoutStore.load("task-1").applied_tree == task.applied_tree


def test_managed_worktree_conflict_leaves_source_untouched(tmp_path, monkeypatch):
    from ollama_code import worktrees

    source = _repository(tmp_path / "source")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    task = TaskCheckoutStore.create(str(source), "task-2")
    (Path(task.execution_path) / "tracked.txt").write_text("task edit\n")
    (source / "tracked.txt").write_text("concurrent source edit\n")

    with pytest.raises(WorktreeError, match="conflict"):
        task.apply()
    assert (source / "tracked.txt").read_text() == "concurrent source edit\n"


def test_parallel_worktree_forks_same_snapshot_and_integrates_in_order(tmp_path, monkeypatch):
    from ollama_code import worktrees

    source = _repository(tmp_path / "source")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    parent = TaskCheckoutStore.create(str(source), "parallel-parent")
    left = TaskCheckoutStore.fork(parent, "parallel-left")
    right = TaskCheckoutStore.fork(parent, "parallel-right")

    Path(left.execution_path, "left.txt").write_text("left\n")
    Path(right.execution_path, "right.txt").write_text("right\n")
    parent.integrate(left)
    parent.integrate(right)

    assert Path(parent.execution_path, "left.txt").read_text() == "left\n"
    assert Path(parent.execution_path, "right.txt").read_text() == "right\n"
    assert Path(source, "left.txt").exists() is False


def test_parallel_manifest_allows_independent_writers() -> None:
    manifest = _manifest(parallel_writers=True)
    manifest["team"]["member_ids"].append("writer-two")
    manifest["profiles"].append(
        _profile("writer-two", "implementer", "workspace_write")
    )
    _, team, profiles, _ = parse_manifest(manifest)
    plan = _valid_plan()
    plan["jobs"].insert(2, {
        "id": "write-two",
        "agent_id": "writer-two",
        "goal": "Implement an independent area",
        "dependencies": ["plan"],
        "kind": "writer",
    })
    # The reviewer must depend on both mutation scopes.
    plan["jobs"][-1]["dependencies"] = ["write", "write-two"]
    validated = validate_dispatch_plan(plan, team, profiles)
    assert {job.id for job in validated.jobs if job.kind == "writer"} == {
        "write", "write-two"
    }


def test_replay_checkout_starts_from_original_immutable_baseline(tmp_path, monkeypatch):
    from ollama_code import worktrees

    source = _repository(tmp_path / "source")
    (source / "tracked.txt").write_text("dirty baseline\n")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    original = TaskCheckoutStore.create(str(source), "original")
    (Path(original.execution_path) / "tracked.txt").write_text("agent mutation\n")
    (source / "tracked.txt").write_text("new workspace state\n")

    replay = TaskCheckoutStore.replay(original, "replay")

    assert replay.baseline_tree == original.baseline_tree
    assert Path(replay.execution_path, "tracked.txt").read_text() == "dirty baseline\n"
    assert replay.patch()[0] == ""


def test_cleanup_removes_only_managed_checkout(tmp_path, monkeypatch):
    from ollama_code import worktrees

    source = _repository(tmp_path / "source")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    task = TaskCheckoutStore.create(str(source), "cleanup")
    workspace_file = source / "tracked.txt"
    before = workspace_file.read_text(encoding="utf-8")

    result = TaskCheckoutStore.cleanup(task.id)

    assert result["removed"] is True
    assert TaskCheckoutStore.load(task.id) is None
    assert workspace_file.read_text(encoding="utf-8") == before


def test_agent_job_is_a_plain_non_recursive_record():
    job = AgentJob("one", "planner", "plan", (), "specialist")
    assert not hasattr(job, "delegate")
