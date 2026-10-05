from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest
from locus_memory.errors import OwnershipFenced

from ollama_code.memory import MemoryError, MemoryVault
from ollama_code.memory_migration import HostMemoryMigration, main
from ollama_code.memory_ownership import ownership_state, profile_lease


def seed(root: Path):
    database = root / "memory" / "memory.sqlite3"
    vault = MemoryVault(database, fallback_key_path=database.with_name("master.key"))
    first = vault.save({"title": "Formatting", "content": "Use tabs for indentation",
                        "scope": "personal", "kind": "preference"})
    second = vault.save({"title": "Pending preference", "content": "A candidate must stay private",
                         "scope": "personal", "status": "candidate"})
    return vault, first, second


def test_host_shadow_enabled_cutover_restart_and_rollback(tmp_path, monkeypatch):
    legacy_vault, first, second = seed(tmp_path)
    monkeypatch.setenv("LOCUS_MEMORY_ENGINE_MODE", "shadow")
    with HostMemoryMigration(tmp_path) as host:
        assert host.inventory()["rows"] == 2
        comparison = host.compare(["tabs", "candidate"])
        assert all(item["legacy_prompt_unchanged"] for item in comparison["queries"])
        assert comparison["queries"][0]["overlap"] == 1
        assert comparison["queries"][1]["engine_items"] <= 1
        assert [item.id for item in host.engine.list(host.access)] == [first["id"]]
    monkeypatch.setenv("LOCUS_MEMORY_ENGINE_MODE", "enabled")
    with HostMemoryMigration(tmp_path) as host:
        assert host.compare(["tabs"])["queries"][0]["engine_items"] == 1
        assert host.snapshot()["state"] == "shadow_prepared"
        assert host.validate(["tabs"])["validated"]
        assert host.cutover(["tabs"])["state"] == "package_authoritative"
        assert host.migrator.plan_rollback()["safe"]
    with pytest.raises(OwnershipFenced):
        legacy_vault.save({"content": "late write", "scope": "personal"})
    monkeypatch.setenv("LOCUS_MEMORY_ENGINE_MODE", "disabled")
    canonical = MemoryVault(tmp_path / "memory" / "memory.sqlite3")
    assert type(canonical).__name__ == "CanonicalMemoryVault"
    assert {item["id"] for item in canonical.list()} == {first["id"], second["id"]}
    canonical.save({"title": "Formatting", "content": "Use spaces for indentation",
                    "scope": "personal", "kind": "preference"}, first["id"])
    assert canonical.delete(second["id"])
    canonical.close()
    with HostMemoryMigration(tmp_path) as host:
        assert host.migrator.plan_rollback()["safe"]
        assert host.rollback()["state"] == "legacy_authoritative"
    restored = MemoryVault(tmp_path / "memory" / "memory.sqlite3",
                           fallback_key_path=tmp_path / "memory" / "master.key")
    values = restored.list()
    assert len(values) == 1
    assert values[0]["content"] == "Use spaces for indentation"
    assert not list((tmp_path / "memory-engine" / "migration").glob("snapshot-*"))


def test_live_backend_lease_blocks_migration(tmp_path):
    seed(tmp_path)
    with profile_lease(tmp_path), pytest.raises(MemoryError, match="in use"):
        with HostMemoryMigration(tmp_path):
            pytest.fail("migration must not run against an active backend")


def test_failed_validation_never_transfers_ownership(tmp_path):
    seed(tmp_path)
    with HostMemoryMigration(tmp_path) as host:
        host.snapshot()
        with sqlite3.connect(host.database) as conn:
            conn.execute("UPDATE memories SET ciphertext=?", (b"corrupt",))
        assert not host.validate()["validated"]
        with pytest.raises(Exception, match="validated"):
            host.cutover()
    assert ownership_state(tmp_path, "Locus") == "shadow_prepared"


def test_inventory_does_not_create_engine_or_rekey(tmp_path, capsys):
    seed(tmp_path)
    key = (tmp_path / "memory" / "master.key").read_bytes()
    assert main(["--app-dir", str(tmp_path), "inventory"]) == 0
    assert json.loads(capsys.readouterr().out)["rows"] == 2
    assert not (tmp_path / "memory-engine").exists()
    assert (tmp_path / "memory" / "master.key").read_bytes() == key


def test_unknown_ownership_fails_closed(tmp_path):
    seed(tmp_path)
    root = tmp_path / "memory-engine"
    root.mkdir()
    (root / "control.sqlite3").write_bytes(b"invalid")
    with pytest.raises(MemoryError, match="refusing legacy fallback"):
        MemoryVault(tmp_path / "memory" / "memory.sqlite3")


def test_shadow_does_not_reuse_successful_metrics_after_failure(tmp_path, monkeypatch):
    from locus_memory.errors import MemoryEngineError

    from ollama_code.memory_adapter import MemoryAdapter

    seed(tmp_path)
    monkeypatch.setenv("LOCUS_MEMORY_ENGINE_MODE", "shadow")
    original = MemoryAdapter._packet
    calls = 0

    def packet(self, *args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise MemoryEngineError("simulated failure")
        return original(self, *args, **kwargs)

    monkeypatch.setattr(MemoryAdapter, "_packet", packet)
    with HostMemoryMigration(tmp_path) as host, pytest.raises(Exception, match="shadow comparison failed"):
        host.compare(["tabs", "preferences"])


def test_missing_ownership_does_not_restore_legacy_authority(tmp_path):
    seed(tmp_path)
    with HostMemoryMigration(tmp_path) as host:
        host.snapshot()
    (tmp_path / "memory-engine" / "control.sqlite3").unlink()
    with pytest.raises(MemoryError, match="ownership is missing"):
        MemoryVault(tmp_path / "memory" / "memory.sqlite3")


def test_rollback_refuses_corrupt_package_records_before_changing_owner(tmp_path):
    seed(tmp_path)
    with HostMemoryMigration(tmp_path) as host:
        host.snapshot()
        assert host.validate()["validated"]
        assert host.cutover()["cutover"]
        ctx = host.engine.partition_context(host.partition)
        with ctx.partition.db.write() as connection:
            connection.execute("UPDATE records SET ciphertext=?", (b"damaged",))
        with pytest.raises(Exception, match="could not be authenticated"):
            host.rollback()
        assert host.migrator.state().state == "package_authoritative"
    with sqlite3.connect(tmp_path / "memory" / "memory.sqlite3") as connection:
        assert connection.execute("SELECT COUNT(*) FROM memories").fetchone()[0] == 2
