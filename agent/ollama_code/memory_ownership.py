"""Locus profile paths for package-owned writer fencing and process leases."""
from __future__ import annotations

import sqlite3
from contextlib import closing
from pathlib import Path

from locus_memory.compat.legacy_vault import LegacyVaultError
from locus_memory.errors import OwnershipFenced
from locus_memory.migrations import ownership
from locus_memory.migrations.legacy import CUTOVER_SET_KEY
from locus_memory.migrations.state import WRITERS
from locus_memory.models import PartitionRef


def ownership_state(app_dir: Path | str, edition: str) -> str:
    root = Path(app_dir) / "memory-engine"
    partition = PartitionRef(edition.lower(), "default")
    state = ownership.ownership_state(root, partition)
    control = root / "control.sqlite3"
    if state != "legacy_authoritative" or not control.exists():
        return state
    # 0.3.0 treats an absent ownership row as an unmigrated shadow profile.
    # That is valid only without evidence of an ownership transition. A restored
    # pre-cutover control file can have no rows while the surviving partition
    # still records its cutover. Never authorize legacy fallback in that case.
    try:
        with closing(sqlite3.connect(control.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            if db.execute("SELECT 1 FROM ownership WHERE partition_id=? AND family='memories'",
                          (partition.partition_id,)).fetchone():
                return state  # Includes an explicitly completed rollback.
            transitioned = db.execute(
                "SELECT 1 FROM ownership_log WHERE partition_id=? AND family='memories' LIMIT 1",
                (partition.partition_id,),
            ).fetchone()
        database = root / partition.partition_id / "memory.sqlite3"
        if not transitioned and database.exists():
            with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as db:
                transitioned = db.execute("SELECT 1 FROM meta WHERE key=?", (CUTOVER_SET_KEY,)).fetchone()
        if transitioned:
            raise LegacyVaultError("memory ownership is missing for a previously initialized or migrated profile; refusing legacy fallback")
    except (sqlite3.Error, OSError) as exc:
        raise LegacyVaultError("memory ownership is unavailable; refusing legacy fallback") from exc
    return state


def assert_legacy_writer(app_dir: Path | str, edition: str) -> None:
    state = ownership_state(app_dir, edition)
    if "legacy" not in WRITERS[state]:
        raise OwnershipFenced(f"legacy memory writes are fenced while ownership is {state}")


def profile_lease(app_dir: Path | str, *, exclusive: bool = False):
    return ownership.profile_lease(Path(app_dir) / ".memory-runtime.lock", exclusive=exclusive)
