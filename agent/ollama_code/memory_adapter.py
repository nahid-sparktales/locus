"""Locus bindings for the host-independent locus-memory recall runtime.

Only application key custody, paths/env flags, profile leases, trusted core identity
and prompt/session callbacks live here. Packet selection, shadow comparison, legacy
synchronization, revalidation, archival safety and maintenance live in the package.
"""
from __future__ import annotations

import logging
import os
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import Any

from locus_memory.bootstrap import initialize_fresh_profile
from locus_memory.compat.legacy_vault import legacy_agent_hash, legacy_workspace_hash
from locus_memory.crypto import derive_subkey
from locus_memory.errors import VaultLocked
from locus_memory.migrations.legacy import (
    LegacyImporter as LegacyImporter,  # re-export for existing callers
)
from locus_memory.models import (
    AccessContext,
    Actor,
    ContextPacket,
    Operation,
    PartitionRef,
    ScopeGrants,
)
from locus_memory.models import MemoryKind as MemoryKind
from locus_memory.runtime import (
    LEGACY_RESULTS_HEADER as LEGACY_RESULTS_HEADER,
)
from locus_memory.runtime import (
    MAINTENANCE_INTERVAL_S,
    MODES,
    LegacyRecall,
    RecallRuntime,
    assert_single_memory_layer,
    project_id,
)
from locus_memory.runtime import (
    _legacy_state as _legacy_state,
)

from .sessions import strip_prompt_decoration

logger = logging.getLogger(__name__)
MODE_ENV = "LOCUS_MEMORY_ENGINE_MODE"
ARCHIVE_ENV = "LOCUS_MEMORY_ARCHIVE"
ENGINE_DIR = "memory-engine"
ENGINE_KEY_ID = "locus-v1"
ENGINE_KEY_INFO = "locus-memory/engine/v1"
PROFILE = "default"
ALL_SCOPES = ("personal", "workspace", "agent")
_SYNTHETIC_KEYS = ("_locus_context", "_delivery_id", "_dispatcher_control", "_mcp_observation")

#: purpose -> (actor, operations). User routes act as USER, model tools as AGENT.
_PURPOSES: dict[str, tuple[Actor, frozenset[Operation]]] = {
    "recall": (Actor.USER, frozenset({Operation.READ})),
    "user": (Actor.USER, frozenset({Operation.READ, Operation.WRITE, Operation.APPROVE, Operation.FORGET})),
    "tool": (Actor.AGENT, frozenset({Operation.READ, Operation.PROPOSE})),
    "ingest": (Actor.HOST, frozenset({Operation.INGEST})),
    "maintain": (Actor.HOST, frozenset({Operation.MAINTAIN})),
}
#: The importer needs ADMIN only. It authorizes each propagated deletion against that
#: record's own scope, so the import access carries no grants at all.
_IMPORT_OPERATIONS = frozenset({Operation.ADMIN})


class LocusKeyProvider:
    """Engine master key derived from the existing Locus key custody (``memory.py``).

    ``derive_subkey(legacy master key, 'locus-memory/engine/v1')`` under key id
    ``locus-v1``. A missing key for an existing vault is reported as locked; a new
    legacy key is created only where ``memory._master_key`` itself would create one.
    """

    def __init__(self, app_dir: Path) -> None:
        self._memory_dir = Path(app_dir) / "memory"
        self._lock = threading.Lock()
        self._legacy: bytes | None = None
        self._engine: bytes | None = None

    def legacy_key(self) -> bytes:
        from . import memory as legacy_memory

        with self._lock:
            if self._legacy is None:
                try:
                    self._legacy = legacy_memory._master_key(
                        None, self._memory_dir / "master.key",
                        vault_path=self._memory_dir / "memory.sqlite3",
                    )
                except legacy_memory.MemoryError as exc:
                    raise VaultLocked("the Locus memory key is unavailable") from exc
            return self._legacy

    def current_key_id(self) -> str:
        return ENGINE_KEY_ID

    def get_key(self, key_id: str) -> bytes:
        if key_id != ENGINE_KEY_ID:
            raise KeyError(key_id)
        legacy = self.legacy_key()
        with self._lock:
            if self._engine is None:
                self._engine = derive_subkey(legacy, ENGINE_KEY_INFO)
            return self._engine


class MemoryAdapter(RecallRuntime):
    """Map Locus core lifecycle events onto the reusable package runtime."""

    def __init__(
        self, *, app_dir: Path | str, edition: str, mode: str = "disabled",
        archive: bool = False, schedule: Callable[[Callable[[], None]], None] | None = None,
        clock: Callable[[], float] = time.time,
        maintenance_interval_s: float = MAINTENANCE_INTERVAL_S,
        hold_profile_lease: bool = False,
    ) -> None:
        if mode not in MODES:
            raise ValueError(f"memory engine mode must be one of {', '.join(MODES)}")
        self.app_dir = Path(app_dir)
        self.edition = str(edition).strip().lower()
        from .memory_ownership import ownership_state, profile_lease
        ensure_memory_profile(self.app_dir, self.edition)
        self._profile_lease = profile_lease(self.app_dir) if hold_profile_lease else None
        if self._profile_lease is not None:
            self._profile_lease.__enter__()
        try:
            owner = ownership_state(self.app_dir, self.edition)
            partition = PartitionRef(self.edition, PROFILE)
            keys = LocusKeyProvider(self.app_dir)
            from .memory_capabilities import memory_capabilities
            super().__init__(
                root=self.app_dir / ENGINE_DIR, partition=partition, key_provider=keys,
                host=memory_capabilities(self.app_dir, self.edition, keys),
                mode=mode, initial_state=owner, archive=archive,
                legacy_database=self.app_dir / "memory" / "memory.sqlite3",
                legacy_key=keys.legacy_key,
                legacy_access=AccessContext(principal="locus-host", partition=partition, actor=Actor.HOST,
                                            operations=_IMPORT_OPERATIONS, purpose="legacy-shadow-import"),
                maintenance_access=AccessContext(principal="locus-host", partition=partition, actor=Actor.HOST,
                                                 operations=_PURPOSES["maintain"][1], purpose="maintain"),
                schedule=schedule, clock=clock, maintenance_interval_s=maintenance_interval_s,
                layer_validator=lambda text: assert_single_memory_layer(text), log=logger,
            )
        except BaseException:
            if self._profile_lease is not None:
                self._profile_lease.__exit__(None, None, None)
                self._profile_lease = None
            raise

    @classmethod
    def from_environment(cls, *, app_dir: Path | str, edition: str,
                         environ: Mapping[str, str] | None = None, **kwargs: Any) -> MemoryAdapter:
        env = os.environ if environ is None else environ
        raw = str(env.get(MODE_ENV) or "disabled").strip().lower()
        if raw not in MODES:
            logger.warning("%s is not one of %s; the memory engine stays disabled", MODE_ENV, "/".join(MODES))
            raw = "disabled"
        archive = str(env.get(ARCHIVE_ENV) or "").strip() == "1"
        return cls(app_dir=app_dir, edition=edition, mode=raw, archive=archive, **kwargs)

    def active(self, core: Any) -> bool:
        return self.mode != "disabled" and not getattr(core, "identity_mode", False)

    def close(self) -> None:
        try:
            super().close()
        finally:
            lease, self._profile_lease = self._profile_lease, None
            if lease is not None:
                lease.__exit__(None, None, None)

    def access(self, core: Any, purpose: str = "recall", *, scopes: Iterable[str] = ALL_SCOPES,
               just_chat: bool = False, agent_id: str = "primary") -> AccessContext:
        """A trusted AccessContext from host state only (never from client input).

        Ask mode (``just_chat``) drops the workspace grants, mirroring server.py.
        """
        actor, operations = _PURPOSES[purpose]
        workspace = str(core.workspace_root or core.cwd or "")
        scopes = set(scopes)
        projects: set[str] = set()
        agents: set[str] = set()
        legacy: set[str] = set()
        workspace_granted = purpose == "ingest" or ("workspace" in scopes and not just_chat)
        if purpose != "maintain" and workspace_granted and workspace.strip():
            digest = legacy_workspace_hash(workspace)
            projects.add(project_id(digest))
            legacy.add("workspace:" + digest)
        if purpose not in ("ingest", "maintain") and "agent" in scopes and str(agent_id or "").strip():
            agents.add(agent_id)
            legacy.add("agent:" + legacy_agent_hash(agent_id))
        return AccessContext(
            principal=f"locus-{actor.value}", partition=self.partition, actor=actor,
            grants=ScopeGrants(projects=frozenset(projects), agents=frozenset(agents),
                               legacy_targets=frozenset(legacy)),
            operations=operations, purpose=purpose,
        )

    def _prepare_memory(self, core, scopes, agent_id):
        if self.mode != "enabled" or not scopes:
            return
        from .memory import MemoryError
        from .memory_canonical import CanonicalMemoryVault
        from .memory_markdown import MarkdownMemoryError
        from .memory_ownership import ownership_state

        if ownership_state(self.app_dir, self.edition) not in {"package_authoritative", "legacy_retired"}:
            return  # Migration shadow copies remain read-only and SQL-owned.

        try:
            with CanonicalMemoryVault(self.app_dir, edition=self.edition,
                    workspace=str(core.workspace_root or core.cwd or ""),
                    agent_id=agent_id, scopes=tuple(scopes)) as vault:
                vault.synchronize()
        except MemoryError as exc:
            # The runtime drops the packet on storage/source-check failures.
            raise MarkdownMemoryError(str(exc)) from exc

    def _packet(self, core: Any, query: str, policy: Any, *, just_chat: bool,
                agent_id: str) -> tuple[AccessContext, ContextPacket] | None:
        if not policy.automatic_recall_enabled:
            return None
        scopes = policy.recall_scopes(just_chat=just_chat)
        if not scopes:
            return None
        self._prepare_memory(core, scopes, agent_id)
        access = self.access(core, "recall", scopes=scopes, just_chat=just_chat, agent_id=agent_id)
        text = str(query or "").replace("\x00", " ")
        built = self.packet(access, strip_prompt_decoration(text) or text,
                            max_tokens=policy.max_automatic_tokens, max_items=policy.max_automatic_memories,
                            include_personal="personal" in scopes)
        core._memory_empty_packet = built if built and not built[1].items else None
        core._memory_selected_receipt = built[1].receipt_id if built else None
        core._memory_recall_run_id = str(getattr(getattr(core, "tool_ctx", None), "memory_run_id", "") or "standalone")
        return built

    def recall(self, core: Any, query: str, policy: Any, *, just_chat: bool, agent_id: str,
               legacy: Callable[[], LegacyRecall]) -> str:
        core._memory_recall_policy = policy
        core._memory_recall_agent = agent_id
        core._memory_recall_just_chat = just_chat
        core._memory_empty_packet = None
        core._memory_selected_receipt = None
        if getattr(core, "identity_mode", False):
            return ""
        return super().recall(core, legacy=legacy, build_packet=lambda: self._packet(
            core, query, policy, just_chat=just_chat, agent_id=agent_id))

    def revalidate_before_use(self, core: Any) -> None:
        active = self.active(core)
        configuration = getattr(core, "agent_configuration", None)
        if configuration is not None:
            policy = configuration.memory_policy
            just_chat = getattr(core, "agent_mode", "work") == "ask"
            agent_id = str(getattr(core, "agent_id", "primary"))
            previous_policy = getattr(core, "_memory_recall_policy", policy)
            if (policy != previous_policy or agent_id != getattr(core, "_memory_recall_agent", agent_id)
                    or just_chat != getattr(core, "_memory_recall_just_chat", just_chat)):
                # ScopeGrants do not encode the host's personal-memory switch.
                # A changed policy drops the old packet until the next recall.
                active = False
                core._memory_empty_packet = None
                core._memory_selected_receipt = None
            current = self.access(core, scopes=policy.recall_scopes(just_chat=just_chat),
                                  just_chat=just_chat, agent_id=agent_id)
            with self._lock:
                pending = self._pending.get(id(core))
                if pending is not None and pending[0] is core:
                    self._pending[id(core)] = (core, current, pending[2])
            core._memory_recall_policy = policy
            core._memory_recall_agent = agent_id
            core._memory_recall_just_chat = just_chat
            active = active and policy.automatic_recall_enabled and bool(policy.recall_scopes(just_chat=just_chat))
            if active:
                from locus_memory.errors import MemoryEngineError
                try:
                    self._prepare_memory(core, policy.recall_scopes(just_chat=just_chat), agent_id)
                except (MemoryEngineError, OSError) as exc:
                    self._failed("source_check", exc)
                    active = False
                    core._memory_empty_packet = None
                    core._memory_selected_receipt = None
        replacement = self.revalidate(core, str(getattr(core, "memory_context", "") or ""),
                                      active=active)
        if replacement is not None:
            core.memory_context = replacement
            core.reset_system_message()

    def begin_submission(self, core: Any, *, state: str = "selected", permitted: bool = True) -> dict[str, Any] | None:
        """Bind a model attempt to its final packet; errors never invent delivery."""
        if not self.active(core) or self.mode != "enabled":
            return None
        try:
            self.revalidate_before_use(core)
            policy = getattr(core, "_memory_recall_policy", None)
            if policy is None:
                policy = core.agent_configuration.memory_policy
            agent_id = str(getattr(core, "_memory_recall_agent", getattr(core, "agent_id", "primary")))
            just_chat = bool(getattr(core, "_memory_recall_just_chat", False))
            access = self.access(core, scopes=policy.recall_scopes(just_chat=just_chat),
                                 just_chat=just_chat, agent_id=agent_id)
            with self._lock:
                pending = self._pending.get(id(core))
            packet = pending[2] if pending is not None and pending[0] is core else None
            # Never claim the packet was delivered when the host replaced it.
            if packet and str(getattr(core, "memory_context", "")) != packet.text[:24_000]:
                packet = None
            ctx = getattr(core, "tool_ctx", None)
            run_id = str(getattr(ctx, "memory_run_id", "") or getattr(core, "_output_run_id", "") or "standalone")
            empty = getattr(core, "_memory_empty_packet", None)
            if packet is None and empty and getattr(core, "_memory_recall_run_id", None) == run_id:
                packet = self.engine.revalidate_context(access, empty[1])
                if packet.items:
                    packet = None  # no replacement text was actually added to this request
            if not permitted:
                packet = None
            session_id = str(getattr(getattr(core, "session", None), "session_id", "") or "standalone")
            metadata = dict(context_receipt_id=packet.receipt_id if packet else None,
                            selected_context_receipt_id=getattr(core, "_memory_selected_receipt", None),
                            session_id=session_id, run_id=run_id, agent_id=agent_id,
                            turn_id=str(getattr(core, "_memory_turn_id", "") or run_id),
                            attempt_id=uuid.uuid4().hex,
                            state=state if packet and packet.items else "skipped",
                            reason=("policy_disabled" if not permitted else "" if packet and packet.items else "no_eligible_memory"))
            recorded = self.engine.record_context_submission(access, **metadata)
            emit = getattr(core, "_emit", None)
            if emit:
                emit({"type": "memory_submission", "submission_id": recorded["submission_id"]})
            return {"access": access, "metadata": metadata, "submission_id": recorded["submission_id"]}
        except Exception as exc:
            self._failed("submission", exc)
            return None

    def finish_submission(self, handle: dict[str, Any] | None, *, state: str) -> None:
        if handle is None or handle["metadata"]["state"] == "skipped":
            return
        try:
            metadata = {**handle["metadata"], "state": state,
                        "reason": {"submitted": "provider_returned", "failed": "provider_failed"}.get(
                            state, "delivery_unknown")}
            self.engine.record_context_submission(handle["access"], **metadata,
                                                  submission_id=handle["submission_id"])
        except Exception as exc:
            self._failed("submission", exc)

    def continuity_allowed(self, core: Any) -> bool:
        return not getattr(core, "identity_mode", False)

    def on_committed_message(self, core: Any, message: Mapping[str, Any],
                             persisted: Mapping[str, Any] | None = None, *, event_id: str = "") -> None:
        if not self.active(core) or getattr(core, "memory_evaluation_disabled", False):
            return
        record = persisted if persisted is not None else message
        if any(message.get(key) or record.get(key) for key in _SYNTHETIC_KEYS):
            return
        role, text = record.get("role"), record.get("content")
        if role not in ("user", "assistant") or not isinstance(text, str):
            return
        if role == "user":
            from .memory_automation import capture_user_memory

            try:
                capture_user_memory(core, text)
            except Exception as exc:
                # Memory capture must not prevent a committed chat from running.
                self._failed("automatic_capture", exc)
        if not self.archive:
            return
        self.archive_text(
            self.access(core, "ingest"), session_ref=core.session.session_id, role=role,
            text=strip_prompt_decoration(text) if role == "user" else text,
            event_id=event_id or record.get("_item_id") or "", source="locus",
        )

    @staticmethod
    def _clear_prompt_context(core: Any) -> None:
        # Dropping the runtime slot must also drop the text the host already copied
        # into its prompt, including legacy and continuity layers in rollout modes.
        if getattr(core, "memory_context", "") or getattr(core, "continuity_context", ""):
            core.memory_context = core.continuity_context = ""
            core.reset_system_message()

    def on_session_boundary(self, core: Any, reason: str = "") -> None:
        self._clear_prompt_context(core)
        self.session_boundary(core, active=self.active(core) and not getattr(core, "memory_evaluation_disabled", False))

    def on_scope_change(self, core: Any, reason: str) -> None:
        self._clear_prompt_context(core)
        self.scope_change(core, reason, active=self.active(core))


def ensure_memory_profile(app_dir: Path | str, edition: str) -> str:
    """Give a new profile package ownership; preserve every existing ownership state."""
    from .memory_capabilities import memory_capabilities
    from .memory_ownership import profile_lease

    app_dir = Path(app_dir)
    keys = LocusKeyProvider(app_dir)
    return initialize_fresh_profile(
        app_dir / ENGINE_DIR, app_dir / "memory" / "memory.sqlite3", keys,
        host=memory_capabilities(app_dir, edition, keys),
        partition=PartitionRef(edition.lower(), PROFILE),
        initialization_lock=app_dir / ".memory-initialize.lock",
        lease=lambda: profile_lease(app_dir, exclusive=True),
    )


def ensure_memory_adapter(core: Any) -> MemoryAdapter:
    """Attach an owned adapter to standalone writers/helpers on their first recall."""
    adapter = getattr(core, "memory_adapter", None)
    if adapter is None:
        from . import paths
        from .product_build import PRODUCT_NAME
        adapter = MemoryAdapter.from_environment(
            app_dir=paths.APP_DIR, edition=PRODUCT_NAME, hold_profile_lease=True,
        )
        core.memory_adapter = adapter
    return adapter


__all__ = [
    "ARCHIVE_ENV", "ENGINE_DIR", "ENGINE_KEY_ID", "ENGINE_KEY_INFO", "MODE_ENV", "MODES",
    "LegacyRecall", "LocusKeyProvider", "MemoryAdapter", "assert_single_memory_layer", "project_id",
    "ensure_memory_adapter", "ensure_memory_profile",
]
