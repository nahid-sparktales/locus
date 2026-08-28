"""Shared runtime state for session routes and task compatibility handlers."""

import threading

from .runstore import ACTIVE_NONRECOVERABLE_STATES, RunStore
from .transcript_search import TranscriptIndex

_TRANSCRIPT_INDEX: TranscriptIndex | None = None
_TRANSCRIPT_INDEX_LOCK = threading.Lock()


def session_has_active_run(run_store: RunStore, session_id: str) -> bool:
    active_states = ACTIVE_NONRECOVERABLE_STATES | {"waiting_dispatch_approval"}
    return any(
        str(run.get("state") or "") in active_states
        for run in run_store.list_runs(session_id=session_id, limit=20)
    )


def transcript_index() -> TranscriptIndex:
    """Return the process-wide index, rebuilding if the data home moved."""
    global _TRANSCRIPT_INDEX
    from . import transcript_search as transcript_search_mod

    with _TRANSCRIPT_INDEX_LOCK:
        if (
            _TRANSCRIPT_INDEX is None
            or _TRANSCRIPT_INDEX.path != transcript_search_mod.DEFAULT_PATH
        ):
            _TRANSCRIPT_INDEX = TranscriptIndex()
        return _TRANSCRIPT_INDEX


__all__ = ["session_has_active_run", "transcript_index"]
