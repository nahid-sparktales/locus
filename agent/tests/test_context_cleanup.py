"""Save/commit failures and restart boundaries use disposable real session logs."""
from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from ollama_code import context_cleanup, memory_automation
from ollama_code.context_preservation import protected_context, retrieval_query
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse
from ollama_code.sessions import SessionStore


def extraction(summary="Verified exploration", **extra):
    value = {"summary": summary, "checkpoint": {"objective": "Finish the migration",
        "unfinished_work": ["Verify migration"], "decisions": [], "blockers": [],
        "next_steps": ["Run the required checks"], "evidence_refs": []},
        "candidates": [], "resolved_inputs": []}
    value.update(extra)
    return json.dumps(value)


@pytest.fixture
def core(tmp_path):
    value = AgentCore(cwd=str(tmp_path), model="fixture", skip_permissions=True,
                      config={"provider": "ollama", "auto_compact": False})
    value.context_limit = 128000
    value.messages = [value.system_message()]
    value._emit_info = lambda: None
    value._add_message({"role": "user", "content": "Preserve the public API"})
    value._add_message({"role": "assistant", "content": "Inspecting the migration"})
    value.client = SimpleNamespace(chat_stream=lambda *a, **k: ChatResponse(content_parts=[extraction()]))
    return value


def test_cleanup_commits_checkpoint_keeps_export_and_enriches_next_search(core):
    history = SessionStore.load(core.session.path)
    result = core._slash_compact()
    assert not result.get("error"), result
    assert result["data"]["checkpoint_status"] == "saved"
    assert result["data"]["context_generation"] == 1
    assert SessionStore.load(core.session.path) == history
    assert SessionStore.authoritative_inputs(core.session.path) == []
    assert "Preserve the public API" in protected_context(core)
    assert "Finish the migration" in retrieval_query(core, "Continue")
    assert retrieval_query(core, "Explain leases") == "Explain leases"
    assert core.messages[1:] == SessionStore.load_context(core.session.path)


@pytest.mark.parametrize("reply", ["not JSON", "{}", extraction(checkpoint={}), "", extraction(candidates="invalid")])
def test_malformed_extraction_never_replaces_context(core, reply):
    original = list(core.messages)
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[reply])
    result = core._slash_compact()
    assert result.get("error")
    assert result["data"]["checkpoint_status"] == "not_committed"
    assert core.messages == original
    assert SessionStore.context_checkpoint(core.session.path) is None


def test_failed_save_retries_prepared_operation_without_another_model_call(core, monkeypatch):
    original = list(core.messages)
    calls = []
    def save(*args):
        calls.append(args[2])
        if len(calls) == 1:
            raise OSError("vault unavailable")
        return []
    monkeypatch.setattr(memory_automation, "save_cleanup_candidates", save)
    assert core._slash_compact().get("error")
    assert core.messages == original
    operation = SessionStore.cleanup_operation(core.session.path)
    core.client.chat_stream = lambda *a, **k: pytest.fail("retry must reuse extraction")
    assert not core._slash_compact().get("error")
    assert calls == [operation["operation_id"]] * 2


def test_pending_memories_preserved_without_approval_and_trace_has_no_content(core, monkeypatch):
    monkeypatch.setattr(memory_automation, "prepare_cleanup_candidates", lambda *a: [{"content": "Unconfirmed lesson"}])
    monkeypatch.setattr(memory_automation, "save_cleanup_candidates", lambda *a: [{
        "status": "pending", "memory_id": "memory-1", "revision": 1, "scope": "agent",
        "content": "private memory content", "record": {"content": "private memory content"}}])
    events = []
    core.on_event(events.append)
    result = core._slash_compact()
    assert not result.get("error"), result
    assert result["data"]["counts"] == {"saved": 0, "pending": 1, "skipped": 0}
    assert "Unconfirmed lesson" in protected_context(core)
    assert result["data"]["outcomes"][0]["id"] == "memory-1"
    trace = next(e for e in events if e["type"] == "context_cleanup")
    assert "private memory content" not in json.dumps(trace)


def test_commit_failure_does_not_replace_live_context_and_retry_is_resumable(core, monkeypatch):
    original = list(core.messages)
    commit = core.session.commit_cleanup
    monkeypatch.setattr(core.session, "commit_cleanup", lambda *a, **k: (_ for _ in ()).throw(OSError("full disk")))
    assert core._slash_compact().get("error")
    assert core.messages == original
    assert SessionStore.context_checkpoint(core.session.path) is None
    monkeypatch.setattr(core.session, "commit_cleanup", commit)
    core.client.chat_stream = lambda *a, **k: pytest.fail("retry must reuse extraction")
    assert not core._slash_compact().get("error")


@pytest.mark.parametrize("change", ["input", "policy", "cancel", "steer"])
def test_concurrent_change_blocks_commit(core, monkeypatch, change):
    from dataclasses import replace
    original = list(core.messages)
    def save(*args):
        if change == "input":
            core._add_message({"role": "user", "content": "Do not deploy"})
        elif change == "policy":
            core.agent_configuration = replace(core.agent_configuration,
                memory_policy=replace(core.agent_configuration.memory_policy, auto_save_enabled=False))
        elif change == "cancel":
            core._interrupt.set()
        else:
            core._pending_steers.append("Correction")
            core._steer_event.set()
        return []
    monkeypatch.setattr(memory_automation, "save_cleanup_candidates", save)
    assert core._slash_compact().get("error")
    assert core.messages[:len(original)] == original
    assert SessionStore.context_checkpoint(core.session.path) is None


def test_closed_input_does_not_return_through_native_runtime_context(core):
    core._add_message({"role": "user", "content": "Cancel the old API requirement. Finish the migration instead."})
    sources = SessionStore.cleanup_source_records(core.session.path)
    resolved = [{"source_id": sources[0]["source_id"], "resolved_text": "Preserve the public API",
                 "resolution_source_id": sources[-1]["source_id"], "resolution_quote": "Cancel the old API requirement."}]
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction(resolved_inputs=resolved)])
    assert not core._slash_compact().get("error")
    assert "Preserve the public API" not in protected_context(core)
    core._add_message({"role": "user", "content": "Do not publish"})
    assert "Do not publish" in protected_context(core)


def test_resolution_retires_only_confirmed_part_of_old_user_input(core):
    core._add_message({"role": "user", "content": "Update the docs. Never publish without approval."})
    core._add_message({"role": "user", "content": "Cancel updating the docs. Continue the migration."})
    sources = SessionStore.cleanup_source_records(core.session.path)
    resolved = [{"source_id": sources[-2]["source_id"], "resolved_text": "Update the docs.",
                 "resolution_source_id": sources[-1]["source_id"], "resolution_quote": "Cancel updating the docs."}]
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction(resolved_inputs=resolved)])
    assert not core._slash_compact().get("error")
    checkpoint = SessionStore.context_checkpoint(core.session.path)["checkpoint"]
    old = next(item for item in checkpoint["active_constraints"] if item["source_id"] == sources[-2]["source_id"])
    assert old["content"] == "Never publish without approval."


@pytest.mark.parametrize("resolution", [
    "Do not cancel the API requirement.", "The API task is not complete.",
    "Never stop preserving the API.", "Cancel the API requirement only if I approve.",
    "Once the API work is completed, continue.",
])
def test_negated_or_conditional_resolution_preserves_old_constraint(core, resolution):
    core._add_message({"role": "user", "content": resolution})
    sources = SessionStore.cleanup_source_records(core.session.path)
    resolved = [{"source_id": sources[0]["source_id"], "resolved_text": "Preserve the public API",
                 "resolution_source_id": sources[-1]["source_id"], "resolution_quote": resolution}]
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction(resolved_inputs=resolved)])
    assert not core._slash_compact().get("error")
    assert "Preserve the public API" in protected_context(core)


def test_resolution_quote_cannot_omit_surrounding_negation(core):
    core._add_message({"role": "user", "content": "Do not cancel the API requirement."})
    sources = SessionStore.cleanup_source_records(core.session.path)
    resolved = [{"source_id": sources[0]["source_id"], "resolved_text": "Preserve the public API",
                 "resolution_source_id": sources[-1]["source_id"], "resolution_quote": "cancel the API requirement"}]
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction(resolved_inputs=resolved)])
    assert not core._slash_compact().get("error")
    assert "Preserve the public API" in protected_context(core)


def test_direct_identity_cleanup_never_extracts_or_persists_private_context(core):
    from ollama_code.context_preservation import compact

    core.identity_mode = True
    before = core.session.path.read_bytes()
    core.client.chat_stream = lambda *a, **k: pytest.fail("private extraction must not run")
    assert compact(core).get("error")
    assert core.session.path.read_bytes() == before
    assert "Preserve the public API" in json.dumps(SessionStore.load(core.session.path))


def test_cleanup_does_not_reset_or_consume_retrieval_allowance(core):
    from ollama_code.adaptive_retrieval import TurnAllowance
    allowance = TurnAllowance(rounds=2)
    coordinator = SimpleNamespace(allowance=allowance)
    core.adaptive_retrieval = coordinator
    assert not core._slash_compact().get("error")
    assert core.adaptive_retrieval is coordinator
    assert allowance.rounds == 2
    assert allowance.reserve() is None


def test_section_payloads_are_bounded_json_with_source_ids():
    source = {"source_id": "long-tool", "role": "tool", "content": ('"\\\n漢字' * 10000)}
    parts = context_cleanup._sections([source], {}, 4000)
    assert all(len(part.encode()) <= 4000 for part in parts)
    decoded = [json.loads(part) for part in parts]
    assert {row["source_id"] for row in decoded} == {"long-tool"}
    assert "".join(row["content"] for row in decoded) == source["content"]


def test_post_commit_observer_failure_cannot_undo_cleanup(core, monkeypatch):
    monkeypatch.setattr(core, "_emit_info", lambda: (_ for _ in ()).throw(RuntimeError("UI disconnected")))
    assert not core._slash_compact().get("error")
    assert core.messages[1:] == SessionStore.load_context(core.session.path)


def test_prepared_cleanup_resumes_after_a_process_restart(core, monkeypatch):
    monkeypatch.setattr(memory_automation, "save_cleanup_candidates",
                        lambda *a: (_ for _ in ()).throw(OSError("offline")))
    result = core._slash_compact()
    assert result.get("error")
    operation_id = result["data"]["cleanup_operation_id"]
    recovered = AgentCore(cwd=core.cwd, model="fixture", skip_permissions=True,
                          config={"provider": "ollama", "auto_compact": False})
    recovered.context_limit = 128000
    recovered._emit_info = lambda: None
    assert not recovered._slash_resume(core.session.session_id).get("error")
    recovered.client = SimpleNamespace(chat_stream=lambda *a, **k: pytest.fail("restart must reuse prepared extraction"))
    monkeypatch.setattr(memory_automation, "save_cleanup_candidates", lambda *a: [])
    result = recovered._slash_compact()
    assert not result.get("error"), result
    assert result["data"]["cleanup_operation_id"] == operation_id


def test_prepared_operation_stores_fingerprints_instead_of_duplicate_transcript(core):
    core._add_message({"role": "tool", "content": "large private tool output " * 10000})
    result = core._slash_compact()
    assert not result.get("error"), result
    prepared = SessionStore.cleanup_operation(core.session.path)
    assert "sources" not in prepared["snapshot"]
    assert prepared["snapshot"]["source_fingerprints"]
    assert "large private tool output" not in json.dumps(prepared)


def test_goal_usage_accounting_does_not_invalidate_cleanup_input(core, tmp_path):
    from ollama_code.goal_runtime import GoalRuntime, attach_goal_runtime
    from ollama_code.goals import GoalStore
    from ollama_code.runstore import RunStore

    runs = RunStore(tmp_path / "goal-runs.sqlite3")
    goals = GoalStore(runs)
    goal = goals.create(core.session.session_id, "Finish the migration", execution={
        "provider": "ollama", "model": "fixture", "runner": "solo", "workspace_root": core.cwd})
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    attach_goal_runtime(core, GoalRuntime(goals, goal, run["id"]), coordinator=True)
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction()],
                                                        prompt_eval_count=100, eval_count=20)
    result = core._slash_compact()
    assert not result.get("error"), result
    assert core.total_prompt_tokens == 100
    assert core.total_completion_tokens == 20
    assert "Finish the migration" in protected_context(core)


def test_recent_tail_cannot_restore_retired_instructions(core):
    core._add_message({"role": "user", "content": "Build the prototype."})
    core._add_message({"role": "assistant", "content": "Starting the prototype"})
    core._add_message({"role": "user", "content": "Cancel the prototype."})
    sources = SessionStore.cleanup_source_records(core.session.path)
    resolved = [{"source_id": sources[-3]["source_id"], "resolved_text": "Build the prototype.",
                 "resolution_source_id": sources[-1]["source_id"], "resolution_quote": "Cancel the prototype."}]
    core.client.chat_stream = lambda *a, **k: ChatResponse(content_parts=[extraction(resolved_inputs=resolved)])
    result = core._slash_compact()
    assert not result.get("error"), result
    assert "Build the prototype." not in json.dumps(core.messages)
    assert "Build the prototype." in json.dumps(SessionStore.load(core.session.path))
