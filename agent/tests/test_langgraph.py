"""Workflow validation, durable graph execution, and recovery guarantees."""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from langgraph.checkpoint.sqlite import SqliteSaver

from ollama_code import config as config_mod
from ollama_code import extensions as extensions_mod
from ollama_code import sessions as sessions_mod
from ollama_code.core import AgentCore
from ollama_code.langgraph_runtime import (
    GraphRunStore,
    SideEffectCoordinator,
    WorkflowError,
    WorkflowRegistry,
    builtin_templates,
    validate_workflow,
)
from ollama_code.ollama import ChatResponse


@pytest.fixture(autouse=True)
def isolated_runtime(tmp_path, monkeypatch):
    app_dir = tmp_path / "app-state"
    monkeypatch.setattr(sessions_mod, "APP_DIR", app_dir)
    monkeypatch.setattr(sessions_mod, "SESSIONS_DIR", app_dir / "sessions")
    monkeypatch.setattr(sessions_mod, "TRASH_DIR", app_dir / "session-trash")
    monkeypatch.setattr(sessions_mod, "META_PATH", app_dir / "session-meta.json")
    monkeypatch.setattr(config_mod, "APP_DIR", app_dir)
    monkeypatch.setattr(config_mod, "CONFIG_PATH", app_dir / "config.json")
    monkeypatch.setattr(extensions_mod, "APP_DIR", app_dir)
    return app_dir


class WorkflowClient:
    """Prompt-aware fake provider that is safe under parallel graph branches."""

    def __init__(self, *, delay: float = 0.0):
        self.delay = delay
        self.calls: list[tuple[str, float, float]] = []
        self._lock = threading.Lock()

    def chat_stream(
        self,
        model,
        messages,
        tools=None,
        on_token=None,
        should_stop=None,
        on_thinking=None,
        think=False,
        options=None,
    ):
        system = str(messages[0].get("content") or "")
        started = time.monotonic()
        if self.delay:
            time.sleep(self.delay)
        if "Choose every useful next node" in system:
            if "architecture" in system:
                text = '["architecture", "testing", "risks"]'
            else:
                text = '["implementation", "review"]'
        elif "Final answer" in system or "final answer" in system.lower() \
                or "Implementation plan" in system or "Final summary" in system:
            text = "Finished through the graph."
        elif "Architecture" in system or "architecture" in system:
            text = "Architecture findings"
        elif "Testing" in system or "testing" in system:
            text = "Testing findings"
        elif "Risks" in system or "risks" in system:
            text = "Risk findings"
        else:
            text = "Specialist result"
        if should_stop and should_stop():
            raise RuntimeError("stopped")
        if on_token:
            on_token(text)
        ended = time.monotonic()
        with self._lock:
            self.calls.append((system, started, ended))
        return ChatResponse(
            content_parts=[text],
            done=True,
            prompt_eval_count=7,
            eval_count=3,
        )

    def context_length(self, name):
        return 32_768

    def loaded_context_length(self, name):
        return 32_768

    def list_models(self):
        return [{"name": "test-model"}]


def graph_core(tmp_path: Path, *, delay: float = 0.0) -> tuple[AgentCore, WorkflowClient, list[dict]]:
    workspace = tmp_path / "workspace"
    workspace.mkdir(exist_ok=True)
    core = AgentCore(cwd=str(workspace), config={"model": "test-model", "max_iterations": 5})
    client = WorkflowClient(delay=delay)
    core.client = client
    core.model = "test-model"
    core.context_limit = 32_768
    core.messages = [core.system_message()]
    events: list[dict] = []
    core.on_event(events.append)
    return core, client, events


def test_builtin_templates_have_typed_ports_and_validate():
    for template in builtin_templates():
        workflow = validate_workflow(template)
        assert len([node for node in workflow["nodes"] if node["type"] == "input"]) == 1
        assert any(node["type"] == "final" for node in workflow["nodes"])
        assert all("input_ports" in node and "output_ports" in node for node in workflow["nodes"])


def test_validation_rejects_unsafe_routes_mismatched_ports_and_secrets():
    workflow = builtin_templates()[0]
    workflow["nodes"][1]["config"]["api_key"] = "must-not-be-here"
    with pytest.raises(WorkflowError, match="credentials"):
        validate_workflow(workflow)

    workflow = builtin_templates()[0]
    workflow["edges"][0]["target_port"] = "missing"
    with pytest.raises(WorkflowError, match="unknown input port"):
        validate_workflow(workflow)

    workflow = builtin_templates()[0]
    workflow["edges"][0]["condition"] = {"operation": "python", "value": "x"}
    with pytest.raises(WorkflowError, match="unsupported route operation"):
        validate_workflow(workflow)

    workflow = builtin_templates()[0]
    workflow["nodes"][2]["config"]["retry_count"] = 3
    with pytest.raises(WorkflowError, match="between 0 and 2"):
        validate_workflow(workflow)


def test_project_workflow_shadows_global_and_digest_change_revokes_trust(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    registry = WorkflowRegistry(str(workspace), tmp_path / "graph")
    definition = builtin_templates()[0]
    definition["id"] = "global-one"
    registry.save(definition, "global")

    project = json.loads(json.dumps(definition))
    project["id"] = "project-one"
    project["name"] = "Project Single Agent"
    saved = registry.save(project, "project")
    assert registry.get("single-agent")["id"] == "project-one"
    assert saved["trusted"] is False
    registry.trust(saved["id"], saved["digest"])
    assert registry.get(saved["id"], require_trust=True)["trusted"] is True

    path = workspace / ".locus/workflows/single-agent.json"
    changed = json.loads(path.read_text())
    changed["description"] = "Changed after trust"
    changed["nodes"][2]["config"]["prompt"] = "Use the Linear MCP server"
    changed["nodes"][2]["config"]["tools"] = ["mcp__linear__update_issue"]
    path.write_text(json.dumps(changed))
    changed_item = registry.get("single-agent")
    assert changed_item["trusted"] is False
    assert changed_item["capability_diff"]["prompts_changed"] is True
    assert changed_item["capability_diff"]["tools_added"] == ["mcp__linear__update_issue"]
    assert changed_item["capability_diff"]["mutation_after"] is True
    with pytest.raises(WorkflowError, match="trust"):
        registry.get("single-agent", require_trust=True)


def test_workflow_discovery_ignores_symlinks_and_bounds_fanout(tmp_path):
    workspace = tmp_path / "workspace"
    project_dir = workspace / ".locus/workflows"
    project_dir.mkdir(parents=True)
    outside = tmp_path / "outside.json"
    outside.write_text(json.dumps(builtin_templates()[0]))
    (project_dir / "linked.json").symlink_to(outside)
    registry = WorkflowRegistry(str(workspace), tmp_path / "graph")
    assert all(item["slug"] != "linked" for item in registry.list())

    workflow = builtin_templates()[1]
    supervisor = next(node for node in workflow["nodes"] if node["type"] == "supervisor")
    join = next(node for node in workflow["nodes"] if node["type"] == "join")
    for index in range(17):
        node_id = f"extra-{index}"
        workflow["nodes"].append({
            "id": node_id,
            "type": "model",
            "label": node_id,
            "position": {"x": 0, "y": 0},
            "config": {},
        })
        workflow["edges"].append({"id": f"super-{node_id}", "source": supervisor["id"], "target": node_id})
        workflow["edges"].append({"id": f"{node_id}-join", "source": node_id, "target": join["id"]})
    with pytest.raises(WorkflowError, match="more than 16"):
        validate_workflow(workflow)


def test_run_store_marks_crashed_mutation_uncertain_and_requires_resolution(tmp_path):
    root = tmp_path / "graph"
    store = GraphRunStore(root)
    run = store.create(
        run_id="run-1",
        session_id="session-1",
        workflow=builtin_templates()[0],
        mode="build",
        goal="change something",
        status="running",
    )
    assert run["status"] == "running"
    store.begin_effect("run-1", "tools", "write_file", "Write result.txt", "effect-1")

    recovered = GraphRunStore(root)
    assert recovered.get("run-1")["status"] == "uncertain"
    with pytest.raises(WorkflowError, match="only be skipped or explicitly retried"):
        recovered.resolve_uncertain("run-1", "resume")
    resolved = recovered.resolve_uncertain("run-1", "skip")
    assert resolved["status"] == "interrupted"
    assert resolved["side_effects"][0]["status"] == "skipped"


def test_session_trash_discards_linked_graph_history_only(tmp_path):
    store = GraphRunStore(tmp_path / "graph")
    template = builtin_templates()[0]
    store.create(
        run_id="trashed-run", session_id="trashed-session", workflow=template,
        mode="build", goal="old work", status="completed",
    )
    store.create(
        run_id="kept-run", session_id="kept-session", workflow=template,
        mode="build", goal="current work", status="completed",
    )

    assert store.discard_sessions(["trashed-session"]) == 1
    with pytest.raises(WorkflowError, match="not found"):
        store.get("trashed-run")
    assert store.get("kept-run")["session_id"] == "kept-session"


def test_single_agent_streams_only_final_answer_to_main_chat(tmp_path):
    core, _client, events = graph_core(tmp_path)
    result = core.langgraph_engine.start("Answer the task", "build", "single-agent")
    assert result["status"] == "completed"
    assert core.messages[-1]["role"] == "assistant"
    assert core.messages[-1]["content"] == "Finished through the graph."
    assert len([event for event in events if event["type"] == "message_start"]) == 1
    assert any(event["type"] == "graph_node_token" for event in events)
    assert any(event["type"] == "token" for event in events)
    final_usage = next(
        event for event in events
        if event["type"] == "graph_node_token" and event.get("final_node")
    )
    assert final_usage["model"] == "test-model"
    assert final_usage["prompt_tokens"] == 7
    assert final_usage["completion_tokens"] == 3

    core._add_message(
        {"role": "assistant", "content": "Finished through the graph."},
        event_id=f"graph:{result['id']}:final",
    )
    persisted = sessions_mod.SessionStore.load(core.session.path)
    assert len([
        message for message in persisted
        if message.get("role") == "assistant"
        and message.get("content") == "Finished through the graph."
    ]) == 1


def test_planner_specialists_execute_in_parallel(tmp_path):
    core, client, _events = graph_core(tmp_path, delay=0.08)
    result = core.langgraph_engine.start("Plan this feature", "plan", "planner-team")
    assert result["status"] == "completed"
    specialists = [call for call in client.calls if any(
        label in call[0] for label in ("Analyze architecture", "Design verification", "Find safety")
    )]
    assert len(specialists) == 3
    latest_start = max(item[1] for item in specialists)
    earliest_end = min(item[2] for item in specialists)
    assert latest_start < earliest_end, "specialist model calls should overlap"


def test_side_effect_coordinator_is_fifo_while_reads_remain_parallel():
    coordinator = SideEffectCoordinator()
    order: list[str] = []
    release = threading.Event()

    def mutation(name: str, waits: bool = False) -> str:
        def work() -> str:
            order.append(name)
            if waits:
                release.wait(timeout=2)
            return name
        return coordinator.run(True, work)

    first = threading.Thread(target=mutation, args=("first", True))
    second = threading.Thread(target=mutation, args=("second",))
    third = threading.Thread(target=mutation, args=("third",))
    first.start()
    while coordinator._next_ticket < 1:  # noqa: SLF001 - assert the ticketed queue contract
        time.sleep(0.001)
    second.start()
    while coordinator._next_ticket < 2:  # noqa: SLF001
        time.sleep(0.001)
    third.start()
    while coordinator._next_ticket < 3:  # noqa: SLF001
        time.sleep(0.001)
    release.set()
    for thread in (first, second, third):
        thread.join(timeout=2)
    assert order == ["first", "second", "third"]

    times: list[tuple[float, float]] = []
    barrier = threading.Barrier(2)

    def read() -> None:
        barrier.wait(timeout=2)
        started = time.monotonic()
        coordinator.run(False, lambda: time.sleep(0.05) or "read")
        times.append((started, time.monotonic()))

    reads = [threading.Thread(target=read) for _ in range(2)]
    for thread in reads:
        thread.start()
    for thread in reads:
        thread.join(timeout=2)
    assert max(item[0] for item in times) < min(item[1] for item in times)


def test_approval_interrupt_is_durable_and_resumes_by_interrupt_id(tmp_path):
    core, _client, events = graph_core(tmp_path)
    waiting = core.langgraph_engine.start("Build it", "build", "builder-team")
    assert waiting["status"] == "waiting_review"
    request = next(event for event in events if event["type"] == "graph_review_request")
    handled, completed = core.langgraph_engine.record_decision(
        waiting["id"], request["request_id"], "approve"
    )
    assert handled is True
    assert completed and completed["status"] == "completed"


def test_stop_denies_unresolved_graph_interrupts_and_keeps_recovery(tmp_path):
    core, _client, _events = graph_core(tmp_path)
    waiting = core.langgraph_engine.start("Build it", "build", "builder-team")
    assert waiting["status"] == "waiting_review"

    assert core.langgraph_engine.interrupt_active() is True
    stopped = core.langgraph_engine.runs.get(waiting["id"])
    assert stopped["status"] == "interrupted"
    pending = stopped["state"]["pending_interrupts"]
    decisions = stopped["state"]["interrupt_decisions"]
    assert decisions[pending[0]["interrupt_id"]] == "reject"


def test_discard_removes_run_ledger_and_langgraph_checkpoints(tmp_path):
    core, _client, _events = graph_core(tmp_path)
    waiting = core.langgraph_engine.start("Build it", "build", "builder-team")
    checkpoint_path = core.langgraph_engine.runs.checkpoint_path
    import sqlite3

    with sqlite3.connect(checkpoint_path, check_same_thread=False) as connection:
        saver = SqliteSaver(connection)
        config = {"configurable": {"thread_id": waiting["id"]}}
        assert list(saver.list(config))

    core.langgraph_engine.discard(waiting["id"])
    with pytest.raises(WorkflowError, match="not found"):
        core.langgraph_engine.runs.get(waiting["id"])
    with sqlite3.connect(checkpoint_path, check_same_thread=False) as connection:
        assert not list(SqliteSaver(connection).list(config))


def test_plan_mode_hard_blocks_mutations_without_prompting(tmp_path):
    core, _client, events = graph_core(tmp_path)
    result = core.langgraph_engine._run_graph_tool(
        "not-persisted", "tools", "plan", "write_file",
        {"path": "blocked.txt", "content": "no"}, "call-1",
    )
    assert result.startswith("Error: Plan workflows cannot")
    assert not (Path(core.cwd) / "blocked.txt").exists()
    assert not any(event["type"] == "permission_request" for event in events)


def test_transient_credentials_never_reach_run_database_or_errors(tmp_path):
    core, _client, _events = graph_core(tmp_path)
    workflow = builtin_templates()[0]
    workflow["id"] = "credential-workflow"
    workflow["slug"] = "credential-workflow"
    workflow["nodes"][2]["config"]["model_binding"] = {
        "account_id": "remote-account",
        "model": "remote-model",
    }
    core.langgraph_engine.registry.save(workflow, "global")
    waiting = core.langgraph_engine.start("Use remote", "build", "credential-workflow")
    assert waiting["status"] == "awaiting_credentials"
    secret = "super-secret-provider-key"
    core.langgraph_engine._credentials[waiting["id"]] = {
        "remote-account": {"account_id": "remote-account", "api_key": secret}
    }
    assert core.langgraph_engine._redact(f"failed with {secret}", waiting["id"]) == "failed with [redacted]"
    persisted = b"".join(
        path.read_bytes() for path in (tmp_path / "app-state/langgraph").glob("*")
        if path.is_file()
    )
    assert secret.encode() not in persisted
    core.langgraph_engine.interrupt_active()
    assert waiting["id"] not in core.langgraph_engine._credentials


def test_langgraph_rest_catalog_validation_and_uncertain_resolution(tmp_path):
    from ollama_code import server as server_mod

    core, _client, _events = graph_core(tmp_path)
    server_mod.app.state.service = server_mod.ChatService(core)
    with TestClient(server_mod.app) as client:
        status = client.get("/api/langgraph")
        assert status.status_code == 200
        assert status.json()["version"] == "1.2.9"

        catalog = client.get("/api/langgraph/workflows")
        assert catalog.status_code == 200
        assert {item["slug"] for item in catalog.json()["workflows"]} >= {
            "single-agent", "planner-team", "builder-team",
        }

        invalid = builtin_templates()[0]
        invalid["nodes"] = [node for node in invalid["nodes"] if node["type"] != "final"]
        response = client.post("/api/langgraph/workflows/validate", json={"definition": invalid})
        assert response.status_code == 422
        assert "Final Answer" in response.json()["detail"]

        store = core.langgraph_engine.runs
        store.create(
            run_id="rest-uncertain",
            session_id=core.session.session_id,
            workflow=builtin_templates()[0],
            mode="build",
            goal="perform a write",
            status="running",
        )
        store.begin_effect(
            "rest-uncertain", "tools", "write_file", "Write output.txt", "rest-effect"
        )
        store.update("rest-uncertain", status="uncertain")
        resolved = client.post(
            "/api/langgraph/runs/rest-uncertain/resolve-uncertain",
            json={"action": "retry"},
        )
        assert resolved.status_code == 200
        assert resolved.json()["status"] == "interrupted"
        assert resolved.json()["side_effects"][0]["status"] == "retry_authorized"
