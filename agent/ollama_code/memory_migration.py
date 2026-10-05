"""Offline Locus cutover using the host's partition, mapping and key custody.

Run with ``python -m ollama_code.memory_migration --app-dir PATH ACTION``.
Stop Locus first. Snapshot means the Migrator's encrypted snapshot + shadow import;
cutover and rollback require --yes. No standalone CLI keys are created.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from locus_memory.compat.legacy_vault import LegacyMemoryVault, format_memory_results
from locus_memory.errors import MemoryEngineError, MigrationError, OwnershipFenced
from locus_memory.migrations import legacy
from locus_memory.migrations.session import LegacyMigrationSession
from locus_memory.models import PartitionRef

from .agent_config import MemoryPolicy
from .memory_adapter import LegacyRecall, LocusKeyProvider, MemoryAdapter, _legacy_state, project_id
from .memory_ownership import ownership_state, profile_lease
from .product_build import PRODUCT_NAME


def assert_quiescent(app_dir: Path) -> None:
    """Reject older backends that do not yet participate in the profile lease."""
    processes = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True,
                               text=True, timeout=10, check=True)
    for line in processes.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or fields[0] == str(os.getpid()):
            continue
        command = fields[1]
        if (" -m ollama_code.server" in command or " -m ollama_code.runtime " in command
                or "/Contents/MacOS/Locus" in command or "/Contents/Helpers/LocusRuntime" in command):
            raise MigrationError("a Locus app or backend is running; stop it before offline migration")
    database = app_dir / "memory" / "memory.sqlite3"
    files = [str(path) for path in (database, Path(str(database) + "-wal"),
                                   Path(str(database) + "-shm")) if path.exists()]
    if files:
        result = subprocess.run(["/usr/sbin/lsof", "-t", *files], capture_output=True,
                                text=True, timeout=10, check=False)
        if result.returncode not in (0, 1) or result.stderr.strip():
            raise MigrationError("cannot confirm the legacy vault is quiescent")
        other = [pid for pid in result.stdout.split() if pid != str(os.getpid())]
        if other:
            raise MigrationError("legacy vault is open in another process; stop Locus and retry")


def host_mapping(database: Path) -> legacy.LegacyMapping:
    state = _legacy_state(database)
    return legacy.LegacyMapping(workspaces={
        digest: project_id(digest) for digest in (state.workspaces if state else ())
    })


class HostMemoryMigration(LegacyMigrationSession):
    """Bind package migration to Locus paths, keys and offline process checks."""

    def __init__(self, app_dir: Path | str, *, edition: str = PRODUCT_NAME.lower()) -> None:
        self.app_dir = Path(app_dir).expanduser().resolve()
        self.edition = edition.lower()
        database = self.app_dir / "memory" / "memory.sqlite3"
        keys = LocusKeyProvider(self.app_dir)
        from .memory_capabilities import memory_capabilities
        super().__init__(
            self.app_dir / "memory-engine", database, keys,
            partition=PartitionRef(self.edition, "default"), legacy_key=keys.legacy_key,
            mapping=lambda: host_mapping(database),
            lease=lambda: profile_lease(self.app_dir, exclusive=True),
            assert_quiescent=lambda: assert_quiescent(self.app_dir),
            principal="locus-memory-migration",
            host=memory_capabilities(self.app_dir, self.edition, keys),
        )

    def compare(self, queries: list[str], *, workspace: str = "", agent_id: str = "primary") -> dict[str, Any]:
        """Exercise the exact rollout adapter, recording only counts and timing."""
        mode = os.environ.get("LOCUS_MEMORY_ENGINE_MODE", "disabled")
        if mode not in ("shadow", "enabled"):
            raise MigrationError("compare requires LOCUS_MEMORY_ENGINE_MODE=shadow or enabled")
        adapter = MemoryAdapter.from_environment(app_dir=self.app_dir, edition=self.edition)
        core = SimpleNamespace(workspace_root=workspace, cwd=workspace, identity_mode=False,
                               memory_context="", reset_system_message=lambda: None)
        policy = MemoryPolicy()

        def no_writes():
            raise OwnershipFenced("comparison reads the legacy vault without side effects")

        vault = LegacyMemoryVault(self.database, key=self.keys.legacy_key(), write_guard=no_writes)
        comparisons = []
        try:
            for query in queries:
                adapter.last_shadow = None
                results = vault.search(query, workspace=workspace, agent_id=agent_id,
                                       limit=policy.max_automatic_memories)
                expected = LegacyRecall(format_memory_results(results)[:policy.max_automatic_tokens * 4],
                                        tuple(item["id"] for item in results))
                text = adapter.recall(core, query, policy, just_chat=False, agent_id=agent_id,
                                      legacy=lambda expected=expected: expected)
                core.memory_context = text
                adapter.revalidate_before_use(core)
                if mode == "shadow" and (text != expected.text or adapter.last_shadow is None):
                    raise MigrationError("shadow comparison failed or changed legacy context")
                if mode == "enabled":
                    # Do not mistake a fail-closed empty packet for a successful rollout.
                    built = adapter._packet(core, query, policy, just_chat=False, agent_id=agent_id)
                    if built is None:
                        raise MigrationError("enabled context could not be built")
                    count = len(built[1].items)
                    if bool(count) != bool(core.memory_context):
                        raise MigrationError("enabled recall failed to deliver its context packet")
                    comparisons.append({"query_hash": hashlib.sha256(query.encode()).hexdigest()[:12],
                                        "engine_items": count, "context_present": bool(core.memory_context),
                                        "engine_tokens": built[1].token_count})
                else:
                    comparisons.append({"query_hash": hashlib.sha256(query.encode()).hexdigest()[:12],
                                        **adapter.last_shadow, "legacy_prompt_unchanged": True})
            counters = adapter.engine.metrics.snapshot()["counters"]
            if any(value["value"] for name, value in counters.items()
                   if name.endswith(".failed") or name in ("adapter.sync.incomplete", "adapter.layer_violation")):
                raise MigrationError("rollout comparison recorded a memory failure")
        finally:
            adapter.close()
        return {"mode": mode, "queries": comparisons}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-dir", type=Path, required=True)
    parser.add_argument("action", choices=("inventory", "state", "compare", "snapshot", "validate",
                                           "cutover", "rollback", "abort"))
    parser.add_argument("--query", action="append", default=[])
    parser.add_argument("--workspace", default="")
    parser.add_argument("--agent-id", default="primary")
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args(argv)
    app_dir = args.app_dir.expanduser().resolve()
    try:
        if args.action == "inventory":
            database = app_dir / "memory" / "memory.sqlite3"
            if not database.is_file():
                raise MigrationError("the existing Locus memory vault was not found")
            result = legacy.inventory(database, LocusKeyProvider(app_dir).legacy_key(), host_mapping(database))
        elif args.action == "state":
            result = {"state": ownership_state(app_dir, PRODUCT_NAME)}
        else:
            with HostMemoryMigration(app_dir) as host:
                if args.action in ("cutover", "rollback", "abort") and not args.yes:
                    result = {"preview": True, "action": args.action, "state": host.migrator.state().state}
                    if args.action == "rollback":
                        result["plan"] = host.migrator.plan_rollback()
                    print(json.dumps(result, indent=2))
                    return 2
                if args.action == "compare":
                    result = host.compare(args.query or ["preferences", "decisions", "constraints"],
                                          workspace=args.workspace, agent_id=args.agent_id)
                elif args.action == "snapshot":
                    result = host.snapshot()
                elif args.action == "validate":
                    result = host.validate(args.query)
                elif args.action == "cutover":
                    result = host.cutover(args.query)
                elif args.action == "rollback":
                    result = host.rollback()
                else:
                    result = host.migrator.abort_cutover()
        print(json.dumps(result, indent=2))
        if result.get("validated") is False or result.get("cutover") is False:
            return 1
        return 0
    except (MemoryEngineError, OSError, sqlite3.Error, subprocess.SubprocessError) as exc:
        # Engine errors carry no memory content. Do not include tracebacks/locals.
        print(json.dumps({"error": type(exc).__name__, "message": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
