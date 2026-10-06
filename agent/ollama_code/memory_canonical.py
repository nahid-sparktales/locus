"""Locus profile and identity bindings for the package's canonical vault."""
from __future__ import annotations

import contextlib
from dataclasses import replace
from functools import wraps
from pathlib import Path

from locus_memory.compat.canonical_vault import CanonicalMemoryVault as PackageCanonicalMemoryVault
from locus_memory.errors import MemoryEngineError
from locus_memory.models import Actor, Operation, PartitionRef

from .memory import MemoryError


def _synchronized(method):
    """Keep every compatibility read/write on the same Markdown boundary."""
    @wraps(method)
    def call(self, *args, **kwargs):
        try:
            with self.mutation(workspace=kwargs.get("workspace"), agent_id=kwargs.get("agent_id"),
                               scopes=kwargs.get("scopes")):
                result = method(self, *args, **kwargs)
                return result
        except (MemoryEngineError, OSError) as exc:
            raise MemoryError(str(exc)) from exc
    return call


class _MaintenanceView:
    """Host authority for file edits; grants stay bound to the caller's scopes."""
    def __init__(self, vault, workspace, agent_id, scopes=None):
        self.engine, self.partition = vault.engine, vault.partition
        access, selected = vault._access(workspace, agent_id, scopes)
        self.access = replace(access, actor=Actor.USER, operations=frozenset({
            Operation.READ, Operation.WRITE, Operation.PROPOSE, Operation.APPROVE, Operation.FORGET}))
        self.selected = selected
        self._shape, self._scope_name = vault._shape, vault._scope_name

    def _access(self, *_args, **_kwargs):
        return self.access, self.selected


class CanonicalMemoryVault(PackageCanonicalMemoryVault):
    def __init__(self, app_dir: Path | str, *, edition: str = "locus", workspace: str = "",
                 agent_id: str = "primary", actor: Actor = Actor.USER,
                 scopes: tuple[str, ...] | list[str] | None = None) -> None:
        from .memory_adapter import LocusKeyProvider
        from .memory_capabilities import memory_capabilities

        keys = LocusKeyProvider(Path(app_dir))

        super().__init__(
            Path(app_dir) / "memory-engine", keys,
            partition=PartitionRef(edition.lower(), "default"), workspace=workspace,
            agent_id=agent_id, actor=actor, scopes=scopes,
            principal="locus-local-user", host_name="locus",
            host=memory_capabilities(app_dir, edition, keys),
        )
        self._synchronizing = False

    def _reconcile(self, view, workspace, agent_id):
        from .memory_intelligence import bind_sources, consolidate_memories, inspect_staleness
        from .memory_markdown import reconcile

        report = reconcile(self.engine, view.access, scopes=view.selected)
        if report["created"] or report["updated"]:
            for item in PackageCanonicalMemoryVault.list(self, workspace=workspace,
                    agent_id=agent_id, scopes=view.selected):
                bind_sources(view, item["id"], workspace=workspace, agent_id=agent_id)
            consolidate_memories(view, workspace=workspace, agent_id=agent_id)
        report["sources"] = inspect_staleness(view, workspace=workspace, agent_id=agent_id)
        if report["sources"]["marked_stale"] or report["created"] or report["updated"]:
            reconcile(self.engine, view.access, scopes=view.selected)
        return report

    @contextlib.contextmanager
    def mutation(self, *, workspace=None, agent_id=None, scopes=None):
        """Also used by host brokers that call a revision-bound engine operation."""
        from .memory_markdown import storage_lock

        workspace = self.workspace if workspace is None else workspace
        agent_id = self.agent_id if agent_id is None else agent_id
        with storage_lock(self.path.parent / "memories"):
            if self._synchronizing:
                yield
                return
            view = _MaintenanceView(self, workspace, agent_id, scopes)
            self._synchronizing = True
            try:
                self._reconcile(view, workspace, agent_id)
                yield
                self._reconcile(view, workspace, agent_id)
            finally:
                self._synchronizing = False

    def synchronize(self, *, workspace=None, agent_id=None, scopes=None):
        from .memory_markdown import storage_lock

        workspace = self.workspace if workspace is None else workspace
        agent_id = self.agent_id if agent_id is None else agent_id
        try:
            with storage_lock(self.path.parent / "memories"):
                return self._reconcile(_MaintenanceView(self, workspace, agent_id, scopes), workspace, agent_id)
        except (MemoryEngineError, OSError) as exc:
            raise MemoryError(str(exc)) from exc

    @_synchronized
    def save(self, value, memory_id="", *, workspace=None, agent_id=None, **kwargs):
        from .memory_intelligence import bind_sources, consolidate_memories, source_fingerprints

        target = self.workspace if workspace is None else workspace
        agent = self.agent_id if agent_id is None else agent_id
        if memory_id and isinstance(value, dict) and "expected_revision" in value:
            revision = value["expected_revision"]
            if type(revision) is not int or revision < 1:
                raise MemoryError("expected_revision must identify the reviewed memory revision")
            access, selected = self._access(workspace, agent_id)
            if self._get(access, selected, memory_id).revision != revision:
                raise MemoryError("The memory changed on this host; reload it before saving your edit.")
        sources = value.get("source_paths") if isinstance(value, dict) else None
        if sources is not None:
            scope = value.get("scope")
            if memory_id and not scope:
                access, selected = self._access(workspace, agent_id)
                scope = self._scope_name(self._get(access, selected, memory_id))
            if scope and scope != "workspace":
                raise MemoryError("File sources require an ordinary workspace memory.")
            source_fingerprints(target, sources)  # Validate before persisting any content.
        result = super().save(value, memory_id, workspace=workspace, agent_id=agent_id, **kwargs)
        view = _MaintenanceView(self, target, agent)
        bound = bind_sources(view, result["id"], sources, workspace=target, agent_id=agent)
        if bound["status"] == "approved":
            consolidate_memories(view, workspace=target, agent_id=agent)
        return {**result, **self._shape(self.engine.get(view.access, result["id"]))}

    @_synchronized
    def status(self, *, workspace=None, agent_id=None):
        from .memory_markdown import storage_status

        return {**super().status(workspace=workspace, agent_id=agent_id),
                **storage_status(self.engine)}

    @_synchronized
    def consolidate(self, *, workspace=None, agent_id=None):
        from .memory_intelligence import consolidate_memories

        target = self.workspace if workspace is None else workspace
        agent = self.agent_id if agent_id is None else agent_id
        return consolidate_memories(_MaintenanceView(self, target, agent), workspace=target, agent_id=agent)

    @_synchronized
    def bind_sources(self, memory_id, *, workspace=None, agent_id=None):
        from .memory_intelligence import bind_sources

        target = self.workspace if workspace is None else workspace
        agent = self.agent_id if agent_id is None else agent_id
        return bind_sources(_MaintenanceView(self, target, agent), memory_id, workspace=target, agent_id=agent)

    @_synchronized
    def refresh_sources(self, memory_id, *, workspace=None, agent_id=None, expected_revision=None):
        from .memory_intelligence import refresh_memory

        if self.actor != Actor.USER:
            raise MemoryError("Only the user can confirm changed memory sources.")
        target = self.workspace if workspace is None else workspace
        agent = self.agent_id if agent_id is None else agent_id
        return refresh_memory(self, memory_id, workspace=target, agent_id=agent,
                              expected_revision=expected_revision)

    @_synchronized
    def approve(self, memory_id, *, workspace=None, agent_id=None, **kwargs):
        result = super().approve(memory_id, workspace=workspace, agent_id=agent_id, **kwargs)
        self.consolidate(workspace=workspace, agent_id=agent_id)
        access, _ = self._access(workspace, agent_id)
        return {**result, **self._shape(self.engine.get(access, memory_id))}


# Nested package calls reuse the surrounding file lock and synchronization pass.
for _name in ("list", "search", "delete", "delete_all", "feedback", "conflicts_for",
              "diagnostics", "maintain", "expire_candidates", "export", "import_values", "import_legacy_note"):
    setattr(CanonicalMemoryVault, _name, _synchronized(getattr(PackageCanonicalMemoryVault, _name)))
