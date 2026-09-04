from __future__ import annotations

import os
import sqlite3

import pytest

from ollama_code.api.automation_workflows import start_execution
from ollama_code.automation_workflows import (
    WorkflowValidationError,
    agent_prompt,
    implicit_workflow,
    simulate_workflow,
    validate_step_result,
    validate_workflow,
)
from ollama_code.extensions import ExtensionManager
from ollama_code.runstore import RunStore, RunStoreError
from ollama_code.tool_registry import ToolRegistry
from ollama_code.tools import ToolContext, execute_tool


def workflow() -> dict:
    return {
        "version": 1,
        "entry_step_id": "classify",
        "steps": [
            {
                "id": "classify",
                "type": "agent",
                "title": "Classify",
                "instruction_template": "Classify {{trigger.subject}} at {{trigger.data.price}}",
                "mode": "work",
                "outputs": [
                    {"name": "urgent", "type": "boolean"},
                    {"name": "score", "type": "number"},
                ],
            },
            {
                "id": "urgent",
                "type": "condition",
                "title": "Urgent?",
                "reference": "steps.classify.urgent",
                "operator": "is_true",
                "true_step_id": "approve",
                "false_step_id": None,
            },
            {
                "id": "approve",
                "type": "approval",
                "title": "Approve response",
                "explanation_template": "Urgency score: {{steps.classify.score}}",
                "approve_step_id": "respond",
            },
            {
                "id": "respond",
                "type": "agent",
                "title": "Respond",
                "instruction_template": "Respond to {{trigger.subject}}",
                "mode": "work",
                "outputs": [],
                "next_step_id": None,
            },
        ],
    }


def queue_and_bind(store: RunStore, execution_id: str, action: dict, run_id: str) -> None:
    store.queue_run(
        run_id,
        session_id=action["execution"]["session_id"],
        request=action["prompt"],
        manifest={
            "workflow_execution_id": execution_id,
            "workflow_step_id": action["step"]["id"],
        },
    )
    store.bind_automation_step_run(execution_id, action["step"]["id"], run_id)


def test_legacy_workflow_is_one_agent_and_inherits_connectors() -> None:
    value = implicit_workflow("Summarize", "work")
    assert value["steps"] == [{
        "id": "agent", "type": "agent", "title": "Run agent",
        "instruction_template": "Summarize", "mode": "work", "outputs": [],
        "allowed_connection_ids": None, "next_step_id": None,
    }]


def test_graph_template_type_and_permission_validation() -> None:
    value = workflow()
    value["steps"][0]["allowed_connection_ids"] = ["9-mail.connection"]
    normalized = validate_workflow(
        value, allowed_connection_ids={"9-mail.connection", "telegram"}
    )
    assert normalized["steps"][0]["allowed_connection_ids"] == ["9-mail.connection"]

    bad_edge = workflow()
    bad_edge["steps"][2]["approve_step_id"] = "classify"
    with pytest.raises(WorkflowValidationError, match="later step"):
        validate_workflow(bad_edge)

    bad_reference = workflow()
    bad_reference["steps"][3]["instruction_template"] = "{{steps.unknown.value}}"
    with pytest.raises(WorkflowValidationError, match="earlier Agent step"):
        validate_workflow(bad_reference)

    bad_type = workflow()
    bad_type["steps"][1].update({"operator": "equals", "compare_value": "yes"})
    with pytest.raises(WorkflowValidationError, match="compares boolean to string"):
        validate_workflow(bad_type)

    widened = workflow()
    widened["steps"][0]["allowed_connection_ids"] = ["telegram"]
    with pytest.raises(WorkflowValidationError, match="cannot widen"):
        validate_workflow(widened, allowed_connection_ids={"gmail"})

    joined = workflow()
    joined["steps"][1]["false_step_id"] = "respond"
    with pytest.raises(WorkflowValidationError, match="join"):
        validate_workflow(joined)

    unreachable = workflow()
    unreachable["steps"][0]["next_step_id"] = "approve"
    with pytest.raises(WorkflowValidationError, match="unreachable"):
        validate_workflow(unreachable)


def test_limits_and_output_contract() -> None:
    too_many = workflow()
    too_many["steps"] = [
        {"id": f"agent_{index}", "type": "agent", "title": "Agent",
         "instruction_template": "Run", "mode": "work", "outputs": []}
        for index in range(21)
    ]
    too_many["entry_step_id"] = "agent_0"
    with pytest.raises(WorkflowValidationError, match="more than 20"):
        validate_workflow(too_many)

    step = validate_workflow(workflow())["steps"][0]
    assert "submit_workflow_result" in agent_prompt(step, {
        "trigger": {"subject": "Mail", "data": {"price": 10}}, "steps": {},
    })
    with pytest.raises(WorkflowValidationError, match="urgent"):
        validate_step_result(step, {"score": 0.8})
    with pytest.raises(WorkflowValidationError, match="must be boolean"):
        validate_step_result(step, {"urgent": "yes", "score": 0.8})
    assert validate_step_result(step, {"urgent": True, "score": 0.8}) == {
        "urgent": True, "score": 0.8,
    }


def test_internal_result_tool_validates_exact_contract_and_only_submits_once() -> None:
    context = ToolContext(workflow_outputs=[
        {"name": "urgent", "type": "boolean"},
        {"name": "score", "type": "number"},
    ])
    assert "missing workflow output 'score'" in execute_tool(
        "submit_workflow_result", {"result": {"urgent": True}}, context
    )
    assert "must be boolean" in execute_tool(
        "submit_workflow_result", {"result": {"urgent": 1, "score": 1}}, context
    )
    assert execute_tool(
        "submit_workflow_result", {"result": {"urgent": True, "score": 0.8}}, context
    ).startswith("Workflow result submitted")
    assert context.workflow_result == {"urgent": True, "score": 0.8}
    assert "already submitted" in execute_tool(
        "submit_workflow_result", {"result": {"urgent": False, "score": 0.1}}, context
    )


def test_ask_mode_workflow_can_offer_only_the_internal_result_tool(tmp_path) -> None:
    registry = ToolRegistry(
        ExtensionManager(str(tmp_path), root=tmp_path / "extensions")
    )
    clean = registry.set_workflow_outputs([
        {"name": "answer", "type": "string"},
    ])
    registry.set_workflow_result_only(True)
    assert clean == [{"name": "answer", "type": "string"}]
    assert [item["function"]["name"] for item in registry.schemas()] == [
        "submit_workflow_result"
    ]


def test_simulation_is_deterministic_and_has_no_history(tmp_path) -> None:
    value = workflow()
    trigger = {"subject": "Payment", "data": {"price": 42}}
    mocks = {"classify": {"urgent": True, "score": 0.9}}
    first = simulate_workflow(value, trigger=trigger, mock_outputs=mocks)
    second = simulate_workflow(value, trigger=trigger, mock_outputs=mocks)

    assert first == second
    assert first["waiting_for_approval"] is True
    assert [item["step_id"] for item in first["trace"]] == [
        "classify", "urgent", "approve",
    ]
    assert list(tmp_path.iterdir()) == []


def test_durable_execution_snapshots_branches_approval_and_lease(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    original = workflow()
    execution, created = store.create_automation_execution(
        automation_kind="event", automation_id="mail", occurrence_id="delivery-1",
        session_id="agent-chat", workflow=original,
        trigger={"subject": "Payment", "data": {"price": 42}}, settings={"runner": "solo"},
    )
    original["steps"][0]["instruction_template"] = "Edited later"
    assert created is True
    assert execution["workflow"]["steps"][0]["instruction_template"].startswith("Classify")
    with pytest.raises(RunStoreError, match="earlier workflow"):
        store.create_automation_execution(
            automation_kind="event", automation_id="mail", occurrence_id="delivery-2",
            session_id="agent-chat", workflow=workflow(), trigger={}, settings={},
        )

    first = store.advance_automation_execution(execution["id"])
    queue_and_bind(store, execution["id"], first, "run-classify")
    approval = store.complete_automation_step(
        execution["id"], run_id="run-classify", result={"urgent": True, "score": 0.9},
    )
    assert approval["action"] == "wait_for_approval"
    assert store.session_has_active_run("agent-chat") is True
    assert store.attention_items()[0]["kind"] == "workflow_approval"

    continued = store.decide_automation_approval(execution["id"], approve=True)
    assert continued["action"] == "run_agent"
    queue_and_bind(store, execution["id"], continued, "run-respond")
    finished = store.complete_automation_step(
        execution["id"], run_id="run-respond", result={},
    )
    assert finished["execution"]["state"] == "completed"
    # Completed child runs are still ordinary run rows; only the workflow lease is released.
    store.set_state("run-classify", "completed")
    store.set_state("run-respond", "completed")
    assert store.session_has_active_run("agent-chat") is False


def test_false_branch_finishes_without_approval(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    execution, _ = store.create_automation_execution(
        automation_kind="schedule", automation_id="daily", occurrence_id="slot-1",
        session_id="schedule-chat", workflow=workflow(),
        trigger={"subject": "Routine", "data": {"price": 1}}, settings={},
    )
    action = store.advance_automation_execution(execution["id"])
    queue_and_bind(store, execution["id"], action, "run-1")
    finished = store.complete_automation_step(
        execution["id"], run_id="run-1", result={"urgent": False, "score": 0.1},
    )
    assert finished["execution"]["state"] == "completed"
    assert finished["execution"]["context"]["steps"]["classify"]["urgent"] is False


def test_event_team_and_schedule_solo_steps_use_workflow_wide_runner(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")

    class Service:
        run_store = store

    event = start_execution(
        Service(), automation_kind="event", automation_id="mail",
        occurrence_id="delivery-team", session_id="team-chat", workflow=workflow(),
        trigger={"subject": "Payment", "data": {"price": 42}},
        settings={
            "runner": "team", "team_id": "ops", "team_name": "Operations",
            "workspace_root": str(tmp_path), "model": "test",
            "action_connection_ids": ["gmail"],
        },
    )
    assert event["run"]["run_kind"] == "team"
    assert event["run"]["team_id"] == "ops"
    assert event["run"]["manifest"]["action_connection_ids"] == ["gmail"]

    scheduled = start_execution(
        Service(), automation_kind="schedule", automation_id="daily",
        occurrence_id="slot-solo", session_id="solo-chat", workflow=workflow(),
        trigger={"subject": "Routine", "data": {"price": 1}},
        settings={"runner": "solo", "workspace_root": str(tmp_path), "model": "test"},
    )
    assert scheduled["run"]["run_kind"] == "solo"
    assert scheduled["run"]["manifest"]["workflow_outputs"] == [
        {"name": "urgent", "type": "boolean"},
        {"name": "score", "type": "number"},
    ]


def test_legacy_and_persisted_configuration_decoding(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    legacy = store.create_schedule({
        "name": "Legacy", "prompt": "Summarize", "workspace_root": str(tmp_path),
        "provider": "ollama", "model": "test", "timezone": "UTC",
        "rule": {"kind": "interval", "every": 1, "unit": "hours"},
    }, now=1_700_000_000)
    assert legacy["workflow_persisted"] is False
    assert legacy["workflow"]["steps"][0]["instruction_template"] == "Summarize"

    persisted = store.create_schedule({
        "name": "Workflow", "prompt": "legacy projection",
        "workspace_root": str(tmp_path), "provider": "ollama", "model": "test",
        "timezone": "UTC", "rule": {"kind": "interval", "every": 1, "unit": "hours"},
        "workflow": workflow(),
    }, now=1_700_000_000)
    assert persisted["workflow_persisted"] is True
    assert persisted["prompt"].startswith("Classify")

    connection = store.create_connector_connection({
        "kind": "gmail", "display_name": "Mail", "public_config": {}, "cursor": {},
    })
    trigger = store.create_event_trigger({
        "name": "Mail workflow", "connection_id": connection["id"],
        "target_session_id": "mail-chat", "instruction": "legacy projection",
        "mode": "work", "trigger_kind": "event", "filters": {},
        "action_connection_ids": [connection["id"]], "runner": "team",
        "team_id": "ops", "team_name": "Operations", "workflow": workflow(),
    })
    assert trigger["workflow_persisted"] is True
    assert trigger["runner"] == "team"
    assert trigger["team_id"] == "ops"

    changed = workflow()
    changed["steps"][0]["title"] = "Different workflow"
    with pytest.raises(RunStoreError, match="already exists"):
        store.create_event_trigger({
            "id": trigger["id"], "name": "Mail workflow",
            "connection_id": connection["id"], "target_session_id": "mail-chat",
            "instruction": "legacy projection", "mode": "work",
            "trigger_kind": "event", "filters": {},
            "action_connection_ids": [connection["id"]], "runner": "team",
            "team_id": "ops", "team_name": "Operations", "workflow": changed,
        })


def test_failure_retry_retains_outputs_and_warns_about_local_effects(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    execution, _ = store.create_automation_execution(
        automation_kind="event", automation_id="mail", occurrence_id="delivery-1",
        session_id="agent-chat", workflow=workflow(),
        trigger={"subject": "Payment", "data": {"price": 42}}, settings={},
    )
    action = store.advance_automation_execution(execution["id"])
    queue_and_bind(store, execution["id"], action, "run-1")
    failed = store.complete_automation_step(
        execution["id"], run_id="run-1", result={"urgent": True},
    )
    assert failed["execution"]["state"] == "failed"
    assert store.attention_items()[0]["kind"] == "workflow_failure"
    retried = store.retry_automation_step(execution["id"])
    assert retried["action"] == "run_agent"
    assert "does not undo local files or commands" in retried["warning"]
    assert retried["execution"]["context"]["steps"] == {}


def test_connector_receipt_is_idempotent_and_keeps_first_result(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    first = store.record_connector_action_receipt(
        "workflow:key", event_delivery_id="", tool_name="gmail_send",
        result={"text": "sent once"}, automation_execution_id="execution",
        workflow_step_id="send", tool_call_id="call-1", arguments_hash="a" * 64,
    )
    second = store.record_connector_action_receipt(
        "workflow:key", event_delivery_id="", tool_name="gmail_send",
        result={"text": "would be duplicate"}, automation_execution_id="execution",
        workflow_step_id="send", tool_call_id="call-2", arguments_hash="a" * 64,
    )
    assert first["result"] == second["result"] == {"text": "sent once"}
    assert second["tool_call_id"] == "call-1"


def test_attention_deduplicates_workflow_run_and_orders_oldest_decision_first(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    execution, _ = store.create_automation_execution(
        automation_kind="event", automation_id="mail", occurrence_id="delivery-1",
        session_id="agent-chat", workflow=workflow(),
        trigger={"subject": "Payment", "data": {"price": 42}}, settings={}, now=1,
    )
    action = store.advance_automation_execution(execution["id"])
    queue_and_bind(store, execution["id"], action, "workflow-run")
    store.fail_automation_step(execution["id"], "failed", run_id="workflow-run")
    store.set_state("workflow-run", "failed")
    store.start_run("permission-run", session_id="chat-2", state="waiting_permission")
    store.append_event("permission-run", {
        "type": "permission_request", "tool": "shell", "detail": "/tmp/example",
        "always_eligible": False,
    })

    items = store.attention_items()
    assert [item["kind"] for item in items].count("workflow_failure") == 1
    assert not any(item["id"] == "run:workflow-run" for item in items)
    permission = next(item for item in items if item["kind"] == "permission_request")
    assert permission["detail"] == "shell: /tmp/example"
    assert "always_allow" not in permission["actions"]
    assert items[0]["group"] == "decisions"


def test_attention_projects_a_completed_agent_question_from_run_history(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("question-run", session_id="question-chat", state="running")
    store.append_event("question-run", {
        "type": "question_ready",
        "question": {
            "id": "question-1", "title": "Choose a format",
            "question": "Which format should I use?", "options": [],
            "recommended": "Markdown",
        },
    })
    store.set_state("question-run", "completed")

    item = next(
        value for value in store.attention_items()
        if value["kind"] == "completed_question"
    )
    assert item["id"] == "completed-question:question-chat:question-1"
    assert item["request"]["recommended"] == "Markdown"


def test_newer_schema_opens_read_only_before_any_initializer_write(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    store.start_run("preserved", state="completed")
    with sqlite3.connect(path) as connection:
        connection.execute("UPDATE schema_meta SET version=12 WHERE singleton=1")
        connection.commit()
    before = os.stat(path).st_mtime_ns

    downgraded = RunStore(path)

    assert downgraded.read_only is True
    assert downgraded.run("preserved")["state"] == "completed"
    assert os.stat(path).st_mtime_ns == before


def test_restart_keeps_approvals_and_surfaces_inter_step_crashes(tmp_path) -> None:
    path = tmp_path / "runs.sqlite3"
    store = RunStore(path)
    awaiting, _ = store.create_automation_execution(
        automation_kind="schedule", automation_id="daily", occurrence_id="slot-awaiting",
        session_id="awaiting-chat", workflow=workflow(), trigger={}, settings={},
    )
    store.advance_automation_execution(awaiting["id"])

    orphaned, _ = store.create_automation_execution(
        automation_kind="event", automation_id="mail", occurrence_id="delivery-orphan",
        session_id="orphan-chat", workflow=workflow(), trigger={}, settings={},
    )
    store.advance_automation_execution(orphaned["id"])
    store.queue_run(
        "orphan-run", session_id="orphan-chat", request="not yet bound",
        manifest={
            "workflow_execution_id": orphaned["id"],
            "workflow_step_id": "classify",
        },
    )

    approval_execution, _ = store.create_automation_execution(
        automation_kind="event", automation_id="mail", occurrence_id="delivery-approval",
        session_id="approval-chat", workflow=workflow(),
        trigger={"subject": "Payment", "data": {"price": 42}}, settings={},
    )
    first = store.advance_automation_execution(approval_execution["id"])
    queue_and_bind(store, approval_execution["id"], first, "approval-run")
    store.complete_automation_step(
        approval_execution["id"], run_id="approval-run",
        result={"urgent": True, "score": 1},
    )

    reopened = RunStore(path)

    assert reopened.automation_execution(awaiting["id"])["state"] == "failed"
    assert reopened.run("orphan-run")["state"] == "cancelled"
    assert reopened.automation_execution(approval_execution["id"])["state"] == "waiting_approval"
    kinds = {item["kind"] for item in reopened.attention_items()}
    assert {"workflow_failure", "workflow_approval"} <= kinds


def test_schedule_occurrence_tracks_terminal_workflow_state(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    schedule = store.create_schedule({
        "name": "Daily", "prompt": "Run", "workspace_root": str(tmp_path),
        "provider": "ollama", "model": "test", "timezone": "UTC",
        "rule": {"kind": "interval", "every": 1, "unit": "hours"},
    }, now=1_700_000_000)
    _, occurrence, _ = store.claim_schedule_occurrence(
        schedule["id"], trigger="manual", now=1_700_000_001,
    )
    completed = store.finish_schedule_occurrence(occurrence["id"], state="completed")
    assert completed["state"] == "completed"
