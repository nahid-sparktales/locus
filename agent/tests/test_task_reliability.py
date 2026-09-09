from __future__ import annotations

from types import SimpleNamespace

import pytest

from ollama_code.core import AgentCore
from ollama_code.file_history import FileHistory, reverse_text
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.remote import _consume_anthropic_event
from ollama_code.runstore import SCHEMA_VERSION, RunStore
from ollama_code.task_journal import TaskJournal
from ollama_code.task_state import TaskStateError, TaskStateStore, TaskVerifier
from ollama_code.usage_ledger import UsageLedger, UsageLimitError


@pytest.fixture
def task(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    runs = RunStore(tmp_path / "runs.db")
    runs.start_run("run", session_id="session", workspace_root=str(root), execution_path=str(root), request="Make a result")
    journal = TaskJournal.bind(runs, runs.run("run"))
    core = AgentCore(cwd=str(root), config={"permission_mode": "bypass"})
    core.task_journal = journal
    yield SimpleNamespace(root=root, runs=runs, journal=journal, core=core,
                          history=FileHistory(journal, str(root)))
    core.close()


def test_plan_identity_survives_new_run_and_rejects_stale_approval(task):
    plan = {"id": "plan1", "steps": ["Do it"], "constraints": ["Keep API"]}
    ref = task.journal.save_plan(plan, str(task.root))
    task.runs.start_run("next", session_id="session")
    resumed = TaskJournal.bind(task.runs, task.runs.run("next"))
    assert resumed.task_id == task.journal.task_id
    assert resumed.approved_plan(ref, str(task.root)) == plan
    resumed.save_plan({**plan, "id": "plan2"}, str(task.root))
    with pytest.raises(TaskStateError, match="changed"):
        resumed.approved_plan(ref, str(task.root))


def test_plan_source_changes_require_refresh_before_execution(task):
    path = task.root / "source.txt"
    path.write_text("original")
    plan = {"id": "bound-plan", "files": ["source.txt"], "steps": ["Change source"]}
    reference = task.journal.save_plan(plan, str(task.root))
    assert task.journal.snapshot()["plan"]["approval_reference"] == reference
    path.write_text("concurrent edit")
    with pytest.raises(TaskStateError, match="source files changed"):
        task.journal.approved_plan(reference, str(task.root))
    assert task.journal.approved_plan(reference, str(task.root), validate_sources=False) == plan


@pytest.mark.parametrize("artifact_present", [True, False])
def test_actual_work_entrypoint_enforces_saved_plan_checks(task, monkeypatch, artifact_present):
    from test_backend import FakeClient

    from ollama_code import server
    from ollama_code.chat_service import ChatService
    service = ChatService(task.core)
    service.close_codex()
    service.run_store = task.runs
    task.runs.start_run("approved-work", session_id=task.core.session.session_id, workspace_root=str(task.root), execution_path=str(task.root))
    journal = TaskJournal.bind(task.runs, task.runs.run("approved-work"))
    reference = journal.save_plan({"id": "entry-plan", "steps": ["Deliver artifact"], "acceptance_checks": [
        {"id": "output", "kind": "file_exists", "path": "result", "requirement": "Result exists"}]}, str(task.root))
    if artifact_present:
        (task.root / "result").write_text("ready")
    task.core.client = FakeClient([ChatResponse(content_parts=["Done"], prompt_eval_count=4, eval_count=1)])
    for method in ("_automatic_memory_context", "_automatic_continuity_context", "_capture_continuity_snapshot"):
        monkeypatch.setattr(server, method, lambda *a, **k: "")
    server._run_user_turn(service, "Execute approved plan", False, reserved_run_id="approved-work",
                          solo_swarm_enabled=False, approved_plan=reference)
    assert task.core.last_turn_result["reason"] == ("complete" if artifact_present else "verification_required")
    assert task.runs.run("approved-work")["manifest"]["_approved_task_plan"] == reference
    record = TaskStateStore(task.runs).get("work:" + journal.task_id)
    assert record["verification_status"] == ("passed" if artifact_present else "failed")


@pytest.mark.parametrize("measured,completed", [(True, 2), (False, 1)])
def test_read_wave_has_verified_steps_and_no_model_dispatch(task, monkeypatch, measured, completed):
    from ollama_code import server
    from ollama_code.capsule_progress import CapsuleRuntime
    from ollama_code.capsule_read_checks import run_read_wave
    from ollama_code.capsules import CapsuleStore
    for name in ("one", "two"):
        (task.root / name).write_text(name)
    capsule = CapsuleStore(str(task.root)).create({"title": "Read inputs", "request": "Inspect sources", "plan": {
        "steps": ["Read one", "Read two"], "step_details": [
            {"id": name, "title": "Read " + name, "files": [name], "execution_kind": "read"} for name in ("one", "two")]},
        "recipe": {"planner_profile_id": "planner", "executor_profile_id": "worker"}})
    if measured:
        task.core.config["parallel_read_policy"] = {"version": 1, "workload": "capsule_read_wave", "correctness_equal": True, "median_improvement": .15, "p95_regression": .02}
    service = SimpleNamespace(core=task.core, run_store=task.runs, emit=lambda _: None, decide=lambda *_: "once",
                              checkpoint=lambda *_: None, current_task=None)
    progress = CapsuleRuntime(service, capsule, "read-run")
    jobs = [SimpleNamespace(id=name, agent_id="worker", execution_kind="read") for name in ("one", "two")]
    prepared = SimpleNamespace(run_id="read-run", profiles={"worker": SimpleNamespace(id="worker", name="Worker", role="writer")},
                               writer_results=[], completed_writer_job_ids=set())
    monkeypatch.setattr(server, "_team_checkpoint_state", lambda *_: {})
    run_read_wave(service, prepared, progress, jobs)
    assert len(prepared.completed_writer_job_ids) == completed
    assert all(s["state"] == "verified" for s in progress.store.get("read-run")["steps"].values())
    assert all(r.model_calls == 0 for r in prepared.writer_results)
    assert task.core.last_turn_result["model_calls"] == 0


def test_review_finding_id_is_stable_across_rereview_normalization():
    from ollama_code.capsule_execution import review_request
    result = SimpleNamespace(agent_id="reviewer", error=None, output='{"verdict":"revise","findings":[{"message":"Fix it"}]}')
    first = review_request([result])
    assert review_request([result]) == first


def test_interrupted_shell_check_keeps_capsule_action_uncertain(task, monkeypatch):
    from ollama_code import core as core_module
    from ollama_code import server
    from ollama_code.capsule_progress import CapsuleRuntime
    from ollama_code.capsule_read_checks import run_read_wave
    from ollama_code.capsules import CapsuleStore
    capsule = CapsuleStore(str(task.root)).create({"title": "Check", "request": "Run saved check", "plan": {
        "steps": ["Check"], "step_details": [{"id": "check", "title": "Check", "execution_kind": "check",
            "acceptance_checks": [{"id": "command", "kind": "command", "command": "fixture-check", "requirement": "Check succeeds"}]}]},
        "recipe": {"planner_profile_id": "planner", "executor_profile_id": "worker"}})
    service = SimpleNamespace(core=task.core, run_store=task.runs, emit=lambda _: None, decide=lambda *_: "once",
                              checkpoint=lambda *_: None, current_task=None)
    progress = CapsuleRuntime(service, capsule, "interrupted-check")
    prepared = SimpleNamespace(run_id="interrupted-check", writer_results=[], completed_writer_job_ids=set(), profiles={})
    def interrupt(*_):
        (task.root / "partial").write_text("mutation committed")
        raise InterruptedError("Response lost")
    monkeypatch.setattr(core_module, "execute_tool", interrupt)
    monkeypatch.setattr(server, "_team_checkpoint_state", lambda *_: {})
    with pytest.raises(InterruptedError):
        run_read_wave(service, prepared, progress, [SimpleNamespace(id="check", agent_id="worker", execution_kind="check")])
    saved = progress.store.get("interrupted-check")
    assert saved["uncertain_action"]["tool"] == "bash"
    assert (task.root / "partial").read_text() == "mutation committed"
    assert task.journal.snapshot()["receipts"][0]["executed"] is True


def test_provider_reused_call_ids_have_distinct_runtime_receipts(task):
    (task.root / "source").write_text("content")
    calls = [ToolCall("read_file", {"path": "source"}, call_id="provider-call") for _ in range(2)]
    for call in calls:
        task.core._run_tool_call(call, lambda *_: "once")
    receipts = task.journal.snapshot()["receipts"]
    assert len(receipts) == 2
    assert len({r["id"] for r in receipts}) == 2
    assert {r["provider_call_id"] for r in receipts} == {"provider-call"}


def test_duplicate_reported_charge_cannot_overwrite_cost(task):
    ledger = UsageLedger(task.journal)
    identifier = ledger.reserve(provider="tool", model="fixture", stage="tools")
    ledger.settle(identifier, {}, model_calls=0, reported_cost=".5")
    ledger.settle(identifier, {}, model_calls=0, reported_cost=".50")
    with pytest.raises(UsageLimitError):
        ledger.settle(identifier, {}, model_calls=0, reported_cost=".6")


def test_anthropic_reservation_covers_highest_cache_write_rate():
    from decimal import Decimal

    from ollama_code.usage_ledger import request_bound
    rates = {"input_tokens": 3, "output_tokens": 15, "cache_creation_5m_input_tokens": 3.75, "cache_creation_1h_input_tokens": 6}
    assert request_bound(SimpleNamespace(auth_style="anthropic"), rates, 1_000_000, 1_000_000) == Decimal(21)
    rates.pop("cache_creation_1h_input_tokens")
    assert request_bound(SimpleNamespace(auth_style="anthropic"), rates, 1_000_000, 100) is None


@pytest.mark.parametrize("already_used", [0, 1])
def test_ordinary_team_repair_rereviews_and_preserves_round_allowance(task, monkeypatch, already_used):
    from ollama_code import server
    from ollama_code.orchestration import AgentResult
    reviewer = SimpleNamespace(id="reviewer", role="reviewer", can_write=False)
    writer = SimpleNamespace(id="writer", role="implementer", can_write=True)
    plan = SimpleNamespace(jobs=[], structured=lambda: {})
    prepared = SimpleNamespace(team=SimpleNamespace(budget=SimpleNamespace(max_rounds=2)), plan=plan,
        profiles={"reviewer": reviewer, "writer": writer}, writer=writer, writer_results=[], run_id="run", original_request="Fix result")
    checkpoints, actions = [], []
    service = SimpleNamespace(core=task.core, checkpoint=lambda name, state: checkpoints.append(state), current_task=None,
                              run_store=task.runs, decide=lambda *_: "once")
    revised = AgentResult("review", "reviewer", "Review", "reviewer", '{"verdict":"revise","findings":["Repair result"]}', [], 0, 0, 1)
    approved = AgentResult("review", "reviewer", "Review", "reviewer", '{"verdict":"approved"}', [], 0, 0, 1)
    def repair(*args, **kwargs):
        actions.append("repair")
        assert kwargs["model_call_limit"] == 2  # one reviewer and synthesis reserved
        (task.root / "result").write_text("repaired")
        task.core.last_turn_result = {"reason": "complete"}
        return AgentResult("repair", "writer", "Writer", "implementer", "Repaired", [], 0, 0, 1)
    def review(*args, **kwargs):
        actions.append("review")
        assert (task.root / "result").read_text() == "repaired"
        return [approved]
    orchestrator = SimpleNamespace(remaining_model_calls=lambda _: 4, review=review, usage=lambda: {})
    monkeypatch.setattr(server, "_run_team_writer", repair)
    monkeypatch.setattr(server, "_install_writer_route", lambda *_: None)
    monkeypatch.setattr(server, "_restore_writer_route", lambda *_: None)
    monkeypatch.setattr(server, "_team_checkpoint_state", lambda p, *a, **k: {"repair_count": p.repair_count})
    monkeypatch.setattr(server, "_task_diff", lambda *_: "result diff")
    manifest = {"_resume": {"repair_count": already_used}}
    if already_used:
        with pytest.raises(server.TeamWriterBudgetPause, match="allowance is exhausted"):
            server._repair_team_reviews(service, orchestrator, prepared, manifest, [revised])
        assert actions == []
    else:
        assert server._repair_team_reviews(service, orchestrator, prepared, manifest, [revised]) == [approved]
        assert actions == ["repair", "review"]
        assert checkpoints[0]["repair_count"] == 1
        assert prepared.review_files


def test_concurrent_checks_have_independent_execution_receipts(task):
    for name in ("one", "two"):
        (task.root / name).write_text(name)
    store = TaskStateStore(task.runs)
    store.ensure("checks", request="Both", revision=1, workspace=str(task.root), execution=str(task.root))
    checks = [{"id": n, "kind": "file_contains", "path": n, "value": n, "requirement": n} for n in ("one", "two")]
    result = TaskVerifier(store, "checks", task.core, "run", parallelism=2).verify(checks, lambda *_: "once")
    assert result["verification_status"] == "passed"
    receipts = task.journal.snapshot()["receipts"]
    assert len({r["id"] for r in receipts}) == 2
    assert {next(iter(r["fingerprints"])) for r in receipts} == {"one", "two"}


def test_command_receipt_is_invocation_scoped_and_not_previous_result(task):
    first = ToolCall("bash", {"command": "exit 7"})
    second = ToolCall("bash", {"command": "exit 0"})
    task.core._run_tool_call(first, lambda *_: "once")
    task.core._run_tool_call(second, lambda *_: "once")
    assert first.execution_receipt["command"]["exit_code"] == 7
    assert second.execution_receipt["command"]["exit_code"] == 0


def test_cache_usage_is_complete_and_cumulative():
    response = ChatResponse()
    def consume(event):
        _consume_anthropic_event(event, response, {}, {}, None, None)
    consume({"type": "message_start", "message": {"usage": {"input_tokens": 100,
        "cache_read_input_tokens": 5000, "cache_creation_input_tokens": 2000,
        "cache_creation": {"ephemeral_5m_input_tokens": 1500, "ephemeral_1h_input_tokens": 500}}}})
    consume({"type": "message_delta", "usage": {"output_tokens": 20}})
    consume({"type": "message_delta", "usage": {"output_tokens": 30}})
    assert response.prompt_eval_count == 7100
    assert response.eval_count == 30
    assert "cache_creation_input_tokens" not in response.provider_fields["usage"]


def test_cost_ledger_is_idempotent_and_unknown_is_not_free(task):
    ledger = UsageLedger(task.journal)
    identifier = ledger.reserve(provider="anthropic", model="fixture", stage="planning")
    ledger.settle(identifier, {"input_tokens": 100})
    ledger.settle(identifier, {"input_tokens": 100})
    summary = ledger.summary()
    assert len(summary["entries"]) == 1
    assert summary["known_subtotal"] == 0
    assert summary["coverage"] == "partial"
    assert summary["unknown_entries"] == 1
    ledger.set_limit(1)
    with pytest.raises(UsageLimitError, match="reconciled"):
        ledger.reserve(provider="anthropic", model="fixture", stage="repair", upper_bound=.1)
    ledger.reconcile(identifier, amount=.25, note="Reviewed provider receipt")
    with pytest.raises(UsageLimitError, match="reduce"):
        ledger.reconcile(identifier, amount=.1, note="Incorrect reduction")
    identifier = ledger.reserve(provider="anthropic", model="fixture", stage="repair",
                                upper_bound=.5, rates={"input_tokens": 2, "output_tokens": 8})
    ledger.settle(identifier, {"input_tokens": 100000, "output_tokens": 1000})
    assert ledger.summary()["known_subtotal"] == pytest.approx(.458)


def test_interrupted_usage_survives_reconstruction(task):
    ledger = UsageLedger(task.journal)
    ledger.set_limit(1)
    ledger.reserve(provider="anthropic", model="fixture", stage="execution", upper_bound=.1)
    restored = UsageLedger(TaskJournal.for_owner(task.runs, "session:session"))
    assert restored.summary()["pending_entries"] == 1
    with pytest.raises(UsageLimitError):
        restored.reserve(provider="anthropic", model="fixture", stage="repair", upper_bound=.1)
    pending = restored.summary()["entries"][0]
    restored.reconcile(pending["id"], amount=.1, note="Inspected the provider record")
    reconciled = restored.summary()["entries"][0]
    assert reconciled["ended_at"] is None  # Human wait is not measured model time.
    assert reconciled["reconciled_at"]


def test_file_restore_preserves_later_independent_edit(task):
    path = task.root / "file.txt"
    path.write_text("one\ntwo\nthree\nfour\nfive\nsix\n")
    task.core._run_tool_call(ToolCall("edit_file", {"path": "file.txt", "old_string": "one", "new_string": "ONE"}), lambda *_: "once")
    path.write_text(path.read_text().replace("six", "SIX"))
    change = task.history.changes()[0]
    preview = task.history.preview([change["id"]])
    entry = preview["entries"][0]
    assert entry["status"] == "ready"
    result = task.history.apply(preview["token"], ["file.txt"], preview["revision"], {"file.txt": entry["current"]})
    assert path.read_text() == "one\ntwo\nthree\nfour\nfive\nSIX\n"
    task.history.recover(result["recovery_token"])
    assert path.read_text().startswith("ONE")
    assert path.read_text().endswith("SIX\n")


def test_file_restore_rejects_stale_preview_without_writes(task):
    path = task.root / "file.txt"
    path.write_text("before")
    ids = task.history.begin("edit", ["file.txt"])
    path.write_text("after")
    task.history.finish(ids, ok=True)
    preview = task.history.preview(ids)
    path.write_text("user edit")
    with pytest.raises(TaskStateError, match="changed"):
        task.history.apply(preview["token"], ["file.txt"], preview["revision"], {"file.txt": preview["entries"][0]["current"]})
    assert path.read_text() == "user edit"


def test_binary_conflicts_and_uncertain_changes_are_not_restored(task):
    with pytest.raises(TaskStateError, match="Binary"):
        reverse_text(b"a\0", b"b\0", b"c\0")
    path = task.root / "file.txt"
    path.write_text("before")
    ids = task.history.begin("interrupted", ["file.txt"])
    path.write_text("partial")
    assert task.history.changes()[0]["state"] == "pending"
    with pytest.raises(TaskStateError, match="captured"):
        task.history.preview(ids)


def test_migration_preserves_history_and_has_new_tables(task):
    with task.runs._connect(readonly=True) as db:
        assert db.execute("SELECT version FROM schema_meta").fetchone()[0] == SCHEMA_VERSION
    assert task.runs.run("run")["request"] == "Make a result"


def test_artifact_noops_and_prior_states_are_not_new_progress(task):
    path = task.root / 'result'
    path.write_text('before')
    task.core.tool_ctx.plan_document = {'files': ['result']}
    for text in ('before', 'after', 'after', 'before', 'after'):
        task.core._run_tool_call(ToolCall('write_file', {'path': 'result', 'content': text}), lambda *_: 'once')
    milestones = [m for m in task.journal.snapshot()['progress'] if m['kind'] == 'artifact_changed']
    assert len(milestones) == 1


def test_source_findings_deduplicate_quotes_and_reject_changed_sources(task):
    path = task.root / 'source'
    path.write_text('The required interface is stable. It has one method.')
    call = ToolCall('read_file', {'path': 'source'})
    task.core._run_tool_call(call, lambda *_: 'once')
    state = {'requirements': ['Identify the interface']}
    assert task.journal.source_finding(call.execution_receipt['id'], 'Identify the interface', 'interface is stable', state)
    assert not task.journal.source_finding(call.execution_receipt['id'], 'Identify the interface', 'one method', state)
    path.write_text('Interface changed')
    with pytest.raises(TaskStateError, match='stale'):
        task.journal.source_finding(call.execution_receipt['id'], 'Identify the interface', 'one method', state)


def test_denied_tool_has_a_durable_unexecuted_receipt(task):
    task.core.helper_allowed_tools = {'read_file'}
    call = ToolCall('write_file', {'path': 'blocked', 'content': 'no'})
    task.core._run_tool_call(call, lambda *_: 'once')
    receipt = task.journal.snapshot()['receipts'][0]
    assert not receipt['executed'] and not receipt['ok']
    assert 'task_revision' in receipt
    assert not (task.root / 'blocked').exists()


def test_restore_interruption_keeps_journal_and_recovers_only_written_files(task, monkeypatch):
    for name in ('one', 'two'):
        (task.root / name).write_text('old')
    ids = task.history.begin('batch', ['one', 'two'])
    for name in ('one', 'two'):
        (task.root / name).write_text('new')
    task.history.finish(ids, ok=True)
    preview = task.history.preview(ids)
    original = task.history._write
    calls = []
    def interrupted(path, state, **kwargs):
        calls.append(path)
        if len(calls) == 2:
            raise OSError('Simulated interruption')
        original(path, state, **kwargs)
    monkeypatch.setattr(task.history, '_write', interrupted)
    with pytest.raises(OSError):
        task.history.apply(preview['token'], ['one', 'two'], preview['revision'],
                           {e['path']: e['current'] for e in preview['entries']})
    rebuilt = FileHistory(task.journal, str(task.root))
    rebuilt.recover(preview['token'])
    assert all((task.root / name).read_text() == 'new' for name in ('one', 'two'))


def test_usage_exact_decimal_and_duplicate_identity(task):
    ledger = UsageLedger(task.journal)
    for index in range(10):
        identifier = ledger.reserve(provider='anthropic', model='fixture', stage='repair', identifier=str(index),
                                    rates={'input_tokens': 1, 'output_tokens': 1})
        ledger.settle(identifier, {'input_tokens': 1, 'output_tokens': 0})
        ledger.settle(identifier, {'input_tokens': 1, 'output_tokens': 0})
    assert ledger.summary()['known_subtotal_decimal'] == '0.000010'
    with pytest.raises(UsageLimitError, match='another request'):
        ledger.reserve(provider='anthropic', model='different', stage='repair', identifier='0')


def test_task_detail_route_is_read_only_and_restore_rejects_stale_revision(task):
    from fastapi.testclient import TestClient

    from ollama_code.chat_service import ChatService
    from ollama_code.server import create_app
    service = ChatService(task.core)
    service.close_codex()
    service.run_store = task.runs
    task.runs.set_state('run', 'completed')
    client = TestClient(create_app(chat_service=service))
    before = task.runs.run('run')
    response = client.get('/api/sessions/session/task')
    assert response.status_code == 200
    assert response.json()['id'] == task.journal.task_id
    assert response.json()['usage']['coverage'] == 'unknown'
    assert task.runs.run('run')['state'] == before['state']
    assert client.post('/api/sessions/session/task/accept', json={'revision': -1}).status_code == 409
    assert client.post('/api/sessions/session/task/accept', json={'revision': response.json()['revision']}).status_code == 200
