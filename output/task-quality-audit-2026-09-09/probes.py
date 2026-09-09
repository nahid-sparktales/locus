"""Offline audit probes. All runtime state and fixtures use a temporary directory.

These characterize current behavior; a reproduced gap is not a passing product
acceptance test. No model requests or user-session reads are performed.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
isolated = tempfile.TemporaryDirectory(prefix="locus-quality-audit-")
scratch = Path(isolated.name)
os.environ["OLLAMA_CODE_HOME"] = str(scratch / "app")
sys.path.insert(0, str(ROOT / "agent"))

from ollama_code.core import AgentCore
from ollama_code.goal_runtime import validate_goal_report
from ollama_code.goals import GoalStore
from ollama_code.runstore import RunStore
from ollama_code.ollama import ChatResponse
from ollama_code.remote import _consume_anthropic_event
from ollama_code.capsules import CapsuleStore
from ollama_code.capsule_execution import run_capsule_request
from ollama_code.evaluations import EvaluationStore, compare_results
from ollama_code.chat_service import ChatService
from ollama_code.evaluation_runtime import run_evaluation_suite

results = []


def record(name, fn):
    try:
        results.append({"probe": name, "observed": fn()})
    except Exception as exc:
        results.append({"probe": name, "probe_error": f"{type(exc).__name__}: {exc}"})


def goal_case():
    workspace = scratch / "goal-workspace"
    workspace.mkdir()
    runs = RunStore(scratch / "goals.sqlite3")
    goals = GoalStore(runs)
    goal = goals.create("completion", "Create required.txt containing ready", execution={
        "provider": "ollama", "model": "fixture", "workspace_root": str(workspace), "runner": "solo",
    })
    run = goals.claim(goal["id"], goal["revision"])["run"]
    runs.admit(run["id"])
    runs.set_state(run["id"], "running")
    report = validate_goal_report({"status": "complete", "summary": "Finished",
                                   "evidence": ["All checks passed."]})
    goals.report(goal["id"], run["id"], goal["revision"], **report)
    result = goals.reconcile_run(goal["id"], run["id"])
    return {"goal_status": result["status"], "required_file_exists": (workspace / "required.txt").exists(),
            "tools_or_tests_executed": 0}


def progress_case():
    runs = RunStore(scratch / "progress.sqlite3")
    goals = GoalStore(runs)
    goal = goals.create("progress", "Create a result", execution={
        "provider": "ollama", "model": "fixture", "workspace_root": str(scratch), "runner": "solo",
    })
    states = []
    for i in range(5):
        goal = goals.get(goal["id"])
        run = goals.claim(goal["id"], goal["revision"])["run"]
        runs.admit(run["id"])
        runs.set_state(run["id"], "running")
        goals.report(goal["id"], run["id"], goal["revision"], status="continue",
                     summary=f"Still investigating, attempt {i + 1}", evidence=["No new result"],
                     next_step="Continue investigating")
        runs.set_state(run["id"], "completed")
        result = goals.reconcile_run(goal["id"], run["id"])
        states.append({"status": result["status"], "no_progress_count": result["no_progress_count"]})
    return {"turns_with_no_actions": 5, "states": states}


def make_core(name):
    workspace = scratch / name
    workspace.mkdir()
    return AgentCore(model="fixture", cwd=str(workspace), config={"provider": "ollama", "auto_compact": False})


def compaction_case():
    core = make_core("compaction")
    core.messages = [{"role": "system", "content": "fixture"},
                     {"role": "user", "content": "Request details " + "x" * 2100 + " NEVER_CHANGE_PUBLIC_API"},
                     {"role": "assistant", "content": "I will inspect the tests."},
                     {"role": "tool", "name": "bash", "content": "VERIFIED_TEST_FAILURE_TOKEN"},
                     {"role": "assistant", "content": "Investigating."}]
    captured = []
    def summarize(model, messages, **kwargs):
        captured.extend(messages)
        return ChatResponse(content_parts=["Summary"], prompt_eval_count=600, eval_count=25)
    core.client = SimpleNamespace(chat_stream=summarize)
    core._emit_info = lambda: None
    outcome = core._slash_compact()
    sent = json.dumps(captured)
    return {"compaction_returned_error": bool(outcome.get("error")),
            "late_user_constraint_in_summary_input": "NEVER_CHANGE_PUBLIC_API" in sent,
            "test_result_in_summary_input": "VERIFIED_TEST_FAILURE_TOKEN" in sent,
            "provider_reported_tokens": 625,
            "core_recorded_tokens": core.total_prompt_tokens + core.total_completion_tokens}


def output_limit_case():
    core = make_core("output-limit")
    core.messages = [core.system_message(), {"role": "user", "content": "Explain all five requirements."}]
    core.context_limit = 128000
    core._stream_response = lambda: ChatResponse(content_parts=["First requirement..."], done=True,
                                                 done_reason="length", prompt_eval_count=100, eval_count=10)
    core._emit_info = lambda: None
    events = []
    core.on_event(events.append)
    core._run_response_loop(lambda *_: "deny")
    return {"terminal_reason": core.last_turn_result["reason"],
            "incomplete_warning_emitted": any("incomplete" in str(e.get("text", "")) for e in events)}


def anthropic_cache_case():
    response = ChatResponse()
    usage = {"input_tokens": 100, "cache_read_input_tokens": 5000, "cache_creation_input_tokens": 2000}
    _consume_anthropic_event({"type": "message_start", "message": {"usage": usage}},
                              response, {}, {}, None, None)
    return {"provided_usage": usage, "recorded_prompt_tokens": response.prompt_eval_count,
            "provider_fields": response.provider_fields}


def capsule_baseline_case():
    workspace = scratch / "capsule"
    workspace.mkdir()
    (workspace / "app.py").write_text("original")
    (workspace / "schema.json").write_text("original dependency")
    store = CapsuleStore(str(workspace), path=scratch / "capsules.sqlite3")
    capsule = store.create({"title": "Dependency fixture", "request": "Update app using schema",
        "plan": {"steps": ["Update app"], "step_details": [{"id": "step-1", "title": "Update app",
                  "files": ["app.py"], "checks": ["Check output"]}]},
        "recipe": {"planner_profile_id": "planner", "executor_profile_id": "writer"}})
    (workspace / "schema.json").write_text("changed dependency")
    unlisted_change = store.validate(capsule["id"])
    (workspace / "app.py").write_text("completed first step")
    partial_execution = store.validate(capsule["id"])
    return {"unlisted_dependency_change": unlisted_change, "own_partial_execution_change": partial_execution}


def evaluation_case(seed_runs=False):
    suffix = "seeded" if seed_runs else "normal"
    core = make_core("evaluation-source-" + suffix)
    for args in (["init", "-q"], ["config", "user.name", "Audit fixture"],
                 ["config", "user.email", "audit@example.invalid"]):
        subprocess.run(["git", *args], cwd=core.cwd, check=True, capture_output=True)
    (Path(core.cwd) / "fixture.txt").write_text("fixture")
    subprocess.run(["git", "add", "fixture.txt"], cwd=core.cwd, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=core.cwd, check=True, capture_output=True)
    ChatService.background_probes = False
    parent = ChatService(core)
    parent.run_store = RunStore(scratch / ("evaluations-" + suffix + ".sqlite3"))
    store = EvaluationStore(parent.run_store)
    suite = store.save_suite({"name": "False success fixtures", "workspace_root": core.cwd, "cases": [
        {"id": "limit", "prompt": "LIMIT", "target": "solo", "mode": "read_only",
         "assertions": [{"kind": "output_contains", "value": "partial"}]},
        {"id": "rubric", "prompt": "RUBRIC", "target": "solo", "mode": "read_only",
         "rubric": "The answer must contain a complete correct solution, not partial work."},
    ]})
    def fake_turn(self, text, *args, **kwargs):
        self.last_turn_result = {"reason": "max_iterations" if text == "LIMIT" else "complete", "model_calls": 1}
        self.messages.append({"role": "assistant", "content": "partial"})
    evaluation_id = "audit-" + suffix
    if seed_runs:
        # Diagnostic precondition only: create the run records that the real
        # runner creates too late. This does not alter production source.
        for i in range(2):
            parent.run_store.start_run(f"eval-{evaluation_id[:12]}-{i + 1}")
    try:
        with patch.object(AgentCore, "run_turn", fake_turn):
            run_evaluation_suite(parent, suite, {}, {}, evaluation_id, lambda *_: None)
    except Exception as exc:
        return {"run_records_precreated_for_diagnosis": seed_runs,
                "runtime_exception": f"{type(exc).__name__}: {exc}",
                "case_results": store.results(suite["id"])}
    return {"run_records_precreated_for_diagnosis": seed_runs, "case_results": [
        {key: result.get(key) for key in ("case_id", "state", "rubric_score", "rubric_subjective", "estimated_cost", "error")}
        for result in store.results(suite["id"])]}


def capsule_checkout_case():
    source = scratch / "capsule-source"
    execution = scratch / "capsule-execution"
    source.mkdir()
    execution.mkdir()
    (source / "app.py").write_text("approved source")
    (execution / "app.py").write_text("divergent execution contents")
    store = CapsuleStore(str(source))
    capsule = store.create({"title": "Checkout binding", "request": "Update app",
        "plan": {"steps": ["Update app"], "step_details": [{"id": "step-1",
                 "title": "Update app", "files": ["app.py"]}]},
        "recipe": {"planner_profile_id": "planner", "executor_profile_id": "worker"}})
    events = []
    dispatched = []
    svc = SimpleNamespace(core=SimpleNamespace(workspace_root=str(source), cwd=str(execution), identity_mode=False),
        run_store=SimpleNamespace(run=lambda _: {"state": "completed"}), emit=events.append)
    profile = {"id": "worker", "name": "Worker", "model": "fixture", "role": "implementer",
        "access_ceiling": "workspace_write", "metering": "self_hosted",
        "route": {"provider": "ollama", "host": "http://127.0.0.1:11434"}}
    def run_team(svc, *args):
        dispatched.append((Path(svc.core.cwd) / "app.py").read_text())
    run_capsule_request(svc, "Run saved plan", {"id": capsule["id"], "revision": 1,
        "stage": "execute", "profiles": [profile]}, None, None, "checkout-probe",
        run_user=lambda *_: None, run_team=run_team)
    return {"source_baseline_valid": store.validate(capsule["id"])["valid"],
        "execution_dispatched": bool(dispatched), "execution_file_contents": dispatched,
        "errors": [e for e in events if e.get("type") == "error"]}


def comparison_case():
    return compare_results([
        {"target": "solo", "provider": "anthropic", "model": "model-a", "state": "passed", "duration_ms": 100},
        {"target": "solo", "provider": "openai", "model": "model-b", "state": "failed", "duration_ms": 300},
    ])


with patch.object(socket.socket, "connect", side_effect=RuntimeError("Network forbidden in offline audit")):
    for name, fn in [
        ("completion_without_recorded_verification", goal_case),
        ("no_progress_with_paraphrased_reports", progress_case),
        ("compaction_constraint_evidence_and_metering", compaction_case),
        ("output_limit_terminal_status", output_limit_case),
        ("anthropic_cached_input_accounting", anthropic_cache_case),
        ("capsule_baseline_scope_and_partial_run", capsule_baseline_case),
        ("capsule_baseline_checked_against_source_instead_of_execution_checkout", capsule_checkout_case),
        ("evaluation_startup", evaluation_case),
        ("evaluation_limit_and_unexecuted_rubric_after_precreating_runs", lambda: evaluation_case(True)),
        ("comparison_configuration_identity", comparison_case),
    ]:
        record(name, fn)

print(json.dumps({"method": "Offline production-code probes with synthetic provider responses; network blocked",
                  "results": results}, indent=2))
isolated.cleanup()
