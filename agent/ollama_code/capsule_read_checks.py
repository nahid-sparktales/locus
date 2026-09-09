"""Dependency-ready capsule source collection/checks; no shared-checkout writers."""
import copy
import json
from concurrent.futures import ThreadPoolExecutor

from .capsule_progress import workspace_state
from .ollama import ToolCall
from .orchestration import AgentResult
from .task_state import TaskVerifier


def run_read_wave(svc, prepared, progress, jobs):
    from .server import TeamWriterBudgetPause, _team_checkpoint_state
    policy = svc.core.config.get("parallel_read_policy") or {}
    measured = (policy.get("version") == 1 and policy.get("workload") == "capsule_read_wave" and policy.get("correctness_equal") is True
                and policy.get("median_improvement", 0) >= .10 and policy.get("p95_regression", 1) <= .05)
    parallel = measured and all(c["kind"] in {"file_exists", "file_contains", "json_value"}
                               for job in jobs for c in progress.definition(job.id).get("acceptance_checks", []))
    jobs = jobs[:2] if parallel else jobs[:1]
    baseline = workspace_state(svc.core.cwd)
    for job in jobs:
        progress.start_step(job.id)

    def run(job):
        core = copy.copy(svc.core)
        core.tool_ctx = copy.copy(svc.core.tool_ctx)
        core.tool_ctx.read_files = set()
        core.capsule_runtime = None if parallel else progress
        core.helper_allowed_tools = {"read_file"} if parallel else {"read_file", "bash"}
        step = progress.definition(job.id)
        task_id = f"capsule:{progress.value['id']}:{job.id}"
        progress.tasks.ensure(task_id, request=step["title"], revision=progress.capsule["revision"],
                              workspace=core.workspace_root, execution=core.cwd, plan=step)
        checks = list(step.get("acceptance_checks", []))
        sources = []
        if job.execution_kind == "read":
            for path in dict.fromkeys([*step.get("inputs", []), *step.get("files", [])]):
                call = ToolCall("read_file", {"path": path})
                result = core._run_tool_call(call, svc.decide)
                if not call.execution_receipt.get("ok") or not call.execution_receipt.get("executed"):
                    raise TeamWriterBudgetPause(job.id, "review_required", "A required source could not be read: " + path)
                sources.append({"path": path, "invocation_id": call.execution_receipt["id"], "content": result[:8000]})
                checks.append({"id": "source-" + str(len(sources)), "kind": "file_exists", "path": path, "requirement": "Read " + path})
        verified = TaskVerifier(progress.tasks, task_id, core, prepared.run_id, parallelism=1).verify(checks, svc.decide)
        return job, verified, sources

    with ThreadPoolExecutor(max_workers=2 if parallel else 1, thread_name_prefix="capsule-read") as pool:
        results = list(pool.map(run, jobs))
    if workspace_state(svc.core.cwd) != baseline:
        raise TeamWriterBudgetPause("read-check", "review_required", "Files changed during the read/check stage. Recheck the current inputs.")
    for job, checked, sources in results:
        progress.before = baseline
        progress.step_id = job.id
        progress.finish_step(job.id, svc.decide, checked=checked)
        if checked["verification_status"] != "passed":
            raise TeamWriterBudgetPause(job.id, "review_required", checked["verification_reason"])
        profile = prepared.profiles[job.agent_id]
        result = AgentResult(job.id, profile.id, profile.name, profile.role,
                             json.dumps({"sources": sources, "evidence_ids": checked["evidence_ids"]}), checked["evidence_ids"], 0, 0, 0, model_calls=0)
        prepared.writer_results.append(result)
        prepared.completed_writer_job_ids.add(job.id)
        svc.checkpoint("read_check_complete:" + job.id, _team_checkpoint_state(prepared, "running", svc.current_task))
    svc.core.last_turn_result = {"reason": "complete", "model_calls": 0}
