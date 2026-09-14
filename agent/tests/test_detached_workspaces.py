"""Saved agents allocate each new chat once and preserve its source workspace."""
from __future__ import annotations

import subprocess
import uuid
from pathlib import Path

import pytest
from fastapi import HTTPException

from ollama_code import worktrees
from ollama_code.agent_workspaces import AgentChatWorkspace
from ollama_code.api.sessions import (
    session_detached,
    session_detail,
    session_metadata_update,
    session_resume,
)
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.sessions import SessionMeta, SessionStore


def _create(workspace, **changes):
    return session_detached({"cwd": str(workspace), "title": "Research task", **changes})


def _git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.STDOUT)


@pytest.fixture
def repository(tmp_path, monkeypatch):
    monkeypatch.setattr(worktrees, "TASKS_DIR", tmp_path / "managed-tasks")
    root = tmp_path / "project"
    root.mkdir()
    _git(root, "init")
    _git(root, "config", "user.name", "Fixture")
    _git(root, "config", "user.email", "fixture@localhost")
    (root / "file.txt").write_text("original\n")
    _git(root, "add", ".")
    _git(root, "commit", "-m", "Initial fixture")
    return root


@pytest.fixture
def agent_home(tmp_path, monkeypatch):
    root = tmp_path / "AgentHomes"
    monkeypatch.setenv("LOCUS_AGENT_HOMES_ROOT", str(root))
    profile_id = str(uuid.uuid4())
    workspace = root / profile_id / "Workspace"
    workspace.mkdir(parents=True)
    return workspace, profile_id


def test_legacy_detached_request_keeps_local_workspace_without_new_folders(repository):
    before = sorted(path.name for path in repository.iterdir())
    result = _create(repository)
    assert result["workspace_root"] == result["execution_path"] == str(repository)
    assert result["environment"] == {"type": "local", "isolation": "local"}
    assert "output_directory" not in result
    assert "task" not in SessionMeta.get(result["session_id"])
    assert sorted(path.name for path in repository.iterdir()) == before


@pytest.mark.parametrize("policy", ["automatic", "local"])
def test_non_git_chats_keep_selected_folder_with_distinct_outputs(tmp_path, policy):
    workspace = tmp_path / "research"
    workspace.mkdir()
    first = _create(workspace, execution_environment=policy)
    (Path(first["output_directory"]) / "notes.md").write_text("First chat")
    second = _create(workspace, execution_environment=policy)
    assert first["session_id"] != second["session_id"]
    assert first["output_directory"] != second["output_directory"]
    for result in (first, second):
        assert result["execution_path"] == str(workspace)
        assert result["workspace_root"] == str(workspace)
        assert result["environment"]["type"] == "local"
        assert Path(result["output_directory"]).is_dir()
        assert result["environment"]["output_directory"] == result["output_directory"]
    assert (Path(first["output_directory"]) / "notes.md").read_text() == "First chat"


@pytest.mark.parametrize("policy", ["automatic", "worktree"])
def test_git_chats_capture_working_tree_without_touching_source(repository, policy):
    (repository / "file.txt").write_text("staged\n")
    _git(repository, "add", "file.txt")
    (repository / "file.txt").write_text("unstaged\n")
    (repository / "untracked.txt").write_text("unsaved draft\n")
    original_index = (repository / ".git" / "index").read_bytes()
    original_head = _git(repository, "rev-parse", "HEAD")
    original_branch = _git(repository, "symbolic-ref", "HEAD")
    original_status = _git(repository, "status", "--porcelain")
    first = _create(repository, execution_environment=policy)
    second = _create(repository, execution_environment=policy)
    assert first["execution_path"] != second["execution_path"]
    for result in (first, second):
        execution = Path(result["execution_path"])
        assert execution != repository
        assert result["workspace_root"] == str(repository)
        assert (execution / "file.txt").read_text() == "unstaged\n"
        assert (execution / "untracked.txt").read_text() == "unsaved draft\n"
        assert result["environment"]["isolation"] == "managed_worktree"
        assert result["task"]["session_id"] == result["session_id"]
        assert SessionMeta.get(result["session_id"])["task"] == result["task"]
        assert Path(result["output_directory"]).is_dir()
    (Path(first["execution_path"]) / "file.txt").write_text("First chat changed this\n")
    assert (Path(second["execution_path"]) / "file.txt").read_text() == "unstaged\n"
    assert (repository / "file.txt").read_text() == "unstaged\n"
    assert _git(repository, "status", "--porcelain") == original_status
    assert _git(repository, "rev-parse", "HEAD") == original_head
    assert _git(repository, "symbolic-ref", "HEAD") == original_branch
    assert (repository / ".git" / "index").read_bytes() == original_index


def test_explicit_local_git_chat_stays_in_selected_checkout(repository):
    result = _create(repository, execution_environment="local")
    assert result["execution_path"] == str(repository)
    assert result["environment"]["isolation"] == "local"
    assert "task" not in result


def test_git_subfolder_keeps_map_source_and_uses_repository_execution(repository, tmp_path, monkeypatch):
    selected = repository / "subproject"
    selected.mkdir()
    (selected / "notes.txt").write_text("Subproject file")
    result = _create(selected, execution_environment="automatic")
    assert result["workspace_root"] == str(repository)
    assert result["environment"]["source_workspace"] == str(selected)
    assert (Path(result["execution_path"]) / "subproject" / "notes.txt").read_text() == "Subproject file"
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    monkeypatch.setattr(core.mcp, "refresh", lambda **kwargs: None)
    try:
        info = session_resume(result["session_id"], ChatService(core))["session_info"]
        assert info["workspace_root"] == str(repository)
        assert info["execution_path"] == result["execution_path"]
        assert info["environment"]["source_workspace"] == str(selected)
    finally:
        monkeypatch.chdir(tmp_path)


def test_detached_worktree_artifacts_use_existing_archive_restore_lifecycle(repository, tmp_path, monkeypatch):
    result = _create(repository, execution_environment="automatic")
    artifact = Path(result["output_directory"]) / "report.md"
    artifact.write_text("Keep this completed artifact")
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    monkeypatch.setattr(core.mcp, "refresh", lambda **kwargs: None)
    service = ChatService(core)
    try:
        session_metadata_update(result["session_id"], service, {"archived": True})
        assert not Path(result["execution_path"]).exists()
        worktrees.TaskCheckoutStore.restore(result["task"]["id"])
        session_metadata_update(result["session_id"], service, {"archived": False})
        info = session_resume(result["session_id"], service)["session_info"]
        assert info["workspace_root"] == str(repository)
        assert core.cwd == info["execution_path"] == result["execution_path"]
        assert info["output_directory"] == result["output_directory"]
        assert artifact.read_text() == "Keep this completed artifact"
    finally:
        monkeypatch.chdir(tmp_path)


def test_new_allocation_never_reuses_or_cleans_an_existing_worktree(repository):
    first = _create(repository, execution_environment="automatic")
    marker = Path(first["execution_path"]) / "keep.txt"
    marker.write_text("Existing chat work")
    with pytest.raises(worktrees.WorktreeError):
        AgentChatWorkspace.create(repository, first["session_id"], policy="automatic", agent_home=False)
    assert marker.read_text() == "Existing chat work"
    assert worktrees.TaskCheckoutStore.load(first["task"]["id"]) is not None


def test_home_chats_create_distinct_task_folders_and_resume_same_locations(agent_home, tmp_path, monkeypatch):
    workspace, profile_id = agent_home
    (workspace / "memory.md").write_text("Shared agent knowledge")
    options = {"execution_environment": "automatic", "agent_home": True, "agent_profile_id": profile_id}
    first, second = _create(workspace, **options), _create(workspace, **options)
    assert first["execution_path"] != second["execution_path"]
    for result in (first, second):
        execution = workspace / "Tasks" / result["session_id"]
        assert result["workspace_root"] == str(workspace)
        assert result["execution_path"] == str(execution)
        assert result["output_directory"] == str(execution / "Outputs")
        assert result["environment"]["agent_home"] == "true"
        assert execution.is_dir()
        assert not (execution / "memory.md").exists()
        assert session_detail(result["session_id"])["output_directory"] == str(execution / "Outputs")
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    monkeypatch.setattr(core.mcp, "refresh", lambda **kwargs: None)
    service = ChatService(core)
    try:
        for result in (first, second, first):
            resumed = session_resume(result["session_id"], service)["session_info"]
            assert core.cwd == result["execution_path"]
            assert resumed["workspace_root"] == str(workspace)
            assert resumed["execution_path"] == result["execution_path"]
            assert resumed["output_directory"] == result["output_directory"]
            assert resumed["environment"]["isolation"] == "agent_task_folder"
            assert service.current_task is None
    finally:
        monkeypatch.chdir(tmp_path)
    assert (workspace / "memory.md").read_text() == "Shared agent knowledge"


@pytest.mark.parametrize("changes", [
    {"execution_environment": "unknown"}, {"execution_environment": True},
    {"execution_environment": None}, {"execution_environment": {}},
    {"execution_environment": []}, {"agent_home": "true"}, {"agent_home": 1},
    {"agent_home": None}, {"cwd": "bad\x00path"}, {"cwd": []},
    {"agent_home": True},
    {"agent_home": True, "agent_profile_id": str(uuid.uuid4())},
    {"execution_environment": "worktree"},
])
def test_invalid_workspace_requests_leave_no_saved_session_or_folders(tmp_path, changes):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    before = SessionStore.list_sessions()
    with pytest.raises(HTTPException) as error:
        _create(workspace, **changes)
    assert error.value.status_code == 422
    assert SessionStore.list_sessions() == before
    assert list(workspace.iterdir()) == []


def test_home_rejects_worktree_policy_and_symlink_escape(agent_home, tmp_path):
    workspace, profile_id = agent_home
    options = {"agent_home": True, "agent_profile_id": profile_id}
    with pytest.raises(HTTPException) as error:
        _create(workspace, **options, execution_environment="worktree")
    assert error.value.status_code == 422
    other = tmp_path / "other"
    other.mkdir()
    (workspace / "Tasks").symlink_to(other, target_is_directory=True)
    with pytest.raises(HTTPException) as error:
        _create(workspace, **options, execution_environment="automatic")
    assert error.value.status_code == 422
    assert list(other.iterdir()) == []


def test_home_path_cannot_redirect_to_another_workspace(agent_home, tmp_path):
    workspace, profile_id = agent_home
    workspace.rmdir()
    other = tmp_path / "other"
    other.mkdir()
    workspace.symlink_to(other, target_is_directory=True)
    with pytest.raises(HTTPException) as error:
        _create(workspace, agent_home=True, agent_profile_id=profile_id, execution_environment="automatic")
    assert error.value.status_code == 422
    assert list(other.iterdir()) == []


def test_missing_home_is_not_implicitly_created(agent_home):
    workspace, profile_id = agent_home
    workspace.rmdir()
    with pytest.raises(HTTPException) as error:
        _create(workspace, agent_home=True, agent_profile_id=profile_id, execution_environment="automatic")
    assert error.value.status_code == 422
    assert not workspace.exists()


def test_new_chat_output_hint_reaches_both_prompt_paths_and_legacy_has_none(tmp_path, monkeypatch):
    workspace = tmp_path / "research"
    workspace.mkdir()
    current = _create(workspace, execution_environment="automatic")
    legacy = _create(workspace)
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    monkeypatch.setattr(core.mcp, "refresh", lambda **kwargs: None)
    service = ChatService(core)
    try:
        session_resume(current["session_id"], service)
        for prompt in (core.messages[0]["content"], core.system_message()["content"], core._parity_developer_instructions()):
            assert current["output_directory"] in prompt
            assert "unless the user specifies another destination" in prompt
            assert "Keep project source edits in the current working copy" in prompt
        assert current["output_directory"] not in core.system_message(mode="ask")["content"]
        session_resume(legacy["session_id"], service)
        for prompt in (core.messages[0]["content"], core.system_message()["content"], core._parity_developer_instructions()):
            assert "This chat's output folder" not in prompt
    finally:
        monkeypatch.chdir(tmp_path)


def test_failed_home_save_cleans_only_new_task_folder(agent_home, monkeypatch):
    workspace, profile_id = agent_home
    options = {"agent_home": True, "agent_profile_id": profile_id, "execution_environment": "automatic"}
    first = _create(workspace, **options)
    notes = Path(first["output_directory"]) / "notes.md"
    notes.write_text("Keep these notes")
    before = SessionStore.list_sessions()
    monkeypatch.setattr(SessionMeta, "_write", lambda value: None)
    with pytest.raises(HTTPException) as error:
        _create(workspace, **options)
    assert error.value.status_code == 500
    assert SessionStore.list_sessions() == before
    assert [path.name for path in (workspace / "Tasks").iterdir()] == [first["session_id"]]
    assert notes.read_text() == "Keep these notes"


def test_failed_git_save_removes_only_new_managed_checkout(repository, monkeypatch):
    first = _create(repository, execution_environment="automatic")
    before = _git(repository, "worktree", "list", "--porcelain")
    monkeypatch.setattr(SessionMeta, "_write", lambda value: None)
    with pytest.raises(HTTPException) as error:
        _create(repository, execution_environment="automatic")
    assert error.value.status_code == 500
    assert _git(repository, "worktree", "list", "--porcelain") == before
    assert Path(first["execution_path"]).is_dir()
    assert sorted(path.name for path in worktrees.TASKS_DIR.iterdir()) == [first["session_id"]]


@pytest.mark.parametrize("from_home", [False, True])
def test_explicit_local_location_overrides_original_header_without_moving_files(agent_home, tmp_path, monkeypatch, from_home):
    home, profile_id = agent_home
    original = home if from_home else tmp_path / "project-a"
    original.mkdir(exist_ok=True)
    result = _create(original, execution_environment="automatic", agent_home=from_home,
                     agent_profile_id=profile_id)
    artifact = Path(result["output_directory"]) / "earlier.md"
    artifact.write_text("Keep this in the original chat folder")
    destination = tmp_path / "project-b"
    destination.mkdir()
    (destination / "project.txt").write_text("Selected project")
    SessionMeta.update(
        result["session_id"], workspace_root=str(destination), execution_path=str(destination),
        environment={"type": "local", "isolation": "local"}, task=None, output_directory=None,
    )
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    monkeypatch.setattr(core.mcp, "refresh", lambda **kwargs: None)
    try:
        info = session_resume(result["session_id"], ChatService(core))["session_info"]
        assert core.cwd == info["workspace_root"] == info["execution_path"] == str(destination)
        assert info["output_directory"] is None
        assert SessionStore.header(SessionStore.path_for(result["session_id"]))["cwd"] == str(original)
        assert artifact.read_text() == "Keep this in the original chat folder"
        assert sorted(path.name for path in destination.iterdir()) == ["project.txt"]
    finally:
        monkeypatch.chdir(tmp_path)


def test_missing_explicit_local_location_does_not_resume_in_original_folder(tmp_path, monkeypatch):
    original = tmp_path / "original"
    original.mkdir()
    result = _create(original)
    missing = tmp_path / "removed-project"
    SessionMeta.update(result["session_id"], workspace_root=str(missing), execution_path=str(missing))
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    previous = core.session.session_id
    with pytest.raises(HTTPException) as error:
        session_resume(result["session_id"], ChatService(core))
    assert error.value.status_code == 422
    assert "unavailable" in error.value.detail
    assert core.session.session_id == previous
    assert core.cwd == str(tmp_path)
    assert not missing.exists()


@pytest.mark.parametrize("locations", [
    {"workspace_root": "relative", "execution_path": "relative"},
    {"workspace_root": [], "execution_path": "relative"},
    {"execution_path": "/"},
])
def test_invalid_metadata_location_cannot_retarget_execution(tmp_path, locations):
    result = _create(tmp_path)
    SessionMeta.update(result["session_id"], **locations)
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    previous = core.session.session_id
    with pytest.raises(HTTPException) as error:
        session_resume(result["session_id"], ChatService(core))
    assert error.value.status_code == 422
    assert core.session.session_id == previous
    assert core.cwd == str(tmp_path)


def test_legacy_header_location_is_used_when_metadata_omits_locations(tmp_path, monkeypatch):
    original = tmp_path / "legacy-project"
    original.mkdir()
    result = _create(original)
    SessionMeta.update(result["session_id"], workspace_root=None, execution_path=None, environment=None)
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    try:
        info = session_resume(result["session_id"], ChatService(core))["session_info"]
        assert core.cwd == info["workspace_root"] == info["execution_path"] == str(original)
    finally:
        monkeypatch.chdir(tmp_path)
