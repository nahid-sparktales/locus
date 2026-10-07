"""Independent retrieval packets for legacy Solo workers sharing a turn budget."""
from __future__ import annotations

import copy
import hashlib
from types import SimpleNamespace

from .adaptive_retrieval import AdaptiveRetrieval

RETRIEVAL_TOOLS = frozenset({"search_context", "search_memory", "search_workspace_knowledge"})


def helper_identity(run_id: str, worker_id: str) -> str:
    """A model-selected task label must never become a saved-agent scope grant."""
    digest = hashlib.sha256((str(run_id) + "\0" + str(worker_id)).encode()).hexdigest()
    return "solo:" + digest


class _HelperCore:
    # Permission and route properties are read live, while receipt/prompt state
    # belongs exclusively to this object. Never inherit root _memory_* fields.
    _LIVE = frozenset({"workspace_root", "cwd", "provider", "agent_mode", "identity_mode",
                      "agent_configuration", "memory_evaluation_disabled", "chatgpt_parity_active"})

    def __init__(self, root, parent, worker_id, event_context):
        self.root, self.parent = root, parent
        self.agent_id = helper_identity(parent.run_id, worker_id)
        self._memory_turn_id = parent.turn_id + ":" + self.agent_id
        self.session = SimpleNamespace(session_id=parent.session_id)
        self.tool_ctx = SimpleNamespace(memory_run_id=parent.run_id)
        self.memory_adapter = parent.adapter
        self.memory_context = self.continuity_context = ""
        self.event_context = dict(event_context)

    def __getattr__(self, name):
        if name in self._LIVE:
            return getattr(self.root, name)
        raise AttributeError(name)

    def _should_stop_stream(self):
        return self.root.adaptive_retrieval is not self.parent or self.parent.stopped()

    def reset_system_message(self):
        pass  # This packet is delivered to the worker, never to root messages.

    def _emit(self, event):
        self.root._emit({**event, **self.event_context, "run_id": self.parent.run_id})


def coordinator_for(root, event_context):
    parent = getattr(root, "adaptive_retrieval", None)
    worker_id = str((event_context or {}).get("agent_id") or "")
    if parent is None or not worker_id or parent.stopped():
        return None
    with parent._lock:
        helpers = getattr(parent, "_legacy_helpers", None)
        if helpers is None:
            helpers = parent._legacy_helpers = {}
        if worker_id not in helpers:
            core = _HelperCore(root, parent, worker_id, event_context)
            coordinator = AdaptiveRetrieval(core, parent.query, allowance=parent.allowance,
                                            store=parent.store, adapter=parent.adapter)
            coordinator._files = copy.deepcopy(parent._files)
            coordinator._round = parent._round
            coordinator._sources = [source for source in parent._sources if source != "memory"]
            helpers[worker_id] = coordinator
        return helpers[worker_id]


def execution_context(root, name, event_context, *, track_active):
    """A per-call context avoids mutating the root callback during parallel tools."""
    context = root.tool_ctx
    if track_active or name not in RETRIEVAL_TOOLS or getattr(root, "adaptive_retrieval", None) is None:
        return context
    context = copy.copy(context)
    coordinator = coordinator_for(root, event_context)
    context.search_context = coordinator.tool if coordinator is not None else (
        lambda *_: "Error: the delegated retrieval context is unavailable.")
    return context


def deliver(root, name, status, event_context):
    """Add fresh evidence only after the ordinary tool observation was journaled.

    Legacy provider loops offer no reliable per-snapshot acknowledgement. Their
    memory receipts deliberately remain uncertain, rather than inventing success.
    """
    if (name not in RETRIEVAL_TOOLS or getattr(root, "adaptive_retrieval", None) is None
            or status.startswith(("Error:", "Permission denied"))):
        return status
    coordinator = coordinator_for(root, event_context)
    if coordinator is None:
        return "Error: the delegated retrieval context is no longer active."
    with coordinator._lock:
        if not coordinator.allowed_sources():
            coordinator.adapter.release_context(coordinator.core)
            coordinator.core.memory_context = ""
            coordinator.reference()
            return status
        return coordinator.native_tool_result(status)


def release_helpers(parent):
    with parent._lock:
        helpers = getattr(parent, "_legacy_helpers", {})
        parent._legacy_helpers = {}
    for coordinator in helpers.values():
        coordinator.closed = True
        coordinator.adapter.release_context(coordinator.core)
        coordinator.core.memory_context = ""


class WorkerDelivery:
    """Provider seams for ephemeral classic context and immediate native tools."""

    def __init__(self, root, decider):
        self.root, self.decider = root, decider

    def enabled(self):
        return getattr(self.root, "adaptive_retrieval", None) is not None

    def execute(self, name, arguments, call_id, event_context, execution_lock, *, immediate):
        return self.root.run_solo_worker_tool(name, arguments, call_id, self.decider,
            event_context=event_context, execution_lock=execution_lock,
            defer_retrieval_delivery=not immediate)

    def before_request(self, event_context):
        if not self.enabled():
            return ""
        coordinator = coordinator_for(self.root, event_context)
        if coordinator is not None:
            with coordinator._lock:
                # A later successful request cannot confirm an earlier failed
                # attempt. Its stored uncertain receipt remains unchanged.
                coordinator._native_submissions.clear()
                coordinator._pending_delivery_traces.clear()
        return deliver(self.root, "search_context", "Current delegated retrieval evidence.", event_context)

    def after_request(self, event_context):
        coordinator = coordinator_for(self.root, event_context)
        if coordinator is not None:
            with coordinator._lock:
                coordinator.delivery("submitted")
