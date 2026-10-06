"""Apply the user's automatic-memory setting at a host-owned write boundary.

Agents still create candidates. Only this host broker can apply the standing
setting to a newly created candidate; procedures keep their separate review flow.
"""
from __future__ import annotations

import logging
import re
from contextlib import nullcontext
from dataclasses import replace
from typing import Any

from locus_memory.errors import MemoryEngineError
from locus_memory.learning.selected_chat import review_selected_chat
from locus_memory.models import Actor

from .memory import MemoryError, MemoryVault

logger = logging.getLogger(__name__)
_DIRECT_STATEMENT = re.compile(
    r"^(?:please\s+)?(?:remember\b|(?:i|we)\s+(?:prefer|always|never)\b|"
    r"my preference\b|(?:always|never)\s|(?:do not|don't)\s|"
    r"(?:we|i)\s+(?:have\s+)?(?:decided|confirmed)\b)", re.IGNORECASE,
)


def auto_save_candidate(candidate: dict, *, policy, workspace: str, agent_id: str,
                        session_id: str = "", run_id: str = "") -> dict:
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
            except MemoryEngineError:
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


class _CaptureVault:
    """Bind the package's selected-chat extraction to this turn's allowed scope."""
    def __init__(self, vault, scope: str):
        self.vault, self.scope = vault, scope

    def list(self, **kwargs):
        return self.vault.list(scopes=(self.scope,), **kwargs)

    def save(self, value, **kwargs):
        content = value["content"]
        return self.vault.save({**value, "scope": self.scope, "title": content[:80],
            "reason": "Direct durable user statement captured under the memory setting.",
            "kind": "decision" if re.search(r"\b(?:decided|confirmed)\b", content, re.I) else "preference"},
            **kwargs)

    def record_event(self, *args, **kwargs):
        return self.vault.record_event(*args, **kwargs)


def capture_user_memory(core, text: str) -> list[dict[str, Any]]:
    """Capture one committed user statement without scanning history or using a model."""
    from .agent_profile_runtime import trusted_memory_agent
    from .sessions import strip_prompt_decoration

    if (getattr(core, "identity_mode", False) or getattr(core, "memory_evaluation_disabled", False)
            or getattr(core, "evaluation_read_only", False) or getattr(core, "agent_role_contract", "")):
        return []
    try:
        agent_id, configuration = trusted_memory_agent(core)
        policy = configuration.memory_policy
        if not policy.proposals_enabled:
            return []
        if getattr(core, "chatgpt_parity_active", lambda: False)() and not policy.native_codex_enabled:
            return []
        scopes = policy.recall_scopes(just_chat=getattr(core, "agent_mode", "work") == "ask")
        if not scopes:
            return []
        text = strip_prompt_decoration(str(text or "")).strip()
        # Extraction is deliberately narrow: quoted content, code, questions and
        # long/multiline requests are not evidence of a durable user statement.
        if (not text or len(text) > 2_000 or "\n" in text or "?" in text or "`" in text
                or not _DIRECT_STATEMENT.search(text)):
            return []
        scope = next(name for name in ("workspace", "personal", "agent") if name in scopes)
        policy = replace(policy, scopes=(scope,))
        workspace = str(core.workspace_root or core.cwd or "")
        session_id = str(getattr(getattr(core, "session", None), "session_id", "") or "")
        run_id = str(getattr(getattr(core, "tool_ctx", None), "memory_run_id", "") or "")
        vault = MemoryVault(workspace=workspace, agent_id=agent_id, actor=Actor.USER, scopes=(scope,))
        try:
            candidates = review_selected_chat(_CaptureVault(vault, scope), [{"role": "user", "content": text}],
                workspace=workspace, agent_id=agent_id, session_id=session_id, run_id=run_id)
        finally:
            getattr(vault, "close", lambda: None)()
        result = []
        for candidate in candidates:
            try:
                result.append(auto_save_candidate(candidate, policy=policy, workspace=workspace,
                    agent_id=agent_id, session_id=session_id, run_id=run_id))
            except MemoryError:
                # A changed/conflicting candidate remains in the Inbox for review.
                result.append(candidate)
        return result
    except (MemoryError, ValueError):
        logger.debug("Automatic memory capture is unavailable")
        return []
