"""Locus profile and identity bindings for the package's canonical vault."""
from __future__ import annotations

from pathlib import Path

from locus_memory.compat.canonical_vault import CanonicalMemoryVault as PackageCanonicalMemoryVault
from locus_memory.models import Actor, PartitionRef


class CanonicalMemoryVault(PackageCanonicalMemoryVault):
    def __init__(self, app_dir: Path | str, *, edition: str = "locus", workspace: str = "",
                 agent_id: str = "primary", actor: Actor = Actor.USER,
                 scopes: tuple[str, ...] | list[str] | None = None) -> None:
        from .memory_adapter import LocusKeyProvider
        from .memory_capabilities import memory_capabilities
        from .memory_ownership import ownership_state

        ownership_state(app_dir, edition)
        keys = LocusKeyProvider(Path(app_dir))

        super().__init__(
            Path(app_dir) / "memory-engine", keys,
            partition=PartitionRef(edition.lower(), "default"), workspace=workspace,
            agent_id=agent_id, actor=actor, scopes=scopes,
            principal="locus-local-user", host_name="locus",
            host=memory_capabilities(app_dir, edition, keys),
        )
