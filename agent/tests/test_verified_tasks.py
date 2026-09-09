"""Acceptance and restart regressions exercise real stores/tools without providers."""
from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from ollama_code.capsule_progress import CapsuleRuntime
from ollama_code.capsules import CapsuleStore
from ollama_code.core import AgentCore
from ollama_code.goal_runtime import GoalRuntime, attach_goal_runtime
from ollama_code.goals import GoalStore
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.runstore import RunStore, SCHEMA_VERSION
from ollama_code.sessions import SessionStore
from ollama_code.task_state import TaskStateError, TaskStateStore, TaskVerifier, normalize_checks


@pytest.fixture
def environment(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    core = AgentCore(cwd=str(workspace), model="fixture", skip_permissions=True,
                     config={"provider": "ollama", "auto_compact": False})
    core._emit_info = lambda: None
    runs = RunStore(tmp_path / "runs.sqlite3")
    events = []
    svc = SimpleNamespace(core=core, run_store=runs, emit=events.append, decide=lambda *_: "once")
    return workspace, core, runs, svc


def check(identifier="result", kind="file_contains", **extra):
    return {"id": identifier, "requirement": "The required file contains ready", "kind": kind,
            **({"path": "result.txt", "value": "ready"} if kind == "file_contains" else {}), **extra}


def verifier(environment):
    workspace, core, runs, _ = environment
    store = TaskStateStore(runs)
    store.ensure("test", request="Create the result", revision=1, workspace=str(workspace), execution=str(workspace))
    return store, TaskVerifier(store, "test", core, "run")


def test_missing_artifact_and_prose_cannot_complete(environment):
    _, _, runs, _ = environment
    goals = GoalStore(runs)
    goal = goals.create("chat", "Create result.txt", execution={"provider": "ollama", "model": "fixture",
        "runner": "solo", "workspace_root": str(environment[0])})
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    goals.report(goal["id"], run["id"], goal["revision"], status="complete", summary="Done", evidence=["All tests passed"])
    assert goals.reconcile_run(goal["id"], run["id"])["status"] == "needs_review"
    assert not (environment[0] / "result.txt").exists()


def test_checks_record_actual_results_and_reject_stale_evidence(environment):
    workspace, _, _, _ = environment
    store, runner = verifier(environment)
    assert runner.verify([check()], lambda *_: "once")["verification_status"] == "failed"
    (workspace / "result.txt").write_text("ready")
    assert runner.verify([check()], lambda *_: "once")["verification_status"] == "passed"
    assert store.completion("test", revision=1)[0] == "passed"
    assert store.completion("test", revision=2)[0] == "needs_review"
    (workspace / "result.txt").write_text("broken")
    assert store.completion("test", revision=1)[0] == "failed"


def test_command_exit_status_cannot_be_faked_by_stdout(environment):
    store, runner = verifier(environment)
    result = runner.verify([check(kind="command", command="printf 'All checks passed'; exit 3")], lambda *_: "once")
    assert result["verification_status"] == "failed"
    assert store.receipts("test")[-1]["exit_code"] == 3


def test_subjective_check_requires_review_without_model(environment):
    store, runner = verifier(environment)
    assert runner.verify([check(kind="human_review")], None)["verification_status"] == "needs_review"
    assert store.receipts("test")[-1]["state"] == "needs_review"


def test_goal_completion_runs_checks_at_runtime_boundary(environment):
    workspace, core, runs, _ = environment
    goals = GoalStore(runs)
    goal = goals.create(core.session.session_id, "Create result.txt containing ready", execution={
        "provider": "ollama", "model": "fixture", "runner": "solo", "workspace_root": str(workspace)})
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    runtime = GoalRuntime(goals, goal, run["id"])
    attach_goal_runtime(core, runtime, coordinator=True)
    (workspace / "result.txt").write_text("ready")
    runtime.submit_report({"status": "complete", "summary": "Created the result", "evidence": ["Observed result"],
                           "acceptance_checks": [check()]})
    assert runtime.finish("complete")["status"] == "completed"
    assert goals.get(goal["id"])["verification_status"] == "passed"


def test_human_acceptance_is_distinct_and_revision_checked(environment):
    _, core, runs, _ = environment
    goals = GoalStore(runs)
    goal = goals.create(core.session.session_id, "Review the design", execution={"provider": "ollama", "model": "fixture",
        "runner": "solo", "workspace_root": core.cwd})
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    runtime = GoalRuntime(goals, goal, run["id"])
    attach_goal_runtime(core, runtime, coordinator=True)
    runtime.submit_report({"status": "complete", "summary": "Design ready", "evidence": ["Draft prepared"]})
    assert runtime.finish("complete")["status"] == "needs_review"
    accepted = goals.update(goal["id"], "accept", expected_revision=goal["revision"])
    assert accepted["status"] == "completed"
    assert accepted["verification_status"] == "accepted"


def test_compaction_preserves_late_constraints_failures_and_usage(environment):
    _, core, _, _ = environment
    core.context_limit = 128000
    core.messages = [core.system_message(), {"role": "user", "content": "x" * 2200 + " KEEP_PUBLIC_API"},
        {"role": "assistant", "content": "Inspecting"}, {"role": "tool", "content": "FAILED_REQUIRED_CHECK"},
        {"role": "assistant", "content": "Still working"}]
    captured = []
    def summarize(model, messages, **kwargs):
        captured.extend(messages)
        return ChatResponse(content_parts=["Required check still fails."], prompt_eval_count=600, eval_count=25)
    core.client = SimpleNamespace(chat_stream=summarize)
    assert not core._slash_compact().get("error")
    assert "FAILED_REQUIRED_CHECK" in json.dumps(captured)
    assert "KEEP_PUBLIC_API" in json.dumps(core.messages)
    assert core.total_prompt_tokens + core.total_completion_tokens == 625
    assert "KEEP_PUBLIC_API" in json.dumps(SessionStore.load_context(core.session.path))


@pytest.mark.parametrize("fault", ["empty", "limit", "persistence"])
def test_failed_compaction_keeps_previous_context(environment, monkeypatch, fault):
    _, core, _, _ = environment
    core.context_limit = 128000
    core.messages = [core.system_message(), {"role": "user", "content": "Preserve this"}, {"role": "assistant", "content": "Working"}]
    original = list(core.messages)
    core.client = SimpleNamespace(chat_stream=lambda *a, **k: ChatResponse(
        content_parts=[] if fault == "empty" else ["Summary"], done_reason="length" if fault == "limit" else "stop"))
    if fault == "persistence":
        monkeypatch.setattr(core.session, "append_strict", lambda *_: (_ for _ in ()).throw(OSError("full disk")))
    assert core._slash_compact().get("error")
    assert core.messages == original


def capsule(environment, shared=False):
    workspace, _, _, _ = environment
    (workspace / "result.txt").write_text("original")
    second = "result.txt" if shared else "second.txt"
    store = CapsuleStore(str(workspace))
    value = store.create({"title": "Verified work", "request": "Create two results", "plan": {
        "steps": ["First", "Second"], "step_details": [
            {"id": "first", "title": "First", "files": ["result.txt"], "acceptance_checks": [check()]},
            {"id": "second", "title": "Second", "files": [second], "dependencies": ["first"],
             "acceptance_checks": [check("second", path=second, value="done")]},
        ]}, "recipe": {"planner_profile_id": "planner", "executor_profile_id": "worker"}})
    return store, value


def test_capsule_resume_skips_verified_step_and_preserves_allowance(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    first = CapsuleRuntime(svc, value, "run-one")
    first.start_step("first")
    (workspace / "result.txt").write_text("ready")
    first.finish_step("first", svc.decide)
    first.settle("paused", {"model_calls": 7, "metered_tokens": 120, "estimated_cost": 0.2})
    resumed = CapsuleRuntime(svc, value, "run-two", "run-one")
    assert resumed.completed == {"first"}
    assert resumed.value["usage"]["model_calls"] == 7
    assert resumed.value["usage"]["estimated_cost"] == 0.2


def test_later_shared_file_edits_preserve_earlier_progress(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment, shared=True)
    progress = CapsuleRuntime(svc, value, "run-one")
    for identifier, text in [("first", "ready"), ("second", "done")]:
        progress.start_step(identifier)
        (workspace / "result.txt").write_text(text)
        progress.finish_step(identifier, svc.decide)
    progress.settle("paused")
    resumed = CapsuleRuntime(svc, value, "run-two", "run-one")
    assert resumed.completed == {"first", "second"}
    resumed.settle("paused")
    (workspace / "result.txt").write_text("unexpected user change")
    changed = CapsuleRuntime(svc, value, "run-three", "run-one")
    assert changed.completed == set()


def test_partial_step_continues_without_replanning(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "run-one")
    progress.start_step("first")
    (workspace / "result.txt").write_text("partial")
    progress.settle("paused")
    resumed = CapsuleRuntime(svc, value, "run-two", "run-one")
    assert resumed.completed == set()
    assert (workspace / "result.txt").read_text() == "partial"
    assert resumed.value["steps"]["first"]["state"] == "paused"


def test_capsule_rejects_divergent_checkout_duplicate_resume_and_uncertain_action(environment, tmp_path):
    _, core, _, svc = environment
    _, value = capsule(environment)
    checkout = tmp_path / "other"
    checkout.mkdir()
    (checkout / "result.txt").write_text("divergent")
    original = core.cwd
    core.cwd = str(checkout)
    with pytest.raises(TaskStateError, match="differs"):
        CapsuleRuntime(svc, value, "bad")
    core.cwd = original
    progress = CapsuleRuntime(svc, value, "run-one")
    with pytest.raises(TaskStateError, match="already running"):
        CapsuleRuntime(svc, value, "duplicate", "run-one")
    progress.action_started("external", "connector_action")
    progress.settle("paused")
    with pytest.raises(TaskStateError, match="uncertain"):
        CapsuleRuntime(svc, value, "unsafe", "run-one")


@pytest.mark.parametrize("payload", [[{"id": "fake", "kind": "file_exists", "requirement": "File", "path": "../escape"}],
                                     [{"id": "fake", "kind": "human_review", "requirement": "Done", "passed": True}]])
def test_check_declarations_cannot_escape_or_forge_receipts(payload):
    with pytest.raises(ValueError):
        normalize_checks(payload)


def test_command_receipt_becomes_stale_after_workspace_change(environment):
    workspace, _, _, _ = environment
    store, run = verifier(environment)
    result = run.verify([check(kind="command", command="true")], lambda *_: "once")
    assert result["verification_status"] == "passed"
    (workspace / "new.txt").write_text("changed")
    assert store.completion("test")[0] == "failed"


def test_denied_or_unavailable_tool_cannot_verify_a_real_file(environment, monkeypatch):
    workspace, core, _, _ = environment
    (workspace / "result.txt").write_text("ready")
    _, run = verifier(environment)
    monkeypatch.setattr(core, "_run_tool_call", lambda *_: "Not run: tools unavailable.")
    assert run.verify([check()], None)["verification_status"] == "needs_review"


def test_checks_cannot_be_removed_or_weakened_in_a_completion_report(environment):
    workspace, _, _, _ = environment
    (workspace / "result.txt").write_text("ready")
    _, run = verifier(environment)
    run.verify([check(), check("review", kind="human_review")], None)
    assert run.verify([check()], None)["verification_status"] == "needs_review"
    with pytest.raises(TaskStateError, match="changed"):
        run.verify([check(value="read")], None)


def test_pending_requests_and_repeated_corrections_survive_recovery(environment):
    _, core, _, _ = environment
    for text in ["Use A", "Use B", "Use A"]:
        core.session.append_strict({"type": "pending_task_input", "text": text})
        core._add_message({"role": "user", "content": text})
    core.session.append_strict({"type": "pending_task_input", "text": "Never publish"})
    inputs = SessionStore.authoritative_inputs(core.session.path)
    assert [m["content"] for m in inputs] == ["Use A", "Use B", "Use A", "Never publish"]
    assert "Never publish" in json.dumps(SessionStore.load_context(core.session.path))
    assert len(SessionStore.load(core.session.path)) == 3  # Export stays faithful to applied messages.


def test_unresolved_failure_survives_an_optimistic_summary(environment):
    _, core, _, _ = environment
    core.context_limit = 128000
    core._add_message({"role": "user", "content": "Ship after the check passes"})
    core._add_message({"role": "assistant", "content": "Checking"})
    core._add_message({"role": "tool", "name": "bash", "content": "Error: required migration failed"})
    core.client = SimpleNamespace(chat_stream=lambda *a, **k: ChatResponse(content_parts=["Everything looks good."]))
    assert not core._slash_compact().get("error")
    assert "required migration failed" in json.dumps(core.messages)
    assert "required migration failed" in json.dumps(SessionStore.load_context(core.session.path))


def test_compaction_allowance_is_bounded_and_usage_counts_once(environment):
    from test_backend import FakeClient
    _, core, _, _ = environment
    core.config.update(auto_compact=True, context_window=32768)
    core.client = FakeClient([ChatResponse(content_parts=["section"], prompt_eval_count=10, eval_count=2)] * 5 +
                             [ChatResponse(content_parts=["done"], prompt_eval_count=20, eval_count=4)])
    core._add_message({"role": "user", "content": "Keep requirements"})
    core._add_message({"role": "assistant", "content": "x" * 100000})
    core.run_turn("Continue", allow_tools=False, model_call_limit=6)
    assert core.last_turn_result["model_calls"] == 6
    assert core.last_turn_result["prompt_tokens"] == 70
    assert core.last_turn_result["completion_tokens"] == 14
    assert core.client.calls == 6


def test_insufficient_compaction_allowance_keeps_current_request(environment):
    from test_backend import FakeClient
    _, core, _, _ = environment
    core.config.update(auto_compact=True, context_window=32768)
    core.client = FakeClient([])
    core._add_message({"role": "user", "content": "Keep requirements"})
    core._add_message({"role": "assistant", "content": "x" * 100000})
    core.run_turn("Do not change the API", allow_tools=False, model_call_limit=1)
    assert core.client.calls == 0
    assert core.last_turn_result["reason"] == "context_limit"
    assert "Do not change the API" in json.dumps(SessionStore.load_context(core.session.path))


def test_capsule_unknown_mutation_needs_specific_outcome_before_resume(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.start_step("first")
    progress.action_started("send-1", "send_message")
    progress.action_finished("send-1", "Error: connection lost")
    (workspace / "result.txt").write_text("ready")
    with pytest.raises(TaskStateError, match="uncertain"):
        progress.finish_step("first", svc.decide)
    progress.settle("paused")
    with pytest.raises(TaskStateError):
        progress.store.resolve_action("first", value["id"], "wrong-action", "It arrived")
    progress.store.resolve_action("first", value["id"], "send-1", "The message arrived once.")
    resumed = CapsuleRuntime(svc, value, "next", "first")
    assert "The message arrived once." in json.dumps(resumed.context())
    assert not resumed.completed


def test_pending_usage_and_repair_count_survive_interruption(environment):
    _, core, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    profile = SimpleNamespace(metering="self_hosted", input_cost_per_million=0, output_cost_per_million=0)
    progress.value["repair_count"] = 2
    progress.start_model_work({"model_calls": 7, "estimated_cost": 0.3}, profile)
    progress.observe_usage({"model_calls": 2, "prompt_tokens": 12, "completion_tokens": 9})
    progress.settle("paused")
    stored = progress.store.get("first")
    assert stored["usage"]["model_calls"] == 9
    assert stored["usage"]["estimated_cost"] == 0.3
    assert stored["repair_count"] == 2
    with pytest.raises(TaskStateError, match="usage is unsettled"):
        CapsuleRuntime(svc, value, "next", "first")


def test_repair_changes_trigger_step_reverification(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    for identifier, path, content in [("first", "result.txt", "ready"), ("second", "second.txt", "done")]:
        progress.start_step(identifier)
        (workspace / path).write_text(content)
        progress.finish_step(identifier, svc.decide)
    (workspace / "result.txt").write_text("broken after review repair")
    progress.value["recheck_after_repair"] = True
    assert progress.final_check(svc.decide)["verification_status"] == "failed"
    assert progress.value["steps"]["first"]["state"] == "failed"
    assert progress.value["steps"]["first"]["changed_files"] == ["result.txt"]


def test_resume_checks_can_verify_existing_files_without_writer_calls(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.settle("paused")
    (workspace / "result.txt").write_text("ready")
    (workspace / "second.txt").write_text("done")
    resumed = CapsuleRuntime(svc, value, "next", "first")
    resumed.checks_only = True
    assert resumed.completed == {"first", "second"}
    assert resumed.final_check(svc.decide)["verification_status"] == "passed"


def test_native_progress_uses_dynamic_input_without_restarting_the_thread(environment):
    from test_chatgpt_app_server import FakeManagedRuntime, _managed_core
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    runtime = FakeManagedRuntime()
    core = _managed_core(workspace, runtime)
    svc.core = core
    progress = CapsuleRuntime(svc, value, "first")
    core.capsule_runtime = progress
    core.run_turn("Continue", allow_tools=False)
    progress.value["steps"]["first"] = {"state": "verified"}
    core.run_turn("Continue again", allow_tools=False)
    assert runtime.started == ["thread-1"]
    assert '"state": "verified"' in runtime.turn_texts[-1]
    assert runtime.turn_texts[-1].count("Current durable task state.") == 1


def test_classical_route_receives_current_capsule_state(environment):
    from test_backend import FakeClient
    _, core, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    core.capsule_runtime = progress
    progress.value["steps"]["first"] = {"state": "verified"}
    core.client = FakeClient([ChatResponse(content_parts=["Current progress received."])])
    core.run_turn("Continue", allow_tools=False)
    assert '"state": "verified"' in json.dumps(core.client.seen_messages[0]).replace('\\"', '"')


@pytest.mark.parametrize("reason", ["length", "interrupted"])
def test_truncated_and_interrupted_classical_output_is_incomplete(environment, reason):
    from test_backend import FakeClient
    _, core, _, _ = environment
    core.client = FakeClient([ChatResponse(content_parts=["All done"], done_reason=reason)])
    if reason == "interrupted":
        original = core.client.chat_stream
        def interrupted(*args, **kwargs):
            core._interrupt.set()
            return original(*args, **kwargs)
        core.client.chat_stream = interrupted
    core.run_turn("Finish", allow_tools=False, model_call_limit=1)
    assert core.last_turn_result["reason"] != "complete"


def test_native_compaction_uses_selected_account_and_records_usage(environment):
    from test_chatgpt_app_server import FakeManagedRuntime, _managed_core
    workspace, _, _, _ = environment
    runtime = FakeManagedRuntime()
    core = _managed_core(workspace, runtime)
    core.context_limit = 128000
    core._add_message({"role": "user", "content": "A constraint " + "x" * 2100 + " KEEP_THIS"})
    core._add_message({"role": "assistant", "content": "Exploration"})
    assert not core._slash_compact().get("error")
    assert len(runtime.started) == 1
    assert core.total_prompt_tokens == 4
    assert core.total_completion_tokens == 2
    assert "KEEP_THIS" in json.dumps(core.messages)


def test_reviewed_usage_cannot_reset_spend_or_repair_count(environment):
    _, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.start_step("first")
    progress.value.update(usage={"model_calls": 8, "metered_tokens": 90, "estimated_cost": 0.4},
                          repair_count=2, pending_usage={"base": {}, "step_id": "first"})
    progress.settle("paused")
    with pytest.raises(TaskStateError, match="include"):
        progress.store.resolve_usage("first", value["id"], {"model_calls": 1, "metered_tokens": 90, "estimated_cost": 0.4})
    progress.store.resolve_usage("first", value["id"], {"model_calls": 9, "metered_tokens": 120, "estimated_cost": 0.5})
    resumed = CapsuleRuntime(svc, value, "next", "first")
    assert resumed.value["usage"]["model_calls"] == 9
    assert resumed.value["steps"]["first"]["usage"]["model_calls"] == 9
    assert resumed.value["repair_count"] == 2
    assert resumed.value["usage_reviews"][0]["source"] == "human_review"


def test_reviewed_uncertain_action_cannot_be_invoked_identically(environment):
    _, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.action_started("send", "send_message", {"text": "Hello"})
    progress.settle("paused")
    progress.store.resolve_action("first", value["id"], "send", "Delivered once")
    resumed = CapsuleRuntime(svc, value, "next", "first")
    with pytest.raises(TaskStateError, match="replayed"):
        resumed.action_started("send-again", "send_message", {"text": "Hello"})


def test_changed_plan_revision_stops_before_step_execution(environment):
    _, _, _, svc = environment
    store, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    store.update(value["id"], {"request": "Changed requirements"}, value["revision"])
    with pytest.raises(TaskStateError, match="changed during"):
        progress.start_step("first")
    assert progress.value["steps"] == {}


def test_plan_revision_changed_during_checks_cannot_verify_step(environment, monkeypatch):
    workspace, _, _, svc = environment
    store, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.start_step("first")
    (workspace / "result.txt").write_text("ready")
    verify = TaskVerifier.verify
    def revise_after_check(*args, **kwargs):
        result = verify(*args, **kwargs)
        store.update(value["id"], {"request": "Changed requirements"}, value["revision"])
        return result
    monkeypatch.setattr(TaskVerifier, "verify", revise_after_check)
    with pytest.raises(TaskStateError, match="changed during"):
        progress.finish_step("first", svc.decide)
    assert progress.store.get("first")["steps"]["first"]["state"] != "verified"


@pytest.mark.parametrize("changed", ["plan", "file"])
def test_changed_result_cannot_settle_as_completed(environment, changed):
    workspace, _, _, svc = environment
    store, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    for identifier, path, content in [("first", "result.txt", "ready"), ("second", "second.txt", "done")]:
        progress.start_step(identifier)
        (workspace / path).write_text(content)
        progress.finish_step(identifier, svc.decide)
    assert progress.final_check(svc.decide)["verification_status"] == "passed"
    if changed == "plan":
        store.update(value["id"], {"request": "Changed requirements"}, value["revision"])
    else:
        (workspace / "result.txt").write_text("unexpected edit")
    progress.settle("completed")
    assert progress.store.get("first")["state"] == "paused"
    assert progress.store.get("first")["verification_status"] == "pending"


def test_task_snapshot_cannot_overwrite_a_concurrent_newer_revision(environment, monkeypatch):
    workspace, _, _, _ = environment
    store, _ = verifier(environment)
    get = store.get
    def revise_after_read(identifier):
        value = get(identifier)
        store.save({**value, "revision": 2, "request": "New requirements"})
        return value
    monkeypatch.setattr(store, "get", revise_after_read)
    with pytest.raises(TaskStateError, match="changed"):
        store.ensure("test", request="Old request", revision=1, workspace=str(workspace), execution=str(workspace))
    assert get("test")["revision"] == 2


def test_persistence_failure_cannot_create_verified_step_receipt(environment, monkeypatch):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.start_step("first")
    (workspace / "result.txt").write_text("ready")
    def fail(*args, **kwargs):
        raise OSError("disk full")
    monkeypatch.setattr(progress.store, "save", fail)
    with pytest.raises(OSError):
        progress.finish_step("first", svc.decide)
    assert progress.store.get("first")["steps"]["first"]["state"] == "running"


def test_full_plan_restores_without_compaction(environment):
    _, core, _, _ = environment
    plan = {"title": "Plan", "summary": "Summary", "steps": ["Create file"], "tests": ["Inspect"],
            "acceptance_checks": [check()]}
    assert "Plan submitted" in core._run_tool_call(ToolCall("submit_plan", plan), None)
    session = core.session.session_id
    core.tool_ctx.plan_document = None
    core.resume_session(session)
    assert core.tool_ctx.plan_document["acceptance_checks"][0]["id"] == "result"


def test_utf8_compaction_sections_preserve_every_character():
    from ollama_code.context_preservation import bounded_sections, token_estimate
    text = "用户约束 🚀" * 5000
    sections = bounded_sections(text, 24000)
    assert "".join(sections) == text
    assert all(len(section.encode("utf-8")) <= 24000 for section in sections)
    assert token_estimate(text) > len(text) // 3


@pytest.mark.parametrize("late_change", [None, "plan", "file"])
def test_real_team_capsule_execution_resumes_without_repeating_verified_writer(environment, monkeypatch, late_change):
    from test_backend import FakeClient

    from ollama_code import server
    from ollama_code.capsule_execution import run_capsule_request
    from ollama_code.chat_service import ChatService
    from ollama_code.orchestration import TeamOrchestrator
    workspace, core, runs, _ = environment
    _, value = capsule(environment)
    profile = {"id": "worker", "name": "Fixture writer", "role": "implementer", "model": "fixture",
               "access_ceiling": "workspace_write", "route": {"provider": "ollama", "host": "http://127.0.0.1:11434"}}
    monkeypatch.setattr(server, "_automatic_memory_context", lambda *a, **k: "")
    monkeypatch.setattr(server, "_automatic_continuity_context", lambda *a, **k: "")
    monkeypatch.setattr(server, "_capture_continuity_snapshot", lambda *a, **k: None)
    monkeypatch.setattr(server, "_task_diff", lambda *a, **k: "fixture changes")
    monkeypatch.setattr(server, "_install_writer_route", lambda *a: {})
    monkeypatch.setattr(server, "_restore_writer_route", lambda *a: None)
    monkeypatch.setattr(TeamOrchestrator, "_dispatch", lambda *a, **k: pytest.fail("No planner call on saved execution"))
    monkeypatch.setattr(TeamOrchestrator, "_call_agent", lambda *a, **k: pytest.fail("No extra reviewer or synthesis call"))
    service = ChatService(core)
    service.run_store = runs
    events = []
    stopped = False
    original_emit = service.emit
    def emit(event):
        nonlocal stopped
        events.append(event)
        original_emit(event)
        if event.get("type") == "capsule_progress" and not stopped:
            if event["attempt"]["steps"].get("first", {}).get("state") == "verified":
                stopped = True
                core.interrupt()
    service.emit = emit
    core.client = FakeClient([
        ChatResponse(tool_calls=[ToolCall("read_file", {"path": "result.txt"}),
                                 ToolCall("write_file", {"path": "result.txt", "content": "ready"})]),
        ChatResponse(content_parts=["First file ready."]),
    ])
    context = {"id": value["id"], "revision": value["revision"], "stage": "execute", "profiles": [profile]}
    run_capsule_request(service, value["request"], context, [], None, "original-attempt",
                        run_user=lambda *a: pytest.fail("No plan run"), run_team=server._run_team_turn)
    from ollama_code.capsule_progress import CapsuleProgressStore
    saved = CapsuleProgressStore(runs).get("original-attempt")
    assert saved is not None, events[-6:]
    assert saved["state"] == "paused", events[-6:]
    assert saved["steps"]["first"]["state"] == "verified", events[-6:]
    assert saved["usage"]["model_calls"] == 2
    assert saved["steps"]["first"]["usage"]["model_calls"] == 2
    # A new service/core simulates restarting the application.
    resumed_core = AgentCore(cwd=str(workspace), model="fixture", skip_permissions=True,
                             config={"provider": "ollama", "auto_compact": False})
    resumed_core.resume_session(core.session.session_id)
    resumed_core.client = FakeClient([
        ChatResponse(tool_calls=[ToolCall("write_file", {"path": "second.txt", "content": "done"})]),
        ChatResponse(content_parts=["Second file ready."]),
    ])
    next_service = ChatService(resumed_core)
    next_service.run_store = runs
    next_emit = next_service.emit
    resumed_events = []
    def emit_after_resume(event):
        resumed_events.append(event)
        next_emit(event)
        if (late_change and event.get("type") == "capsule_progress"
                and event["attempt"]["state"] == "running" and event["attempt"].get("verification_status") == "passed"):
            if late_change == "plan":
                CapsuleStore(str(workspace)).update(value["id"], {"request": "A new requirement"}, value["revision"])
            else:
                (workspace / "second.txt").write_text("unexpected edit")
    next_service.emit = emit_after_resume
    run_capsule_request(next_service, value["request"], {**context, "resume_attempt_id": "original-attempt"},
                        [], None, "resumed-run", run_user=lambda *a: pytest.fail("No plan run"), run_team=server._run_team_turn)
    saved = CapsuleProgressStore(runs).get("original-attempt")
    assert saved["state"] == ("paused" if late_change else "completed"), saved
    assert saved["verification_status"] == ("pending" if late_change else "passed")
    assert runs.run("resumed-run")["state"] == ("paused" if late_change else "completed")
    terminal = [event for event in resumed_events if event["type"] == "turn_done"][-1]
    assert terminal["reason"] == ("verification_required" if late_change else "complete")
    assert saved["usage"]["model_calls"] == 4
    assert saved["steps"]["first"]["usage"]["model_calls"] == 2
    assert saved["steps"]["second"]["usage"]["model_calls"] == 2
    assert resumed_core.client.calls == 2
    assert (workspace / "result.txt").read_text() == "ready"
    assert (workspace / "second.txt").read_text() == ("unexpected edit" if late_change == "file" else "done")


def test_additive_migration_keeps_historical_runs_unverified(tmp_path):
    path = tmp_path / "old.sqlite3"
    old = RunStore(path)
    old.start_run("historical", session_id="legacy", state="completed")
    with old._connect() as db:
        db.execute("DROP TABLE task_evidence")
        db.execute("DROP TABLE task_records")
        db.execute("DROP TABLE capsule_attempts")
        db.execute("UPDATE schema_meta SET version=13 WHERE singleton=1")
    migrated = RunStore(path)
    assert migrated.run("historical")["state"] == "completed"
    assert TaskStateStore(migrated).completion("historical")[0] == "needs_review"
    with migrated._connect(readonly=True) as db:
        assert db.execute("SELECT version FROM schema_meta").fetchone()[0] == SCHEMA_VERSION


def test_dead_worker_is_presented_as_paused_without_launching(environment):
    _, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    progress.value["owner_pid"] = 99999999
    progress.store.save(progress.value)
    presented = progress.store.list(value["id"])[0]
    assert presented["state"] == "paused"
    assert progress.store.get("first")["run_ids"] == ["first"]


def test_new_checks_invalidate_older_completion_receipts(environment):
    workspace, _, _, _ = environment
    store, run = verifier(environment)
    (workspace / "result.txt").write_text("ready")
    run.verify([check()], None)
    record = store.get("test")
    record["checks"].append(check("new", kind="human_review"))
    store.save(record)
    assert store.completion("test")[0] == "needs_review"


def test_native_tool_failure_is_durable_even_without_classical_tool_messages(environment):
    from test_chatgpt_app_server import FakeManagedRuntime, _managed_core
    workspace, _, _, _ = environment
    core = _managed_core(workspace, FakeManagedRuntime())
    core._emit({"type": "tool_result", "id": "tool-1", "tool": "read_file",
                "summary": "Read required.txt", "result": "Error: required input missing", "ok": False})
    failures = SessionStore.unresolved_failures(core.session.path)
    assert failures[0]["detail"] == "Error: required input missing"
    core._emit({"type": "tool_result", "id": "tool-2", "tool": "read_file",
                "summary": "Read required.txt", "result": "available", "ok": True})
    assert SessionStore.unresolved_failures(core.session.path) == []


def test_private_context_is_not_compacted_or_added_to_capsule_context(environment):
    from ollama_code.context_preservation import runtime_context
    _, core, _, _ = environment
    core.identity_mode = True
    assert runtime_context(core) == ""
    core.messages = [core.system_message(), {"role": "user", "content": "private request"}]
    before = list(core.messages)
    core._slash_compact()
    assert core.messages == before


def test_essential_instructions_that_cannot_fit_stop_before_generation(environment):
    from test_backend import FakeClient
    _, core, _, _ = environment
    core.config.update(context_window=32768, auto_compact=True)
    core.client = FakeClient([])
    core.run_turn("Mandatory constraint " * 12000, allow_tools=False)
    assert core.last_turn_result["reason"] == "context_limit"
    assert core.client.calls == 0
    assert len(SessionStore.authoritative_inputs(core.session.path)[-1]["content"]) > 200000


def test_unsettled_action_cannot_complete_even_after_all_steps_were_verified(environment):
    workspace, _, _, svc = environment
    _, value = capsule(environment)
    progress = CapsuleRuntime(svc, value, "first")
    for identifier, path, content in [("first", "result.txt", "ready"), ("second", "second.txt", "done")]:
        progress.start_step(identifier)
        (workspace / path).write_text(content)
        progress.finish_step(identifier, svc.decide)
    progress.action_started("uncertain-review-repair", "send_message")
    assert progress.final_check(svc.decide)["verification_status"] == "needs_review"
    progress.settle("completed")
    assert progress.value["state"] == "needs_review"


def test_compaction_records_usage_in_the_normal_dashboard_store(environment):
    from ollama_code.chat_service import ChatService
    _, core, runs, _ = environment
    service = ChatService(core)
    service.run_store = runs
    core.context_limit = 128000
    core.messages = [core.system_message()]
    core._add_message({"role": "user", "content": "Preserve constraints"})
    core._add_message({"role": "assistant", "content": "Exploration"})
    core.client = SimpleNamespace(chat_stream=lambda *a, **k: ChatResponse(
        content_parts=["Summary"], prompt_eval_count=600, eval_count=25))
    assert core._slash_compact()["data"]["summary"] == "Summary"
    assert runs.usage_summary()["solo"]["turns"] == 1
    assert core.total_prompt_tokens + core.total_completion_tokens == 625
