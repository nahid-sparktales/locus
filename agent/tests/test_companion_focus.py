import pytest
from ollama_code.goals import GoalError, GoalStore
from ollama_code.runstore import RunStore


def make_session(tmp_path, **fields):
    store = GoalStore(RunStore(tmp_path / "runs.sqlite3"))
    session = {"mode": "learning", "minutes": 30, "steps": ["Explain checkpoint ownership", "Complete the exercise"], **fields}
    goal = store.create("companion", "Explain checkpoint ownership with an example", execution={
        "provider": "ollama", "model": "local", "workspace_root": "/workspace", "companion_session": session,
    })
    return store, goal


def test_learning_session_is_durable_and_never_automatically_claimed(tmp_path):
    store, goal = make_session(tmp_path)
    assert goal["status"] == "paused"
    assert store.claim(goal["id"], goal["revision"])["run"] is None
    with pytest.raises(GoalError, match="never continues automatically"):
        store.update(goal["id"], "resume")
    assert store.for_session("companion")["execution"]["companion_session"]["minutes"] == 30


def test_checkpoint_requires_evidence_and_revision_then_finishes_honestly(tmp_path):
    store, goal = make_session(tmp_path)
    with pytest.raises(GoalError):
        store.update(goal["id"], "session_update", operation="checkpoint", index=0, evidence="")
    goal = store.update(goal["id"], "session_update", expected_revision=goal["revision"],
                        operation="checkpoint", index=0, evidence="I wrote an example that resumes from a saved checkpoint.")
    assert goal["execution"]["companion_session"]["steps"][0]["completed"]
    assert goal["status"] == "paused"
    with pytest.raises(GoalError, match="changed"):
        store.update(goal["id"], "session_update", expected_revision=1, operation="finish")
    goal = store.update(goal["id"], "session_update", expected_revision=goal["revision"], operation="finish")
    assert goal["status"] == "completed"
    assert goal["summary"] == "1 of 2 checkpoints reported complete by you."
    assert "not independently verified" in goal["reason"]
    assert len(goal["evidence"]) == 1


def test_pause_resume_timer_retains_elapsed_without_autonomous_run(tmp_path, monkeypatch):
    monkeypatch.setattr("ollama_code.goals.time.time", lambda: 1000)
    store, goal = make_session(tmp_path)
    monkeypatch.setattr("ollama_code.goals.time.time", lambda: 1045)
    goal = store.update(goal["id"], "session_update", expected_revision=goal["revision"], operation="pause")
    assert goal["execution"]["companion_session"]["elapsed_seconds"] == 45
    monkeypatch.setattr("ollama_code.goals.time.time", lambda: 1300)
    goal = store.update(goal["id"], "session_update", expected_revision=goal["revision"], operation="resume")
    assert goal["execution"]["companion_session"]["elapsed_seconds"] == 45
    assert goal["status"] == "paused"
    assert store.claim(goal["id"], goal["revision"])["run"] is None


@pytest.mark.parametrize("fields", [{"minutes": 0}, {"minutes": 241}, {"minutes": True}, {"steps": []}, {"steps": [" "]}, {"mode": "autonomous"}])
def test_invalid_session_configuration_rejected(tmp_path, fields):
    with pytest.raises(GoalError):
        make_session(tmp_path, **fields)


def test_saved_companion_chat_uses_existing_goal_api_and_checks_workspace(tmp_path, monkeypatch):
    import uuid
    from types import SimpleNamespace
    from fastapi import HTTPException
    from ollama_code.api import goals as api
    path = tmp_path / "companion.jsonl"
    path.write_text('{}\n')
    monkeypatch.setattr(api.SessionStore, "path_for", lambda _: path)
    monkeypatch.setattr(api.SessionStore, "header", lambda _: {"cwd": str(tmp_path)})
    monkeypatch.setattr(api.SessionStore, "_summary_record", lambda _: {})
    monkeypatch.setattr(api.SessionMeta, "get", lambda _: {"agent_profile_id": str(uuid.uuid4())})
    service = SimpleNamespace(run_store=RunStore(tmp_path / "runs.sqlite3"), busy=False,
                             core=SimpleNamespace(session=SimpleNamespace(session_id="foreground"),
                                                  cwd=str(tmp_path), identity_mode=False))
    execution = {"provider": "ollama", "model": "local", "workspace_root": str(tmp_path),
                 "companion_session": {"mode": "focus", "minutes": 20, "steps": ["Write the introduction"]}}
    goal = api.goal_create(service, "companion", {"objective": "Finish the introduction", "execution": execution})
    assert goal["session_id"] == "companion"
    assert goal["status"] == "paused"
    updated = api.goal_update(service, goal["id"], {"action": "session_update", "expected_revision": goal["revision"],
                             "operation": "checkpoint", "index": 0, "evidence": "Drafted three paragraphs."})
    assert updated["execution"]["companion_session"]["steps"][0]["completed"]
    with pytest.raises(HTTPException, match="workspace"):
        api.goal_create(service, "other", {"objective": "Other goal", "execution": {**execution, "workspace_root": "/other"}})
