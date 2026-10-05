"""Encrypted cross-chat context snapshots and skill observations - Locus facade.

Storage, sealing, recall scoring and formatting are implemented by
locus_memory.compat.legacy_vault; the host keeps workspace git inventory.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from locus_memory.compat.legacy_vault import (
    MAX_CHANGED_FILES,
    LegacyContinuityStore,
    format_context_snapshots,
)
from locus_memory.compat.legacy_vault import LegacyContinuityError as ContinuityError

from .memory import _master_key, memory_database
from .proxy import sanitized_child_environment


def workspace_changed_files(workspace: str) -> list[str]:
    """Return a bounded, read-only git status inventory for snapshot evidence."""
    try:
        completed = subprocess.run(
            ["git", "-C", workspace, "status", "--porcelain=v1", "-z"],
            env=sanitized_child_environment(),
            capture_output=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if completed.returncode != 0:
        return []
    files: list[str] = []
    for entry in completed.stdout.decode("utf-8", errors="replace").split("\0"):
        if not entry:
            continue
        path = entry[3:] if len(entry) > 3 else entry
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        value = path.strip()
        if value and value not in files:
            files.append(value[:1_000])
        if len(files) >= MAX_CHANGED_FILES:
            break
    return files


class ContinuityStore(LegacyContinuityStore):
    """Locus facade: storage and crypto live in locus_memory.compat.legacy_vault."""

    def __init__(
        self,
        path: Path | None = None,
        *,
        key: bytes | None = None,
        fallback_key_path: Path | None = None,
    ) -> None:
        database = path or memory_database()
        super().__init__(database, key=_master_key(key, fallback_key_path, vault_path=database))


__all__ = [
    "ContinuityError", "ContinuityStore", "format_context_snapshots",
    "workspace_changed_files",
]
