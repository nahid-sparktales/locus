"""Turn-scoped memory inspection and policy-controlled helper promotion."""
from __future__ import annotations

import hashlib
from contextlib import nullcontext
from dataclasses import replace
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Body, HTTPException, Query
from locus_memory.errors import MemoryEngineError, NotFound
from locus_memory.models import Actor, CandidateProposal, Scope, SourceRef

from ..agent_profile_runtime import saved_memory_agent, trusted_memory_agent
from ..helper_retrieval import helper_identity
from ..memory_adapter import ensure_memory_adapter
from ..memory_policy import MemoryPolicy
from .continuity import ServiceDependency


def _run(service, run_id):
    run = service.run_store.run(run_id)
    core = service.core
    if (not run or core.identity_mode or (run.get("manifest") or {}).get("identity_mode")
            or Path(run.get("workspace_root") or ".").resolve()
            != Path(core.workspace_root or core.cwd or ".").resolve()):
        raise HTTPException(404, "memory run not found in this workspace")
    return run


def _agents(service, run):
    manifest = run.get("manifest") or {}
    identities = {str(manifest.get("memory_agent_id") or "primary"): MemoryPolicy.parse(manifest.get("memory_policy"))}
    for profile in manifest.get("profiles") or []:
        if isinstance(profile, dict) and profile.get("id"):
            identities[str(profile["id"])] = MemoryPolicy.parse((profile.get("behavior") or {}).get("memory_policy"))
    for attempt in run.get("attempts") or []:
        identity = str(attempt.get("agent_id") or "")
        if identity:
            identities.setdefault(identity, MemoryPolicy.parse(manifest.get("memory_policy")))
            identities.setdefault(helper_identity(run["id"], identity), MemoryPolicy.parse(manifest.get("memory_policy")))
    return identities


def _saved_owner(run, agent_id):
    """Saved profiles and ephemeral helpers are identified by owning run data."""
    manifest = run.get("manifest") or {}
    profiles = {str(item["id"]) for item in manifest.get("profiles") or []
                if isinstance(item, dict) and item.get("id")}
    root_id = str(manifest.get("memory_agent_id") or "primary")
    if root_id != "primary":
        profiles.add(root_id)
    attempts = run.get("attempts") or []
    derived = next((item for item in attempts if item.get("agent_id")
                    and helper_identity(run["id"], item["agent_id"]) == agent_id), None)
    if derived is None and agent_id in profiles:
        return agent_id
    by_node = {str(item.get("node_id") or item.get("job_id") or ""): item for item in attempts}
    child = derived or next((item for item in attempts if item.get("agent_id") == agent_id), None)
    visited = set()
    while child:
        node = str(child.get("parent_node_id") or "")
        if not node or node in visited:
            break
        visited.add(node)
        child = by_node.get(node)
        if child and str(child.get("agent_id") or "") in profiles:
            return str(child["agent_id"])
    return root_id if root_id in profiles else None


def _access(service, adapter, agent_id, policy, run):
    current_id, configuration = _current_agent(service)
    current = configuration.memory_policy
    target = current
    owner = _saved_owner(run, agent_id)
    if owner and owner != current_id:
        try:
            _, saved = saved_memory_agent(owner)
            target = saved.memory_policy
        except ValueError:
            # Removed saved profiles cannot regain access from old manifests.
            target = MemoryPolicy.parse({"recall_enabled": False, "scopes": []})
    scopes = tuple(scope for scope in policy.scopes if scope in current.scopes and scope in target.scopes)
    if not current.recall_enabled or not target.recall_enabled:
        scopes = ()
    return adapter.access(service.core, scopes=scopes, agent_id=agent_id), scopes


def _current_agent(service):
    try:
        return trusted_memory_agent(service.core)
    except ValueError as exc:
        raise HTTPException(409, "The conversation's memory agent is unavailable.") from exc


def memory_submissions(service: ServiceDependency, run_id: str = Query(min_length=1),
                       turn_id: str | None = None) -> dict[str, Any]:
    run = _run(service, run_id)
    adapter = ensure_memory_adapter(service.core)
    result = []
    try:
        for agent_id, policy in _agents(service, run).items():
            access, _ = _access(service, adapter, agent_id, policy, run)
            result.extend(adapter.engine.list_context_submissions(
                access, session_id=run.get("session_id") or "standalone", run_id=run_id,
                agent_id=agent_id, turn_id=turn_id))
    except MemoryEngineError as exc:
        raise HTTPException(422, "memory inspection is unavailable") from exc
    return {"submissions": sorted(result, key=lambda item: (item["created_at"], item["attempt_id"])),
            "helpers": [{"attempt_id": item["attempt_id"], "agent_id": item["agent_id"]}
                        for item in run.get("attempts") or []
                        if item.get("state") == "completed" and (item.get("result") or {}).get("output")],
            "note": "Submission is host delivery evidence, not proof the model used a memory."}


def memory_submission(submission_id: str, service: ServiceDependency,
                      run_id: str = Query(min_length=1), include_content: bool = False) -> dict[str, Any]:
    run = _run(service, run_id)
    adapter = ensure_memory_adapter(service.core)
    try:
        for agent_id, policy in _agents(service, run).items():
            access, scopes = _access(service, adapter, agent_id, policy, run)
            entries = adapter.engine.list_context_submissions(access, session_id=run.get("session_id") or "standalone",
                                                              run_id=run_id, agent_id=agent_id)
            for entry in entries:
                if entry["submission_id"] != submission_id:
                    continue
                if not entry["context_receipt_id"]:
                    return {"submission": entry, "context": None}
                detail = adapter.engine.explain_context(access, entry["context_receipt_id"])
                removed = 0
                for key in ("items", "omissions"):
                    visible = []
                    for item in detail[key]:
                        if not scopes or (not item["scope"] and "personal" not in scopes):
                            if key == "items":
                                removed += 1
                            continue
                        if include_content:
                            try:
                                current = adapter.engine.get(access, item["record_id"])
                                item.update(current_title=current.title, current_content=current.content)
                            except NotFound:
                                continue
                        visible.append(item)
                    detail[key] = visible
                visible_ids = {item["record_id"] for item in detail["items"] + detail["omissions"]}
                detail["conflicts"] = [pair for pair in detail["conflicts"] if all(item in visible_ids for item in pair)]
                if removed:
                    detail["token_count"] = None
                    detail["unavailable_items"] += removed
                selected = entry.get("selected_context_receipt_id")
                if selected and selected != entry["context_receipt_id"]:
                    try:
                        before = adapter.engine.explain_context(access, selected)
                        old = {item["record_id"]: item for item in before["items"]
                               if scopes and (item["scope"] or "personal" in scopes)}
                        current = {item["record_id"]: item for item in detail["items"]}
                        detail["revalidation_changes"] = {
                            "added": sorted(current.keys() - old.keys()),
                            "removed": sorted(old.keys() - current.keys()),
                            "revised": sorted(rid for rid in old.keys() & current.keys()
                                              if old[rid]["compiled_revision"] != current[rid]["compiled_revision"]),
                            "unavailable_before": before["unavailable_items"],
                        }
                    except NotFound:
                        detail["revalidation_changes"] = None
                return {"submission": entry, "context": detail}
    except NotFound as exc:
        raise HTTPException(410, "memory explanation expired or became unavailable") from exc
    except MemoryEngineError as exc:
        raise HTTPException(422, "memory inspection is unavailable") from exc
    raise HTTPException(404, "memory submission not found")


def propose_helper_result(service, run_id: str, attempt_id: str, *, agent: bool = False) -> dict[str, Any]:
    run = _run(service, run_id)
    attempt = next((item for item in run.get("attempts") or [] if item.get("attempt_id") == attempt_id), None)
    if not attempt or attempt.get("state") != "completed":
        raise HTTPException(404, "completed helper attempt not found")
    agent_id, configuration = _current_agent(service)
    policy = configuration.memory_policy
    if "workspace" not in policy.scopes or (agent and not policy.proposals_enabled):
        raise HTTPException(403, "workspace memory proposals are disabled")
    result = attempt.get("result") or {}
    output = str(result.get("output") or "").strip()
    if not output:
        raise HTTPException(422, "this helper has no retained result")
    adapter = ensure_memory_adapter(service.core)
    access = adapter.access(service.core, "tool", scopes=("workspace",), agent_id=agent_id)
    # The host has resolved the retained result itself. It attests provenance,
    # not correctness; PROPOSE grants cannot approve the candidate.
    access = replace(access, actor=Actor.HOST, principal="locus-host-helper-proposal")
    project = next(iter(access.grants.projects), None)
    if not project:
        raise HTTPException(403, "workspace memory is unavailable")
    fingerprint = hashlib.sha256(output.encode()).hexdigest()
    candidate = CandidateProposal(content=output[:16_000], kind="fact", scope=Scope.of(project=project),
        title="Helper discovery", proposer="helper",
        rationale="Retained helper evidence saved according to the agent's memory setting.",
        sources=(SourceRef(kind="provider", ref="helper-" + hashlib.sha256(attempt_id.encode()).hexdigest(),
            actor=Actor.AGENT, fingerprint=fingerprint,
            locator={"run_id": run_id, "attempt_id": attempt_id, "session_id": run.get("session_id"),
                     "agent_id": attempt.get("agent_id")}),))
    from ..memory import MemoryError, MemoryVault
    from ..memory_automation import auto_save_candidate

    workspace = service.core.workspace_root or service.core.cwd
    try:
        with MemoryVault(workspace=workspace, agent_id=agent_id, scopes=("workspace",)) as vault:
            with (vault.mutation() if hasattr(vault, "mutation") else nullcontext()):
                saved = adapter.engine.propose(access, candidate, idempotency_key="helper-" + hashlib.sha256(
                    (run_id + "|" + attempt_id + "|" + fingerprint).encode()).hexdigest())
        memory = auto_save_candidate(
            {"id": saved.record.id}, policy=policy, workspace=workspace, agent_id=agent_id,
            session_id=run.get("session_id") or "", run_id=run_id,
        )
    except (MemoryEngineError, MemoryError) as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"ok": True, "memory_id": memory["id"], "status": memory["status"],
            "requires_human_approval": memory["status"] != "approved"}


def helper_proposal(service: ServiceDependency, body: dict[str, Any] = Body(default_factory=dict)):
    return propose_helper_result(service, str(body.get("run_id") or ""), str(body.get("attempt_id") or ""))


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/memory/submissions", memory_submissions, methods=["GET"])
    router.add_api_route("/api/memory/submissions/{submission_id}", memory_submission, methods=["GET"])
    router.add_api_route("/api/memory/helper-proposals", helper_proposal, methods=["POST"])
