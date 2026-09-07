from __future__ import annotations

import copy
import json
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from ollama_code import server
from ollama_code.capsules import CapsuleError, CapsuleStore, normalize_plan


@pytest.fixture
def workspace(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "main.py").write_text("original\n")
    return root


@pytest.fixture
def payload():
    return {
        "title": "Add useful behavior",
        "request": "Implement and verify the planned change.",
        "plan": {
            "id": "plan-1", "title": "Plan", "summary": "A scoped change",
            "steps": ["Implement", "Verify"], "tests": ["Run targeted checks"],
            "constraints": ["Preserve existing behavior"], "decisions": ["Use the existing module"],
            "step_details": [
                {"id": "implement", "title": "Implement", "instructions": "Change the target function",
                 "files": ["main.py", "new/test.py"], "checks": ["Review the diff"]},
                {"id": "verify", "title": "Verify", "dependencies": ["implement"],
                 "files": ["main.py"], "checks": ["Run targeted tests"]},
            ],
        },
        "recipe": {"planner_profile_id": "planner", "executor_profile_id": "executor"},
    }


def test_capsules_persist_versions_and_only_whitelisted_configuration(workspace, payload, isolated_app_dir):
    payload["credentials"] = {"token": "never-store-this"}
    payload["recipe"].update({"api_key": "never-store-this", "provider": {"token": "never-store-this"}})
    payload["plan"]["step_details"][0]["provider_secret"] = "never-store-this"
    store = CapsuleStore(str(workspace))
    first = store.create(payload)
    second = store.update(first["id"], {"title": "Reviewed title"}, expected_revision=1)
    reopened = CapsuleStore(str(workspace))
    assert reopened.get(first["id"])["title"] == "Reviewed title"
    assert reopened.get(first["id"], revision=1)["title"] == payload["title"]
    assert second["revision"] == 2
    assert first["schema_version"] == 1
    assert first["recipe"]["execution_call_limit"] == 60
    assert first["recipe"]["max_repair_attempts"] == 2
    assert len(first["source_fingerprints"]) == 2
    assert "never-store-this" not in json.dumps(first)
    assert b"never-store-this" not in store.path.read_bytes()
    assert store.path.parent == isolated_app_dir


def test_reads_and_invalid_saves_do_not_create_storage_or_workspace_files(workspace, payload, isolated_app_dir):
    store = CapsuleStore(str(workspace))
    assert store.list() == []
    with pytest.raises(CapsuleError, match="not found"):
        store.validate("absent")
    payload["plan"]["step_details"][0]["files"] = ["../outside.txt"]
    with pytest.raises(CapsuleError, match="relative paths"):
        store.create(payload)
    assert not store.path.exists()
    assert not isolated_app_dir.exists()
    assert sorted(path.name for path in workspace.iterdir()) == ["main.py"]


def test_capsules_are_workspace_scoped(workspace, payload, tmp_path):
    other = tmp_path / "other"
    other.mkdir()
    first = CapsuleStore(str(workspace)).create(payload)
    second = CapsuleStore(str(other))
    assert second.list() == []
    with pytest.raises(CapsuleError) as error:
        second.get(first["id"])
    assert error.value.status_code == 404


def test_source_validation_detects_same_size_edits_deletion_and_creation(workspace, payload):
    store = CapsuleStore(str(workspace))
    capsule = store.create(payload)
    assert store.validate(capsule["id"])["valid"] is True
    before = store.path.read_bytes()
    (workspace / "main.py").write_text("modified\n")
    assert store.validate(capsule["id"])["changes"] == [{"path": "main.py", "reason": "changed"}]
    (workspace / "main.py").unlink()
    (workspace / "new").mkdir()
    (workspace / "new/test.py").write_text("new file")
    assert store.validate(capsule["id"])["changes"] == [
        {"path": "main.py", "reason": "deleted"}, {"path": "new/test.py", "reason": "created"},
    ]
    assert store.path.read_bytes() == before


@pytest.mark.parametrize("target", ["../outside.py", "/tmp/outside.py", "nested/../outside.py", "C:/secret", "a\\b", "./main.py", "a//b"])
def test_traversal_and_absolute_paths_are_rejected_without_reading(workspace, payload, target):
    payload["plan"]["step_details"][0]["files"] = [target]
    with pytest.raises(CapsuleError, match="relative paths"):
        CapsuleStore(str(workspace)).create(payload)


@pytest.mark.parametrize("parent_link", [False, True])
def test_symlinks_are_rejected_even_when_they_point_inside_workspace(workspace, payload, parent_link):
    if parent_link:
        (workspace / "linked").symlink_to(workspace, target_is_directory=True)
        target = "linked/main.py"
    else:
        (workspace / "linked.py").symlink_to(workspace / "main.py")
        target = "linked.py"
    payload["plan"]["step_details"][0]["files"] = [target]
    with pytest.raises(CapsuleError, match="symlink"):
        CapsuleStore(str(workspace)).create(payload)


def test_symlink_substitution_after_save_makes_capsule_stale(workspace, payload, tmp_path):
    store = CapsuleStore(str(workspace))
    capsule = store.create(payload)
    outside = tmp_path / "outside.py"
    outside.write_text("original\n")
    (workspace / "main.py").unlink()
    (workspace / "main.py").symlink_to(outside)
    result = store.validate(capsule["id"])
    assert result["valid"] is False
    assert result["changes"][0]["reason"] == "unsafe"


def test_title_edit_does_not_clear_staleness_but_reviewed_plan_versions_baseline(workspace, payload):
    store = CapsuleStore(str(workspace))
    first = store.create(payload)
    (workspace / "main.py").write_text("changed")
    store.update(first["id"], {"title": "New title"}, expected_revision=1)
    assert store.validate(first["id"])["valid"] is False
    store.update(first["id"], {"plan": first["plan"]}, expected_revision=2)
    assert store.validate(first["id"])["valid"] is True
    assert store.validate(first["id"], revision=1)["valid"] is False


def test_concurrent_updates_have_one_winner(workspace, payload):
    first = CapsuleStore(str(workspace)).create(payload)

    def update(title):
        try:
            return CapsuleStore(str(workspace)).update(first["id"], {"title": title}, 1)["revision"]
        except CapsuleError as error:
            return error.status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(update, ["One", "Two"]))
    assert sorted(results) == [2, 409]


def test_run_links_are_durable_and_escalation_allowance_is_atomic(workspace, payload):
    store = CapsuleStore(str(workspace))
    capsule = store.create(payload)

    def link(run_id):
        try:
            return CapsuleStore(str(workspace)).record_run(capsule["id"], run_id, "escalate", "queued", expected_revision=1)
        except CapsuleError as error:
            return error.status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(link, ["run-one", "run-two"]))
    assert sum(isinstance(item, dict) for item in results) == 1
    assert 409 in results
    run = next(item for item in results if isinstance(item, dict))
    store.update(capsule["id"], {"title": "Later revision"}, 1)
    store.record_run(capsule["id"], run["run_id"], "escalate", "completed")
    updated = CapsuleStore(str(workspace)).get(capsule["id"])
    assert updated["revision"] == 2
    assert updated["runs"][0]["revision"] == 1
    assert updated["runs"][0]["state"] == "completed"
    assert len(updated["runs"]) == 1
    with pytest.raises(CapsuleError, match="execution stage"):
        store.record_run(capsule["id"], run["run_id"], "execute", "completed")


def test_only_one_concurrent_clarification_can_consume_a_parent(workspace, payload):
    store = CapsuleStore(str(workspace))
    capsule = store.create(payload)
    store.record_run(capsule["id"], "parent-run", "escalate", "completed")

    def continue_run(run_id):
        try:
            return CapsuleStore(str(workspace)).record_run(capsule["id"], run_id, "escalate", "running", expected_revision=1, continuation_of_run_id="parent-run", reserve=True)
        except CapsuleError as error:
            return error.status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(continue_run, ["child-one", "child-two"]))
    assert sum(isinstance(item, dict) for item in results) == 1
    assert 409 in results
    assert len(store.get(capsule["id"])["runs"]) == 2


@pytest.mark.parametrize("kind", ["cycle", "unknown", "duplicate"])
def test_plan_dependencies_are_validated_without_io(payload, kind):
    plan = copy.deepcopy(payload["plan"])
    if kind == "cycle":
        plan["step_details"][0]["dependencies"] = ["verify"]
    elif kind == "unknown":
        plan["step_details"][0]["dependencies"] = ["missing"]
    else:
        plan["step_details"][1]["id"] = "implement"
    with pytest.raises(CapsuleError):
        normalize_plan(plan)


@pytest.mark.parametrize("field,value", [("execution_call_limit", True), ("execution_call_limit", 101), ("planning_call_limit", 0), ("planning_call_limit", 101), ("max_repair_attempts", -1), ("max_repair_attempts", 8), ("maximum_estimated_cost", float("nan")), ("executor_profile_id", {"api_key": "secret"})])
def test_invalid_recipe_limits_and_embedded_provider_configs_are_rejected(workspace, payload, field, value):
    payload["recipe"][field] = value
    with pytest.raises(CapsuleError):
        CapsuleStore(str(workspace)).create(payload)


def test_api_auth_storage_conflicts_and_validation(workspace, payload):
    service = SimpleNamespace(core=SimpleNamespace(cwd=str(workspace), workspace_root=str(workspace)))
    client = TestClient(server.create_app(chat_service=service, auth_token="capsule-token"))
    try:
        assert client.post("/api/capsules", json=payload).status_code == 401
        headers = {"x-locus-token": "capsule-token"}
        response = client.post("/api/capsules", json=payload, headers=headers)
        assert response.status_code == 200, response.text
        capsule = response.json()["capsule"]
        capsule_id = capsule["id"]
        assert client.get("/api/capsules", headers=headers).json()["capsules"][0]["id"] == capsule_id
        updated = client.patch(f"/api/capsules/{capsule_id}", json={"expected_revision": 1, "title": "Reviewed"}, headers=headers)
        assert updated.json()["capsule"]["revision"] == 2
        assert client.patch(f"/api/capsules/{capsule_id}", json={"expected_revision": 1}, headers=headers).status_code == 409
        assert client.patch(f"/api/capsules/{capsule_id}", json={}, headers=headers).status_code == 422
        assert client.get(f"/api/capsules/{capsule_id}?revision=1", headers=headers).json()["capsule"]["title"] == payload["title"]
        (workspace / "main.py").unlink()
        validation = client.post(f"/api/capsules/{capsule_id}/validate", json={}, headers=headers)
        assert validation.json()["valid"] is False
        assert validation.json()["checked_files"] == 2
        assert client.post("/api/capsules", json={**payload, "workspace_root": ["bad"]}, headers=headers).status_code == 422
    finally:
        client.close()


def test_origin_run_requires_matching_task_and_workspace_and_exposes_only_usage(workspace, payload, tmp_path):
    run = {
        "id": "planning-run", "session_id": "task-one", "workspace_root": str(workspace),
        "state": "completed", "usage": {"model_calls": 3, "metered_tokens": 120, "estimated_cost": 0.02, "provider_token": "private-provider-token"},
    }
    service = SimpleNamespace(
        core=SimpleNamespace(cwd=str(workspace), workspace_root=str(workspace), session=SimpleNamespace(session_id="task-one")),
        run_store=SimpleNamespace(run=lambda _id: run),
    )
    client = TestClient(server.create_app(chat_service=service))
    try:
        response = client.post("/api/capsules", json={**payload, "origin_run_id": "planning-run"})
        assert response.status_code == 200, response.text
        capsule = response.json()["capsule"]
        link = capsule["runs"][0]
        assert link["stage"] == "plan"
        assert link["usage"] == {"model_calls": 3, "metered_tokens": 120, "estimated_cost": 0.02}
        assert "private-provider-token" not in response.text
        assert "usage" not in CapsuleStore(str(workspace)).get(capsule["id"])["runs"][0]
        run["session_id"] = "task-two"
        assert client.post("/api/capsules", json={**payload, "origin_run_id": "planning-run"}).status_code == 422
        assert client.post("/api/capsules", json={**payload, "origin_run_id": "planning-run", "origin_session_id": "task-two"}).status_code == 200
        run["session_id"] = "task-one"
        run["workspace_root"] = str(tmp_path)
        assert client.post("/api/capsules", json={**payload, "origin_run_id": "planning-run"}).status_code == 422
        assert len(CapsuleStore(str(workspace)).list()) == 2
    finally:
        client.close()
