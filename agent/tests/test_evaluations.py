from __future__ import annotations

import json
import sqlite3
import subprocess
import time
from pathlib import Path

import pytest

from ollama_code import worktrees
from ollama_code.evaluations import (
    EvaluationError,
    EvaluationStore,
    compare_results,
    grade_case,
    summarize_results,
    validate_suite,
)
from ollama_code.runstore import RunStore


def _suite(workspace):
    return {
        "name": "Core behavior",
        "workspace_root": str(workspace),
        "tags": ["code"],
        "cases": [{
            "id": "case-1", "name": "Edit", "prompt": "Update the fixture",
            "mode": "write", "assertions": [
                {"kind": "path_exists", "path": "result.txt"},
                {"kind": "file_contains", "path": "result.txt", "value": "ready"},
                {"kind": "changed_paths_forbidden", "value": ["secrets/**"]},
            ],
        }],
    }


def test_evaluation_store_round_trips_tolerant_json(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = EvaluationStore(RunStore(tmp_path / "runs.sqlite3"))
    saved = store.save_suite(_suite(workspace))
    assert store.get_suite(saved["id"])["cases"][0]["prompt"] == "Update the fixture"
    assert store.list_suites(str(workspace))[0]["name"] == "Core behavior"
    assert store.delete_suite(saved["id"])


def test_validation_rejects_missing_workspace_and_unknown_assertion(tmp_path) -> None:
    value = _suite(tmp_path / "missing")
    with pytest.raises(EvaluationError):
        validate_suite(value)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    value = _suite(workspace)
    value["cases"][0]["assertions"] = [{"kind": "computer_control"}]
    with pytest.raises(EvaluationError):
        validate_suite(value)


def test_case_timeout_and_budget_are_bounded_and_normalized(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    value = _suite(workspace)
    value["cases"][0].update({
        "timeout_seconds": 10,
        "budget": {
            "max_jobs": 2,
            "max_rounds": 1,
            "max_model_calls": 4,
            "max_concurrent_calls": 2,
            "max_metered_tokens": 10_000,
        },
    })

    case = validate_suite(value)["cases"][0]

    assert case["timeout_seconds"] == 30
    assert case["budget"] == {
        "max_jobs": 2,
        "max_rounds": 1,
        "max_model_calls": 4,
        "max_concurrent_calls": 2,
        "max_metered_tokens": 10_000,
    }

    value["cases"][0]["budget"]["max_jobs"] = 99
    with pytest.raises(EvaluationError):
        validate_suite(value)


def test_deterministic_grading_supports_files_commands_json_and_paths(tmp_path) -> None:
    (tmp_path / "result.txt").write_text("ready\n")
    (tmp_path / "data.json").write_text(json.dumps({"status": "ok", "items": []}))
    case = {
        "assertions": [
            {"id": "exists", "kind": "path_exists", "path": "result.txt", "required": True},
            {"id": "contains", "kind": "file_contains", "path": "result.txt",
             "value": "ready", "required": True},
            {"id": "command", "kind": "command", "command": "test -f result.txt",
             "value": 0, "required": True, "timeout_seconds": 5},
            {"id": "json", "kind": "json_value", "path": "data.json",
             "value": {"pointer": "/status", "equals": "ok"}, "required": True},
            {"id": "schema", "kind": "json_schema", "path": "data.json",
             "value": {"type": "object", "required": ["items"],
                       "properties": {"items": {"type": "array"}}}, "required": True},
            {"id": "paths", "kind": "changed_paths_allowed", "value": ["result.txt", "data.json"],
             "required": True},
        ]
    }
    result = grade_case(case, str(tmp_path), "done", ["result.txt", "data.json"])
    assert result["deterministic_passed"]
    assert all(item["passed"] for item in result["assertions"])


def test_required_failure_cannot_be_hidden_by_optional_assertion(tmp_path) -> None:
    case = {"assertions": [
        {"id": "required", "kind": "path_exists", "path": "missing", "required": True},
        {"id": "optional", "kind": "output_contains", "value": "yes", "required": False},
    ]}
    result = grade_case(case, str(tmp_path), "yes", [])
    assert not result["deterministic_passed"]
    assert result["assertions"][1]["passed"]


def test_result_summary_reports_pass_rate_and_tail_latency() -> None:
    summary = summarize_results([
        {"state": "passed", "duration_ms": 100, "rubric_score": 90, "model_calls": 2},
        {"state": "failed", "duration_ms": 300, "rubric_score": 70, "model_calls": 1},
        {"state": "running", "duration_ms": 10},
    ])
    assert summary["cases"] == 2
    assert summary["pass_rate"] == 0.5
    assert summary["average_rubric_score"] == 80
    assert summary["p95_latency_ms"] == 300


def test_only_old_successful_unpinned_fixtures_are_cleanup_candidates(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    run_store = RunStore(tmp_path / "runs.sqlite3")
    store = EvaluationStore(run_store)
    suite = store.save_suite(_suite(workspace))
    run_store.start_run("old-pass")
    result_id = store.start_result(suite["id"], "case-1", "old-pass")
    store.finish_result(result_id, {"state": "passed", "task_id": "fixture-old"})
    with sqlite3.connect(run_store.path) as connection:
        connection.execute(
            "UPDATE evaluation_results SET completed_at=? WHERE id=?",
            (time.time() - 8 * 86_400, result_id),
        )

    assert store.expired_successful_task_ids() == ["fixture-old"]

    suite["pinned"] = True
    store.save_suite(suite, suite_id=suite["id"])
    assert store.expired_successful_task_ids() == []


def test_comparison_groups_solo_and_team_metrics_and_failures() -> None:
    comparison = compare_results([
        {"target": "solo", "state": "passed", "duration_ms": 100, "model_calls": 1},
        {"target": "team", "team_id": "a", "state": "failed", "duration_ms": 300,
         "model_calls": 3, "retries": 1, "failure_category": "deterministic_assertion"},
    ])

    assert comparison[0]["configuration"] == "solo"
    assert comparison[0]["pass_rate"] == 1
    assert comparison[1]["configuration"] == "team:a"
    assert comparison[1]["retries"] == 1
    assert comparison[1]["failure_categories"] == {"deterministic_assertion": 1}


def test_git_evaluation_suite_captures_and_cleans_immutable_fixture(
    tmp_path, monkeypatch,
) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=workspace, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=workspace, check=True)
    subprocess.run(
        ["git", "config", "user.email", "test@example.invalid"],
        cwd=workspace, check=True,
    )
    (workspace / "tracked.txt").write_text("original\n")
    subprocess.run(["git", "add", "tracked.txt"], cwd=workspace, check=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=workspace, check=True)
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "tasks")

    store = EvaluationStore(RunStore(tmp_path / "runs.sqlite3"))
    saved = store.save_suite(_suite(workspace))
    fixture_id = saved["cases"][0]["baseline_fixture"]["task_id"]
    fixture = worktrees.TaskCheckoutStore.load(fixture_id)

    assert fixture is not None
    assert (Path(fixture.execution_path) / "tracked.txt").read_text() == "original\n"
    cloned_value = dict(saved)
    cloned_value["id"] = "cloned-suite"
    cloned = store.save_suite(cloned_value)
    cloned_fixture_id = cloned["cases"][0]["baseline_fixture"]["task_id"]
    assert cloned_fixture_id != fixture_id
    (workspace / "tracked.txt").write_text("new workspace state\n")
    replay = worktrees.TaskCheckoutStore.replay(fixture, "eval-test-replay")
    assert (Path(replay.execution_path) / "tracked.txt").read_text() == "original\n"
    worktrees.TaskCheckoutStore.cleanup(replay.id)

    assert store.delete_suite(saved["id"])
    assert worktrees.TaskCheckoutStore.load(fixture_id) is None
    assert worktrees.TaskCheckoutStore.load(cloned_fixture_id) is not None
    assert store.delete_suite(cloned["id"])
