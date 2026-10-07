"""Host-owned, turn-bounded retrieval across canonical memory and workspace evidence.

Searches never grant access, run a judge model, or rebuild an index. Model-facing
reference text is ephemeral; persisted traces contain identifiers and diagnostics.
"""
from __future__ import annotations

import concurrent.futures
import copy
import hashlib
import json
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .capabilities import enabled as capability_enabled
from .knowledge import KnowledgeStore, format_search_results
from .memory_adapter import ensure_memory_adapter

ROUND_SECONDS = 5.0
EVIDENCE_BYTES = 24_000
MEMORY_BYTES = 12_000
WRAPPER_BYTES = 1_024
SOURCES = frozenset({"memory", "workspace", "documents"})
_POOL = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="locus-retrieval")
_SLOTS = threading.BoundedSemaphore(4)


def _submit(operation):
    if not _SLOTS.acquire(blocking=False):
        return None
    def run():
        try:
            return operation()
        finally:
            _SLOTS.release()
    return _POOL.submit(run)


@dataclass
class TurnAllowance:
    lock: threading.RLock = field(default_factory=threading.RLock)
    rounds: int = 0
    closed: bool = False

    def reserve(self) -> int | None:
        with self.lock:
            if self.closed or self.rounds >= 2:
                return None
            self.rounds += 1
            return self.rounds


def enabled_for(core, configuration=None, *, just_chat=False) -> bool:
    if just_chat or getattr(core, "identity_mode", False) or (configuration is None and getattr(core, "agent_mode", "work") == "ask"):
        return False
    if getattr(core, "memory_evaluation_disabled", False):
        return False
    try:
        if not KnowledgeStore(str(core.workspace_root or core.cwd)).settings().get("adaptive_rag_enabled", True):
            return False
        return ensure_memory_adapter(core).mode == "enabled"
    except (OSError, RuntimeError, ValueError, sqlite3.Error):
        return False


class AdaptiveRetrieval:
    def __init__(self, core, query: str, *, allowance: TurnAllowance | None = None,
                 store=None, adapter=None):
        self.core = core
        self.workspace = str(Path(core.workspace_root or core.cwd).resolve())
        self.agent_id = str(core.agent_id)
        self.turn_id = str(core._memory_turn_id)
        self.run_id = str(core.tool_ctx.memory_run_id or self.turn_id)
        self.session_id = str(getattr(getattr(core, "session", None), "session_id", ""))
        self.id = uuid.uuid4().hex
        self.query = query.strip()[:2_000]
        self.allowance = allowance or TurnAllowance()
        self.store = store or KnowledgeStore(self.workspace)
        self.adapter = adapter or ensure_memory_adapter(core)
        self._lock = threading.RLock()
        self._inflight = False
        self._queries: set[tuple] = set()
        self._files: list[dict] = []
        self._selected: list[dict] = []
        self._memory: dict = {}
        self._diagnostics: list[str] = []
        self._sources: list[str] = []
        self._omitted = 0
        self._packing_omitted = 0
        self._round = 0
        self._duration = 0.0
        self._bytes = 0
        self._emitted: set[str] = set()
        self._native_submissions: list = []
        self._pending_delivery_traces: list[dict] = []
        self.closed = False

    def stopped(self) -> bool:
        stop = getattr(self.core, "_should_stop_stream", None)
        return bool(self.closed or self.allowance.closed or str(self.core._memory_turn_id) != self.turn_id
                    or str(getattr(getattr(self.core, "session", None), "session_id", "")) != self.session_id
                    or str(self.core.tool_ctx.memory_run_id or self.turn_id) != self.run_id
                    or (stop and stop()))

    def allowed_sources(self, *, automatic=False) -> set[str]:
        core = self.core
        if (self.stopped() or getattr(core, "identity_mode", False) or core.agent_mode == "ask"
                or str(Path(core.workspace_root or core.cwd).resolve()) != self.workspace
                or str(core.agent_id) != self.agent_id):
            return set()
        try:
            config = self.store.settings()
        except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
            # An unavailable file index does not remove canonical memory access.
            config = {"adaptive_rag_enabled": True, "enabled": False, "documents_enabled": False}
            diagnostic = "index_unavailable:" + type(exc).__name__
            if diagnostic not in self._diagnostics:
                self._diagnostics.append(diagnostic)
        if not config.get("adaptive_rag_enabled", True):
            return set()
        policy = core.agent_configuration.memory_policy
        allowed = set()
        native = core.provider == "chatgpt" and core.chatgpt_parity_active(True)
        memory_enabled = policy.automatic_recall_enabled if automatic else policy.search_enabled
        if (memory_enabled and policy.recall_scopes(just_chat=False)
                and (not native or policy.native_codex_enabled)):
            allowed.add("memory")
        if (capability_enabled("workspace_knowledge") and config["enabled"]
                and core.agent_configuration.capability_policy.workspace_read):
            allowed.add("workspace")
            if config["documents_enabled"]:
                allowed.add("documents")
        return allowed

    def initial(self):
        self._retrieve(self.query, SOURCES, automatic=True)

    def tool(self, name: str, arguments: dict[str, Any]) -> str:
        query = arguments.get("query")
        if not isinstance(query, str) or not query.strip() or len(query) > 2_000:
            return "Error: query must contain 1–2000 characters."
        requested = arguments.get("sources", ["all"])
        if name == "search_memory":
            requested = ["memory"]
        elif name == "search_workspace_knowledge":
            requested = ["workspace", "documents"]
        if (not isinstance(requested, list) or not requested
                or any(not isinstance(value, str) or value not in SOURCES | {"all"} for value in requested)):
            return "Error: sources must be a list of memory, workspace, documents, or all."
        sources = SOURCES if "all" in requested else frozenset(requested)
        memory_scopes = arguments.get("scopes") if name == "search_memory" else None
        if memory_scopes is not None and (not isinstance(memory_scopes, list) or not memory_scopes
                or any(not isinstance(scope, str) or scope not in {"personal", "workspace", "agent"} for scope in memory_scopes)):
            return "Error: scopes must be a nonempty list of personal, workspace, or agent."
        key = self._key(query, sources, memory_scopes)
        with self._lock:
            if key in self._queries:
                return self._status("cached")
            if self._inflight:
                return self._status("search_in_progress")
        gap = arguments.get("missing_information")
        if not isinstance(gap, str) or not gap.strip() or len(gap) > 1_000:
            return "Error: name the missing_information (1–1000 characters) and a focused query for the one follow-up."
        self._retrieve(query.strip(), sources, automatic=False, memory_scopes=memory_scopes)
        return self._status("available")

    @staticmethod
    def _key(query, sources, memory_scopes=None):
        return (" ".join(query.casefold().split()), tuple(sorted(sources)),
                tuple(sorted(set(memory_scopes))) if memory_scopes is not None else None)

    def _retrieve(self, query, sources, *, automatic, memory_scopes=None):
        key = self._key(query, sources, memory_scopes)
        with self._lock:
            if key in self._queries or self._inflight or self.stopped():
                return
            allowed = self.allowed_sources(automatic=automatic) & set(sources)
            if not allowed and not automatic:
                self._diagnostics = ["sources_disabled"]
                return
            number = self.allowance.reserve()
            if number is None:
                self._diagnostics = list(dict.fromkeys([*self._diagnostics, "follow_up_exhausted"]))
                return
            self._queries.add(key)
            self._inflight = True
            self._round = number
            self._sources = sorted(allowed)
            self._diagnostics = [] if allowed else ["sources_disabled"]
        started = time.monotonic()
        deadline = started + ROUND_SECONDS
        policy = self.core.agent_configuration.memory_policy
        refined = query if automatic else (self.query[:975] + "\n" + query[:1_000])
        jobs = {}
        lexical = []
        lexical_lock = threading.Lock()

        def retain_keywords(rows):
            with lexical_lock:
                lexical[:] = rows[:24]

        if "memory" in allowed:
            jobs["memory"] = _submit(lambda: self.adapter.prepare_retrieval(
                self.core, refined, policy, agent_id=self.agent_id, max_bytes=MEMORY_BYTES,
                deadline=deadline, should_stop=self.stopped, automatic=automatic, scopes=memory_scopes))
        file_sources = tuple(sorted(allowed - {"memory"}))
        if file_sources:
            jobs["files"] = _submit(lambda: self.store.search_with_diagnostics(
                query, files_only=True, sources=file_sources, allow_reindex=False,
                deadline=deadline - .05, should_stop=self.stopped, pack=False, on_lexical=retain_keywords))
        try:
            for name, future in jobs.items():
                if future is None:
                    self._diagnostics.append(name + "_busy")
                    continue
                try:
                    value = future.result(timeout=max(0, deadline - time.monotonic()))
                except concurrent.futures.TimeoutError:
                    self._diagnostics.append(name + "_deadline")
                    if name != "files":
                        continue
                    with lexical_lock:
                        value = {"results": list(lexical), "diagnostics": {"fallbacks": ["keyword_fallback"]}}
                except Exception as exc:
                    self._diagnostics.append(name + "_unavailable:" + type(exc).__name__)
                    continue
                if self.stopped():
                    break
                if name == "memory":
                    if "memory" in self.allowed_sources(automatic=automatic):
                        self.adapter.install_retrieval(self.core, value, policy, agent_id=self.agent_id, automatic=automatic)
                        self._diagnostics.extend(value.diagnostics)
                else:
                    rows = value.get("results", [])
                    merged = {item["id"]: item for item in [*self._files, *rows]}
                    self._files = list(merged.values())[:48]
                    info = value.get("diagnostics", {})
                    self._diagnostics.extend(str(item) for item in info.get("fallbacks", []))
                    self._diagnostics.extend(str(item) for item in info.get("partial_reasons", []))
                    if info.get("embedding_pending", 0):
                        self._diagnostics.append("embeddings_pending")
                    if info.get("index_not_ready"):
                        self._diagnostics.append("index_not_ready")
            if self.stopped():
                self._files = []
                self._diagnostics.append("cancelled")
        finally:
            with self._lock:
                self._duration = round((time.monotonic() - started) * 1000, 2)
                self._inflight = False
        self.reference(revalidate_memory=False, deadline=deadline)
        self._duration = round((time.monotonic() - started) * 1000, 2)
        if time.monotonic() >= deadline and "deadline_exceeded" not in self._diagnostics:
            self._diagnostics.append("deadline_exceeded")
        self.trace("retrieved")

    def reference(self, *, revalidate_memory=True, deadline=None) -> str:
        """Fresh workspace context, separate from the intact memory receipt layer."""
        with self._lock:
            # Final packet revalidation uses the mode in which it was compiled.
            self._memory = self.adapter.retrieval_details(self.core, revalidate=revalidate_memory)
            allowed = self.allowed_sources(automatic=getattr(self.core, "_memory_retrieval_automatic", True))
            if not allowed:
                self._omitted += len(self._files)
                self._files = []
                self._selected = []
                self._bytes = 0
                return ""
            memory_text = str(getattr(self.core, "memory_context", "") or "")
            memory_bytes = len(memory_text.encode("utf-8"))
            eligible = [item for item in self._files if
                        ("workspace" if item.get("format") == "text" else "documents") in allowed]
            try:
                valid = self.store.revalidate_results(eligible, deadline=deadline if deadline is not None else time.monotonic() + ROUND_SECONDS,
                                                      should_stop=self.stopped)
            except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
                valid = []
                self._diagnostics.append("index_unavailable:" + type(exc).__name__)
            current_sources = self.allowed_sources(automatic=getattr(self.core, "_memory_retrieval_automatic", True))
            valid = [item for item in valid if
                     ("workspace" if item.get("format") == "text" else "documents") in current_sources]
            self._omitted += len(self._files) - len(valid)
            self._files = valid
            self._selected = self.store.pack_results(valid, limit=8,
                byte_budget=max(0, EVIDENCE_BYTES - memory_bytes - WRAPPER_BYTES))
            self._packing_omitted = len(valid) - len(self._selected)
            text = "\n\n".join(
                f"Source {item['id']} ({'workspace' if item.get('format') == 'text' else 'documents'}), "
                f"SHA-256 {item['content_hash']}\n" + format_search_results([item])
                for item in self._selected) if self._selected else "No eligible workspace evidence was retrieved."
            state = (f"Adaptive retrieval: {self.allowance.rounds}/2 rounds used. "
                     + ("One focused follow-up is available through search_context. " if self.allowance.rounds < 2
                        else "No retrieval follow-up remains for this turn. ")
                     + "Search completion or ranking does not establish answer sufficiency. Preserve source versions and identify conflicts, unsupported claims, and remaining gaps.\n")
            if self._diagnostics:
                state += "Availability: " + ", ".join(sorted(set(self._diagnostics))) + ".\n"
            result = state + text
            self._bytes = len(result.encode("utf-8")) + memory_bytes + (2 if memory_bytes else 0)
            if self._bytes + 512 > EVIDENCE_BYTES:
                self._packing_omitted += len(self._selected)
                self._selected = []
                result = state + "Workspace evidence omitted to preserve the shared evidence budget."
                self._bytes = len(result.encode()) + memory_bytes + (2 if memory_bytes else 0)
            return result

    def snapshot(self) -> dict:
        """Evaluation view of the current permitted evidence; never persisted wholesale."""
        self.reference()
        return copy.deepcopy({"results": self._selected, "memory": self._memory,
            "diagnostics": sorted(set(self._diagnostics)), "sources": self._sources,
            "rounds": self.allowance.rounds, "packed_bytes": self._bytes})

    def _status(self, status):
        self.reference()
        return json.dumps({"retrieval": status, "rounds": self.allowance.rounds,
            "remaining_follow_ups": max(0, 2 - self.allowance.rounds),
            "evidence": "The current, revalidated evidence is supplied as request-only reference data.",
            "fallbacks": sorted(set(self._diagnostics))})

    def native_tool_result(self, status: str) -> str:
        """Native helpers consume tool output inside their own model loop.

        Serialize fresh evidence only at that delivery boundary, after the normal
        tool observation was recorded without source bodies.
        """
        if status.startswith("Error:"):
            return status
        submission = self.adapter.begin_submission(self.core)
        reference = self.reference(revalidate_memory=False)
        self.adapter.finish_submission(submission, state="uncertain")
        if submission:
            self._native_submissions.append(submission)
        self.delivery("uncertain")
        return status + "\n\nUntrusted evidence snapshot; preserve source versions and citations.\n" + "\n\n".join(
            text for text in (str(getattr(self.core, "memory_context", "") or ""), reference) if text)

    def delivery(self, phase):
        if phase == "submitted":
            for submission in self._native_submissions:
                self.adapter.finish_submission(submission, state=phase)
            self._native_submissions.clear()
            # A native turn can consume a follow-up within one provider call.
            # Confirm each immutable snapshot, including the initial packet.
            for trace in self._pending_delivery_traces:
                self._emit_trace({**trace, "id": trace["id"].rsplit(":", 1)[0] + ":submitted", "phase": phase})
            self._pending_delivery_traces.clear()
        else:
            trace = self.trace(phase)
            if phase == "uncertain":
                self._pending_delivery_traces.append(copy.deepcopy(trace))

    def trace(self, phase):
        selected = [{"kind": "memory", "id": item["id"], "revision": item["revision"]}
                    for item in self._memory.get("items", [])]
        selected.extend({"kind": "workspace" if item.get("format") == "text" else "documents",
            "id": item["id"], "path": item["path"], "content_hash": item["content_hash"],
            "locator": {key: value for key, value in item["locator"].items()
                        if key in {"kind", "line_start", "line_end", "page", "paragraph_start", "paragraph_end", "sheet", "cell_range"}}}
                        for item in self._selected)
        trace = {"id": f"{self.id}:{self._round}:{phase}", "turn_id": self.turn_id,
            "agent_id": self.agent_id, "round": self._round, "phase": phase, "sources": self._sources,
            "selected": selected, "omitted": [{"reason": "revoked_or_stale", "count": self._omitted},
                {"reason": "packing_or_limit", "count": self._packing_omitted}],
            "fallbacks": sorted(set(self._diagnostics)), "duration_ms": self._duration,
            "packed_bytes": self._bytes, "unavailable_items": self._omitted}
        self._emit_trace(trace)
        return trace

    def _emit_trace(self, trace):
        fingerprint = hashlib.sha256(json.dumps(trace, sort_keys=True).encode()).hexdigest()
        if fingerprint not in self._emitted:
            self._emitted.add(fingerprint)
            self.core._emit({"type": "retrieval_trace", "run_id": self.run_id, "trace": trace})


def begin_turn(core, query: str, *, allow_tools=True):
    previous = getattr(core, "adaptive_retrieval", None)
    if previous:
        previous.closed = True
        from .helper_retrieval import release_helpers
        release_helpers(previous)
        if not getattr(core, "adaptive_retrieval_parent", None):
            previous.allowance.closed = True
    core.adaptive_retrieval = None
    core.tool_ctx.search_context = None
    core.tool_registry.adaptive_retrieval_enabled = False
    if not allow_tools or not enabled_for(core):
        return
    parent_core = getattr(core, "adaptive_retrieval_parent", None)
    parent = getattr(parent_core, "adaptive_retrieval", None)
    from .context_preservation import retrieval_query
    coordinator = AdaptiveRetrieval(core, retrieval_query(core, query), allowance=parent.allowance if parent else None)
    coordinator.adapter.release_context(core)
    core.memory_context = ""
    core.adaptive_retrieval = coordinator
    core.tool_ctx.search_context = coordinator.tool
    core.tool_registry.adaptive_retrieval_enabled = True
    if parent:
        # Helpers share the turn allowance, never the root's personal/agent packet.
        coordinator._files = list(parent._files) if coordinator.workspace == parent.workspace else []
        coordinator._round = parent._round
        coordinator._sources = [source for source in parent._sources if source != "memory"]
    else:
        coordinator.initial()
