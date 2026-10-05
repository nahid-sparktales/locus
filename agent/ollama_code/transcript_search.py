"""Bind package-owned saved-chat search to Locus session capabilities."""
from __future__ import annotations

from pathlib import Path

from locus_memory.errors import MemoryEngineError
from locus_memory.history.transcript_cache import EncryptedTranscriptCache
from locus_memory.history.transcript_search import (
    BACKGROUND_BUILD_BYTES,
    TranscriptLimits,
    TranscriptSearchError,
    TranscriptSource,
)
from locus_memory.history.transcript_search import (
    TranscriptIndex as PackageTranscriptIndex,
)
from locus_memory.models import PartitionRef

from . import PRODUCT_NAME
from .memory_adapter import LocusKeyProvider
from .memory_ownership import profile_lease
from .paths import APP_DIR
from .sessions import (
    MAX_SESSION_BYTES,
    MAX_SESSION_LINE_BYTES,
    MAX_SESSION_MESSAGES,
    SessionMeta,
    SessionStore,
    strip_prompt_decoration,
)

DEFAULT_PATH = APP_DIR / "transcript-index.sqlite3"


class TranscriptIndex(PackageTranscriptIndex):
    def __init__(self, path: Path | None = None) -> None:
        target = Path(path) if path is not None else DEFAULT_PATH
        if target.exists() and not EncryptedTranscriptCache.is_legacy(target) and not (APP_DIR / "memory/master.key").exists():
            raise TranscriptSearchError("saved-chat encryption key is unavailable")
        try:
            super().__init__(
                target,
                TranscriptSource(SessionStore.list_sessions, SessionMeta.all, strip_prompt_decoration),
                TranscriptLimits(MAX_SESSION_BYTES, MAX_SESSION_LINE_BYTES, MAX_SESSION_MESSAGES),
                keys=LocusKeyProvider(APP_DIR), partition_id=PartitionRef(PRODUCT_NAME.lower(), "default").partition_id,
                upgrade_lease=lambda: profile_lease(APP_DIR, exclusive=True),
                background_build_bytes=BACKGROUND_BUILD_BYTES,
            )
            self._profile_lease = profile_lease(APP_DIR)
            self._profile_lease.__enter__()
        except (MemoryEngineError, OSError) as exc:
            raise TranscriptSearchError("saved-chat search is unavailable; unlock memory or finish the exclusive cache upgrade") from exc


    def close(self) -> None:
        try:
            super().close()
        finally:
            lease = getattr(self, "_profile_lease", None)
            self._profile_lease = None
            if lease is not None:
                lease.__exit__(None, None, None)


def prepare_transcript_cache() -> None:
    """Upgrade before ChatService takes its lifetime shared profile lease."""
    if DEFAULT_PATH.exists() and EncryptedTranscriptCache.is_legacy(DEFAULT_PATH):
        index = TranscriptIndex()
        index.close()


__all__ = ["TranscriptIndex", "TranscriptSearchError"]
