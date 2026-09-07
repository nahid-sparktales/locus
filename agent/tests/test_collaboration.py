from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

import pytest

from ollama_code import collaboration as module
from ollama_code import worktrees
from ollama_code.collaboration import (
    CollaborationError,
    CollaborationStore,
    SoloCollaborationManager,
)


def git(path, *args):
    return subprocess.run(["git", *args], cwd=path, check=True, capture_output=True).stdout.decode().strip()


@pytest.fixture
def repo(tmp_path, monkeypatch):
    root = tmp_path / "project"
    root.mkdir()
    git(root, "init", "-q")
    git(root, "config", "user.name", "Test")
    git(root, "config", "user.email", "test@example.invalid")
    (root / "file.txt").write_text("original\n")
    git(root, "add", ".")
    git(root, "commit", "-qm", "initial")
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")
    return root


class FakeRuntime:
    def __init__(self, spec, callback=None):
        self.spec = spec
        self.history = list(spec.checkpoint.get("history", []))
        self.mailbox_ack_seq = int(spec.checkpoint.get("mailbox_ack_seq") or 0)
        self.callback = callback
        self.interrupted = threading.Event()

    def run(self, prompt, *, max_calls, should_stop, drain_messages, on_usage, on_checkpoint):
        self.history.append(prompt)
        if self.callback:
            result = self.callback(self, max_calls, should_stop, drain_messages, on_usage)
            if result:
                return result
        for message in drain_messages():
            self.history.append(message["text"])
            self.mailbox_ack_seq = max(self.mailbox_ack_seq, message["seq"])
        on_usage({"model_calls": 1, "prompt_tokens": 10, "completion_tokens": 5})
        return {"output": "done", "reason": "complete",
                "usage": {"model_calls": 1, "prompt_tokens": 10, "completion_tokens": 5}}

    def snapshot(self):
        return {"history": self.history, "mailbox_ack_seq": self.mailbox_ack_seq}

    def interrupt(self):
        self.interrupted.set()

    def close(self):
        pass


def manager(tmp_path, path, callback=None, *, run_id="run", store=None):
    return SoloCollaborationManager(session_id="session", run_id=run_id, execution_path=str(path),
        store=store or CollaborationStore(tmp_path / "collaboration.db"), emit=lambda event: None,
        worker_factory=lambda spec: FakeRuntime(spec, callback))


def idle(m, identifier):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        helper = m.read(identifier)["agent"]
        if helper["state"] not in module.ACTIVE_STATES:
            return helper
        time.sleep(0.01)
    raise AssertionError("helper did not stop")


def test_spawn_returns_while_worker_runs_and_sibling_finishes(tmp_path):
    release, started = threading.Event(), threading.Event()
    def work(runtime, *_):
        if runtime.spec.label == "slow":
            started.set()
            assert release.wait(3)
    m = manager(tmp_path, tmp_path, work)
    slow = m.spawn("wait", label="slow")["id"]
    assert started.wait(2)
    fast = m.spawn("finish", label="fast")["id"]
    assert idle(m, fast)["state"] == "idle"
    assert m.read(slow)["agent"]["state"] == "running"
    result = m.wait([fast], timeout_ms=0)
    assert result["messages"][0]["agent_id"] == fast
    assert not m.wait([fast], after_cursor=result["cursor"], timeout_ms=0)["messages"]
    release.set()
    m.close()


def test_session_handle_and_context_survive_later_parent_run(tmp_path):
    store = CollaborationStore(tmp_path / "collaboration.db")
    first = manager(tmp_path, tmp_path, store=store)
    identifier = first.spawn("first task")["id"]
    idle(first, identifier)
    first.close()
    second = manager(tmp_path, tmp_path, run_id="second", store=store)
    second.send_message(identifier, "new information")
    second.followup(identifier, "second task")
    idle(second, identifier)
    assert store.get("helpers", identifier)["checkpoint"]["history"] == [
        "first task", "second task", "new information"]
    assert first.usage["model_calls"] == second.usage["model_calls"] == 1
    first_attempt = store.get("attempts", f"run:{identifier}:1")
    second_attempt = store.get("attempts", f"second:{identifier}:2")
    assert first_attempt["current_prompt"] == "first task"
    assert second_attempt["current_prompt"] == "second task"
    assert first_attempt["attempt_usage"]["model_calls"] == 1
    second.close()


def test_individual_interrupt_does_not_stop_sibling(tmp_path):
    started = threading.Event()
    def work(runtime, _, stopping, *__):
        if runtime.spec.label == "slow":
            started.set()
            deadline = time.monotonic() + 3
            while not stopping() and time.monotonic() < deadline:
                time.sleep(0.01)
            return {"output": "partial", "reason": "interrupted"}
    m = manager(tmp_path, tmp_path, work)
    slow = m.spawn("wait", label="slow")["id"]
    assert started.wait(2)
    fast = m.spawn("finish", label="fast")["id"]
    m.interrupt(slow)
    assert idle(m, slow)["state"] == "interrupted"
    assert idle(m, fast)["state"] == "idle"
    m.close()


def test_budget_across_followups_does_not_reset_or_double_count(tmp_path):
    def work(_, calls, __, ___, usage):
        usage({"model_calls": calls, "prompt_tokens": 80, "completion_tokens": 8})
        return {"reason": "model_call_budget", "usage": {
            "model_calls": calls, "prompt_tokens": 80, "completion_tokens": 8}}
    m = manager(tmp_path, tmp_path, work)
    identifier = m.spawn("bounded task")["id"]
    for _ in range(3):
        idle(m, identifier)
        m.resume(identifier)
    assert idle(m, identifier)["reason"] == "delegated_budget"
    assert m.usage["model_calls"] == 24
    assert m.usage["delegated_tokens"] == 264
    assert m.store.get("runs", "run")["reserved_calls"] == 0
    m.close()


def test_edit_snapshots_dirty_parent_worktree_and_integrates_there(tmp_path, repo):
    parent = worktrees.TaskCheckoutStore.create(str(repo), "parent")
    parent_path = Path(parent.execution_path)
    (parent_path / "file.txt").write_text("parent uncommitted\n")
    (parent_path / "new.txt").write_text("new parent file\n")
    index_before = git(parent_path, "diff", "--cached")
    def edit(runtime, *_):
        target = Path(runtime.spec.execution_path)
        assert (target / "file.txt").read_text() == "parent uncommitted\n"
        assert (target / "new.txt").is_file()
        (target / "file.txt").write_text("helper changed\n")
    m = manager(tmp_path, parent_path, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    helper = idle(m, identifier)
    assert helper["state"] == "idle", helper
    assert (parent_path / "file.txt").read_text() == "parent uncommitted\n"
    result_id = helper["result"]["result_id"]
    assert m.integrate(identifier, result_id)["ok"]
    assert (parent_path / "file.txt").read_text() == "helper changed\n"
    assert (repo / "file.txt").read_text() == "original\n"
    assert git(parent_path, "diff", "--cached") == index_before
    assert m.integrate(identifier, result_id)["already_integrated"]
    m.close()


def test_followup_after_integration_refreshes_checkout(tmp_path, repo):
    observed = []
    def edit(runtime, *_):
        target = Path(runtime.spec.execution_path)
        observed.append((target, (target / "file.txt").read_text()))
        (target / "file.txt").write_text("helper\n")
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    helper = idle(m, identifier)
    m.integrate(identifier, helper["result"]["result_id"])
    (repo / "file.txt").write_text("new root work\n")
    m.followup(identifier, "new task")
    assert idle(m, identifier)["generation"] == 2
    assert observed[0][0] != observed[1][0]
    assert observed[1][1] == "new root work\n"
    m.close()


def test_conflict_preserves_parent_and_new_attempt_preserves_old_result(tmp_path, repo):
    def edit(runtime, *_):
        (Path(runtime.spec.execution_path) / "file.txt").write_text("helper\n")
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    first = idle(m, identifier)
    (repo / "file.txt").write_text("root changed same line\n")
    assert m.integrate(identifier, first["result"]["result_id"])["code"] == "conflict"
    assert (repo / "file.txt").read_text() == "root changed same line\n"
    m.followup(identifier, "reconcile")
    helper = idle(m, identifier)
    assert helper["generation"] == 2
    assert helper["prior_result"]["result_id"] == first["result"]["result_id"]
    assert Path(first["result"]["patch_path"]).exists()
    m.close()


def test_uncertain_integration_is_never_replayed(tmp_path, repo, monkeypatch):
    def edit(runtime, *_):
        (Path(runtime.spec.execution_path) / "file.txt").write_text("helper\n")
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    frozen = idle(m, identifier)["result"]
    calls = []
    def broken(*args):
        calls.append(args)
        raise OSError("simulated crash during application")
    monkeypatch.setattr(module, "apply_helper_integration", broken)
    assert m.integrate(identifier, frozen["result_id"])["code"] == "integration_uncertain"
    assert m.integrate(identifier, frozen["result_id"])["code"] == "integration_not_applied"
    assert len(calls) == 1
    m.close()


def test_restart_marks_unfinished_helpers_interrupted(tmp_path, monkeypatch):
    m = manager(tmp_path, tmp_path)
    identifier = m.spawn("first")["id"]
    idle(m, identifier)
    m.close()
    helper = m.store.get("helpers", identifier)
    helper.update(state="running", owner_pid=123456789)
    m.store.put("helpers", helper)
    again = manager(tmp_path, tmp_path, run_id="again", store=m.store)
    assert again.read(identifier)["agent"]["state"] == "interrupted"
    again.resume(identifier)
    assert idle(again, identifier)["state"] == "idle"
    again.close()


def test_non_git_edit_refused_and_session_scope_enforced(tmp_path):
    m = manager(tmp_path, tmp_path)
    assert m.spawn("edit", mode="edit")["code"] == "isolation_unavailable"
    with pytest.raises(CollaborationError):
        m.read("foreign-helper")
    assert m.list_agents()["agents"] == []
    m.close()


def test_six_new_helpers_limit_and_three_active_maximum(tmp_path):
    release = threading.Event()
    lock = threading.Lock()
    running = peak = 0
    def work(*_):
        nonlocal running, peak
        with lock:
            running += 1
            peak = max(peak, running)
        assert release.wait(3)
        with lock:
            running -= 1
    m = manager(tmp_path, tmp_path, work)
    identifiers = [m.spawn(str(i))["id"] for i in range(6)]
    with pytest.raises(CollaborationError, match="six"):
        m.spawn("seventh")
    release.set()
    for identifier in identifiers:
        idle(m, identifier)
    assert peak <= 3
    m.close()


def test_fork_copies_worktreeinclude_from_actual_checkout(tmp_path, repo):
    (repo / ".gitignore").write_text(".env\n")
    (repo / ".worktreeinclude").write_text(".env\n")
    (repo / ".env").write_text("development fixture\n")
    child, source = worktrees.fork_execution(str(repo), "included")
    assert (Path(child.execution_path) / ".env").read_text() == "development fixture\n"
    assert source["execution_root"] == str(repo)
    assert ".env" not in git(Path(child.execution_path), "ls-files")


def test_active_followup_runs_after_current_boundary_and_keeps_messages(tmp_path):
    started, release = threading.Event(), threading.Event()
    def work(runtime, *_):
        if len(runtime.history) == 1:
            started.set()
            assert release.wait(3)
            # Simulate completion after its last input boundary. A queued
            # follow-up must initiate another attempt, without losing text.
            return {"output": "first done", "reason": "complete", "usage": {"model_calls": 1}}
    m = manager(tmp_path, tmp_path, work)
    identifier = m.spawn("first")["id"]
    assert started.wait(2)
    m.followup(identifier, "new scope")
    release.set()
    helper = idle(m, identifier)
    assert helper["attempt"] == 2
    assert "new scope" in m.store.get("helpers", identifier)["checkpoint"]["history"]
    m.close()


def test_finish_run_stops_and_joins_all_children(tmp_path):
    started = threading.Event()
    def work(_, __, stopping, *___):
        started.set()
        while not stopping():
            time.sleep(0.005)
        return {"reason": "interrupted"}
    m = manager(tmp_path, tmp_path, work)
    identifier = m.spawn("ongoing")["id"]
    assert started.wait(2)
    m.finish_run()
    assert m.read(identifier)["agent"]["state"] == "interrupted"
    assert all(future.done() for future in m._futures.values())
    with pytest.raises(CollaborationError, match="closed"):
        m.followup(identifier, "too late")


def test_tampered_frozen_patch_never_changes_parent(tmp_path, repo):
    def edit(runtime, *_):
        (Path(runtime.spec.execution_path) / "file.txt").write_text("helper\n")
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    frozen = idle(m, identifier)["result"]
    Path(frozen["patch_path"]).write_text("")
    assert m.integrate(identifier, frozen["result_id"])["code"] == "conflict"
    assert (repo / "file.txt").read_text() == "original\n"
    m.close()


def test_failed_checkpoint_redelivers_unacknowledged_worker_message(tmp_path):
    m = manager(tmp_path, tmp_path)
    identifier = m.spawn("first")["id"]
    idle(m, identifier)
    m.send_message(identifier, "must survive")
    assert m.store.messages("session", agent=identifier, direction="worker", consume=True)
    # Delivery without a saved worker checkpoint cannot acknowledge the
    # instruction. Resume must deliver it again.
    m.followup(identifier, "resume")
    idle(m, identifier)
    assert "must survive" in m.store.get("helpers", identifier)["checkpoint"]["history"]
    m.close()


def test_draining_without_applying_does_not_acknowledge_mailbox(tmp_path):
    drained = []

    def work(runtime, _, __, drain, ___):
        if runtime.history[-1] == "drain and stop":
            drained.extend(drain())
            return {"reason": "interrupted"}

    m = manager(tmp_path, tmp_path, work)
    identifier = m.spawn("first")["id"]
    idle(m, identifier)
    message = m.send_message(identifier, "preserve unapplied guidance")
    m.followup(identifier, "drain and stop")
    idle(m, identifier)
    assert drained[0]["seq"] == message["seq"]
    assert m.store.get("helpers", identifier)["mailbox_ack_seq"] == 0
    m.followup(identifier, "apply now")
    idle(m, identifier)
    checkpoint = m.store.get("helpers", identifier)["checkpoint"]
    assert checkpoint["history"].count("preserve unapplied guidance") == 1
    assert checkpoint["mailbox_ack_seq"] == message["seq"]
    m.close()


def test_recover_receipt_when_patch_applied_before_completion_was_recorded(tmp_path, repo, monkeypatch):
    def edit(runtime, *_):
        (Path(runtime.spec.execution_path) / "file.txt").write_text("helper\n")
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    frozen = idle(m, identifier)["result"]
    original = module.apply_helper_integration
    calls = []
    def applied_but_ack_lost(*args):
        calls.append(args)
        original(*args)
        raise OSError("lost completion acknowledgement")
    monkeypatch.setattr(module, "apply_helper_integration", applied_but_ack_lost)
    assert m.integrate(identifier, frozen["result_id"])["code"] == "integration_uncertain"
    recovered = m.integrate(identifier, frozen["result_id"])
    assert recovered["ok"] and recovered["recovered"]
    assert len(calls) == 1
    assert m.read(identifier)["agent"]["result"]["state"] == "integrated"
    m.close()


def test_interrupted_edit_freezes_partial_patch_and_evidence(tmp_path, repo):
    def edit(runtime, *_):
        (Path(runtime.spec.execution_path) / "file.txt").write_text("partial helper work\n")
        return {"reason": "interrupted", "output": "not finished", "evidence": ["file.txt:1"],
                "validation": [{"command": "test", "passed": False}]}
    m = manager(tmp_path, repo, edit)
    identifier = m.spawn("edit", mode="edit")["id"]
    helper = idle(m, identifier)
    assert helper["state"] == "interrupted"
    assert helper["result"]["state"] == "partial"
    assert helper["result"]["validation"] == [{"command": "test", "passed": False}]
    assert helper["result"]["evidence"] == ["file.txt:1"]
    assert "partial helper work" in Path(helper["result"]["patch_path"]).read_text()
    with pytest.raises(CollaborationError):
        m.integrate(identifier, helper["result"]["result_id"])
    assert (repo / "file.txt").read_text() == "original\n"
    m.close()


def test_helper_lists_and_messages_are_bounded_without_truncating_saved_records(tmp_path):
    m = manager(tmp_path, tmp_path)
    try:
        for number in range(121):
            record = {"id": str(number), "agent_id": str(number), "session_id": "session",
                "run_id": "old-run", "state": "running" if number == 0 else "idle",
                "updated_at": number, "label": "helper", "mode": "research", "goal": "inspect",
                "output": "done", "current_prompt": "inspect", "checkpoint": {}, "context": {}}
            if number == 120:
                record.update(goal="g" * 120000, current_prompt="p" * 120000, output="o" * 120000,
                    result={"result_id": "frozen-id", "patch_path": "/saved/result.patch",
                        "validation": [{"result": "v" * 20000}] * 30})
            m.store.put("helpers", record)
        listing = m.list_agents()
        assert listing["total"] == 121 and listing["truncated"]
        assert len(listing["agents"]) == 100
        assert listing["agents"][0]["id"] == "0", "an older active helper must remain visible"
        summary = next(h for h in listing["agents"] if h["id"] == "120")
        assert len(summary["goal"]) == len(summary["current_prompt"]) == 2000
        assert len(summary["output"]) == 8000
        assert len(json.dumps(summary)) < 22000
        assert summary["details_truncated"]
        detail = m.read("120")["agent"]
        assert len(detail["output"]) == 96000
        assert len(json.dumps(detail)) < 120000
        assert detail["result"]["result_id"] == "frozen-id"
        assert detail["result"]["patch_path"] == "/saved/result.patch"
        saved = m.store.get("helpers", "120")
        assert len(saved["goal"]) == len(saved["output"]) == 120000
        assert len(saved["result"]["validation"]) == 30
        seq = m.store.message("session", "120", "parent", {"type": "completed",
            "output": saved["output"], "result": saved["result"], "run_id": "run"})
        message = m.wait(timeout_ms=0)["messages"][0]
        assert message["seq"] == seq and message["agent_id"] == "120"
        assert len(json.dumps(message)) < 13000
    finally:
        m.close()
