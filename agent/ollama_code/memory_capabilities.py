"""Host-owned capabilities supplied consistently to every memory entry point."""
from __future__ import annotations

from pathlib import Path

from locus_memory.crypto import KeyProvider
from locus_memory.host import HostCapabilities


def memory_capabilities(app_dir: Path | str, edition: str, keys: KeyProvider) -> HostCapabilities:
    from .memory_guard import build_memory_guard

    from .config import load_config
    from .memory_embeddings import PROVIDER_NAME, build_memory_embedding_provider

    provider = build_memory_embedding_provider(load_config())
    return HostCapabilities(ledger_mirror=build_memory_guard(Path(app_dir), edition, keys),
                            providers={PROVIDER_NAME: provider} if provider is not None else {})
