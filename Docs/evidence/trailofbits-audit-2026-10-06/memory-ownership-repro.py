"""Isolated partial-restore probe; does not access the user's Locus profile."""
from contextlib import closing
from pathlib import Path
from types import SimpleNamespace
import os
import shutil
import sqlite3
import tempfile


def backup(src, dst):
    with closing(sqlite3.connect(src)) as db, closing(sqlite3.connect(dst)) as out:
        db.backup(out)


with tempfile.TemporaryDirectory(prefix="locus-audit-control-restore-") as raw:
    os.environ["OLLAMA_CODE_HOME"] = raw
    from locus_memory.compat.legacy_vault import LegacyMemoryVault
    from ollama_code import memory_migration
    from ollama_code.memory import MemoryVault
    from ollama_code.memory_adapter import LocusKeyProvider, MemoryAdapter
    from ollama_code.memory_ownership import ownership_state

    root = Path(raw)
    # The real checker rejects unrelated Locus processes. This profile is new,
    # private to this process, and still uses the real exclusive migration lease.
    memory_migration.assert_quiescent = lambda _: None
    legacy = LegacyMemoryVault(root / "memory/memory.sqlite3", key=LocusKeyProvider(root).legacy_key())
    legacy.save({"content": "legacy baseline canary", "scope": "personal", "status": "approved"})
    adapter = MemoryAdapter(app_dir=root, edition="locus", mode="shadow")
    adapter.packet(adapter.access(SimpleNamespace(workspace_root="", cwd="")), "canary", max_tokens=1000, max_items=8)
    adapter.close()
    control = root / "memory-engine/control.sqlite3"
    with closing(sqlite3.connect(control)) as db:
        print("actual shadow ownership rows", db.execute("SELECT COUNT(*) FROM ownership").fetchone()[0])
    backup(control, root / "pre-cutover-control.sqlite3")
    with memory_migration.HostMemoryMigration(root) as migration:
        migration.snapshot()
        migration.validate()
        print("cutover state", migration.cutover()["state"])
    with MemoryVault() as vault:
        record = vault.save({"content": "package era canary", "scope": "personal"})
        print("before restore visible", record["id"] in {m["id"] for m in vault.list()})
    backup(control, root / "good-control.sqlite3")
    control.unlink()
    try:
        ownership_state(root, "locus")
    except Exception as exc:
        print("missing file negative control", type(exc).__name__)
    shutil.copyfile(root / "pre-cutover-control.sqlite3", control)
    print("old control restored state", ownership_state(root, "locus"))
    vault = MemoryVault()
    print("after restore visible", record["id"] in {m["id"] for m in vault.list()})
    vault.save({"content": "divergent legacy canary", "scope": "personal", "status": "approved"})
    print("legacy write accepted", len(vault.list()))
    shutil.copyfile(root / "good-control.sqlite3", control)
    with MemoryVault() as vault:
        print("package record preserved", record["id"] in {m["id"] for m in vault.list()})
