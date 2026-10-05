"""Offline, human-reviewed recovery of memory deletion-checkpoint custody.

Export checkpoint proofs while protection is healthy and keep them outside the
profile backup. Recovery never reconstructs missing deletion entries. It requires
acknowledgment of that loss and advances above the authenticated known checkpoint.
An unreadable/corrupt existing Keychain item is never deleted or overwritten.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from contextlib import closing
from pathlib import Path

from locus_memory import MemoryEngine
from locus_memory.crypto import PartitionKeyring
from locus_memory.errors import MemoryEngineError, ReconciliationRequired, VaultLocked
from locus_memory.host import HostCapabilities
from locus_memory.migrations.state import OwnershipControl
from locus_memory.models import AccessContext, Actor, Operation, PartitionRef
from locus_memory.storage.ledger import DeletionLedger
from locus_memory.storage.partition import GAP_ACKNOWLEDGED_KIND

from .memory_adapter import LocusKeyProvider
from .memory_guard import KeychainLedgerMirror, build_memory_guard, restore_protection_status
from .memory_migration import assert_quiescent
from .memory_ownership import ownership_state, profile_lease
from .product_build import PRODUCT_NAME


def local_checkpoint(app_dir: Path, partition: PartitionRef, keys) -> tuple[int, str]:
    """Read/authenticate the current local checkpoint without opening an engine."""
    directory = app_dir / "memory-engine" / partition.partition_id
    keyring = PartitionKeyring(partition.partition_id, keys)
    try:
        with closing(sqlite3.connect((directory / "memory.sqlite3").as_uri() + "?mode=ro", uri=True)) as db:
            db.execute("PRAGMA query_only=ON")
            keyring.unlock(db)
        return DeletionLedger.inspect_head(directory / "deletion-ledger.sqlite3", lambda text: keyring.token("ledger", text))
    finally:
        keyring.close()


def recover(app_dir: Path, edition: str, guard: KeychainLedgerMirror, keys, *, proof=None,
            acknowledge_lost_history=False, acknowledge_latest_proof=False, apply=False) -> dict:
    """Caller holds the exclusive profile lease throughout preview and application."""
    partition = PartitionRef(edition.lower(), "default")
    if ownership_state(app_dir, edition) not in {"package_authoritative", "legacy_retired"}:
        raise ReconciliationRequired("restore recovery requires the existing package-owned profile; no cutover is performed")
    local = local_checkpoint(app_dir, partition, keys)
    preview = guard.recovery_preview(partition.partition_id, local_checkpoint=local, proof=proof)
    preview.update(preview=not apply, local_generation=local[0],
                   warning="Missing deletion history cannot be reconstructed. Acknowledgment accepts that restored records may include previously forgotten information.")
    if not apply:
        return preview
    if not acknowledge_lost_history:
        raise ReconciliationRequired("explicit --acknowledge-lost-deletion-history is required")
    if not preview["recoverable"]:
        raise ReconciliationRequired(preview.get("reason") or "restore the external checkpoint before recovery")
    if preview["state"] == "checkpoint_missing":
        if not acknowledge_latest_proof:
            raise ReconciliationRequired("confirm --proof-is-latest after checking external backups; an old local marker does not establish the lost high-water mark")
        guard.restore_missing_checkpoint(partition.partition_id, proof)
    minimum = int(preview["known_generation"])
    root = app_dir / "memory-engine"
    control = OwnershipControl(root)
    access = AccessContext(principal="locus-memory-recovery", partition=partition, actor=Actor.HOST,
                           operations=frozenset({Operation.ADMIN}), purpose="human-acknowledged deletion-history recovery")
    try:
        with MemoryEngine(root, keys, host=HostCapabilities(ownership=control, ledger_mirror=guard), create_partitions=False) as engine:
            report = engine.reconcile(access, acknowledge_mirror_gap=True)
            if report["deletion_generation"] <= minimum:
                # If the local ledger matched the recovered checkpoint exactly, a
                # durable acknowledgment is still required. The marker has no content.
                context = engine.partition_context(partition)
                context.partition.ledger.append([(GAP_ACKNOWLEDGED_KIND, "keychain-recovery-acknowledged")],
                                                 min_generation=minimum)
                report = engine.reconcile(access, acknowledge_mirror_gap=True)
            if report["deletion_generation"] <= minimum:
                raise ReconciliationRequired("recovery did not advance beyond the authenticated checkpoint")
    finally:
        control.close()
    return {"recovered": True, "previous_known_generation": minimum,
            "deletion_generation": report["deletion_generation"], "lost_history_acknowledged": True,
            "history_reconstructed": False}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-dir", required=True, type=Path)
    parser.add_argument("--edition", choices=("locus", "locusx"), default=PRODUCT_NAME.lower())
    parser.add_argument("action", choices=("status", "export-checkpoint", "preview", "recover"))
    parser.add_argument("--proof-file", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--acknowledge-lost-deletion-history", action="store_true")
    parser.add_argument("--proof-is-latest", action="store_true")
    args = parser.parse_args(argv)
    app_dir = args.app_dir.expanduser().resolve()
    keys = LocusKeyProvider(app_dir)
    try:
        if args.action == "status":
            result = restore_protection_status(app_dir, args.edition, keys)
        else:
            if not (app_dir / "memory" / "master.key").is_file():
                raise VaultLocked("the existing memory custody key is unavailable; recovery never creates a replacement key")
            # Same exclusion contract as cutover; the operation cannot overlap
            # any profile writer, and never reruns the completed cutover.
            with profile_lease(app_dir, exclusive=True):
                assert_quiescent(app_dir)
                guard = build_memory_guard(app_dir, args.edition, keys)
                if not isinstance(guard, KeychainLedgerMirror):
                    raise VaultLocked("the signed memory guard helper is unavailable; use the installed app's helper explicitly for offline recovery")
                if args.action == "export-checkpoint":
                    result = guard.export_checkpoint(PartitionRef(args.edition, "default").partition_id)
                    if args.output is None:
                        raise ValueError("--output is required; keep the checkpoint proof outside profile backups")
                    descriptor = os.open(args.output.expanduser(), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    try:
                        os.write(descriptor, json.dumps(result, indent=2).encode())
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                    result = {"exported": True, "generation": result["checkpoint"][0], "output": str(args.output)}
                else:
                    proof = None
                    if args.proof_file:
                        if args.proof_file.stat().st_size > 8192:
                            raise ValueError("checkpoint proof exceeds the supported size")
                        proof = json.loads(args.proof_file.read_text())
                    apply = args.action == "recover" and args.yes
                    result = recover(app_dir, args.edition, guard, keys, proof=proof, apply=apply,
                        acknowledge_lost_history=args.acknowledge_lost_deletion_history,
                        acknowledge_latest_proof=args.proof_is_latest)
        print(json.dumps(result, indent=2))
        return 2 if result.get("preview") else 0
    except (MemoryEngineError, OSError, ValueError, sqlite3.Error) as exc:
        print(json.dumps({"error": type(exc).__name__, "message": str(exc),
                          "reset_performed": False, "recovery_requires_known_checkpoint": True}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
