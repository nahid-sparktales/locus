"""Canonical host contracts across real package ownership transitions."""
from __future__ import annotations

import pytest
from locus_memory import MemoryEngine
from locus_memory.compat.legacy_vault import LegacyMemoryVault, LegacyVaultError
from locus_memory.host import HostCapabilities
from locus_memory.migrations.cutover import Migrator
from locus_memory.migrations.state import OwnershipControl
from locus_memory.models import AccessContext, Actor, Lifecycle, Operation, PartitionRef

from ollama_code.memory_adapter import LocusKeyProvider
from ollama_code.memory_canonical import CanonicalMemoryVault


@pytest.fixture
def canonical(tmp_path):
    app = tmp_path / "app"
    memory = app / "memory"
    memory.mkdir(parents=True)
    (memory / "master.key").write_bytes(b"c" * 32)
    legacy = LegacyMemoryVault(memory / "memory.sqlite3", key=b"c" * 32)
    root = app / "memory-engine"
    control = OwnershipControl(root)
    engine = MemoryEngine(root, LocusKeyProvider(app), host=HostCapabilities(ownership=control))
    partition = PartitionRef("locus", "default")
    access = AccessContext("migration", partition, Actor.HOST,
                           operations=frozenset({Operation.ADMIN}))
    migrator = Migrator(engine, control, access, legacy.path, b"c" * 32, work_dir=root / "migration")
    assert migrator.prepare_shadow()["state"] == "shadow_prepared"
    assert migrator.validate()["validated"]
    assert migrator.cutover()["cutover"]
    made = []

    def make(**kwargs):
        vault = CanonicalMemoryVault(app, workspace=str(tmp_path / "project"), **kwargs)
        made.append(vault)
        return vault

    yield make, migrator, legacy
    for vault in made:
        vault.close()
    engine.close()
    control.close()


def test_user_roundtrip_and_rollback_preserve_all_scopes(canonical):
    make, migrator, legacy = canonical
    user = make()
    records = [user.save({"title": scope, "content": f"The {scope} color is violet.", "scope": scope})
               for scope in ("workspace", "personal", "agent")]
    assert len(user.list()) == 3
    assert {r["id"] for r in user.search("violet")} == {r["id"] for r in records}
    assert user.status()["approved_count"] == 3
    exported = user.export()
    assert exported["format"] == "locus-memory-export"
    assert exported["version"] == 2
    assert migrator.plan_rollback()["safe"]
    assert migrator.rollback()["state"] == "legacy_authoritative"
    restored = legacy.list(workspace=user.workspace, agent_id="primary")
    assert {r["id"] for r in restored} == {r["id"] for r in records}
    assert {r["scope"] for r in restored} == {"workspace", "personal", "agent"}
    with pytest.raises(LegacyVaultError, match="fenced"):
        user.save({"content": "Not writable after rollback", "scope": "personal"})


def test_agent_proposes_but_cannot_approve_edit_delete_or_widen_scopes(canonical):
    make, _, _ = canonical
    user = make()
    agent = make(actor=Actor.AGENT, scopes=("workspace",))
    hidden = user.save({"content": "Private personal color is turquoise", "scope": "personal"})
    assert agent.list(scopes=["personal"]) == []
    assert agent.search("turquoise", scopes=[]) == []
    with pytest.raises(LegacyVaultError):
        agent.save({"content": "Approved by model", "scope": "workspace"})
    with pytest.raises(LegacyVaultError):
        agent.save({"content": "Personal scope", "scope": "personal", "status": "candidate"})
    item = agent.save({"title": "Proposal", "content": "The build command is make check.",
                       "scope": "workspace", "status": "candidate"})
    assert item["status"] == "candidate"
    assert user.search("make check") == []
    with pytest.raises(LegacyVaultError):
        agent.approve(item["id"])
    with pytest.raises(LegacyVaultError):
        agent.save({**item, "content": "Changed by model"}, item["id"])
    with pytest.raises(LegacyVaultError):
        agent.delete(item["id"])
    assert agent.delete(hidden["id"]) is False
    assert user.approve(item["id"])["status"] == "approved"
    assert user.search("make check")[0]["id"] == item["id"]


def test_target_isolation_and_empty_scopes(canonical):
    make, _, _ = canonical
    first = make()
    second = make(agent_id="second")
    record = second.save({"content": "Second agent uses cinnamon", "scope": "agent"})
    assert first.delete(record["id"]) is False
    with pytest.raises(LegacyVaultError, match="not found"):
        first.feedback(record["id"], "incorrect")
    with pytest.raises(LegacyVaultError, match="not found"):
        first.save({**record, "content": "Overwrite a guessed id"}, record["id"])
    assert first.list(scopes=[]) == []
    assert second.list()[0]["content"] == "Second agent uses cinnamon"


def test_incorrect_feedback_invalidates_context_and_pin_preserves_stale(canonical):
    make, _, _ = canonical
    vault = make()
    record = vault.save({"title": "Deployment", "content": "Deploy with violet deploy.", "scope": "workspace"})
    vault.feedback(record["id"], "incorrect")
    assert vault.search("violet deploy") == []
    stale = vault.list()[0]
    assert stale["stale"]
    pinned = vault.save({**stale, "pinned": True}, stale["id"])
    assert pinned["stale"] and pinned["pinned"]
    assert vault.search("violet deploy") == []
    assert vault.approve(record["id"])["stale"] is False
    assert vault.search("violet deploy")


def test_delete_suppression_and_plaintext_note_migration(canonical):
    make, migrator, _ = canonical
    vault = make()
    note = {"id": "old-note", "title": "Test note", "content": "The test runner is violet.", "created_at": 1700000000}
    identifier, outcome = vault.import_legacy_note(note, workspace=vault.workspace)
    assert outcome == "migrated"
    assert vault.list()[0]["created_at"] == note["created_at"]
    vault.save({"scope": "workspace", "content": "The updated test runner is jade."}, identifier)
    assert vault.import_legacy_note(note, workspace=vault.workspace) == (identifier, "already_migrated")
    assert vault.list()[0]["content"] == "The updated test runner is jade."
    assert vault.delete(identifier)
    with pytest.raises(LegacyVaultError, match="forgotten"):
        vault.import_legacy_note(note, workspace=vault.workspace)
    assert migrator.plan_rollback()["safe"]


def test_candidate_metadata_does_not_approve_and_forget_keeps_rollback_safe(canonical):
    make, migrator, _ = canonical
    user = make()
    candidate = user.save({"content": "Review violet tooling", "scope": "workspace", "status": "candidate"})
    changed = user.save({**candidate, "pinned": True}, candidate["id"])
    assert changed["status"] == "candidate"
    access, _ = user._access()
    assert user.engine.get(access, changed["id"]).lifecycle == Lifecycle.CANDIDATE
    user.delete(changed["id"])
    assert migrator.plan_rollback()["safe"]
    assert not user.list()


def test_partial_updates_preserve_candidate_scope_kind_and_validity(canonical):
    make, _, _ = canonical
    vault = make()
    record = vault.save({"content": "Violet is a preferred theme.", "scope": "personal", "kind": "preference",
                         "status": "candidate", "valid_from": 1700000000})
    changed = vault.save({"title": "Color preference"}, record["id"])
    assert (changed["scope"], changed["kind"], changed["status"], changed["valid_from"]) == (
        "personal", "preference", "candidate", 1700000000,
    )


@pytest.mark.parametrize("bad", [{"kind": "nonsense"}, {"confidence": "no"}, {"tags": 42}])
def test_invalid_input_is_legacy_error_without_write(canonical, bad):
    make, _, _ = canonical
    vault = make()
    with pytest.raises(LegacyVaultError):
        vault.save({"content": "Violet tooling", "scope": "personal", **bad})
    assert vault.list() == []


def test_agent_cannot_change_constructor_identity_or_create_procedure(canonical):
    make, _, _ = canonical
    agent = make(actor=Actor.AGENT, scopes=("workspace", "agent"))
    with pytest.raises(LegacyVaultError, match="identity"):
        agent.search("violet", workspace="/other/project")
    with pytest.raises(LegacyVaultError, match="identity"):
        agent.list(agent_id="someone-else")
    with pytest.raises(LegacyVaultError, match="procedure"):
        agent.save({"content": "Violet build steps", "scope": "workspace", "kind": "procedure", "status": "candidate"})
    assert agent.list() == []


def test_source_bindings_are_engine_sources_and_preserved_on_edit(canonical):
    make, _, _ = canonical
    vault = make()
    record = vault.save({"content": "Violet notes.", "scope": "workspace", "source_session_id": "session-one",
                         "source_run_id": "run-one"})
    assert record["source_session_id"] == "session-one"
    assert record["source_run_id"] == "run-one"
    edited = vault.save({"title": "A new title"}, record["id"])
    assert edited["source_session_id"] == "session-one"
    access, _ = vault._access()
    stored = vault.engine.get(access, record["id"])
    assert any(s.kind.value == "session" and s.ref == "session-one" for s in stored.sources)
    assert "locus" not in stored.extra
