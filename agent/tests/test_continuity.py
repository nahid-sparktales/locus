"""Encrypted cross-chat continuity and Task Observer storage."""
from __future__ import annotations

import sqlite3

import pytest

from ollama_code.continuity import (
    ContinuityError,
    ContinuityStore,
    format_context_snapshots,
)


def _store(tmp_path) -> ContinuityStore:
    return ContinuityStore(
        tmp_path / "memory.sqlite3",
        key=b"k" * 32,
    )


def test_snapshot_is_encrypted_rolling_and_workspace_scoped(tmp_path):
    store = _store(tmp_path)
    workspace = tmp_path / "alpha"
    other = tmp_path / "beta"
    workspace.mkdir()
    other.mkdir()

    first = store.save_snapshot(
        str(workspace), "session-1", {"goal": "secret launch", "outcome": "drafted"}
    )
    replaced = store.save_snapshot(
        str(workspace), "session-1", {"goal": "secret launch", "outcome": "verified"}
    )
    store.save_snapshot(str(other), "session-2", {"goal": "other workspace"})

    assert first["id"] == replaced["id"]
    assert replaced["outcome"] == "verified"
    assert [item["id"] for item in store.list_snapshots(str(workspace))] == [first["id"]]
    assert store.list_snapshots(str(workspace), exclude_session="session-1") == []
    assert store.list_snapshots(str(other))[0]["goal"] == "other workspace"
    database_bytes = (tmp_path / "memory.sqlite3").read_bytes()
    assert b"secret launch" not in database_bytes
    assert b"verified" not in database_bytes


def test_snapshot_relevance_token_cap_pin_and_delete_scope(tmp_path):
    store = _store(tmp_path)
    workspace = tmp_path / "alpha"
    other = tmp_path / "beta"
    workspace.mkdir()
    other.mkdir()
    store.save_snapshot(str(workspace), "old", {"goal": "update documentation"})
    match = store.save_snapshot(
        str(workspace),
        "match",
        {
            "goal": "repair GitHub device authentication",
            "outcome": "device polling implemented " * 100,
            "changed_files": ["Locus/MCPAuthCoordinator.swift"],
        },
    )

    results = store.search_snapshots("GitHub auth polling", str(workspace), limit=1)
    assert results[0]["id"] == match["id"]
    rendered = format_context_snapshots(results, max_tokens=25)
    assert len(rendered) <= 100
    pinned = store.set_snapshot_pinned(match["id"], str(workspace), True)
    assert pinned["pinned"] is True
    assert pinned["expires_at"] is None
    assert store.delete_snapshot(match["id"], str(other)) is False
    assert store.delete_snapshot(match["id"], str(workspace)) is True


def test_observation_lifecycle_export_and_evidence_requirement(tmp_path):
    store = _store(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    with pytest.raises(ContinuityError, match="require issue"):
        store.record_observation(str(workspace), {"issue": "too vague"})
    observation = store.record_observation(str(workspace), {
        "title": "Clarify verification",
        "skill": "verification-before-completion",
        "issue": "The workflow did not name the focused command.",
        "suggested_improvement": "Require the exact command in the completion evidence.",
        "principle": "Completion claims should be reproducible.",
    })
    assert observation["number"] == 1
    assert observation["status"] == "OPEN"
    updated = store.set_observation_status(observation["id"], str(workspace), "actioned")
    assert updated["status"] == "ACTIONED"
    assert store.export_observations(str(workspace))["observations"][0]["id"] == observation["id"]
    assert store.delete_observation(observation["id"], str(workspace)) is True
    assert store.list_observations(str(workspace)) == []


def test_snapshot_limit_keeps_latest_unpinned_records(tmp_path):
    store = _store(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    for index in range(55):
        store.save_snapshot(str(workspace), f"session-{index}", {"goal": f"goal-{index}"})

    snapshots = store.list_snapshots(str(workspace), limit=100)
    assert len(snapshots) == 50
    assert "goal-0" not in {item["goal"] for item in snapshots}


def test_expired_unpinned_snapshot_is_pruned(tmp_path):
    store = _store(tmp_path)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    item = store.save_snapshot(str(workspace), "session", {"goal": "temporary"})
    with sqlite3.connect(tmp_path / "memory.sqlite3") as connection:
        connection.execute(
            "UPDATE context_snapshots SET expires_at=0 WHERE id=?", (item["id"],)
        )
    assert store.list_snapshots(str(workspace)) == []
