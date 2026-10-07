"""Legacy workers receive separate, scoped evidence after content-free journaling."""
import copy
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from types import SimpleNamespace

import pytest
from locus_memory.models import RememberRequest, Scope

from ollama_code.adaptive_retrieval import begin_turn
from ollama_code.api.memory_inspector import memory_submission, memory_submissions
from ollama_code.core import AgentCore
from ollama_code.helper_retrieval import (
    WorkerDelivery,
    coordinator_for,
    helper_identity,
    release_helpers,
)
from ollama_code.knowledge import KnowledgeStore
from ollama_code.memory_adapter import ensure_memory_adapter
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.solo_swarm import SoloSwarmError, SoloSwarmExecutor, SoloSwarmRoute

CODE = "CODE-CANARY: release validation signs the package."
DOCUMENT = "DOCUMENT-CANARY: release validation needs two reviewers."
ROOT = "ROOT-AGENT-CANARY: release validation uses a private root token."
HELPER = "HELPER-AGENT-CANARY: release validation checks the worker manifest."


@pytest.fixture
def worker_host(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "release.txt").write_text(CODE)
    store = KnowledgeStore(str(workspace))
    store.reindex()
    store.configure(documents_enabled=True)
    raw = b"fixture release document"
    (workspace / "release.pdf").write_bytes(raw)
    store.index_extracted_document("release.pdf", hashlib.sha256(raw).hexdigest(),
        [{"text": DOCUMENT, "locator": {"kind": "pdf", "page": 2}, "method": "embedded"}], "pdf")
    root = AgentCore(cwd=str(workspace), config={"model": "fixture"})
    root.mcp.close()
    root.configure_agent({"memory_policy": {"auto_save_enabled": False, "proposals_enabled": False}})
    root._memory_turn_id = "root-turn"
    root.tool_ctx.memory_run_id = "helper-run"
    adapter = ensure_memory_adapter(root)
    # Deliberately collide the model-selected task ID with the primary agent.
    context = {"agent_id": "primary", "job_id": "primary", "agent_name": "Worker"}
    own_id = helper_identity("helper-run", "primary")
    for identity, content in (("primary", ROOT), (own_id, HELPER),
                              (helper_identity("helper-run", "other"), "OTHER-AGENT-CANARY: release validation.")):
        access = adapter.access(root, "user", agent_id=identity)
        adapter.engine.remember(access, RememberRequest(content=content, title="Release validation", scope=Scope.of(agent=identity)))
    events = []
    root.on_event(events.append)
    begin_turn(root, "release validation")
    yield root, store, context, events
    release_helpers(root.adaptive_retrieval)
    adapter.close()


def call(root, context, *, query="release validation worker manifest", sources=None):
    return root.run_solo_worker_tool("search_context", {"query": query,
        "missing_information": "Exact release validation evidence", "sources": sources or ["all"]},
        "helper-search", lambda *_: "once", event_context=context, execution_lock=None)


def test_worker_gets_code_documents_own_memory_and_uncertain_receipt(worker_host):
    root, _, context, events = worker_host
    original_packet = root.memory_context
    assert ROOT in original_packet
    result = call(root, context)
    assert all(body in result for body in (CODE, DOCUMENT, HELPER))
    assert ROOT not in result and "OTHER-AGENT-CANARY" not in result
    assert "release.txt" in result and "release.pdf" in result and "SHA-256" in result
    assert root.memory_context == original_packet
    helper = coordinator_for(root, context)
    assert helper.allowance is root.adaptive_retrieval.allowance
    assert helper.allowance.rounds == 2
    records = root.memory_adapter.engine.list_context_submissions(
        root.memory_adapter.access(helper.core, agent_id=helper.agent_id),
        session_id=root.session.session_id, run_id="helper-run", agent_id=helper.agent_id)
    assert records and records[-1]["state"] == "uncertain"
    persisted = json.dumps(events)
    assert all(body not in persisted for body in (ROOT, HELPER, CODE, DOCUMENT))
    traces = [event["trace"] for event in events if event.get("type") == "retrieval_trace"]
    assert traces[-1]["agent_id"] == helper_identity("helper-run", "primary")


def test_worker_permission_revoked_after_tool_observation_drops_delivery(worker_host):
    root, _, context, _ = worker_host
    def revoke(event):
        if event.get("type") == "tool_result":
            config = root.agent_configuration
            root.agent_configuration = replace(config,
                memory_policy=replace(config.memory_policy, scopes=()),
                capability_policy=replace(config.capability_policy, workspace_read=False))
    root.on_event(revoke)
    result = call(root, context)
    assert all(body not in result for body in (ROOT, HELPER, CODE, DOCUMENT))
    assert coordinator_for(root, context).core.memory_context == ""


def test_parallel_workers_do_not_swap_callbacks_or_reset_allowance(worker_host):
    root, _, context, _ = worker_host
    callback = root.tool_ctx.search_context
    contexts = [context, {**context, "agent_id": "other", "job_id": "other"}]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda item: call(root, item), contexts))
    assert root.tool_ctx.search_context is callback
    assert root.adaptive_retrieval.allowance.rounds == 2
    assert ROOT not in "\n".join(results)
    assert "OTHER-AGENT-CANARY" not in results[0]
    assert HELPER not in results[1]
    assert all(CODE in result and DOCUMENT in result for result in results)


def test_namespaced_helper_receipt_is_inspectable_only_for_own_run(worker_host):
    root, _, context, _ = worker_host
    call(root, context)
    run = {"id": "helper-run", "workspace_root": root.workspace_root,
           "session_id": root.session.session_id, "manifest": {"memory_agent_id": "primary"},
           "attempts": [{"agent_id": "primary", "job_id": "primary", "state": "completed"}]}
    service = SimpleNamespace(core=root, run_store=SimpleNamespace(run=lambda _: run))
    records = memory_submissions(service, run_id="helper-run", turn_id=None)["submissions"]
    helper_id = helper_identity("helper-run", "primary")
    receipt = next(record for record in records if record["agent_id"] == helper_id)
    detail = memory_submission(receipt["submission_id"], service, run_id="helper-run", include_content=True)
    contents = [item["current_content"] for item in detail["context"]["items"]]
    assert HELPER in contents and ROOT not in contents
    run["id"] = "different-run"
    assert not memory_submissions(service, run_id="different-run", turn_id=None)["submissions"]


def test_new_root_turn_revokes_old_helper_context(worker_host):
    root, _, context, _ = worker_host
    call(root, context)
    old = coordinator_for(root, context)
    root._memory_turn_id = "next-root-turn"
    begin_turn(root, "other work")
    assert old.stopped()
    assert id(old.core) not in root.memory_adapter._pending
    assert old.core.memory_context == ""


def completed_worker(identifier="primary"):
    return json.dumps({"id": identifier, "label": "Worker", "status": "completed",
                       "findings": "Checked the evidence", "evidence": [], "uncertainties": []})


def executor_for(root, client, *, native=False, hosted=False):
    route = SoloSwarmRoute(provider="chatgpt" if native else "ollama", model="fixture",
        provider_label="Fixture", client=client, workspace=root.cwd, behavior={}, hosted_openai_eligible=hosted)
    return SoloSwarmExecutor(route, emit=lambda _: None, should_stop=lambda: False,
        tool_schemas=root.solo_worker_tool_schemas, tool_execute=lambda *_: "No source evidence here.",
        tool_is_parallel_safe=lambda _: True, retrieval_delivery=WorkerDelivery(root, lambda *_: "once"))


def test_classic_worker_revalidates_every_request_without_replaying_tool_evidence(worker_host):
    root, _, context, events = worker_host
    wire = []
    class Client:
        def chat_stream(self, model, messages, **kwargs):
            wire.append(copy.deepcopy(messages))
            if len(wire) == 1:
                calls = [ToolCall("search_context", {"query": "release validation worker manifest",
                    "missing_information": "Worker-specific check", "sources": ["all"]})]
            elif len(wire) == 2:
                config = root.agent_configuration
                root.agent_configuration = replace(config, memory_policy=replace(config.memory_policy, scopes=()),
                    capability_policy=replace(config.capability_policy, workspace_read=False))
                calls = [ToolCall("read_file", {"path": "release.txt"})]
            else:
                return ChatResponse(content_parts=[completed_worker()], done=True)
            return ChatResponse(content_parts=["Checking"], tool_calls=calls, done=True)
    executor = executor_for(root, Client())
    task = executor._resolve_task_tools([{"id": "primary", "label": "Worker", "goal": "Check release"}])[0]
    assert executor._run_one(task)["status"] == "completed"
    assert len(wire) == 3
    assert CODE in json.dumps(wire[0]) and DOCUMENT in json.dumps(wire[0])
    assert HELPER in json.dumps(wire[1]) and ROOT not in json.dumps(wire)
    assert all(body not in json.dumps(wire[2]) for body in (CODE, DOCUMENT, HELPER))
    for request in wire:
        for message in request:
            if message["role"] == "tool":
                assert all(body not in message["content"] for body in (CODE, DOCUMENT, HELPER))
    helper = coordinator_for(root, context)
    records = root.memory_adapter.engine.list_context_submissions(
        root.memory_adapter.access(helper.core, agent_id=helper.agent_id),
        session_id=root.session.session_id, run_id="helper-run", agent_id=helper.agent_id)
    assert any(record["state"] == "submitted" for record in records)
    assert not any(record["state"] == "uncertain" for record in records)
    assert all(body not in json.dumps(events) for body in (ROOT, HELPER, CODE, DOCUMENT))
    assert root.adaptive_retrieval.allowance.rounds == 2


@pytest.mark.parametrize("failure", [None, "failed", "exception"])
def test_native_worker_returns_fresh_evidence_and_confirms_only_success(worker_host, failure):
    root, _, context, _ = worker_host
    wire = {}
    class Native:
        def start_thread(self, **kwargs):
            return "native-worker"
        def run_turn(self, **kwargs):
            wire["initial"] = kwargs["text"]
            wire["tool"] = kwargs["tool_handler"]("search_context", {
                "query": "release validation worker manifest", "missing_information": "worker check",
                "sources": ["all"]}, "native-search")
            if failure == "exception":
                raise RuntimeError("fixture transport failure")
            kwargs["event_handler"]({"method": "item/agentMessage/delta", "params": {"delta": completed_worker()}})
            return {"status": failure or "completed"}
    executor = executor_for(root, Native(), native=True)
    task = executor._resolve_task_tools([{"id": "primary", "label": "Worker", "goal": "Check release"}])[0]
    if failure == "exception":
        with pytest.raises(RuntimeError, match="fixture transport failure"):
            executor._run_one(task)
    elif failure == "failed":
        with pytest.raises(SoloSwarmError, match="native worker request failed"):
            executor._run_one(task)
    else:
        executor._run_one(task)
    assert CODE in wire["initial"] and DOCUMENT in wire["initial"]
    assert all(body in wire["tool"] for body in (CODE, DOCUMENT, HELPER))
    assert ROOT not in json.dumps(wire)
    helper = coordinator_for(root, context)
    records = root.memory_adapter.engine.list_context_submissions(
        root.memory_adapter.access(helper.core, agent_id=helper.agent_id),
        session_id=root.session.session_id, run_id="helper-run", agent_id=helper.agent_id)
    states = [record["state"] for record in records if record["state"] != "skipped"]
    assert states == ["uncertain" if failure else "submitted"]


def test_adaptive_workers_use_regular_route_instead_of_unhooked_hosted_loop(worker_host, monkeypatch):
    root, _, _, _ = worker_host
    class Client:
        def chat_stream(self, model, messages, **kwargs):
            prompt = next(message["content"] for message in messages if "Task ID:" in message["content"])
            identifier = prompt.split("Task ID: ", 1)[1].splitlines()[0]
            return ChatResponse(content_parts=[completed_worker(identifier)], done=True)
    executor = executor_for(root, Client(), hosted=True)
    monkeypatch.setattr(executor, "_run_hosted", lambda _: pytest.fail("Hosted loop has no fresh-context hook"))
    result = json.loads(executor.execute({"tasks": [
        {"id": identity, "label": "Worker", "goal": "Check release"} for identity in ("primary", "other")]}))
    assert result["summary"]["execution_engine"] == "locus_managed"
    assert all(item["status"] == "completed" for item in result["results"])


def test_namespaced_owner_cannot_impersonate_saved_profile_named_by_worker():
    from ollama_code.api.memory_inspector import _saved_owner
    run = {"id": "run-a", "manifest": {"memory_agent_id": "actual-owner", "profiles": [{"id": "spoofed"}]},
           "attempts": [{"agent_id": "spoofed", "job_id": "spoofed"}]}
    assert _saved_owner(run, helper_identity("run-a", "spoofed")) == "actual-owner"


def test_later_success_does_not_confirm_prior_uncertain_snapshot(worker_host):
    root, _, context, _ = worker_host
    call(root, context)
    delivery = WorkerDelivery(root, lambda *_: "once")
    assert HELPER in delivery.before_request(context)
    delivery.after_request(context)
    helper = coordinator_for(root, context)
    records = root.memory_adapter.engine.list_context_submissions(
        root.memory_adapter.access(helper.core, agent_id=helper.agent_id),
        session_id=root.session.session_id, run_id="helper-run", agent_id=helper.agent_id)
    assert sorted(record["state"] for record in records) == ["submitted", "uncertain"]


def test_inherited_file_evidence_keeps_parent_round_and_source_metadata(worker_host):
    root, _, context, events = worker_host
    delivery = WorkerDelivery(root, lambda *_: "once")
    assert CODE in delivery.before_request(context)
    trace = [event["trace"] for event in events if event.get("type") == "retrieval_trace"][-1]
    assert trace["round"] == 1 and set(trace["sources"]) == {"workspace", "documents"}
    assert all(item["kind"] != "memory" for item in trace["selected"])
