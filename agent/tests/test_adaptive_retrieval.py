"""A turn has one shared, bounded refinement and only current permitted evidence."""
import hashlib
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from locus_memory.models import RememberRequest, Scope

from ollama_code import adaptive_retrieval as rag
from ollama_code.knowledge import KnowledgeStore
from ollama_code.memory_adapter import MemoryAdapter
from ollama_code.memory_policy import MemoryPolicy


@pytest.fixture
def retrieval(tmp_path, isolated_app_dir, monkeypatch):
    from ollama_code import knowledge_embeddings
    monkeypatch.setattr(knowledge_embeddings, "schedule_embeddings", lambda _: None)
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "deploy.py").write_text('def canary_release():\n    return "violet"\n')
    store = KnowledgeStore(str(root))
    store.reindex()
    store.configure(documents_enabled=True)
    raw = b"opaque canary manual"
    (root / "manual.pdf").write_bytes(raw)
    store.index_extracted_document("manual.pdf", hashlib.sha256(raw).hexdigest(),
        [{"text": "canary release requires signed packages", "locator": {"kind": "pdf", "page": 2},
          "method": "embedded"}], "pdf")
    policy = MemoryPolicy.parse({"auto_save_enabled": False, "proposals_enabled": False})
    events = []
    core = SimpleNamespace(workspace_root=str(root), cwd=str(root), agent_id="primary", agent_mode="work",
        provider="ollama", identity_mode=False, memory_context="", continuity_context="",
        agent_configuration=SimpleNamespace(memory_policy=policy, capability_policy=SimpleNamespace(workspace_read=True)),
        tool_ctx=SimpleNamespace(memory_run_id="run", search_context=None),
        session=SimpleNamespace(session_id="session"), _memory_turn_id="turn", _output_run_id="run",
        _emit=events.append, _should_stop_stream=lambda: False, reset_system_message=Mock(),
        chatgpt_parity_active=lambda _: False, tool_registry=SimpleNamespace(adaptive_retrieval_enabled=False))
    adapter = MemoryAdapter(app_dir=isolated_app_dir, edition="locus", mode="enabled")
    core.memory_adapter = adapter
    access = adapter.access(core, "user", agent_id="primary")
    record = adapter.engine.remember(access, RememberRequest(content="Canary release uses violet deployment.",
        title="Canary release", scope=Scope.of(project=next(iter(access.grants.projects))))).record
    coordinator = rag.AdaptiveRetrieval(core, "canary release", store=store, adapter=adapter)
    core.adaptive_retrieval = coordinator
    yield coordinator, core, store, adapter, record, events
    adapter.close()


def followup(coordinator, query="signed packages", sources=None):
    return json.loads(coordinator.tool("search_context", {"query": query,
        "missing_information": "Need exact deployment evidence", "sources": sources or ["all"]}))


def test_initial_combines_canonical_memory_code_documents_and_labels(retrieval):
    co, core, _, _, record, events = retrieval
    co.initial()
    state = co.snapshot()
    assert state["rounds"] == 1
    assert state["memory"]["items"][0]["id"] == record.id
    assert {row["path"] for row in state["results"]} == {"deploy.py", "manual.pdf"}
    assert all(row["content_hash"] and row["locator"] for row in state["results"])
    assert "violet" in core.memory_context and "manual.pdf" in co.reference()
    assert all(row["content_hash"] in co.reference() and row["id"] in co.reference() for row in state["results"])
    assert state["packed_bytes"] <= rag.EVIDENCE_BYTES
    assert events[-1]["trace"]["phase"] == "retrieved"


def test_refinement_replaces_memory_packet_and_merges_file_evidence(retrieval, monkeypatch):
    co, core, _, adapter, _, _ = retrieval
    queries = []
    original = adapter.prepare_retrieval
    def prepare(*args, **kwargs):
        queries.append(args[1])
        return original(*args, **kwargs)
    monkeypatch.setattr(adapter, "prepare_retrieval", prepare)
    co.initial()
    receipt = co.snapshot()["memory"]["receipt_id"]
    followup(co, "canary violet")
    assert queries == ["canary release", "canary release\ncanary violet"]
    assert co.snapshot()["memory"]["receipt_id"] != receipt
    assert id(core) in adapter._pending, co.snapshot()
    assert core.memory_context == adapter._pending[id(core)][2].text
    assert len({row["id"] for row in co.snapshot()["results"]}) == len(co.snapshot()["results"])
    assert {row["path"] for row in co.snapshot()["results"]} == {"deploy.py", "manual.pdf"}


@pytest.mark.parametrize("alias,sources", [("search_memory", ["memory"]),
    ("search_workspace_knowledge", ["documents", "workspace"]), ("search_context", ["documents"])])
def test_aliases_use_same_followup_and_never_reset(retrieval, alias, sources):
    co, *_ = retrieval
    co.initial()
    args = {"query": "signed packages", "missing_information": "missing procedure", "sources": ["documents"]}
    assert json.loads(co.tool(alias, args))["rounds"] == 2
    assert co.snapshot()["sources"] == sources
    assert json.loads(co.tool(alias, args))["retrieval"] == "cached"
    for _ in range(3):
        assert "follow_up_exhausted" in followup(co, "another query")["fallbacks"]
        assert co.allowance.rounds == 2


@pytest.mark.parametrize("arguments", [{"query": "x"}, {"query": ""}, {"query": "x", "sources": [{}]},
    {"query": "x", "sources": "all"}, {"query": "x", "missing_information": "x" * 1001},
    {"query": "x" * 2001, "missing_information": "gap"}])
def test_invalid_refinement_never_spends_allowance(retrieval, arguments):
    co, *_ = retrieval
    co.initial()
    assert co.tool("search_context", arguments).startswith("Error:")
    assert co.allowance.rounds == 1


def test_concurrent_refinements_and_duplicate_retries_run_once(retrieval, monkeypatch):
    co, _, store, *_ = retrieval
    co.initial()
    started, release = threading.Event(), threading.Event()
    original = store.search_with_diagnostics
    def search(*args, **kwargs):
        started.set()
        assert release.wait(2)
        return original(*args, **kwargs)
    monkeypatch.setattr(store, "search_with_diagnostics", search)
    with ThreadPoolExecutor(max_workers=2) as pool:
        active = pool.submit(followup, co, "procedure", ["workspace"])
        assert started.wait(1)
        duplicate = followup(co, "procedure", ["workspace"])
        other = followup(co, "different", ["workspace"])
        assert duplicate["retrieval"] == "cached"
        assert other["retrieval"] == "search_in_progress"
        release.set()
        active.result()
    assert co.allowance.rounds == 2


def test_delegates_share_root_allowance_but_not_root_memory(retrieval):
    co, core, store, adapter, *_ = retrieval
    co.initial()
    child = SimpleNamespace(**vars(core))
    child.agent_id = "helper"
    child._memory_turn_id = "helper-turn"
    child.memory_context = ""
    child.adaptive_retrieval = None
    child.adaptive_retrieval_parent = core
    child.tool_ctx = SimpleNamespace(memory_run_id="helper-run", search_context=None)
    child.tool_registry = SimpleNamespace(adaptive_retrieval_enabled=False)
    rag.begin_turn(child, "check canary")
    helper = child.adaptive_retrieval
    assert helper.allowance is co.allowance and child.memory_context == ""
    assert helper.snapshot()["memory"]["items"] == []
    followup(helper, sources=["workspace"])
    assert co.allowance.rounds == 2
    assert "follow_up_exhausted" in followup(co)["fallbacks"]
    assert adapter._pending[id(core)][2].text == core.memory_context


def test_failure_consumes_followup_but_keeps_previous_evidence(retrieval, monkeypatch):
    co, _, store, *_ = retrieval
    co.initial()
    monkeypatch.setattr(store, "search_with_diagnostics", Mock(side_effect=RuntimeError("provider unavailable")))
    result = followup(co, sources=["workspace"])
    assert "files_unavailable:RuntimeError" in result["fallbacks"]
    assert co.snapshot()["results"]
    assert "follow_up_exhausted" in followup(co, "retry")["fallbacks"]


def test_round_deadline_returns_already_available_keywords_without_retry(retrieval, monkeypatch):
    co, _, store, *_ = retrieval
    rows = store.search_with_diagnostics("canary", files_only=True, pack=False)["results"]
    release, ended = threading.Event(), threading.Event()
    def slow(*args, **kwargs):
        kwargs["on_lexical"](rows)
        assert kwargs["allow_reindex"] is False
        try:
            release.wait(2)
            return {"results": [], "diagnostics": {}}
        finally:
            ended.set()
    monkeypatch.setattr(rag, "ROUND_SECONDS", .1)
    monkeypatch.setattr(store, "search_with_diagnostics", slow)
    start = time.monotonic()
    try:
        co.initial()
        assert time.monotonic() - start < .8
        assert "files_deadline" in co.snapshot()["diagnostics"]
        assert "keyword_fallback" in co.snapshot()["diagnostics"]
        assert co.snapshot()["results"]
    finally:
        release.set()
        assert ended.wait(2)


def test_shared_absolute_deadline_passed_to_both_sources(retrieval, monkeypatch):
    co, _, store, adapter, *_ = retrieval
    deadlines = {}
    memory, files = adapter.prepare_retrieval, store.search_with_diagnostics
    def prepare(*args, **kwargs):
        deadlines["memory"] = kwargs["deadline"]
        return memory(*args, **kwargs)
    def search(*args, **kwargs):
        deadlines["files"] = kwargs["deadline"]
        return files(*args, **kwargs)
    monkeypatch.setattr(adapter, "prepare_retrieval", prepare)
    monkeypatch.setattr(store, "search_with_diagnostics", search)
    co.initial()
    assert deadlines["memory"] - deadlines["files"] == pytest.approx(.05)


@pytest.mark.parametrize("change", ["read", "documents", "delete", "document_hash", "workspace", "session", "turn", "identity"])
def test_final_delivery_drops_revoked_or_stale_evidence(retrieval, change):
    co, core, store, *_ = retrieval
    co.initial()
    if change == "read":
        core.agent_configuration.capability_policy.workspace_read = False
    elif change == "documents":
        store.configure(documents_enabled=False)
    elif change == "delete":
        (store.root / "deploy.py").unlink()
    elif change == "document_hash":
        (store.root / "manual.pdf").write_bytes(b"changed")
    elif change == "workspace":
        core.workspace_root += "other"
    elif change == "session":
        core.session.session_id = "other"
    elif change == "turn":
        core._memory_turn_id = "other"
    else:
        core.identity_mode = True
    paths = {row["path"] for row in co.snapshot()["results"]}
    if change in {"read", "workspace", "session", "turn", "identity"}:
        assert paths == set()
    elif change == "delete":
        assert paths == {"manual.pdf"}
    else:
        assert paths == {"deploy.py"}


def test_cancelled_late_result_cannot_install_memory_or_files(retrieval, monkeypatch):
    co, core, _, adapter, *_ = retrieval
    original = adapter.prepare_retrieval
    def cancel(*args, **kwargs):
        result = original(*args, **kwargs)
        core._should_stop_stream = lambda: True
        return result
    monkeypatch.setattr(adapter, "prepare_retrieval", cancel)
    co.initial()
    assert core.memory_context == "" and co.snapshot()["results"] == []
    assert "cancelled" in co.snapshot()["diagnostics"]
    assert co.allowance.rounds == 1


def test_manual_memory_followup_when_automatic_recall_disabled(retrieval):
    co, core, _, _, record, _ = retrieval
    core.agent_configuration.memory_policy = replace(core.agent_configuration.memory_policy, recall_enabled=False)
    co.initial()
    assert not core.memory_context
    followup(co, "canary", ["memory"])
    assert co.snapshot()["memory"]["items"], co.snapshot()
    assert co.snapshot()["memory"]["items"][0]["id"] == record.id
    assert core.memory_context


def test_automatic_memory_remains_when_explicit_search_disabled(retrieval):
    co, core, *_ = retrieval
    core.agent_configuration.memory_policy = replace(core.agent_configuration.memory_policy, search_enabled=False)
    co.initial()
    assert core.memory_context and co.snapshot()["memory"]["items"]
    assert "sources_disabled" in followup(co, sources=["memory"])["fallbacks"]
    assert co.allowance.rounds == 1


def test_native_memory_optout_keeps_workspace_lane(retrieval):
    co, core, *_ = retrieval
    core.provider = "chatgpt"
    core.chatgpt_parity_active = lambda _: True
    core.agent_configuration.memory_policy = replace(core.agent_configuration.memory_policy, native_codex_enabled=False)
    co.initial()
    assert not core.memory_context
    assert co.snapshot()["sources"] == ["documents", "workspace"]
    assert co.snapshot()["results"]


def test_feature_off_restores_legacy_callbacks_without_changing_saving(retrieval):
    co, core, store, *_ = retrieval
    co.initial()
    policy = core.agent_configuration.memory_policy
    store.configure(adaptive_rag_enabled=False)
    rag.begin_turn(core, "canary")
    assert core.adaptive_retrieval is None and core.tool_ctx.search_context is None
    assert core.tool_registry.adaptive_retrieval_enabled is False
    assert core.agent_configuration.memory_policy == policy


def test_cold_index_is_distinct_from_complete_empty_results(retrieval, monkeypatch):
    co, _, store, *_ = retrieval
    with store._connect() as connection:
        connection.execute("UPDATE settings SET last_indexed=NULL")
    monkeypatch.setattr(store, "reindex", lambda: pytest.fail("No hot-path index build"))
    co.initial()
    assert "index_not_ready" in co.snapshot()["diagnostics"]
    assert not co.snapshot()["results"] and co.snapshot()["memory"]["items"]


def test_persisted_trace_has_ids_and_versions_but_no_source_text(retrieval):
    co, _, _, _, _, events = retrieval
    co.initial()
    co._selected[0]["locator"]["heading"] = "sensitive source body"
    co.trace("submitted")
    serialized = json.dumps(events)
    assert "sensitive source body" not in serialized
    assert "signed packages" not in serialized and "violet" not in serialized
    selected = events[-1]["trace"]["selected"]
    assert {row["kind"] for row in selected} == {"memory", "workspace", "documents"}


def test_empty_automatic_sources_still_leave_only_one_manual_round(retrieval):
    co, core, store, *_ = retrieval
    core.agent_configuration.memory_policy = replace(core.agent_configuration.memory_policy, recall_enabled=False)
    store.configure(enabled=False)
    co.initial()
    assert co.allowance.rounds == 1
    assert followup(co, "canary", ["memory"])["rounds"] == 2
    assert "follow_up_exhausted" in followup(co, "release", ["memory"])["fallbacks"]


def test_automatic_memory_only_trace_when_manual_search_is_disabled(retrieval):
    co, core, store, _, record, events = retrieval
    core.agent_configuration.memory_policy = replace(core.agent_configuration.memory_policy, search_enabled=False)
    store.configure(enabled=False)
    co.initial()
    assert core.memory_context and co.snapshot()["packed_bytes"] > 0
    assert events[-1]["trace"]["selected"] == [{"kind": "memory", "id": record.id, "revision": record.revision}]


def test_shared_utf8_budget_includes_hashes_locators_and_intact_memory(retrieval):
    co, core, store, adapter, *_ = retrieval
    for index in range(12):
        (store.root / f"evidence{index}.md").write_text(f"# canary release {index}\n" + "界証" * 1800 + "\n")
    store.reindex()
    co.initial()
    reference = co.reference()
    assert co.snapshot()["results"]
    assert len((core.memory_context + reference).encode()) + 512 <= rag.EVIDENCE_BYTES
    assert co.snapshot()["memory"]["token_count"] <= core.agent_configuration.memory_policy.max_automatic_tokens
    assert core.memory_context == adapter._pending[id(core)][2].text


def test_native_completion_confirms_initial_and_followup_snapshots(retrieval):
    co, _, _, _, _, events = retrieval
    co.initial()
    first = co.snapshot()
    co.delivery("uncertain")
    followup(co, "canary violet")
    co.native_tool_result("ok")
    co.delivery("submitted")
    submitted = [event["trace"] for event in events if event.get("trace", {}).get("phase") == "submitted"]
    assert {trace["round"] for trace in submitted} == {1, 2}
    assert submitted[0]["packed_bytes"] == first["packed_bytes"]
