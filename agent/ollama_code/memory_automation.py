"""Apply the user's automatic-memory setting at a host-owned write boundary.

Agents still create candidates. Only this host broker can apply the standing
setting to a newly created candidate; procedures keep their separate review flow.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import uuid
from contextlib import nullcontext
from dataclasses import replace
from pathlib import Path
from typing import Any

from locus_memory.errors import (
    MemoryEngineError,
    RevisionConflict,
    SensitiveContent,
    SuppressedError,
)
from locus_memory.models import Actor, CandidateProposal, SourceRef

from .memory import MemoryError, MemoryVault

logger = logging.getLogger(__name__)
_DIRECT_STATEMENT = re.compile(
    r"^(?:please\s+)?(?:remember\b|(?:i|we)\s+(?:prefer|always|never)\b|"
    r"my preference\b|(?:always|never)\s|(?:do not|don't)\s|"
    r"(?:we|i)\s+(?:have\s+)?(?:decided|confirmed)\b)", re.IGNORECASE,
)


def auto_save_candidate(candidate: dict, *, policy, workspace: str, agent_id: str,
                        session_id: str = "", run_id: str = "", strict: bool = False) -> dict:
    """Resolve a host-created candidate in its granted scope before saving it.

    The caller supplies the id returned by its own proposal operation, never an
    arbitrary client-selected record. Candidate content and status are reloaded.
    """
    identifier = str(candidate.get("id") or "")
    scopes = tuple(policy.scopes)
    if not identifier or not scopes:
        return candidate
    vault = MemoryVault(workspace=workspace, agent_id=agent_id, actor=Actor.USER, scopes=scopes)
    try:
        current = next((item for item in vault.list(workspace=workspace, agent_id=agent_id,
                                                  scopes=scopes) if item["id"] == identifier), None)
        if current is None:
            raise MemoryError("memory candidate is unavailable in the current scope")
        if hasattr(vault, "bind_sources"):
            current = vault.bind_sources(identifier, workspace=workspace, agent_id=agent_id)
        if (not policy.proposals_enabled or not getattr(policy, "auto_save_enabled", False)
                or current["status"] != "candidate" or current["kind"] == "procedure"):
            return current
        for field, expected in (("source_session_id", session_id), ("source_run_id", run_id)):
            if expected and current.get(field) and current[field] != expected:
                raise MemoryError("memory candidate belongs to another source")
        if vault.conflicts_for(current, workspace=workspace, agent_id=agent_id):
            return current
        # Canonical approval binds the exact revision and rejects a conflict
        # arriving since the preflight. The package retains content/safety gates.
        if hasattr(vault, "engine"):
            access, _ = vault._access(workspace, agent_id, scopes)
            try:
                with (vault.mutation(workspace=workspace, agent_id=agent_id, scopes=scopes)
                      if hasattr(vault, "mutation") else nullcontext()):
                    vault.engine.approve(access, identifier, expected_revision=current["revision"],
                                         expected_conflicts=())
                    if hasattr(vault, "consolidate"):
                        vault.consolidate(workspace=workspace, agent_id=agent_id)
            except RevisionConflict:
                return current
            except MemoryEngineError:
                if strict:
                    raise
                return current
            result = next(item for item in vault.list(workspace=workspace, agent_id=agent_id,
                                                      scopes=scopes) if item["id"] == identifier)
        else:
            result = vault.approve(identifier, workspace=workspace, agent_id=agent_id)
        vault.record_event("approval", "accepted", memory_id=identifier,
                           workspace=workspace, agent_id=agent_id, session_id=session_id,
                           run_id=run_id, reason_code="automatic_save_setting")
        return result
    finally:
        getattr(vault, "close", lambda: None)()


# Routing is about the claim, never the currently open workspace. These markers
# deliberately keep project-specific preferences from becoming personal defaults.
_PROJECT = re.compile(r"\b(?:this|our|the|current)\s+(?:project|workspace|repo(?:sitory)?|codebase|app)\b|\bproject[- ]specific\b", re.I)
_TASK_ONLY = re.compile(r"\b(?:for this (?:task|turn|chat|request)|just (?:this time|for now)|until (?:this|the) task)\b", re.I)
_PROJECT_NOUN = re.compile(r"\b(?:project|workspace|repo(?:sitory)?|codebase)\b", re.I)
_NAMED_CONTEXT = re.compile(r"\b(?:for|in|on|within)\s+(?:the\s+)?(?:[A-Z][\w-]*|[\w-]+[.!]?$)")
_PREFERENCE = re.compile(r"\b(?:prefer|preference|always|never|do not|don't)\b", re.I)
_SECRET = re.compile(r"(?:api[_-]?key|authorization|password|secret|bearer\s+[A-Za-z0-9])", re.I)
_CATEGORIES = {
    "personal_preference": ("personal", "preference"),
    "project_preference": ("workspace", "preference"),
    "project_fact": ("workspace", "fact"),
    "project_decision": ("workspace", "decision"),
    "specialist_lesson": ("agent", "fact"),
}


def automatic_memory_scope(content: str, *, kind: str = "fact", workspace: str = "") -> str | None:
    """Conservative default; an ambiguous named context never becomes personal."""
    if _TASK_ONLY.search(content):
        return None
    if kind == "preference" or _PREFERENCE.search(content):
        project_name = Path(workspace).name if workspace else ""
        named_project = bool(len(project_name) >= 3 and project_name.lower() not in {
            "project", "workspace", "repo", "repository", "home", "companion", "tmp"} and re.search(
            r"(?<![\w-])" + re.escape(project_name) + r"(?![\w-])", content, re.I))
        if _PROJECT.search(content) or named_project:
            return "workspace"
        if _PROJECT_NOUN.search(content) or _NAMED_CONTEXT.search(content):
            return None
        return "personal"
    return "workspace"


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def _normalized(text: str) -> str:
    return " ".join(text.split()).casefold()


def _capture_context(core):
    from .agent_profile_runtime import trusted_memory_agent

    agent_id, configuration = trusted_memory_agent(core)
    policy = configuration.memory_policy
    enabled = not any(getattr(core, name, False) for name in
        ("identity_mode", "memory_evaluation_disabled", "evaluation_read_only", "agent_role_contract"))
    enabled = enabled and policy.proposals_enabled
    if getattr(core, "chatgpt_parity_active", lambda: False)() and not policy.native_codex_enabled:
        enabled = False
    scopes = policy.recall_scopes(just_chat=getattr(core, "agent_mode", "work") == "ask")
    return agent_id, policy, scopes if enabled else (), str(core.workspace_root or core.cwd or "")


def _lesson_authority(core, candidate, workspace, agent_id):
    from .agent_profile_runtime import trusted_memory_agent
    from .memory_learning import TaskVerificationAuthority

    _, configuration = trusted_memory_agent(core)
    if getattr(core, "agent_mode", "work") == "ask" or not configuration.capability_policy.workspace_read:
        return None
    # Only a host-admitted saved profile has a persistent specialist namespace.
    try:
        uuid.UUID(agent_id)
    except (ValueError, TypeError, AttributeError):
        return None
    receipt = candidate.get("verification_receipt") or {}
    if not isinstance(receipt, dict):
        return None
    task_id = candidate.get("task_id") or receipt.get("task_id")
    receipt_ids = candidate.get("receipt_ids") or receipt.get("receipt_ids")
    runs = getattr(core, "usage_store", None)
    if (not runs or not isinstance(task_id, str) or not task_id
            or not isinstance(receipt_ids, list) or not receipt_ids or len(receipt_ids) > 64
            or any(not isinstance(value, str) or not value for value in receipt_ids)):
        return None
    authority = TaskVerificationAuthority(runs, task_id, workspace=workspace, agent_id=agent_id)
    results = [authority.resolve(value) for value in receipt_ids]
    if not all(result and result.trusted and result.task_ref == authority.task_ref
               and result.checks and all(check.passed for check in result.checks if check.required)
               for result in results):
        return None
    return authority


def cleanup_verification_context(core) -> list[dict]:
    """Expose only current successful receipts for this chat's persistent owner."""
    agent_id, _, scopes, workspace = _capture_context(core)
    runs = getattr(core, "usage_store", None)
    session_id = str(getattr(getattr(core, "session", None), "session_id", "") or "")
    if not runs or "agent" not in scopes:
        return []
    try:
        uuid.UUID(agent_id)
    except (ValueError, TypeError, AttributeError):
        return []
    # Bounded discovery is only a prompt hint; each supplied receipt is resolved
    # again from its task and fingerprints before preparation and persistence.
    with runs._connect(readonly=True) as db:
        rows = db.execute("SELECT payload FROM task_records WHERE json_extract(payload, '$.session_id')=? "
            "AND json_extract(payload, '$.agent_id')=? ORDER BY updated_at DESC LIMIT 20",
            (session_id, agent_id)).fetchall()
    result = []
    for row in rows:
        task = json.loads(row[0])
        candidate = {"task_id": task["id"], "receipt_ids": task.get("evidence_ids", [])}
        if _lesson_authority(core, candidate, workspace, agent_id) is not None:
            result.append({**candidate, "objective": str(task.get("request") or "")[:1000],
                           "task_revision": task["revision"]})
    return result


def prepare_cleanup_candidates(core, candidates, operation_id: str, source_records) -> list[dict]:
    """Validate model proposals against retained evidence and freeze host-owned routing.

    The caller persists these specs before saving. No candidate data can supply
    its own owner, approval, evidence text, or claimed verification result.
    """
    from .sessions import strip_prompt_decoration

    if not isinstance(candidates, list) or len(candidates) > 20:
        raise MemoryError("Cleanup must return at most twenty memory candidates.")
    if not isinstance(operation_id, str) or not operation_id:
        raise MemoryError("Cleanup requires a durable operation identifier.")
    agent_id, _, scopes, workspace = _capture_context(core)
    session_id = str(getattr(getattr(core, "session", None), "session_id", "") or "")
    run_id = str(getattr(getattr(core, "tool_ctx", None), "memory_run_id", "") or "")
    sources = {}
    for record in source_records:
        if not isinstance(record, dict):
            continue
        identifier = record.get("source_id") or record.get("id") or record.get("_item_id")
        if isinstance(identifier, str) and identifier and isinstance(record.get("content"), str):
            sources[identifier] = record
    prepared = []
    for index, value in enumerate(candidates):
        if not isinstance(value, dict):
            raise MemoryError("Cleanup memory candidates must be objects.")
        category, content = value.get("category"), value.get("content")
        spec = {"category": category if isinstance(category, str) else "unknown",
                "content": content if isinstance(content, str) else "", "operation_id": operation_id,
                "agent_id": agent_id, "workspace": workspace, "session_id": session_id, "run_id": run_id,
                "source_path": str(getattr(getattr(core, "session", None), "path", "") or ""),
                "idempotency_key": "cleanup-" + _digest([session_id, operation_id, index]),
                "status": "unresolved", "reason": "No durable, source-backed ownership was established."}
        prepared.append(spec)
        ids = value.get("source_ids")
        if (not isinstance(category, str) or category not in _CATEGORIES
                or not isinstance(content, str) or not content.strip()
                or len(content) > 4000 or not isinstance(ids, list) or not ids or len(ids) > 20
                or any(not isinstance(identifier, str) or identifier not in sources for identifier in ids)):
            continue
        content = content.strip()
        evidence = [sources[identifier] for identifier in dict.fromkeys(ids)]
        scope, kind = _CATEGORIES[category]
        if _TASK_ONLY.search(content) or any(_TASK_ONLY.search(str(item["content"])) for item in evidence):
            spec["reason"] = "Task-specific instructions remain in the checkpoint."
            continue
        if scope == "personal":
            routed = [automatic_memory_scope(text, kind="preference", workspace=workspace)
                      for text in [content, *(strip_prompt_decoration(item["content"]) for item in evidence)]]
            if "workspace" in routed:
                scope = "workspace"
            elif None in routed:
                spec["reason"] = "The preference names an ambiguous project or context; keep it in the checkpoint."
                continue
        if _SECRET.search(content):
            spec.update(status="suppressed", reason="Sensitive credential-like content is not captured.")
            continue
        user_evidence = [item for item in evidence if item.get("role") == "user"]
        exact_user = any(_normalized(content) in _normalized(clean)
                         and _DIRECT_STATEMENT.search(clean)
                         for item in user_evidence
                         if (clean := strip_prompt_decoration(item["content"]).strip()))
        if category in ("personal_preference", "project_preference", "project_decision") and not user_evidence:
            spec["reason"] = "Preferences and confirmed decisions require a user source."
            continue
        if category == "specialist_lesson":
            authority = _lesson_authority(core, value, workspace, agent_id)
            if authority is None or _PROJECT.search(content) or re.search(r"(?:^|\s)(?:/|\.\./)", content):
                spec["reason"] = "A reusable specialist lesson requires a saved owner and current successful verification receipts."
                continue
            receipt = value.get("verification_receipt") or {}
            spec.update(task_id=value.get("task_id") or receipt.get("task_id"),
                        receipt_ids=value.get("receipt_ids") or receipt.get("receipt_ids"))
        spec.update(content=content, scope=scope, kind=kind,
            basis="user_stated" if exact_user else "model_interpretation",
            allow_automatic_save=exact_user or category == "specialist_lesson",
            sources=[{"source_id": identifier, "role": sources[identifier].get("role", ""),
                      "fingerprint": hashlib.sha256(sources[identifier]["content"].encode()).hexdigest()}
                     for identifier in dict.fromkeys(ids)],
            status="ready" if scope in scopes else "policy_disabled",
            reason="Source-backed durable knowledge captured during chat cleanup.")
    return prepared


def _check_candidate_sources(core, spec) -> None:
    """Re-read host transcript evidence immediately before each durable write."""
    from .sessions import SessionStore

    path = spec.get("source_path")
    if not path:
        return  # Host tests/legacy direct adapters may supply their own source view.
    current_path = str(getattr(getattr(core, "session", None), "path", "") or "")
    if path != current_path:
        raise MemoryError("The cleanup source transcript changed; the chat was preserved.")
    current = {item["source_id"]: item for item in SessionStore.cleanup_source_records(
        Path(path), include_covered=True)}
    for source in spec["sources"]:
        observed = current.get(source["source_id"])
        if (not observed or observed["content_hash"] != source["fingerprint"]
                or observed["role"] != source["role"]):
            raise MemoryError("Cleanup source evidence changed or disappeared; the chat was preserved.")


def save_cleanup_candidates(core, candidates, operation_id: str, *, auto_save: bool = True) -> list[dict]:
    """Save prepared candidates idempotently and verify their durable current state.

    Real storage failures propagate: cleanup must not erase the source context.
    Pending/conflicting proposals are successful writes, not approved knowledge.
    """
    from locus_memory import MemoryEngine

    results = []
    for spec in candidates:
        agent_id, policy, scopes, workspace = _capture_context(core)
        session_id = str(getattr(getattr(core, "session", None), "session_id", "") or "")
        if (spec.get("operation_id") != operation_id or spec.get("agent_id") != agent_id
                or spec.get("workspace") != workspace or spec.get("session_id") != session_id):
            raise MemoryError("The cleanup memory owner or source changed; prepare cleanup again.")
        base = {"category": spec["category"], "scope": spec.get("scope"),
                "source_ids": [item["source_id"] for item in spec.get("sources", [])],
                "content": spec["content"]}
        if spec["status"] != "ready":
            results.append({**base, "status": spec["status"], "reason": spec["reason"]})
            continue
        scope = spec["scope"]
        if scope not in scopes:
            results.append({**base, "status": "policy_disabled", "reason": "The intended scope is disabled."})
            continue
        authority = None
        if spec["category"] == "specialist_lesson":
            authority = _lesson_authority(core, spec, workspace, agent_id)
            if authority is None:
                raise MemoryError("Specialist lesson verification changed during cleanup.")
        vault = MemoryVault(workspace=workspace, agent_id=agent_id, actor=Actor.USER, scopes=(scope,))
        try:
            if not hasattr(vault, "engine"):
                raise MemoryError("Reliable cleanup requires the canonical memory store.")
            access, _ = vault._access(workspace, agent_id, (scope,))
            sources = [SourceRef(kind="user_action" if item["role"] == "user" else "provider",
                ref="locus-message-" + _digest([session_id, item["source_id"]]), actor=Actor.HOST,
                locator={"kind": "session_message", "session_id": session_id,
                         "message_id": item["source_id"], "role": item["role"]},
                fingerprint=item["fingerprint"], extraction_version="locus-cleanup-v1")
                for item in spec["sources"]]
            sources.append(SourceRef(kind="provider", ref=session_id, actor=Actor.HOST,
                                     locator={"legacy_field": "source_session_id"}))
            if spec["run_id"]:
                sources.append(SourceRef(kind="provider", ref=spec["run_id"], actor=Actor.HOST,
                                         locator={"legacy_field": "source_run_id"}))
            if authority:
                sources.extend(SourceRef(kind="verification_receipt", ref=identifier, actor=Actor.HOST,
                    locator={"task_id": spec["task_id"], "task_ref": authority.task_ref})
                    for identifier in spec["receipt_ids"])
            candidate = CandidateProposal(content=spec["content"], title=spec["content"][:80],
                kind=spec["kind"], scope=vault._target(scope, workspace, agent_id), sources=tuple(sources),
                basis=spec["basis"], proposer="locus-cleanup", rationale=spec["reason"])
            _check_candidate_sources(core, spec)
            with vault.mutation(workspace=workspace, agent_id=agent_id, scopes=(scope,)):
                runtime = vault.engine
                with (MemoryEngine(runtime.root, runtime.keys,
                        host=replace(runtime.host, verification=authority), config=runtime.config)
                      if authority else nullcontext(runtime)) as engine:
                    written = engine.propose(access, candidate, idempotency_key=spec["idempotency_key"])
                current = vault._shape(vault.engine.get(access, written.record.id))
            was_saved = current["status"] == "approved"
            fresh_agent, policy, fresh_scopes, fresh_workspace = _capture_context(core)
            if fresh_agent != agent_id or fresh_workspace != workspace or scope not in fresh_scopes:
                raise MemoryError("The memory grants changed during cleanup; the chat was preserved.")
            _check_candidate_sources(core, spec)
            if authority is not None and _lesson_authority(core, spec, workspace, agent_id) is None:
                raise MemoryError("Specialist lesson verification changed before approval.")
            # A duplicate awaiting review may come from another chat. Reuse it
            # without borrowing that chat's authorization to approve its candidate.
            same_source = all(not current.get(field) or not expected or current[field] == expected
                for field, expected in (("source_session_id", session_id), ("source_run_id", spec["run_id"])))
            if same_source or current["status"] == "approved":
                current = auto_save_candidate(current, policy=replace(policy, scopes=(scope,),
                    auto_save_enabled=bool(policy.auto_save_enabled and auto_save and spec["allow_automatic_save"])),
                    workspace=workspace, agent_id=agent_id, session_id=session_id, run_id=spec["run_id"], strict=True)
            # Always read again through the canonical authority; never acknowledge a
            # model's proposed record or a write result that is no longer visible.
            current = vault._shape(vault.engine.get(access, current["id"]))
            if (_normalized(current["content"]) != _normalized(spec["content"])
                    or current["scope"] != scope or current.get("stale")):
                raise MemoryError("The saved memory changed during cleanup; the chat was preserved.")
            results.append({**base, "status": "already_saved" if was_saved else
                            "approved" if current["status"] == "approved" else "pending",
                            "memory_id": current["id"], "revision": current["revision"],
                            "owner": agent_id if scope == "agent" else workspace if scope == "workspace" else "personal",
                            "already_existing": (written.receipt.status == "noop" or written.receipt.idempotent_replay), "record": current})
        except (SuppressedError, SensitiveContent) as exc:
            results.append({**base, "status": "suppressed", "reason": str(exc)})
        except MemoryEngineError as exc:
            raise MemoryError(str(exc)) from exc
        finally:
            vault.close()
    return results


def capture_user_memory(core, text: str, *, event_id: str = "", auto_save: bool = True) -> list[dict[str, Any]]:
    """Capture one committed direct statement without scanning history or a model."""
    from .sessions import strip_prompt_decoration

    try:
        original = str(text or "")
        text = strip_prompt_decoration(original).strip()
        if (not text or len(text) > 2000 or "\n" in text or "?" in text or "`" in text
                or not _DIRECT_STATEMENT.search(text)):
            return []
        kind = "decision" if re.search(r"\b(?:decided|confirmed)\b", text, re.I) else "preference"
        scope = automatic_memory_scope(text, kind=kind, workspace=str(core.workspace_root or core.cwd or ""))
        if scope is None:
            return []
        category = "project_decision" if kind == "decision" else "project_preference" if scope == "workspace" else "personal_preference"
        path = getattr(getattr(core, "session", None), "path", None)
        if path:
            from .sessions import SessionStore
            records = SessionStore.cleanup_source_records(path, include_covered=True)
            source = next((item for item in reversed(records) if item["role"] == "user"
                and item["content"] == original and (not event_id or item["source_id"] == event_id)), None)
            if source is None:
                return []
            identifier = source["source_id"]
        else:
            identifier = event_id or "direct-" + _digest(text)
        operation_id = "capture-" + _digest(identifier)
        prepared = prepare_cleanup_candidates(core, [{"category": category, "content": text,
            "source_ids": [identifier]}], operation_id,
            [{"source_id": identifier, "role": "user", "content": original}])
        outcomes = save_cleanup_candidates(core, prepared, operation_id, auto_save=auto_save)
        return [result["record"] for result in outcomes if result["status"] in ("approved", "pending")
                and not result.get("already_existing")]
    except (MemoryError, MemoryEngineError, ValueError):
        logger.debug("Automatic memory capture is unavailable")
        return []
