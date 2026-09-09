import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from ollama_code.goals import GoalBudgetExceeded, GoalError, GoalStore
from ollama_code.runstore import SCHEMA_VERSION, RunStore, RunStoreError


@pytest.fixture
def stores(tmp_path):
    runs = RunStore(tmp_path / "runs.sqlite3")
    return runs, GoalStore(runs)


def make_goal(goals, **kwargs):
    return goals.create("chat", "Finish the requested work", execution={
        "provider": "ollama", "model": "local", "workspace_root": "/workspace", "runner": "solo",
    }, **kwargs)


def start(goals, runs, goal):
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    return run


def report(goals, goal, run, status="continue", **kwargs):
    return goals.report(goal["id"], run["id"], goal["revision"], status=status,
                        summary=kwargs.get("summary", "Implemented the first step"),
                        evidence=kwargs.get("evidence", ["The targeted check passed"]),
                        next_step="Run the remaining checks" if status == "continue" else "",
                        blocker="User answer needed" if status == "blocked" else "")


def test_goal_schema_and_unfinished_uniqueness(stores):
    runs, goals = stores
    goal = make_goal(goals)
    assert runs._existing_schema_version() == SCHEMA_VERSION
    assert goals.for_session("chat")["id"] == goal["id"]
    with pytest.raises(GoalError, match="unfinished"):
        make_goal(goals)
    goals.update(goal["id"], "cancel")
    assert make_goal(goals)["id"] != goal["id"]


def test_old_task_evidence_and_paraphrased_reports_do_not_restart_progress(stores):
    from ollama_code.task_journal import TaskJournal
    runs, goals = stores
    TaskJournal(runs, "session:chat").milestone("check_passed", {"check_hash": "prior-task-result"})
    goal = make_goal(goals)
    for index, summary in enumerate(("Investigating the issue", "Looking into a different approach", "Considering another possibility")):
        run = start(goals, runs, goal)
        report(goals, goal, run, summary=summary)
        runs.set_state(run["id"], "completed")
        saved = goals.reconcile_run(goal["id"], run["id"])
        assert saved["no_progress_count"] == index + 1
    assert saved["status"] == "paused"


def test_claim_is_atomic_across_store_instances(stores):
    runs, goals = stores
    goal = make_goal(goals)
    def claim(_):
        return GoalStore(RunStore(runs.path)).claim(goal["id"], goal["revision"])["run"]["id"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        ids = list(pool.map(claim, range(8)))
    assert len(set(ids)) == 1
    assert len(runs.list_runs(session_id="chat")) == 1
    assert goals.get(goal["id"])["continuation_ordinal"] == 1
    runs.admit(ids[0])
    assert goals.claim(goal["id"], goal["revision"])["run"] is None


def test_pause_invalidates_queued_admission_and_preserves_allowances(stores):
    runs, goals = stores
    goal = make_goal(goals, model_call_budget=4)
    run = goals.claim(goal["id"], goal["revision"])["run"]
    paused = goals.update(goal["id"], "pause")
    assert paused["status"] == "paused"
    with pytest.raises(RunStoreError):
        runs.admit(run["id"])
    with pytest.raises(GoalError, match="changed"):
        goals.claim(goal["id"], goal["revision"])
    assert goals.get(goal["id"])["model_call_budget"] == 4


def test_usage_reservation_checkpoint_and_settlement_are_idempotent(stores):
    runs, goals = stores
    goal = make_goal(goals, model_call_budget=2, token_budget=100)
    run = start(goals, runs, goal)
    for _ in range(2):
        goals.reserve_usage(goal["id"], run["id"], "call1", prompt_tokens=20, completion_tokens=10)
    goals.checkpoint_usage(goal["id"], run["id"], "call1", prompt_tokens=20, completion_tokens=8)
    for _ in range(2):
        goals.settle_usage(goal["id"], run["id"], "call1", prompt_tokens=20, completion_tokens=10)
    goals.checkpoint_usage(goal["id"], run["id"], "call1", prompt_tokens=5, completion_tokens=1)
    saved = goals.get(goal["id"])
    assert (saved["model_calls"], saved["prompt_tokens"], saved["completion_tokens"]) == (1, 20, 10)
    goals.reserve_usage(goal["id"], run["id"], "call2")
    with pytest.raises(GoalBudgetExceeded):
        goals.reserve_usage(goal["id"], run["id"], "call3")


def test_parallel_token_reservations_cannot_exceed_remaining(stores):
    runs, goals = stores
    goal = make_goal(goals, token_budget=50)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "a", prompt_tokens=30)
    with pytest.raises(GoalBudgetExceeded):
        goals.reserve_usage(goal["id"], run["id"], "b", prompt_tokens=30)


def test_completion_commits_only_at_outer_boundary_with_evidence(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    with pytest.raises(GoalError, match="evidence"):
        report(goals, goal, run, "complete", evidence=[])
    report(goals, goal, run, "complete")
    assert goals.get(goal["id"])["status"] == "active"
    completed = goals.reconcile_run(goal["id"], run["id"])
    assert completed["status"] == "needs_review"
    assert goals.reconcile_run(goal["id"], run["id"]) == completed
    assert goals.claim(goal["id"], goal["revision"])["run"] is None


@pytest.mark.parametrize("uncertain", ["model", "mutation"])
def test_unknown_call_or_action_blocks_completion_and_recovery(stores, uncertain):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    if uncertain == "model":
        goals.reserve_usage(goal["id"], run["id"], "call")
    else:
        goals.start_action(goal["id"], run["id"], "write", tool="write_file")
    report(goals, goal, run, "complete")
    runs.set_state(run["id"], "interrupted")
    saved = GoalStore(RunStore(runs.path)).recover()[0]
    assert saved["status"] == "blocked"
    assert "uncertain" in saved["reason"]


def test_mutation_after_report_invalidates_completion(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    report(goals, goal, run, "complete")
    goals.start_action(goal["id"], run["id"], "write", tool="write_file")
    goals.finish_action(goal["id"], run["id"], "write")
    assert goals.reconcile_run(goal["id"], run["id"])["status"] == "active"
    assert goals.get(goal["id"])["no_progress_count"] == 1


def test_queued_inputs_fence_completion_until_each_message_attaches(stores):
    runs, goals = stores
    goal = make_goal(goals)
    old_run = start(goals, runs, goal)
    report(goals, goal, old_run, "complete")
    goal = goals.update(goal["id"], "steer", input_id="first")
    assert goals.update(goal["id"], "steer", input_id="first")["revision"] == goal["revision"]
    goal = goals.update(goal["id"], "steer", input_id="second")
    runs.set_state(old_run["id"], "completed")
    assert goals.reconcile_run(goal["id"], old_run["id"])["status"] == "active"
    assert goals.claim(goal["id"], goal["revision"])["run"] is None
    runs.queue_run("manual", session_id="chat", run_kind="solo")
    goal = goals.attach_run(goal["id"], "manual", goal["revision"], input_id="first")
    assert goal["pending_input_count"] == 1
    runs.admit("manual")  # Remaining manual input does not prevent this message.
    report(goals, goal, {"id": "manual"}, "complete")
    assert goals.reconcile_run(goal["id"], "manual")["status"] == "active"


def test_steering_preserves_current_execution_but_invalidates_its_report(stores):
    runs, goals = stores
    goal = make_goal(goals, model_call_budget=10)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "first")
    steered = goals.update(goal["id"], "steer", input_id="next-message")
    assert steered["revision"] > goal["revision"]
    assert steered["execution_revision"] == goal["execution_revision"]
    goals.settle_usage(goal["id"], run["id"], "first", prompt_tokens=10)
    goals.reserve_usage(goal["id"], run["id"], "second")
    goals.settle_usage(goal["id"], run["id"], "second", prompt_tokens=5)
    goals.start_action(goal["id"], run["id"], "write", tool="write_file")
    goals.finish_action(goal["id"], run["id"], "write")
    with pytest.raises(GoalError, match="changed"):
        report(goals, goal, run, "complete")
    runs.set_state(run["id"], "completed")
    assert goals.reconcile_run(goal["id"], run["id"])["status"] == "active"
    next_run = goals.queue_user_run(goal["id"], "next", steered["revision"], session_id="chat", input_id="next-message")
    assert next_run["manifest"]["goal_revision"] == steered["revision"]
    assert goals.get(goal["id"])["model_calls"] == 2


@pytest.mark.parametrize("uncertain", ["model", "mutation"])
def test_stale_goal_run_uncertainty_blocks_next_user_attachment(stores, uncertain):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    if uncertain == "model":
        goals.reserve_usage(goal["id"], run["id"], "uncertain")
    else:
        goals.start_action(goal["id"], run["id"], "uncertain", tool="write_file")
    steered = goals.update(goal["id"], "steer", input_id="next-message")
    runs.set_state(run["id"], "interrupted")
    with pytest.raises(GoalError, match="uncertain"):
        goals.queue_user_run(goal["id"], "next", steered["revision"], session_id="chat", input_id="next-message")
    assert runs.run("next") is None
    assert goals.reconcile_run(goal["id"], run["id"])["status"] == "blocked"


def test_later_steering_does_not_cancel_queued_manual_turn(stores):
    runs, goals = stores
    goal = make_goal(goals)
    goals.queue_user_run(goal["id"], "first", goal["revision"], session_id="chat")
    steered = goals.update(goal["id"], "steer", input_id="second")
    assert runs.run("first")["state"] == "queued"
    runs.admit("first")
    bound = goals.bind(goal["id"], "first", goal["revision"])
    assert bound["revision"] == steered["revision"]
    assert bound["run_revision"] == goal["revision"]
    goals.reserve_usage(goal["id"], "first", "still-authorized")


def test_restore_all_goals_and_usage_survive_run_retention(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "call")
    goals.settle_usage(goal["id"], run["id"], "call", prompt_tokens=9, completion_tokens=3)
    report(goals, goal, run, "complete")
    runs.set_state(run["id"], "completed")
    goals.reconcile_run(goal["id"], run["id"])
    goals.update(goal["id"], "accept", expected_revision=goal["revision"])
    with runs._connect() as connection:
        connection.execute("UPDATE runs SET updated_at=?", (time.time() - 100 * 86400,))
    runs.prune(retention_days=1)
    assert runs.run(run["id"]) is None
    saved = GoalStore(RunStore(runs.path)).for_session("chat")
    assert saved["status"] == "completed"
    assert saved["model_calls"] == 1
    assert saved["evidence"]


def test_open_goal_current_run_is_retention_protected(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    runs.set_state(run["id"], "interrupted")
    with runs._connect() as connection:
        connection.execute("UPDATE runs SET updated_at=?", (time.time() - 100 * 86400,))
    runs.prune(retention_days=1, max_bytes=1)
    assert runs.run(run["id"]) is not None


def test_required_answer_is_immediate_block_and_shutdown_is_resumable(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    saved = goals.reconcile_run(goal["id"], run["id"], outcome="waiting_input")
    assert saved["status"] == "blocked"
    goal = goals.update(goal["id"], "resume")
    runs.set_state(run["id"], "interrupted")
    run = start(goals, runs, goal)
    assert goals.reconcile_run(goal["id"], run["id"], outcome="app_shutdown")["status"] == "active"


def test_execution_strips_credentials_and_keeps_team_configuration(stores):
    _, goals = stores
    goal = goals.create("chat", "Work", execution={"provider": "ollama", "model": "m", "workspace_root": "/w",
                                                  "api_key": "secret", "agent_config": {"authorization": "Bearer key", "name": "worker"},
                                                  "team_configuration": "saved comparison"})
    assert "api_key" not in goal["execution"]
    assert goal["execution"]["agent_config"]["authorization"] == "[redacted]"
    assert goal["execution"]["team_configuration"] == "saved comparison"


@pytest.mark.parametrize("has_report", [False, True])
def test_third_consecutive_turn_without_progress_pauses(stores, has_report):
    runs, goals = stores
    goal = make_goal(goals)
    for index in range(3):
        run = start(goals, runs, goal)
        if has_report:
            report(goals, goal, run)
        runs.set_state(run["id"], "completed")
        saved = goals.reconcile_run(goal["id"], run["id"])
        assert saved["no_progress_count"] == index + 1
        assert saved["status"] == ("paused" if index == 2 else "active")


@pytest.mark.parametrize("outcome", ["error", "max_iterations", "model_call_budget", "interrupted"])
def test_runtime_safety_stops_pause_without_retry(stores, outcome):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    assert goals.reconcile_run(goal["id"], run["id"], outcome=outcome)["status"] == "paused"


def test_invalid_repaired_goal_report_pauses_instead_of_external_block(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    saved = goals.reconcile_run(goal["id"], run["id"], reason="invalid_goal_report")
    assert saved["status"] == "paused"
    assert "valid goal progress report" in saved["reason"]


def test_edit_requires_revision_and_pauses_without_resetting_usage(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "call")
    goals.settle_usage(goal["id"], run["id"], "call", prompt_tokens=10)
    with pytest.raises(GoalError):
        goals.update(goal["id"], "edit", objective="More work")
    changed = goals.update(goal["id"], "edit", expected_revision=goal["revision"], objective="More work")
    assert changed["status"] == "paused"
    assert changed["prompt_tokens"] == 10


def test_resume_cancelled_queue_claims_without_needing_list_refresh(stores):
    runs, goals = stores
    goal = make_goal(goals)
    first = goals.claim(goal["id"], goal["revision"])["run"]
    goals.update(goal["id"], "pause")
    resumed = goals.update(goal["id"], "resume")
    second = goals.claim(goal["id"], resumed["revision"])["run"]
    assert second["id"] != first["id"]
    assert second["state"] == "queued"


def test_team_checkpoint_recovery_keeps_run_and_updates_binding(stores):
    runs, goals = stores
    goal = goals.create("chat", "Finish work", execution={"provider": "ollama", "model": "m", "workspace_root": "/w",
                                                          "runner": "team", "team_id": "team"})
    first = start(goals, runs, goal)
    runs.set_state(first["id"], "interrupted", recoverable=True)
    goals.update(goal["id"], "pause")
    resumed = goals.update(goal["id"], "resume")
    recovery = goals.claim(goal["id"], resumed["revision"])["run"]
    assert recovery["id"] == first["id"]
    assert recovery["manifest"]["goal_revision"] == resumed["revision"]
    assert goals.bind(goal["id"], first["id"], resumed["revision"])["id"] == goal["id"]


def test_run_restart_cannot_drop_trusted_goal_metadata(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    runs.start_run(run["id"], session_id="chat", state="running", manifest={"different": "runtime payload"})
    manifest = runs.run(run["id"])["manifest"]
    assert manifest["goal_id"] == goal["id"]
    assert manifest["goal_revision"] == goal["revision"]
    assert manifest["different"] == "runtime payload"


@pytest.mark.parametrize("unknown_call", [False, True])
def test_recover_orphaned_live_run_after_hard_kill(stores, unknown_call):
    runs, goals = stores
    goal = make_goal(goals)
    run = start(goals, runs, goal)
    if unknown_call:
        goals.reserve_usage(goal["id"], run["id"], "in-flight")
    with runs._connect() as connection:
        connection.execute("UPDATE runs SET owner_pid=0 WHERE id=?", (run["id"],))
    recovered = goals.recover(lease_active=lambda _: False)[0]
    assert runs.run(run["id"])["state"] == "interrupted"
    assert recovered["status"] == ("blocked" if unknown_call else "active")


def test_recovery_waits_for_provider_lease_and_preserves_never_admitted_queue(stores):
    runs, goals = stores
    goal = make_goal(goals)
    run = goals.claim(goal["id"], goal["revision"])["run"]
    with runs._connect() as connection:
        connection.execute("UPDATE runs SET owner_pid=0 WHERE id=?", (run["id"],))
    goals.recover(lease_active=lambda _: False)
    assert runs.run(run["id"])["state"] == "queued"
    runs.admit(run["id"])
    with runs._connect() as connection:
        connection.execute("UPDATE runs SET owner_pid=0 WHERE id=?", (run["id"],))
    goals.recover(lease_active=lambda _: True)
    assert runs.run(run["id"])["state"] == "dispatching"


@pytest.mark.parametrize("budget", [None, 100])
def test_unmeasured_tokens_allow_unbudgeted_goals_only(stores, budget):
    runs, goals = stores
    goal = make_goal(goals, token_budget=budget)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "call")
    goals.settle_usage(goal["id"], run["id"], "call", tokens_known=False)
    report(goals, goal, run, "complete")
    result = goals.reconcile_run(goal["id"], run["id"])
    assert result["token_usage_available"] is False
    assert result["status"] == ("needs_review" if budget is None else "blocked")


@pytest.mark.parametrize("allowance", [{"token_budget": 100}, {"model_call_budget": 10}])
def test_resume_does_not_turn_interrupted_usage_into_known_zero(stores, allowance):
    runs, goals = stores
    goal = make_goal(goals, **allowance)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "uncertain")
    runs.set_state(run["id"], "interrupted")
    assert goals.recover()[0]["status"] == "blocked"
    resumed = goals.update(goal["id"], "resume")
    assert resumed["token_usage_available"] is False
    assert resumed["model_call_usage_available"] is False
    claimed = goals.claim(goal["id"], resumed["revision"])
    assert claimed["run"] is None
    assert claimed["goal"]["status"] == "blocked"
    assert "usage is unavailable" in claimed["goal"]["reason"]
    assert claimed["goal"]["model_calls"] == 1


def test_late_authoritative_settlement_can_recover_acknowledged_usage(stores):
    runs, goals = stores
    goal = make_goal(goals, token_budget=100, model_call_budget=10)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "uncertain")
    runs.set_state(run["id"], "interrupted")
    goals.recover()
    goals.update(goal["id"], "resume")
    goals.checkpoint_usage(goal["id"], run["id"], "uncertain", prompt_tokens=10, completion_tokens=5)
    assert goals.get(goal["id"])["token_usage_available"] is False
    goals.settle_usage(goal["id"], run["id"], "uncertain", model_calls=2, prompt_tokens=20, completion_tokens=5)
    saved = goals.get(goal["id"])
    assert saved["token_usage_available"] is True
    assert saved["model_call_usage_available"] is True
    assert saved["model_calls"] == 2
    assert (saved["prompt_tokens"], saved["completion_tokens"]) == (20, 5)
    assert goals.claim(goal["id"], saved["revision"])["run"] is not None


def test_explicit_cap_removal_allows_unknown_usage_without_reset(stores):
    runs, goals = stores
    goal = make_goal(goals, token_budget=100, model_call_budget=10)
    run = start(goals, runs, goal)
    goals.reserve_usage(goal["id"], run["id"], "uncertain")
    runs.set_state(run["id"], "interrupted")
    goals.recover()
    resumed = goals.update(goal["id"], "resume")
    edited = goals.update(goal["id"], "edit", expected_revision=resumed["revision"],
                          token_budget=None, model_call_budget=None)
    assert edited["model_calls"] == 1
    resumed = goals.update(goal["id"], "resume")
    assert resumed["token_usage_available"] is False
    assert goals.claim(goal["id"], resumed["revision"])["run"] is not None


def test_goal_projection_is_empty_for_older_readonly_schema(tmp_path):
    path = tmp_path / "old.sqlite3"
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE schema_meta(singleton INTEGER,version INTEGER)")
        connection.execute("INSERT INTO schema_meta VALUES(1,999)")
    goals = GoalStore(RunStore(path))
    assert goals.list() == []
    assert goals.get("none") is None
    assert goals.for_session("none") is None
    with pytest.raises(GoalError, match="read-only"):
        make_goal(goals)


def test_discard_input_is_exact_and_idempotent(stores):
    _, goals = stores
    goal = make_goal(goals)
    goals.update(goal["id"], "steer", input_id="a")
    goals.update(goal["id"], "steer", input_id="b")
    changed = goals.update(goal["id"], "discard_input", input_id="a")
    assert changed["pending_input_count"] == 1
    assert goals.update(goal["id"], "discard_input", input_id="a")["revision"] == changed["revision"]
    assert goals.update(goal["id"], "discard_input", input_id="b")["pending_user_input"] is False


def test_reopening_lost_user_queue_blocks_until_explicit_resume(stores):
    runs, goals = stores
    goal = make_goal(goals)
    goals.update(goal["id"], "steer", input_id="lost")
    with runs._connect() as connection:
        connection.execute("UPDATE goal_inputs SET owner_pid=0")
    saved = goals.recover()[0]
    assert saved["status"] == "blocked"
    assert "queued user input" in saved["reason"]
    assert goals.update(goal["id"], "resume")["pending_user_input"] is False


@pytest.fixture
def api_service(stores, tmp_path, monkeypatch):
    from types import SimpleNamespace

    from ollama_code.api import goals as api
    runs, _ = stores
    session_path = tmp_path / "chat.jsonl"
    session_path.write_text('{}\n')
    monkeypatch.setattr(api.SessionStore, "path_for", lambda _: session_path)
    monkeypatch.setattr(api.SessionStore, "header", lambda _: {"cwd": str(tmp_path)})
    monkeypatch.setattr(api.SessionStore, "_summary_record", lambda _: {})
    monkeypatch.setattr(api.SessionMeta, "get", lambda _: {})
    return SimpleNamespace(run_store=runs, busy=False,
                           core=SimpleNamespace(session=SimpleNamespace(session_id="chat"), cwd=str(tmp_path), identity_mode=False))


def test_goal_api_roundtrip_claim_and_revision_errors(api_service, tmp_path):
    from fastapi import HTTPException

    from ollama_code.api.goals import goal_claim, goal_create, goal_list, goal_update, session_goal
    goal = goal_create(api_service, "chat", {"objective": "Work", "execution": {
        "provider": "ollama", "model": "m", "workspace_root": str(tmp_path)}})
    assert session_goal(api_service, "chat")["goal"]["id"] == goal["id"]
    assert goal_list(api_service, False)["goals"][0]["id"] == goal["id"]
    claimed = goal_claim(api_service, goal["id"], {"expected_revision": goal["revision"]})
    assert claimed["run"]["manifest"]["goal_id"] == goal["id"]
    paused = goal_update(api_service, goal["id"], {"action": "pause"})
    assert paused["status"] == "paused"
    with pytest.raises(HTTPException) as error:
        goal_claim(api_service, goal["id"], {"expected_revision": goal["revision"]})
    assert error.value.status_code == 409


@pytest.mark.parametrize("invalid", ["busy", "identity", "agent", "workspace"])
def test_goal_api_rejects_unavailable_or_mismatched_chat(api_service, monkeypatch, invalid):
    from fastapi import HTTPException

    from ollama_code.api import goals as api
    body = {"objective": "Work", "execution": {"provider": "ollama", "model": "m"}}
    if invalid == "busy":
        api_service.busy = True
    elif invalid == "identity":
        api_service.core.identity_mode = True
    elif invalid == "agent":
        monkeypatch.setattr(api.SessionMeta, "get", lambda _: {"agent_trigger_id": "schedule"})
    else:
        body["execution"]["workspace_root"] = "/a/different/workspace"
    with pytest.raises(HTTPException) as error:
        api.goal_create(api_service, "chat", body)
    assert error.value.status_code == 409


def test_manual_queue_api_attaches_only_exact_session_goal(api_service):
    from ollama_code.api.runs import run_queue
    goal = make_goal(GoalStore(api_service.run_store))
    goal = GoalStore(api_service.run_store).update(goal["id"], "steer", input_id="manual")
    queued = run_queue(api_service, {"session_id": "chat", "run_id": "manual-run", "goal_id": goal["id"],
                                     "goal_revision": goal["revision"], "goal_input_id": "manual"})
    assert queued["manifest"]["goal_id"] == goal["id"]
    assert GoalStore(api_service.run_store).get(goal["id"])["pending_input_count"] == 0


def test_manual_queue_rolls_back_reservation_if_goal_attachment_fails(stores, monkeypatch):
    runs, goals = stores
    goal = make_goal(goals)
    goal = goals.update(goal["id"], "steer", input_id="input")
    def fail(*args, **kwargs):
        raise GoalError("simulated interruption before binding")
    monkeypatch.setattr(goals, "attach_run", fail)
    with pytest.raises(GoalError):
        goals.queue_user_run(goal["id"], "manual", goal["revision"], session_id="chat", input_id="input")
    assert runs.run("manual") is None
    assert goals.get(goal["id"])["pending_input_count"] == 1


def test_minimal_user_queue_uses_saved_team_and_rejects_route_overrides(stores):
    _, goals = stores
    goal = goals.create("chat", "Work", execution={"provider": "ollama", "model": "m", "workspace_root": "/saved",
                                                  "execution_path": "/saved/tree", "runner": "team", "team_id": "saved-team",
                                                  "team_name": "Saved team", "execution_environment": "worktree", "solo_swarm": True})
    run = goals.queue_user_run(goal["id"], "run", goal["revision"], session_id="chat", request="User feedback",
                              run_kind="solo", team_id="other-team", workspace_root="/wrong", execution_environment="local")
    assert run["run_kind"] == "team"
    assert run["team_id"] == "saved-team"
    assert run["workspace_root"] == "/saved"
    assert run["execution_path"] == "/saved/tree"
    assert run["execution_environment"] == "worktree"
    assert run["manifest"]["solo_swarm"] is True


def test_pause_resume_preserves_live_queued_input_fences(stores):
    _, goals = stores
    goal = make_goal(goals)
    goals.update(goal["id"], "steer", input_id="first")
    goals.update(goal["id"], "steer", input_id="second")
    goals.update(goal["id"], "pause")
    resumed = goals.update(goal["id"], "resume")
    assert resumed["pending_input_count"] == 2
    assert goals.claim(goal["id"], resumed["revision"])["run"] is None


def test_generic_retry_and_replay_reject_goal_owned_runs(api_service):
    import asyncio

    from fastapi import HTTPException

    from ollama_code.api.runs import _resume_orchestration, run_retry
    goals = GoalStore(api_service.run_store)
    goal = make_goal(goals)
    run = start(goals, api_service.run_store, goal)
    api_service.run_store.set_state(run["id"], "interrupted", recoverable=True)
    with pytest.raises(HTTPException, match="Goal Resume"):
        run_retry(api_service, run["id"])
    with pytest.raises(HTTPException, match="Goal Resume"):
        asyncio.run(_resume_orchestration(api_service, lambda *args: None, run["id"], {}, action="replay"))


def test_archiving_pauses_and_delete_cancels_goal_before_session_mutation(api_service, monkeypatch):
    from ollama_code.api import sessions as api
    goals = GoalStore(api_service.run_store)
    goal = make_goal(goals)
    api_service.core.session.session_id = "other"
    monkeypatch.setattr(api.SessionStore, "find", lambda _: True)
    monkeypatch.setattr(api, "update_session_metadata", lambda *args, **kwargs: kwargs)
    api.session_metadata_update("chat", api_service, {"archived": True})
    assert goals.get(goal["id"])["status"] == "paused"
    api._transition_session_goal(api_service, "chat", "cancel")
    assert goals.get(goal["id"])["status"] == "cancelled"
