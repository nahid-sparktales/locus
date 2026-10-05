"""Encrypted local memory - Locus facade over the locus-memory package.

Record format, AES-256-GCM sealing, lifecycle, conflict detection, search and
export/import are implemented by ``locus_memory.compat.legacy_vault`` (a
format-compatible extraction of the code that used to live here; same tables,
same associated data, same payloads). This module keeps only host concerns:
the app-data path and local key custody. Bridge removal criterion: delete this
facade once every caller uses the memory adapter and the canonical backend is
``package`` (see locus-memory docs/ownership-and-extraction.md).
"""
from __future__ import annotations

import os
import secrets
import sqlite3
from pathlib import Path

from locus_memory.compat.legacy_vault import (
    CANDIDATE_TTL_SECONDS,
    MAX_MEMORY_CONTENT,
    VALID_KINDS,
    VALID_SCOPES,
    VALID_STATUSES,
    LegacyMemoryVault,
    format_memory_results,
    legacy_target,
)
from locus_memory.compat.legacy_vault import LegacyVaultError as MemoryError

from . import paths
from .memory_ownership import assert_legacy_writer, ownership_state
from .product_build import PRODUCT_NAME


def memory_database() -> Path:
    return paths.APP_DIR / "memory" / "memory.sqlite3"


def _vault_has_rows(vault_path: Path | None) -> bool:
    if vault_path is None:
        return False
    # A cutover can leave an empty legacy table while the engine holds records
    # or a deletion ledger. Its envelopes still require the original host key.
    engine_root = Path(vault_path).parent.parent / "memory-engine"
    if engine_root.exists() and any(engine_root.glob("p*/*.sqlite3")):
        return True
    # A ledger-only restore or an enrolled checkpoint still needs the original
    # key even if both database files are absent. Never mint a new identity.
    if engine_root.exists() and any(engine_root.glob("p*/deletion-ledger*")):
        return True
    enrollment = Path(vault_path).parent.parent / "memory-guard"
    if enrollment.exists() and any(enrollment.glob("*.json")):
        return True
    if not Path(vault_path).exists():
        return False
    try:
        connection = sqlite3.connect(f"file:{vault_path}?mode=ro", uri=True, timeout=10)
        try:
            for table in ("memories", "context_snapshots", "skill_observations"):
                exists = connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
                ).fetchone()
                if exists and connection.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone():
                    return True
        finally:
            connection.close()
    except sqlite3.Error:
        return True  # unreadable vault: never assume it is safe to create a new key
    return False


def _fallback_key(path: Path | None = None, *, vault_path: Path | None = None) -> bytes:
    """Load or create the user-only local key used for the encrypted vault.

    A new key is created only when no encrypted rows exist yet; a missing key
    for an existing vault is an error instead of silently splitting the vault.
    """
    key_path = path or (paths.APP_DIR / "memory" / "master.key")
    key_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        key_path.parent.chmod(0o700)
    except OSError:
        pass
    try:
        value = key_path.read_bytes()
        if len(value) == 32:
            try:
                key_path.chmod(0o600)
            except OSError:
                pass
            return value
        if key_path.exists():
            raise MemoryError("the memory encryption key is invalid")
    except OSError:
        pass
    if _vault_has_rows(vault_path):
        raise MemoryError(
            "the memory encryption key is missing; refusing to create a new key for an existing vault"
        )
    value = secrets.token_bytes(32)
    try:
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        try:
            existing = key_path.read_bytes()
        except OSError as read_error:
            raise MemoryError("the memory encryption key is unavailable") from read_error
        if len(existing) == 32:
            return existing
        raise MemoryError("the memory encryption key is invalid") from exc
    try:
        os.write(descriptor, value)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return value


def _master_key(key: bytes | None = None, fallback_path: Path | None = None, *,
                vault_path: Path | None = None) -> bytes:
    value = key or _fallback_key(fallback_path, vault_path=vault_path)
    if len(value) != 32:
        raise MemoryError("memory encryption requires a 256-bit key")
    return value


def _target(scope: str, *, workspace: str = "", agent_id: str = "") -> str:
    return legacy_target(scope, workspace=workspace, agent_id=agent_id)


def _embed(model: str, host: str, inputs: list[str]) -> list[list[float]]:
    from .knowledge import embed_texts

    return embed_texts(model, host, inputs)


class MemoryVault(LegacyMemoryVault):
    def __new__(cls, path: Path | None = None, *, key: bytes | None = None,
                fallback_key_path: Path | None = None, workspace: str = "",
                agent_id: str = "primary", actor=None, scopes=None):
        database = Path(path) if path is not None else memory_database()
        app_dir = database.parent.parent
        if database.parent.name == "memory":
            if key is None and fallback_key_path is None:
                from .memory_adapter import ensure_memory_profile

                state = ensure_memory_profile(app_dir, PRODUCT_NAME)
            else:
                # Explicit-key callers retain the compatibility-vault contract.
                state = ownership_state(app_dir, PRODUCT_NAME)
            if state in ("package_authoritative", "legacy_retired"):
                from locus_memory.models import Actor

                from .memory_canonical import CanonicalMemoryVault

                return CanonicalMemoryVault(
                    app_dir, edition=PRODUCT_NAME.lower(), workspace=workspace,
                    agent_id=agent_id, actor=actor or Actor.USER, scopes=scopes,
                )
            if state in ("cutover_in_progress", "rollback_in_progress"):
                raise MemoryError("memory migration is in progress; resume it before opening the vault")
        return super().__new__(cls)

    def __init__(
        self,
        path: Path | None = None,
        *,
        key: bytes | None = None,
        fallback_key_path: Path | None = None,
        workspace: str = "",
        agent_id: str = "primary",
        actor=None,
        scopes=None,
    ) -> None:
        database = path or memory_database()
        super().__init__(
            database,
            key=_master_key(key, fallback_key_path, vault_path=database),
            embedder=_embed,
            write_guard=lambda: assert_legacy_writer(database.parent.parent, PRODUCT_NAME),
        )


__all__ = [
    "MemoryError", "MemoryVault", "format_memory_results", "memory_database",
    "VALID_SCOPES", "VALID_STATUSES", "VALID_KINDS", "CANDIDATE_TTL_SECONDS", "MAX_MEMORY_CONTENT",
]
