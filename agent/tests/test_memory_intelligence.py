"""File evidence invalidation and conservative duplicate consolidation on real stores."""
from dataclasses import replace

import pytest
from locus_memory.compat.canonical_vault import CanonicalMemoryVault
from locus_memory.errors import MemoryEngineError, RevisionConflict
from locus_memory.models import Actor, Lifecycle, PartitionRef

from ollama_code import paths
from ollama_code.memory import MemoryError
from ollama_code.memory_adapter import LocusKeyProvider, ensure_memory_profile
from ollama_code.memory_capabilities import memory_capabilities
from ollama_code.memory_intelligence import (
    SOURCE_KEY,
    bind_sources,
    consolidate_memories,
    inspect_staleness,
    refresh_memory,
    source_fingerprints,
)
from ollama_code.product_build import PRODUCT_NAME


def _open_vault(*, workspace, agent_id="primary", actor=Actor.USER):
    """Exercise explicit intelligence calls without the host's automatic hooks.

    Keep real host profile ownership, keys and guard capabilities. The package
    facade supplies the same engine/access interface without binding sources
    or consolidating records as part of test setup.
    """
    ensure_memory_profile(paths.APP_DIR, PRODUCT_NAME)
    keys = LocusKeyProvider(paths.APP_DIR)
    return CanonicalMemoryVault(
        paths.APP_DIR / "memory-engine", keys,
        partition=PartitionRef(PRODUCT_NAME.lower(), "default"), workspace=workspace,
        agent_id=agent_id, actor=actor, principal="locus-local-user", host_name="locus",
        host=memory_capabilities(paths.APP_DIR, PRODUCT_NAME, keys),
    )


@pytest.fixture
def vault(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = _open_vault(workspace=str(workspace), agent_id="primary")
    yield store, workspace
    store.close()


def _save(vault, content, **kwargs):
    store, _ = vault
    return store.save({"title": content[:60], "content": content, "scope": "workspace", "kind": "fact", **kwargs})


def _get(vault, identifier):
    store, workspace = vault
    access, _ = store._access(str(workspace), "primary")
    return store.engine.get(access, identifier)


def test_changed_source_becomes_stale_and_requires_explicit_refresh(vault):
    store, workspace = vault
    source = workspace / "config.json"
    source.write_text('{"worker_count": 2}')
    saved = _save(vault, "The worker count in config.json is 2.")
    bound = bind_sources(store, saved["id"], ["config.json"], workspace=str(workspace))
    assert bound["provenance"][SOURCE_KEY]["files"]["config.json"]["size"] == source.stat().st_size
    assert inspect_staleness(store, workspace=str(workspace))["marked_stale"] == 0
    source.write_text('{"worker_count": 3}')
    report = inspect_staleness(store, workspace=str(workspace))
    assert report["marked_stale"] == 1 and report["items"][0]["changed_paths"] == ["config.json"]
    assert _get(vault, saved["id"]).lifecycle == Lifecycle.STALE
    assert store.search("worker count") == []
    assert store.list()[0]["feedback"] == {}
    # Rebinding cannot silently rebaseline or approve a stale statement.
    assert bind_sources(store, saved["id"], ["config.json"], workspace=str(workspace))["stale"]
    assert inspect_staleness(store, workspace=str(workspace))["marked_stale"] == 0
    current = _get(vault, saved["id"])
    refreshed = refresh_memory(store, saved["id"], workspace=str(workspace), expected_revision=current.revision)
    assert not refreshed["stale"]
    assert store.search("worker count")
    assert inspect_staleness(store, workspace=str(workspace))["items"][0]["state"] == "current"


def test_missing_file_is_stale_and_cannot_be_refreshed(vault):
    store, workspace = vault
    (workspace / "rules.txt").write_text("rule")
    saved = _save(vault, "The rules are in rules.txt.")
    bind_sources(store, saved["id"], ["rules.txt"], workspace=str(workspace))
    (workspace / "rules.txt").unlink()
    assert inspect_staleness(store, workspace=str(workspace))["marked_stale"] == 1
    with pytest.raises(MemoryEngineError):
        refresh_memory(store, saved["id"], workspace=str(workspace))
    assert _get(vault, saved["id"]).lifecycle == Lifecycle.STALE


def test_dependency_fact_tracks_manifests_but_preferences_do_not(vault):
    store, workspace = vault
    (workspace / "package.json").write_text('{"dependencies":{"react":"19"}}')
    (workspace / "package-lock.json").write_text('{"lockfileVersion":3}')
    dependency = _save(vault, "This project uses React version 19.")
    preference = _save(vault, "I prefer concise answers.", kind="preference")
    bound = bind_sources(store, dependency["id"], workspace=str(workspace))
    assert set(bound["provenance"][SOURCE_KEY]["files"]) == {"package.json", "package-lock.json"}
    assert SOURCE_KEY not in bind_sources(store, preference["id"], workspace=str(workspace))["provenance"]
    (workspace / "package-lock.json").write_text('{"lockfileVersion":4}')
    assert inspect_staleness(store, workspace=str(workspace))["marked_stale"] == 1
    assert _get(vault, preference["id"]).lifecycle == Lifecycle.APPROVED


def test_explicit_source_limit_does_not_fail_when_dependencies_are_inferred(vault):
    store, workspace = vault
    names = [f"source-{number}.txt" for number in range(32)]
    for name in names:
        (workspace / name).write_text("evidence")
    (workspace / "package.json").write_text('{"dependencies":{"react":"19"}}')
    saved = _save(vault, "This project uses React version 19.")
    bound = bind_sources(store, saved["id"], names, workspace=str(workspace))
    assert set(bound["provenance"][SOURCE_KEY]["files"]) == set(names)


@pytest.mark.parametrize("path", ["../outside.txt", "/tmp/outside.txt", ".env", ".git/config"])
def test_source_paths_cannot_escape_or_read_excluded_files(vault, path):
    _, workspace = vault
    with pytest.raises((MemoryError, MemoryEngineError)):
        source_fingerprints(str(workspace), [path])


def test_source_symlink_is_not_followed(vault, tmp_path):
    _, workspace = vault
    outside = tmp_path / "outside.txt"
    outside.write_text("private outside data")
    (workspace / "linked.txt").symlink_to(outside)
    with pytest.raises(MemoryEngineError):
        source_fingerprints(str(workspace), ["linked.txt"])


def test_source_files_remain_scoped_and_refresh_checks_revision(vault):
    store, workspace = vault
    (workspace / "rules.txt").write_text("rule")
    personal = _save(vault, "I prefer concise answers.", kind="preference", scope="personal")
    with pytest.raises(MemoryError, match="workspace"):
        bind_sources(store, personal["id"], ["rules.txt"], workspace=str(workspace))
    saved = _save(vault, "The rules are in rules.txt.")
    bind_sources(store, saved["id"], workspace=str(workspace))
    with pytest.raises(MemoryError, match="changed"):
        refresh_memory(store, saved["id"], workspace=str(workspace), expected_revision=saved["revision"])
    with _open_vault(workspace=str(workspace / "another")) as other:
        with pytest.raises(MemoryEngineError):
            refresh_memory(other, saved["id"], workspace=str(workspace / "another"))


def test_duplicate_paraphrases_consolidate_without_losing_originals(vault):
    store, workspace = vault
    first = _save(vault, "I prefer concise answers.", kind="preference")
    second = _save(vault, "My preference is brief responses.", kind="preference")
    third = _save(vault, "I prefer concise answers.", kind="preference")
    preview = consolidate_memories(store, workspace=str(workspace), apply=False)
    assert preview["merged"] == 0 and len(preview["groups"]) == 1
    report = consolidate_memories(store, workspace=str(workspace))
    assert report["merged"] == 2
    keeper = _get(vault, first["id"])
    assert keeper.lifecycle == Lifecycle.APPROVED
    assert set(keeper.links.supersedes) == {second["id"], third["id"]}
    assert _get(vault, second["id"]).content == second["content"]
    assert _get(vault, second["id"]).lifecycle == Lifecycle.SUPERSEDED
    assert len(store.search("concise answers")) == 1


@pytest.mark.parametrize("left,right", [
    ("Use Python 3.11.", "Use Python 3.12."),
    ("The worker count is 2.", "The worker count is 3."),
    ("I prefer concise answers.", "I never prefer concise answers."),
    ("Use config/A.py.", "Use config/a.py."),
    ("The client calls the server.", "The server calls the client."),
])
def test_distinct_versions_numbers_negations_paths_and_roles_are_not_duplicates(vault, left, right):
    store, workspace = vault
    _save(vault, left)
    _save(vault, right)
    assert consolidate_memories(store, workspace=str(workspace))["merged"] == 0


def test_different_kinds_scopes_and_provenance_do_not_consolidate(vault):
    store, workspace = vault
    content = "The preferred release color is violet."
    _save(vault, content)
    _save(vault, content, scope="personal")
    _save(vault, content, kind="decision")
    with _open_vault(workspace=str(workspace), actor=Actor.AGENT) as agent:
        candidate = agent.save({"content": content, "kind": "fact", "scope": "workspace", "status": "candidate"})
    store.approve(candidate["id"])
    assert consolidate_memories(store, workspace=str(workspace))["merged"] == 0


def test_different_source_baselines_do_not_consolidate(vault):
    store, workspace = vault
    source = workspace / "rules.txt"
    source.write_text("first")
    first = _save(vault, "The rules are in rules.txt.")
    bind_sources(store, first["id"], workspace=str(workspace))
    source.write_text("second")
    second = _save(vault, "The rules are in rules.txt.")
    bind_sources(store, second["id"], workspace=str(workspace))
    assert consolidate_memories(store, workspace=str(workspace))["merged"] == 0


def test_agent_cannot_apply_intelligence_changes(vault):
    store, workspace = vault
    first = _save(vault, "I prefer concise answers.", kind="preference")
    _save(vault, "My preference is brief responses.", kind="preference")
    with _open_vault(workspace=str(workspace), actor=Actor.AGENT) as agent:
        with pytest.raises(MemoryEngineError):
            consolidate_memories(agent, workspace=str(workspace))
        with pytest.raises(MemoryEngineError):
            refresh_memory(agent, first["id"], workspace=str(workspace))


def test_different_validity_and_confidence_are_not_consolidated(vault):
    store, workspace = vault
    content = "The favorite color is violet."
    _save(vault, content, valid_until=2000000000)
    _save(vault, content, valid_until=2100000000)
    _save(vault, content, confidence=0.5)
    _save(vault, content, confidence=0.9)
    assert consolidate_memories(store, workspace=str(workspace))["merged"] == 0


def test_changed_survivor_is_not_used_by_an_earlier_duplicate_decision(vault, monkeypatch):
    from ollama_code import memory_intelligence
    store, workspace = vault
    first = _save(vault, "I prefer concise answers.", kind="preference")
    second = _save(vault, "My preference is brief responses.", kind="preference")
    merge = memory_intelligence._merge_pair

    def changed_before_merge(*args):
        store.save({"content": "I prefer comprehensive explanations."}, first["id"])
        return merge(*args)

    monkeypatch.setattr(memory_intelligence, "_merge_pair", changed_before_merge)
    report = consolidate_memories(store, workspace=str(workspace))
    assert report["merged"] == 0 and report["skipped"] == 1
    assert _get(vault, second["id"]).lifecycle == Lifecycle.APPROVED


def test_deleted_memory_cannot_return_during_a_source_check(vault, monkeypatch):
    from ollama_code import memory_intelligence
    store, workspace = vault
    path = workspace / "rules.txt"
    path.write_text("old")
    saved = _save(vault, "The rules are in rules.txt.")
    bind_sources(store, saved["id"], workspace=str(workspace))
    path.write_text("new")
    write = memory_intelligence._write_sources

    def delete_before_write(*args, **kwargs):
        store.delete(saved["id"])
        return write(*args, **kwargs)

    monkeypatch.setattr(memory_intelligence, "_write_sources", delete_before_write)
    report = inspect_staleness(store, workspace=str(workspace))
    assert report["marked_stale"] == 0
    assert store.list() == []


def test_default_source_preflight_checks_records_beyond_one_engine_page(vault):
    store, workspace = vault
    source = workspace / "rules.txt"
    source.write_text("original")
    saved = _save(vault, "The special deployment rules are in rules.txt.")
    bind_sources(store, saved["id"], ["rules.txt"], workspace=str(workspace))
    # Pinned records sort first regardless of timestamp/ID; the source-backed
    # record is guaranteed to be beyond both the old 500 cap and page size 1000.
    filler = _get(vault, _save(vault, "Project label 0 is recorded.", pinned=True)["id"])
    ctx = store.engine.partition_context(store.partition)
    # Bulk fixture insertion still uses canonical encrypted writes/indexes;
    # repeat-save conflict discovery is unrelated to pagination under test.
    with ctx.partition.db.write() as connection:
        for number in range(1, 1000):
            ctx.services.core.write_internal(connection,
                replace(filler, id=f"pagination-filler-{number}", title=f"Project label {number}",
                        content=f"Project label {number} is recorded."),
                change="test_pagination_fixture", actor=Actor.USER, expected=None)
    source.write_text("changed")
    assert inspect_staleness(store, workspace=str(workspace), limit=500)["checked"] == 0
    report = inspect_staleness(store, workspace=str(workspace))
    assert report["checked"] == report["marked_stale"] == 1
    assert report["items"] == [{"id": saved["id"], "state": "stale", "changed_paths": ["rules.txt"]}]
    assert _get(vault, saved["id"]).lifecycle == Lifecycle.STALE
    assert saved["id"] not in {item["id"] for item in store.search("special deployment rules")}


def test_source_preflight_aborts_when_a_revision_race_leaves_changed_evidence_approved(vault, monkeypatch):
    from ollama_code import memory_intelligence
    store, workspace = vault
    source = workspace / "rules.txt"
    source.write_text("original")
    saved = _save(vault, "The deployment rules are in rules.txt.")
    bind_sources(store, saved["id"], ["rules.txt"], workspace=str(workspace))
    source.write_text("changed")
    write = memory_intelligence._write_sources

    def edit_before_invalidation(*args, **kwargs):
        store.save({"title": "Revised display title"}, saved["id"])
        return write(*args, **kwargs)

    monkeypatch.setattr(memory_intelligence, "_write_sources", edit_before_invalidation)
    with pytest.raises(RevisionConflict):
        inspect_staleness(store, workspace=str(workspace))
    assert _get(vault, saved["id"]).lifecycle == Lifecycle.APPROVED
    monkeypatch.setattr(memory_intelligence, "_write_sources", write)
    assert inspect_staleness(store, workspace=str(workspace))["marked_stale"] == 1


@pytest.mark.parametrize("status", ["approved", "candidate", "stale"])
def test_source_refresh_is_not_a_generic_approval_route(vault, status):
    store, workspace = vault
    saved = _save(vault, "The deployment region is east.", status="approved" if status == "stale" else status)
    if status == "stale":
        store.feedback(saved["id"], "incorrect")
    before = _get(vault, saved["id"])
    with pytest.raises(MemoryError, match="file sources"):
        refresh_memory(store, saved["id"], workspace=str(workspace))
    after = _get(vault, saved["id"])
    assert (after.lifecycle, after.revision) == (before.lifecycle, before.revision)


def test_source_refresh_cannot_restore_a_consolidated_memory(vault):
    store, workspace = vault
    (workspace / "rules.txt").write_text("original")
    first = _save(vault, "The deployment rules are in rules.txt.")
    second = _save(vault, "The deployment rules are in rules.txt.")
    for item in (first, second):
        bind_sources(store, item["id"], ["rules.txt"], workspace=str(workspace))
    report = consolidate_memories(store, workspace=str(workspace))
    assert report["merged"] == 1
    identifier = report["groups"][0]["duplicates"][0]
    before = _get(vault, identifier)
    assert before.lifecycle == Lifecycle.SUPERSEDED
    with pytest.raises(MemoryError, match="current workspace"):
        refresh_memory(store, identifier, workspace=str(workspace))
    after = _get(vault, identifier)
    assert (after.lifecycle, after.revision) == (before.lifecycle, before.revision)
