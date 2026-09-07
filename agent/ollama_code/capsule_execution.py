"""Execute saved capsule specifications through the existing Locus runtime.

The saved recipe contains profile identifiers only. Routes arrive in memory
from the native credential owner, and execution never calls the plan author.
"""
from __future__ import annotations

import copy
import json
import re
import sqlite3
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .capsules import CapsuleError, CapsuleStore
from .orchestration import MAX_TEAM_JOBS, parse_manifest, validate_dispatch_plan


def execution_manifest(capsule: dict, profiles: list[dict], run_id: str) -> dict:
    recipe = capsule["recipe"]
    executor_id = recipe["executor_profile_id"]
    by_id = {p.get("id"): p for p in profiles if isinstance(p, dict)}
    if executor_id not in by_id:
        raise ValueError("The capsule's implementation profile is unavailable. Choose it explicitly before running.")
    writer = copy.deepcopy(by_id[executor_id])
    writer["role"] = "implementer"
    if writer.get("access_ceiling") not in {"workspace_write", "computer_control"}:
        raise ValueError("The implementation profile needs workspace-write access.")
    # A coordinator is required by the established team runtime. It uses the
    # worker's route, never the premium planning route, including for synthesis.
    coordinator = copy.deepcopy(writer)
    coordinator.update(id="capsule-coordinator", name="Capsule handoff", role="dispatcher",
                       access_ceiling="read_only", instructions="Summarize verified capsule results.")
    members = [coordinator, writer]
    reviewer_id = recipe.get("reviewer_profile_id")
    if reviewer_id:
        if reviewer_id not in by_id:
            raise ValueError("The capsule's review profile is unavailable.")
        reviewer = copy.deepcopy(by_id[reviewer_id])
        reviewer.update(role="reviewer", access_ceiling="read_only")
        # One profile may serve both lanes, but each job needs a unique identity.
        reviewer["id"] = "capsule-reviewer"
        members.append(reviewer)
    for profile in members:
        route = profile.get("route") or {}
        if route.get("provider") in {"chatgpt", "ollama"} or str(route.get("account_kind") or "").lower().replace("_", "") == "kimicode":
            profile["metering"] = "self_hosted"
            profile.pop("input_cost_per_million", None)
            profile.pop("output_cost_per_million", None)
    plan = capsule["plan"]
    details = plan.get("step_details") or [
        {"id": f"step-{i + 1}", "title": title, "instructions": title,
         "dependencies": [], "files": [], "checks": []}
        for i, title in enumerate(plan["steps"])
    ]
    if len(details) > MAX_TEAM_JOBS:
        raise ValueError(f"A capsule can execute at most {MAX_TEAM_JOBS} steps per run. Split this plan first.")
    pending = list(details)
    details = []
    while pending:
        ready = next((step for step in pending if set(step.get("dependencies", [])) <= {s["id"] for s in details}), None)
        if ready is None:
            raise ValueError("The saved plan has missing or cyclic step dependencies.")
        details.append(ready)
        pending.remove(ready)
    jobs = []
    previous = None
    for step in details:
        # Serialize writes even when the author described independent steps.
        dependencies = list(dict.fromkeys([*step.get("dependencies", []), *([previous] if previous else [])]))
        goal = json.dumps({
            "step": step,
            "constraints": plan.get("constraints", []),
            "decisions": plan.get("decisions", []),
            "overall_verification": plan.get("tests", []),
        }, ensure_ascii=False)
        jobs.append({"id": step["id"], "agent_id": executor_id, "kind": "writer",
                     "dependencies": dependencies, "goal":
                     "Implement this saved capsule step. Inspect the named sources, preserve prior steps, "
                     "and perform the specified checks. Report evidence and unresolved blockers truthfully. "
                     "Do not redesign the overall plan or call a different model.\n" + goal})
        previous = step["id"]
    manifest = {
        "run_id": run_id,
        "profiles": members,
        "team": {
            "id": f"capsule-{capsule['id']}", "name": capsule["title"][:64],
            "dispatcher_id": coordinator["id"], "default_writer_id": executor_id,
            "member_ids": [p["id"] for p in members], "use_managed_worktree": False,
            "parallel_writers": False, "dispatch_approval_mode": "automatic", "routing_mode": "manual",
            "maximum_estimated_cost": recipe.get("maximum_estimated_cost") or 0,
            "budget": {"max_jobs": max(len(jobs), 1), "max_rounds": recipe["max_repair_attempts"] + 1,
                       "max_model_calls": recipe["execution_call_limit"], "max_concurrent_calls": 1,
                       "max_metered_tokens": 2_000_000, "call_budget_mode": "fixed"},
            "swarm_policy": {"engine": "locus_managed", "delegation_mode": "flat",
                             "max_total_agents": len(members), "max_depth": 1},
        },
        "capsule": {"id": capsule["id"], "revision": capsule["revision"]},
        "_capsule_plan": {"summary": plan.get("summary") or capsule["request"], "jobs": jobs},
    }
    _, team, parsed, forced = parse_manifest(manifest)
    validate_dispatch_plan(manifest["_capsule_plan"], team, parsed, forced)
    return manifest


def review_request(reviews: list) -> str:
    """An unavailable or malformed reviewer is not evidence of success."""
    revisions = []
    for review in reviews:
        if review.error:
            raise ValueError("The review model could not finish. Retry review or ask the planner for help.")
        raw = str(review.output or "").strip()
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        try:
            result = json.loads(match.group(0) if match else raw)
        except (ValueError, TypeError):
            raise ValueError("The reviewer did not return a verifiable verdict. Review is still required.") from None
        if not isinstance(result, dict) or result.get("verdict") not in {"approved", "revise"}:
            raise ValueError("The reviewer did not return an approved or revise verdict.")
        if result["verdict"] == "revise":
            revisions.append(raw)
    return "\n\n".join(revisions)


def run_capsule_request(svc: Any, text: str, context: dict, attachments: Any,
                        agent_config: Any, run_id: str, *, run_user: Callable,
                        run_team: Callable) -> None:
    store = None
    capsule = None
    reserved = False
    completed = False
    stage = str(context.get("stage") or "")
    try:
        store = CapsuleStore(svc.core.workspace_root or svc.core.cwd)
        if svc.core.identity_mode:
            raise ValueError("Open a regular task to work with capsules.")
        if stage not in {"plan", "execute", "review", "escalate"}:
            raise ValueError("Unknown capsule stage.")
        if context.get("id"):
            capsule = store.get(str(context["id"]))
            if capsule["revision"] != context.get("revision"):
                raise ValueError("The saved capsule changed. Reload it before continuing.")
        elif stage != "plan":
            raise ValueError("Save a capsule plan before running this stage.")
        continuation = context.get("continuation_of_run_id")
        if continuation is not None:
            if stage != "escalate" or not capsule or not isinstance(continuation, str) or not continuation or len(continuation) > 200:
                raise ValueError("Only a planner escalation can continue a clarification.")
            prior = svc.run_store.run(continuation)
            session_id = getattr(getattr(svc.core, "session", None), "session_id", None)
            if not prior or prior.get("state") != "completed" or not session_id or prior.get("session_id") != session_id or not prior.get("workspace_root") or Path(prior["workspace_root"]).resolve() != store.root:
                raise ValueError("The planner clarification must continue a completed run in this task.")
        if stage == "execute":
            validation = store.validate(capsule["id"])
            if not validation["valid"]:
                paths = ", ".join(c["path"] for c in validation["changes"][:5])
                raise ValueError(f"The plan's source files changed ({paths}). Ask the planner to update it first.")
            manifest = execution_manifest(capsule, context.get("profiles") or [], run_id)
        else:
            limit = context.get("call_limit", 12)
            if capsule:
                limit = capsule["recipe"]["planning_call_limit"]
            if type(limit) is not int or not 1 <= limit <= 100:
                raise ValueError("The capsule call limit must be between 1 and 100.")
        if capsule:
            store.record_run(capsule["id"], run_id, stage, "running", expected_revision=capsule["revision"], continuation_of_run_id=continuation, reserve=True)
            reserved = True
        svc.emit({"type": "capsule_stage", "capsule_id": capsule["id"] if capsule else None,
                  "stage": stage, "run_id": run_id, "state": "running"})
        if stage == "execute":
            run_team(svc, text, manifest, attachments)
        else:
            # Plan mode enforces read-only work for authors and reviewers. The
            # exact selected account is already installed on the isolated worker.
            run_user(svc, text, False, attachments, agent_config, "plan", run_id,
                     False, None, limit)
        completed = True
    except (CapsuleError, ValueError) as exc:
        svc.emit({"type": "error", "message": str(exc), "run_id": run_id})
        svc.emit({"type": "turn_done", "reason": "error", "duration_ms": 0, "run_id": run_id})
    finally:
        if reserved:
            try:
                run = svc.run_store.run(run_id) or {}
                state = (run.get("state") or "interrupted") if completed else "failed"
                # A plan may have been revised while its terminal event was
                # delivered. Finish the original link without reserving again.
                store.record_run(capsule["id"], run_id, stage, state)
            except (CapsuleError, OSError, sqlite3.DatabaseError):
                pass
