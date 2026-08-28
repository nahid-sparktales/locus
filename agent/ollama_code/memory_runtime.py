"""Shared encrypted-memory ownership used by knowledge and continuity APIs."""

import hashlib
from pathlib import Path

from .chat_service import ChatService
from .knowledge import KnowledgeError, KnowledgeStore
from .memory import MemoryError, MemoryVault


def memory_vault(workspace: str = "") -> MemoryVault:
    """Open the encrypted vault and migrate legacy plaintext workspace notes."""
    vault = MemoryVault()
    target = workspace.strip()
    if target:
        try:
            legacy = KnowledgeStore(target)
            for memory in legacy.list_memories():
                identifier = "legacy-" + hashlib.sha256(
                    f"{Path(target).resolve()}|{memory['id']}".encode()
                ).hexdigest()[:40]
                vault.save(
                    {**memory, "scope": "workspace", "status": "approved"},
                    identifier,
                    workspace=target,
                )
                legacy.delete_memory(memory["id"])
        except (KnowledgeError, MemoryError, OSError):
            # A failed migration leaves the legacy record intact and visible
            # through a later retry; it is never deleted before encryption.
            pass
    return vault


def memory_workspace(service: ChatService, workspace: str = "") -> str:
    return workspace.strip() or service.core.workspace_root or service.core.cwd


__all__ = ["memory_vault", "memory_workspace"]
