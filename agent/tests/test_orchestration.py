from __future__ import annotations

import subprocess
import threading
import time
from pathlib import Path

import pytest

from ollama_code.orchestration import (
    AgentJob,
    CrossProcessModelCallScheduler,
    ModelCallScheduler,
    OrchestrationError,
    parse_manifest,
    validate_dispatch_plan,
)
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


def test_manifest_and_dispatch_plan_enforce_one_writer_and_known_members():
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
    with pytest.raises(OrchestrationError, match="exactly one writer"):
        validate_dispatch_plan(no_writer, team, profiles)


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


def test_manifest_rejects_multiple_writers_missing_credentials_and_limit_violations():
    manifest = _manifest()
    manifest["profiles"].append(_profile("writer-2", "implementer", "workspace_write"))
    manifest["team"]["member_ids"].append("writer-2")
    with pytest.raises(OrchestrationError, match="exactly one"):
        parse_manifest(manifest)

    manifest = _manifest()
    manifest["profiles"][1]["route"] = {
        "provider": "remote",
        "base_url": "https://provider.example/v1",
    }
    with pytest.raises(OrchestrationError, match="credentials"):
        parse_manifest(manifest)

    with pytest.raises(OrchestrationError, match="max_jobs"):
        parse_manifest(_manifest(budget={"max_jobs": 99}))


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


def test_agent_job_is_a_plain_non_recursive_record():
    job = AgentJob("one", "planner", "plan", (), "specialist")
    assert not hasattr(job, "delegate")
