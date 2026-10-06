from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from locus_memory.models import RememberRequest, Scope

from ollama_code import paths
from ollama_code.agent_config import AgentConfiguration
from ollama_code.api.retrieval import retrieval_trace
from ollama_code.api.runs import orchestration_events, orchestration_export
from ollama_code.knowledge import KnowledgeStore
from ollama_code.memory_adapter import MemoryAdapter
from ollama_code.runstore import RunStore


@pytest.fixture
def host(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "source.py").write_text("private source text", encoding="utf-8")
    (workspace / "guide.csv").write_text("private,document", encoding="utf-8")
    adapter = MemoryAdapter(app_dir=paths.APP_DIR, edition="locus")
    core = SimpleNamespace(workspace_root=str(workspace), cwd=str(workspace), identity_mode=False,
        agent_configuration=AgentConfiguration.parse({}), agent_id="primary", memory_adapter=adapter)
    run = {"id": "run-a", "workspace_root": str(workspace), "manifest": {"memory_agent_id": "primary"},
           "attempts": []}
    events = []
    service = SimpleNamespace(core=core, run_store=SimpleNamespace(
        run=lambda rid: run if rid == "run-a" else None,
        events=lambda rid, after_seq=0, limit=500: [event for event in events if event["seq"] > after_seq][:limit]))
    yield service, adapter, run, events
    adapter.close()


def trace(selected, **extra):
    return {"id": "trace-a", "agent_id": "primary", "turn_id": "turn-a", "round": 1,
            "phase": "retrieved", "sources": ["memory", "workspace", "documents"],
            "selected": selected, "duration_ms": 3.2, "packed_bytes": 100, **extra}


def workspace_citation(path="source.py", kind="workspace"):
    return {"kind": kind, "id": "file:1", "path": path, "hash": "a" * 64,
            "locator": {"kind": "line", "line_start": 1, "line_end": 1},
            "snippet": "private source text", "context": "private heading"}


def test_trace_is_content_free_and_rechecks_canonical_memory_access(host):
    service, adapter, _, events = host
    access = adapter.access(service.core, "user")
    project = next(iter(access.grants.projects))
    memory = adapter.engine.remember(access, RememberRequest(content="private memory content",
        scope=Scope.of(project=project))).record
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([
        workspace_citation(), {"kind": "memory", "id": memory.id, "revision": memory.revision,
                               "content": memory.content}], query="private raw query", gap="private gap",
        omitted=[{"reason": "budget", "count": 2, "content": "private text"}],
        fallbacks=["semantic_unavailable:TimeoutError", "raw error includes private text"])})

    item = retrieval_trace(service, run_id="run-a")["traces"][0]

    assert len(item["selected"]) == 2
    assert item["selected"][0]["content_hash"] == "a" * 64
    assert item["selected"][1] == {"kind": "memory", "id": memory.id, "revision": memory.revision}
    assert item["omitted"] == [{"reason": "budget", "count": 2}]
    assert item["fallbacks"] == ["semantic_unavailable:TimeoutError"]
    assert "private" not in str(item)

    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"scopes": []}})
    limited = retrieval_trace(service, run_id="run-a")["traces"][0]
    assert len(limited["selected"]) == 1
    assert limited["unavailable_items"] == 1
    assert memory.id not in str(limited)


def test_trace_hides_personal_memory_even_when_engine_global_grants_allow_it(host):
    service, adapter, _, events = host
    memory = adapter.engine.remember(adapter.access(service.core, "user"),
        RememberRequest(content="personal private preference", kind="preference")).record
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([
        {"kind": "memory", "id": memory.id, "revision": 1}])})
    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"scopes": ["workspace"]}})

    item = retrieval_trace(service, run_id="run-a")["traces"][0]

    assert item["selected"] == []
    assert item["unavailable_items"] == 1


def test_trace_file_paths_follow_current_document_exclusion_and_workspace_policy(host):
    service, _, _, events = host
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([
        workspace_citation(), workspace_citation("guide.csv", "documents"),
        workspace_citation("../outside.py"), workspace_citation("/outside.py")])})
    store = KnowledgeStore(service.core.workspace_root)
    first = retrieval_trace(service, run_id="run-a")["traces"][0]
    assert [item["path"] for item in first["selected"]] == ["source.py"]
    assert first["unavailable_items"] == 3

    store.configure(documents_enabled=True, exclusions=["source.py"])
    second = retrieval_trace(service, run_id="run-a")["traces"][0]
    assert [item["path"] for item in second["selected"]] == ["guide.csv"]

    service.core.agent_configuration = AgentConfiguration.parse({"capability_policy": {"workspace_read": False}})
    denied = retrieval_trace(service, run_id="run-a")["traces"][0]
    assert denied["selected"] == []
    assert "source.py" not in str(denied)
    assert "guide.csv" not in str(denied)


def test_trace_rejects_wrong_workspace_identity_and_unknown_agent(host):
    service, _, run, events = host
    with pytest.raises(HTTPException) as missing:
        retrieval_trace(service, run_id="elsewhere")
    assert missing.value.status_code == 404
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([workspace_citation()], agent_id="unknown")})
    assert retrieval_trace(service, run_id="run-a")["traces"] == []
    service.core.identity_mode = True
    with pytest.raises(HTTPException):
        retrieval_trace(service, run_id="run-a")
    service.core.identity_mode = False
    run["workspace_root"] = "/different-workspace"
    with pytest.raises(HTTPException):
        retrieval_trace(service, run_id="run-a")


def test_trace_scans_later_event_pages_and_ignores_unrelated_event_content(host):
    service, _, run, events = host
    events.extend({"seq": index, "type": "token", "text": "private text"} for index in range(1, 601))
    events.append({"seq": 601, "type": "retrieval_trace", "trace": trace([workspace_citation()])})
    run["last_seq"] = 601

    result = retrieval_trace(service, run_id="run-a")

    assert len(result["traces"]) == 1
    assert "private text" not in str(result)


def test_trace_reloads_saved_owner_file_permissions(host, monkeypatch):
    service, _, run, events = host
    run["manifest"]["profiles"] = [{"id": "reviewer", "behavior": {}}]
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([workspace_citation()], agent_id="reviewer")})
    denied = AgentConfiguration.parse({"capability_policy": {"workspace_read": False}})
    monkeypatch.setattr("ollama_code.api.retrieval.saved_memory_agent", lambda _: (None, denied))

    result = retrieval_trace(service, run_id="run-a")["traces"][0]

    assert result["selected"] == []
    assert result["unavailable_items"] == 1


def test_trace_hides_deleted_and_symlinked_sources_and_missing_memory(host):
    service, _, _, events = host
    workspace = Path(service.core.workspace_root)
    (workspace / "alias.py").symlink_to(workspace / "source.py")
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([
        workspace_citation("alias.py"), workspace_citation("deleted.py"),
        {"kind": "memory", "id": "missing-memory", "revision": 1}])})

    result = retrieval_trace(service, run_id="run-a")["traces"][0]

    assert result["selected"] == []
    assert result["unavailable_items"] == 3
    assert "alias.py" not in str(result)
    assert "missing-memory" not in str(result)


def test_trace_rechecks_file_access_each_time_instead_of_replaying_old_identifiers(host):
    service, _, _, events = host
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([workspace_citation()])})
    before = retrieval_trace(service, run_id="run-a")["traces"][0]
    assert before["selected"][0]["path"] == "source.py"
    assert "private source text" not in str(before)
    Path(service.core.workspace_root, "source.py").unlink()

    after = retrieval_trace(service, run_id="run-a")["traces"][0]

    assert after["selected"] == []
    assert after["unavailable_items"] == 1
    assert "source.py" not in str(after)


def test_trace_preserves_numeric_pdf_locator_but_drops_source_heading(host):
    service, _, _, events = host
    workspace = Path(service.core.workspace_root)
    (workspace / "guide.pdf").write_bytes(b"fixture is never parsed")
    KnowledgeStore(str(workspace)).configure(documents_enabled=True)
    citation = workspace_citation("guide.pdf", "documents")
    citation["locator"] = {"kind": "pdf", "page": 4, "page_index": 3,
                           "bounds": [0.1, 0.2, 0.3, 0.4], "heading": "private heading"}
    events.append({"seq": 1, "type": "retrieval_trace", "trace": trace([citation])})

    result = retrieval_trace(service, run_id="run-a")["traces"][0]["selected"][0]

    assert result["locator"] == {"kind": "pdf", "page": 4, "page_index": 3,
                                  "bounds": [0.1, 0.2, 0.3, 0.4]}


@pytest.mark.parametrize("include_content", [False, True])
def test_generic_events_and_exports_cannot_bypass_retrieval_citation_redaction(tmp_path, include_content):
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run-a", session_id="session-a", workspace_root=str(tmp_path))
    selected = [workspace_citation("restricted/private.py"),
                {"kind": "memory", "id": "restricted-memory-id", "revision": 7}]
    store.append_event("run-a", {"type": "retrieval_trace", "trace": trace(selected)})
    store.append_event("run-a", {"type": "note", "text": "ordinary event"})
    service = SimpleNamespace(run_store=store)

    listing = orchestration_events(service, "run-a", after_seq=0, limit=50)
    exported = orchestration_export(service, "run-a", include_content=include_content)

    for result in (listing, exported):
        assert "restricted/private.py" not in str(result)
        assert "restricted-memory-id" not in str(result)
    public_trace = listing["events"][0]["trace"]
    assert public_trace["selected"] == []
    assert public_trace["citations_redacted"] is True
    assert public_trace["round"] == 1
    assert listing["last_seq"] == 2
    assert listing["events"][1]["text"] == "ordinary event"
    # Inspection still has the original retained source identities to reauthorize.
    assert store.events("run-a")[0]["trace"]["selected"] == selected
