"""An ambiguous restored control file cannot silently re-enable legacy writers."""
from __future__ import annotations

import shutil
import sqlite3
from contextlib import closing
from types import SimpleNamespace

import pytest
from locus_memory.compat.legacy_vault import LegacyMemoryVault
from locus_memory.models import PartitionRef

from ollama_code.memory import MemoryError, MemoryVault
from ollama_code.memory_adapter import MemoryAdapter, ensure_memory_profile
from ollama_code.memory_canonical import CanonicalMemoryVault
from ollama_code.memory_migration import HostMemoryMigration, main
from ollama_code.memory_ownership import assert_legacy_writer, ownership_state


@pytest.fixture(autouse=True)
def isolated_profile_processes(monkeypatch):
    # Every fixture owns a fresh temporary profile. Keep real process leases;
    # unrelated UI tests on the same host do not own this profile.
    monkeypatch.setattr("ollama_code.memory_migration.assert_quiescent", lambda _: None)
    monkeypatch.setattr("ollama_code.memory_guard._helper_path", lambda: None)


def _backup(source, target):
    with closing(sqlite3.connect(source)) as db, closing(sqlite3.connect(target)) as backup:
        db.backup(backup)


def _shadow(root):
    database = root / "memory/memory.sqlite3"
    legacy = MemoryVault(database, fallback_key_path=database.with_name("master.key"))
    legacy.save({"content": "Legacy baseline canary", "scope": "personal", "status": "approved"})
    adapter = MemoryAdapter(app_dir=root, edition="locus", mode="shadow")
    try:
        core = SimpleNamespace(workspace_root="", cwd="")
        packet = adapter.packet(adapter.access(core), "canary", max_tokens=1000, max_items=8)
        assert packet and packet[1].items
    finally:
        adapter.close()
    control = root / "memory-engine/control.sqlite3"
    with closing(sqlite3.connect(control)) as db:
        assert db.execute("SELECT COUNT(*) FROM ownership").fetchone()[0] == 0
    return legacy


@pytest.fixture
def migrated(isolated_app_dir):
    root = isolated_app_dir
    legacy = _shadow(root)
    control = root / "memory-engine/control.sqlite3"
    old = root / "shadow-control.sqlite3"
    _backup(control, old)
    with HostMemoryMigration(root) as migration:
        migration.snapshot()
        assert migration.validate()["validated"]
        assert migration.cutover()["cutover"]
    with MemoryVault() as vault:
        record = vault.save({"content": "Package-era canary", "scope": "personal"})
    current = root / "current-control.sqlite3"
    _backup(control, current)
    return root, legacy, record["id"], old, current


@pytest.mark.parametrize("entrypoint", [
    "state", "bootstrap", "vault", "explicit_key", "canonical", "adapter", "writer", "retained_writer", "migration",
])
def test_actual_pre_cutover_control_restore_fails_closed(migrated, entrypoint):
    root, legacy, identifier, old, current = migrated
    control = root / "memory-engine/control.sqlite3"
    shutil.copyfile(old, control)
    calls = {
        "state": lambda: ownership_state(root, "locus"),
        "bootstrap": lambda: ensure_memory_profile(root, "locus"),
        "vault": MemoryVault,
        "explicit_key": lambda: MemoryVault(root / "memory/memory.sqlite3",
                                             fallback_key_path=root / "memory/master.key"),
        "canonical": lambda: CanonicalMemoryVault(root),
        "adapter": lambda: MemoryAdapter(app_dir=root, edition="locus"),
        "writer": lambda: assert_legacy_writer(root, "locus"),
        "retained_writer": lambda: legacy.save({"content": "Divergent history", "scope": "personal"}),
        "migration": lambda: HostMemoryMigration(root).__enter__(),
    }
    with pytest.raises(MemoryError, match="ownership is missing.*refusing legacy fallback"):
        calls[entrypoint]()
    # Failure does not adopt the stale state, alter canonical data or split writes.
    with closing(sqlite3.connect(control)) as db:
        assert db.execute("SELECT COUNT(*) FROM ownership").fetchone()[0] == 0
    shutil.copyfile(current, control)
    with MemoryVault() as vault:
        assert identifier in {item["id"] for item in vault.list()}
        assert all(item["content"] != "Divergent history" for item in vault.list())


@pytest.mark.parametrize("action", ["state", "snapshot", "cutover", "rollback", "abort"])
def test_offline_cli_does_not_adopt_restored_control(migrated, action, capsys):
    root, _, _, old, _ = migrated
    shutil.copyfile(old, root / "memory-engine/control.sqlite3")
    assert main(["--app-dir", str(root), action, "--yes"]) == 1
    assert "refusing legacy fallback" in capsys.readouterr().out


def test_fresh_profile_missing_row_is_not_a_legacy_vault(isolated_app_dir):
    root = isolated_app_dir
    with MemoryVault() as vault:
        vault.save({"content": "Fresh canonical record", "scope": "personal"})
    control = root / "memory-engine/control.sqlite3"
    with closing(sqlite3.connect(control)) as db, db:
        db.execute("DELETE FROM ownership")
    with pytest.raises(MemoryError, match="ownership is missing"):
        MemoryVault()
    assert not (root / "memory/memory.sqlite3").exists()


@pytest.mark.parametrize("remove_history", [False, True])
def test_missing_row_after_cutover_is_rejected_with_or_without_control_history(migrated, remove_history):
    root, _, _, _, _ = migrated
    with closing(sqlite3.connect(root / "memory-engine/control.sqlite3")) as db, db:
        db.execute("DELETE FROM ownership")
        if remove_history:
            db.execute("DELETE FROM ownership_log")
    with pytest.raises(MemoryError, match="ownership is missing"):
        ownership_state(root, "locus")


def test_valid_empty_row_shadow_still_serves_and_writes_legacy(isolated_app_dir):
    root = isolated_app_dir
    _shadow(root)
    assert ownership_state(root, "locus") == "legacy_authoritative"
    assert ensure_memory_profile(root, "locus") == "legacy_authoritative"
    vault = MemoryVault()
    assert isinstance(vault, LegacyMemoryVault)
    assert len(vault.list()) == 1
    vault.save({"content": "Valid legacy write", "scope": "personal", "status": "approved"})
    assert len(vault.list()) == 2


def test_explicit_rollback_keeps_legacy_access_and_can_cut_over_again(migrated):
    root, legacy, identifier, _, _ = migrated
    with HostMemoryMigration(root) as migration:
        assert migration.rollback()["state"] == "legacy_authoritative"
    # The package's cutover marker survives rollback. The explicit ownership row
    # distinguishes this supported reverse sync from a missing-row restore.
    partition = PartitionRef("locus", "default")
    with closing(sqlite3.connect(root / "memory-engine" / partition.partition_id / "memory.sqlite3")) as db:
        assert db.execute("SELECT 1 FROM meta WHERE key='migration_cutover_set'").fetchone()
    assert ownership_state(root, "locus") == "legacy_authoritative"
    assert identifier in {item["id"] for item in legacy.list()}
    legacy.save({"content": "Post-rollback canary", "scope": "personal", "status": "approved"})
    with HostMemoryMigration(root) as migration:
        assert migration.snapshot()["state"] == "shadow_prepared"
        assert migration.validate()["validated"]
        assert migration.cutover()["cutover"]
    with MemoryVault() as vault:
        assert identifier in {item["id"] for item in vault.list()}
        assert any(item["content"] == "Post-rollback canary" for item in vault.list())
