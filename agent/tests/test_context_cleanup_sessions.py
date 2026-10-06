"""Durable checkpoint boundaries, recovery and native-provider invalidation."""
from __future__ import annotations

import hashlib

import pytest

from ollama_code.sessions import SessionStore, SessionTooLargeError


def message(store, role, content, **fields):
    store.append_strict({"type": "message", "message": {
        "role": role, "content": content, **fields,
    }})


def commit_record(snapshot, **fields):
    return {
        "type": "compacted_context", "messages": [{"role": "user", "content": "checkpoint"}],
        "checkpoint": {"objective": "Finish the migration", "constraints": ["Never publish"]},
        "covered_through": snapshot["covered_through"],
        "context_generation": snapshot["context_generation"] + 1,
        "cleanup_operation_id": "cleanup-1", **fields,
    }


def marker(thread_id, **fields):
    return {
        "type": "chatgpt_thread", "thread_id": thread_id,
        "protocol_version": "test", "tool_schema_fingerprint": "schema",
        "history_revision": 2, **fields,
    }


def test_cleanup_sources_are_exact_stable_and_exclude_generated_context(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Use blue", _item_id="user-1")
    message(store, "assistant", "Checked the result")
    message(store, "user", "Injected context", _locus_context=True)
    message(store, "assistant", "Private reasoning", _display_only=True)
    store.append_strict({"type": "pending_task_input", "text": "Never publish"})
    store.append_strict({"type": "native_tool_observation", "result": {"status": "ok"}})

    snapshot = store.cleanup_snapshot(store.path)
    assert [source["role"] for source in snapshot["sources"]] == ["user", "assistant", "user", "tool"]
    assert snapshot["sources"][0] == {
        "source_id": "user-1", "position": 2, "role": "user", "content": "Use blue",
        "content_hash": hashlib.sha256(b"Use blue").hexdigest(),
    }
    assert snapshot["sources"][1]["source_id"] == f"{store.session_id}:record:3"
    assert snapshot["sources"][3]["content"] == '{"status": "ok"}'
    message(store, "user", "Later correction")
    assert store.cleanup_source_records(store.path, through=snapshot["covered_through"]) == snapshot["sources"]


def test_committed_checkpoint_covers_old_inputs_but_preserves_new_corrections_and_export(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Old completed request")
    message(store, "assistant", "Complete")
    snapshot = store.cleanup_snapshot(store.path)
    store.commit_cleanup(commit_record(snapshot), snapshot)
    store.append_strict({"type": "pending_task_input", "text": "Use green"})
    message(store, "user", "Use green")
    store.append_strict({"type": "pending_task_input", "text": "Never publish"})

    assert store.context_generation(store.path) == 1
    assert store.context_checkpoint(store.path)["checkpoint"]["objective"] == "Finish the migration"
    assert store.authoritative_inputs(store.path) == [
        {"role": "user", "content": "Use green"},
        {"role": "user", "content": "Never publish", "pending": True},
    ]
    context = store.load_context(store.path)
    assert all(item["content"] != "Old completed request" for item in context)
    assert "Never publish" in context[-1]["content"]
    assert store.load(store.path)[0]["content"] == "Old completed request"
    assert all(source["content"] != "Old completed request"
               for source in store.cleanup_source_records(store.path))
    assert store.cleanup_source_records(store.path, include_covered=True)[0] == snapshot["sources"][0]


def test_prepared_operation_and_outcomes_recover_without_advancing_context(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Remember my preference")
    snapshot = store.cleanup_snapshot(store.path)
    store.append_strict({"type": "context_cleanup_prepared", "operation_id": "cleanup-1",
                         "candidates": [{"candidate_id": "candidate-1"}], "snapshot": snapshot})
    store.append_strict({"type": "context_cleanup_outcome", "operation_id": "cleanup-1",
                         "candidate_id": "candidate-1", "status": "pending", "memory_id": "memory-1"})

    recovered = store.cleanup_operation(store.path)
    assert recovered["outcomes"][0]["memory_id"] == "memory-1"
    assert recovered["candidates"] == [{"candidate_id": "candidate-1"}]
    assert not recovered["committed"]
    assert store.context_checkpoint(store.path) is None
    assert store.authoritative_inputs(store.path)[0]["content"] == "Remember my preference"
    store.commit_cleanup(commit_record(snapshot), snapshot)
    assert store.cleanup_operation(store.path)["committed"]


@pytest.mark.parametrize("new_record", [
    {"type": "message", "message": {"role": "user", "content": "new instruction"}},
    {"type": "pending_task_input", "text": "new correction"},
    {"type": "native_tool_observation", "result": "verification failed"},
])
def test_cleanup_commit_refuses_concurrent_evidence(tmp_path, new_record):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Initial request")
    snapshot = store.cleanup_snapshot(store.path)
    store.append_strict(new_record)
    with pytest.raises(ValueError, match="changed during cleanup"):
        store.commit_cleanup(commit_record(snapshot), snapshot)
    assert store.context_checkpoint(store.path) is None
    assert store.load_context(store.path)[0]["content"] == "Initial request"


def test_checkpoint_failure_does_not_write_a_commit(tmp_path, monkeypatch):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Initial request")
    snapshot = store.cleanup_snapshot(store.path)

    def fail(_record):
        raise OSError("storage unavailable")

    monkeypatch.setattr(store, "_append_strict_unlocked", fail)
    with pytest.raises(OSError, match="storage unavailable"):
        store.commit_cleanup(commit_record(snapshot), snapshot)
    assert store.context_checkpoint(store.path) is None


def test_failed_checkpoint_fsync_rolls_back_readable_record(tmp_path, monkeypatch):
    import ollama_code.sessions as sessions

    store = SessionStore(str(tmp_path))
    message(store, "user", "Initial request")
    snapshot = store.cleanup_snapshot(store.path)
    original = store.path.read_bytes()

    def fail(_descriptor):
        raise OSError("fsync unavailable")

    monkeypatch.setattr(sessions.os, "fsync", fail)
    with pytest.raises(OSError, match="fsync unavailable"):
        store.commit_cleanup(commit_record(snapshot), snapshot)
    assert store.path.read_bytes() == original
    assert store.context_checkpoint(store.path) is None


def test_strict_records_refuse_utf8_overflow_before_writing(tmp_path, monkeypatch):
    import ollama_code.sessions as sessions

    store = SessionStore(str(tmp_path))
    message(store, "user", "Keep this request")
    before = store.path.read_bytes()
    monkeypatch.setattr(sessions, "MAX_SESSION_LINE_BYTES", 512)
    with pytest.raises(SessionTooLargeError, match="record exceeds"):
        store.append_strict({"type": "context_cleanup_prepared", "summary": "🚀" * 200})
    assert store.path.read_bytes() == before
    assert store.load_context(store.path)[0]["content"] == "Keep this request"


def test_fingerprint_only_prepared_boundary_revalidates_exact_sources(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Keep this request")
    snapshot = store.cleanup_snapshot(store.path)
    prepared_boundary = {
        "context_generation": snapshot["context_generation"],
        "covered_through": snapshot["covered_through"],
        "source_fingerprints": [{key: source[key] for key in (
            "source_id", "position", "role", "content_hash",
        )} for source in snapshot["sources"]],
    }
    store.commit_cleanup(commit_record(snapshot), prepared_boundary)
    assert store.context_generation(store.path) == 1
    second = store.cleanup_snapshot(store.path)
    bad = {**second, "source_fingerprints": prepared_boundary["source_fingerprints"]}
    with pytest.raises(ValueError, match="changed during cleanup"):
        store.commit_cleanup(commit_record(second), bad)
    assert store.context_generation(store.path) == 1


def test_second_commit_requires_new_snapshot_and_supersedes_previous_checkpoint(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Initial request")
    first = store.cleanup_snapshot(store.path)
    store.commit_cleanup(commit_record(first), first)
    with pytest.raises(ValueError, match="changed during cleanup"):
        store.commit_cleanup(commit_record(first), first)
    message(store, "user", "New request")
    second = store.cleanup_snapshot(store.path)
    store.commit_cleanup(commit_record(second, cleanup_operation_id="cleanup-2",
                                       checkpoint={"objective": "New request"}), second)
    assert store.context_generation(store.path) == 2
    assert store.context_checkpoint(store.path)["checkpoint"] == {"objective": "New request"}
    assert store.authoritative_inputs(store.path) == []


def test_native_threads_cannot_resume_before_cleanup_or_from_late_old_markers(tmp_path):
    store = SessionStore(str(tmp_path))
    store.append_strict(marker("old-thread"))
    assert store.chatgpt_thread_state(store.path)["thread_id"] == "old-thread"
    snapshot = store.cleanup_snapshot(store.path)
    store.commit_cleanup(commit_record(snapshot), snapshot)
    assert store.chatgpt_thread_state(store.path) is None
    store.append_strict(marker("old-thread", context_generation=0))
    assert store.chatgpt_thread_state(store.path) is None
    store.append_strict(marker("new-thread", context_generation=1))
    store.append_strict(marker("old-thread", context_generation=0))
    assert store.chatgpt_thread_state(store.path)["thread_id"] == "new-thread"
    assert store.chatgpt_thread_state(store.path)["context_generation"] == 1


def test_legacy_compaction_keeps_input_replay_but_resets_native_thread(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Keep this old input until checkpointed")
    store.append_strict(marker("old-thread"))
    store.append_strict({"type": "compacted_context", "messages": [{"role": "user", "content": "summary"}]})
    assert store.context_generation(store.path) == 1
    assert store.context_checkpoint(store.path) is None
    assert store.authoritative_inputs(store.path)[0]["content"] == "Keep this old input until checkpointed"
    assert store.chatgpt_thread_state(store.path) is None


def test_malformed_checkpoint_cannot_hide_user_inputs(tmp_path):
    store = SessionStore(str(tmp_path))
    message(store, "user", "Keep this input")
    store.append_strict({"type": "compacted_context", "messages": [],
                         "checkpoint": {}, "covered_through": 9000})
    assert store.context_checkpoint(store.path) is None
    assert store.authoritative_inputs(store.path)[0]["content"] == "Keep this input"


@pytest.mark.parametrize("provider", ["chatgpt", "claude_plan"])
def test_native_resume_rebuilds_after_persisted_cleanup(tmp_path, monkeypatch, provider):
    from test_chatgpt_app_server import FakeManagedRuntime

    from ollama_code.core import AgentCore
    from ollama_code.knowledge import KnowledgeStore

    KnowledgeStore(str(tmp_path)).configure(adaptive_rag_enabled=False)
    runtime = FakeManagedRuntime()
    monkeypatch.setattr(runtime, "account", lambda **kwargs: {"account": {"type": provider}})
    core = AgentCore(cwd=str(tmp_path), config={})
    getattr(core, f"use_{provider}")(
        account_id="managed-account", model="gpt-test", account_label="Managed", manager=runtime,
    )
    core.run_turn("First request", allow_tools=False)
    snapshot = core.session.cleanup_snapshot(core.session.path)
    core.session.commit_cleanup(commit_record(snapshot), snapshot)
    session_id = core.session.session_id
    core.start_new_session()
    core.resume_session(session_id)
    assert core._chatgpt_thread_id == ""
    core.run_turn("Continue", allow_tools=False)

    assert runtime.resumed == []
    assert runtime.started == ["thread-1", "thread-2"]
    assert "First request" not in runtime.turn_texts[-1]
    state = core.session.chatgpt_thread_state(core.session.path)
    assert state["thread_id"] == "thread-2"
    assert state["context_generation"] == 1
