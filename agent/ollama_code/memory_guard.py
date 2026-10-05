"""Signed macOS Keychain custody for deletion-ledger high-water marks.

No keychain is discovered or accessed by the reusable memory package. Source
checkouts without a helper explicitly lack restore protection; an enrolled
profile never silently falls back to that state.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

from locus_memory.crypto import derive_subkey
from locus_memory.errors import IntegrityError, ReconciliationRequired, VaultLocked

SERVICE = "io.sparktales.locus.memory-guard.v1"
HELPER_ID = "io.sparktales.locus.memory-guard"


def _helper_path() -> Path | None:
    override = os.environ.get("LOCUS_MEMORY_GUARD_HELPER", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    for parent in Path(__file__).resolve().parents:
        if parent.name == "Contents" and parent.parent.suffix == ".app":
            path = parent / "Helpers" / "LocusMemoryGuard"
            return path if path.is_file() else None
    return None


class KeychainLedgerMirror:
    def __init__(self, app_dir: Path, edition: str, keys, helper: Path, *, runner=subprocess.run) -> None:
        self.root = Path(app_dir)
        self.edition = edition.lower()
        self.keys = keys
        self.helper = helper
        self.runner = runner
        self._lock = threading.RLock()
        self._seen: dict[str, tuple[int, str] | None] = {}

    def _identity(self, partition: str) -> tuple[str, str, Path, bytes]:
        # Locus engine key rotations do not rename this account: derive from the
        # stable custody root when available, rather than the current DEK/master id.
        key = self.keys.legacy_key() if hasattr(self.keys, "legacy_key") else self.keys.get_key(self.keys.current_key_id())
        guard_key = derive_subkey(key, "locus-memory/keychain-guard/v1")
        identity = json.dumps([self.edition, partition], separators=(",", ":"))
        account = hmac.new(guard_key, ("account|" + identity).encode(), hashlib.sha256).hexdigest()
        token = hmac.new(guard_key, ("enroll|" + identity).encode(), hashlib.sha256).hexdigest()
        return account, token, self.root / "memory-guard" / (account + ".json"), guard_key

    @staticmethod
    def _proof(key: bytes, value: dict) -> str:
        canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hmac.new(key, b"checkpoint-proof/v2|" + canonical, hashlib.sha256).hexdigest()

    def _local_checkpoint(self, path: Path, account: str, key: bytes) -> tuple[int, str] | None:
        if not path.exists():
            return None
        try:
            value = json.loads(path.read_text())
            if value.get("format") == 1:
                expected = hmac.new(key, ("enrolled|" + account).encode(), hashlib.sha256).hexdigest()
                if value != {"format": 1, "account": account, "proof": expected}:
                    raise ValueError("invalid proof")
                return None  # Older enrollment records did not retain a generation.
            proof = value.pop("proof")
            if value.get("account") != account or value.get("format") != 2 or not hmac.compare_digest(proof, self._proof(key, value)):
                raise ValueError("invalid proof")
            return _checkpoint(value.get("checkpoint"))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise IntegrityError("memory restore protection enrollment is corrupt") from exc

    def _marker(self, path: Path, account: str, key: bytes, *, create=False, checkpoint=None) -> bool:
        import fcntl
        # Serialize marker updates across app/CLI instances: a delayed writer
        # must not replace a newer authenticated local high-water mark.
        if not create:
            self._local_checkpoint(path, account, key)
            return path.exists()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(path.with_suffix(".lock"), os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            current = self._local_checkpoint(path, account, key)
            if current is not None and checkpoint is not None:
                if current[0] > checkpoint[0]:
                    raise ReconciliationRequired("Keychain checkpoint is older than the authenticated local high-water mark")
                if current[0] == checkpoint[0] and current != checkpoint:
                    raise IntegrityError("local deletion checkpoint conflicts at the same generation")
            if checkpoint is None:
                raise IntegrityError("enrollment requires an authenticated checkpoint")
            value = {"format": 2, "account": account, "checkpoint": list(checkpoint)}
            value["proof"] = self._proof(key, value)
            temporary = path.with_suffix("." + secrets.token_hex(8) + ".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                os.write(fd, json.dumps(value).encode())
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            return True
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def export_checkpoint(self, partition_id: str) -> dict:
        checkpoint = self.read(partition_id)
        if checkpoint is None:
            raise ReconciliationRequired("restore protection is not enrolled")
        account, _, _, key = self._identity(partition_id)
        value = {"format": 2, "kind": "locus-memory-checkpoint", "account": account,
                 "edition": self.edition, "partition_id": partition_id,
                 "checkpoint": list(checkpoint), "exported_at": time.time()}
        return {**value, "proof": self._proof(key, value)}

    def verify_checkpoint_proof(self, partition_id: str, proof: dict) -> tuple[int, str]:
        account, _, _, key = self._identity(partition_id)
        if not isinstance(proof, dict):
            raise IntegrityError("an authenticated external checkpoint proof is required")
        value = dict(proof)
        signature = value.pop("proof", "")
        if (value.get("format") != 2 or value.get("kind") != "locus-memory-checkpoint"
                or value.get("edition") != self.edition or value.get("partition_id") != partition_id
                or value.get("account") != account or not isinstance(signature, str)
                or not hmac.compare_digest(signature, self._proof(key, value))):
            raise IntegrityError("checkpoint proof is invalid or belongs to another profile")
        return _checkpoint(value.get("checkpoint"))

    def recovery_preview(self, partition_id: str, *, local_checkpoint: tuple[int, str], proof: dict | None) -> dict:
        account, token, marker, key = self._identity(partition_id)
        remembered = self._local_checkpoint(marker, account, key)
        reply = self._request({"operation": "read", "account": account, "token": token})
        current = _checkpoint(reply["checkpoint"]) if reply.get("checkpoint") is not None else None
        if current is not None:
            if remembered and (current[0] < remembered[0] or current[0] == remembered[0] and current[1] != remembered[1]):
                raise ReconciliationRequired("the Keychain item is older than or conflicts with the authenticated enrollment; restore the newer Keychain checkpoint")
            # Existing readable custody uses normal ledger-gap reconciliation.
            known = max(current[0], local_checkpoint[0], remembered[0] if remembered else 0)
            return {"state": "checkpoint_available", "keychain_checkpoint": list(current),
                    "known_generation": known, "next_generation": known + 1, "recoverable": True,
                    "requires_external_proof": False, "lost_history_acknowledgment_required": True}
        if proof is None:
            return {"state": "checkpoint_missing", "known_generation": max(local_checkpoint[0], remembered[0] if remembered else 0),
                    "next_generation": None, "recoverable": False, "requires_external_proof": True,
                    "reason": "No exact external high-water mark survives in Keychain. Supply the newest authenticated exported checkpoint; local markers may have been restored."}
        external = self.verify_checkpoint_proof(partition_id, proof)
        for point in (local_checkpoint, remembered):
            if point is not None and (external[0] < point[0] or external[0] == point[0] and external[1] != point[1]):
                raise ReconciliationRequired("external checkpoint proof is older than or conflicts with authenticated local state")
        return {"state": "checkpoint_missing", "known_generation": external[0],
                "next_generation": external[0] + 1, "recoverable": True,
                "requires_external_proof": True, "lost_history_acknowledgment_required": True,
                "checkpoint": list(external), "external_proof_must_be_latest": True}

    def restore_missing_checkpoint(self, partition_id: str, proof: dict) -> None:
        """Offline recovery only; caller holds exclusive lease and human acknowledgment.

        This never deletes or replaces an existing Keychain value. A corrupt value
        or uncertain generation needs restoration from an external Keychain backup.
        """
        external = self.verify_checkpoint_proof(partition_id, proof)
        account, token, marker, key = self._identity(partition_id)
        with self._lock:
            remembered = self._local_checkpoint(marker, account, key)
            if remembered and (external[0] < remembered[0] or external[0] == remembered[0] and external[1] != remembered[1]):
                raise ReconciliationRequired("the external checkpoint is older than local authenticated enrollment")
            reply = self._request({"operation": "read", "account": account, "token": token})
            current = _checkpoint(reply["checkpoint"]) if reply.get("checkpoint") is not None else None
            if current is not None and current != external:
                raise ReconciliationRequired("Keychain changed; preview recovery again")
            if current is None:
                self._request({"operation": "advance", "account": account, "token": token,
                               "expected": None, "checkpoint": list(external)})
            self._seen[partition_id] = external
            self._marker(marker, account, key, create=True, checkpoint=external)

    def _request(self, body: dict) -> dict:
        try:
            result = self.runner([str(self.helper)], input=json.dumps(body), text=True, capture_output=True,
                                 timeout=15, check=False, env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())})
            if result.returncode != 0 or len(result.stdout) > 8192:
                raise ValueError("guard failed")
            reply = json.loads(result.stdout)
            if not isinstance(reply, dict) or reply.get("ok") is not True:
                raise ValueError("guard rejected")
            return reply
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise VaultLocked("memory restore protection is unavailable; unlock the login Keychain or restore its checkpoint") from exc

    def read(self, partition_id: str) -> tuple[int, str] | None:
        with self._lock:
            account, token, marker, key = self._identity(partition_id)
            enrolled = self._marker(marker, account, key)
            reply = self._request({"operation": "read", "account": account, "token": token})
            value = reply.get("checkpoint")
            if value is None:
                if enrolled:
                    raise ReconciliationRequired("the enrolled memory deletion checkpoint is missing from Keychain")
                checkpoint = None
            else:
                checkpoint = _checkpoint(value)
                self._marker(marker, account, key, create=True, checkpoint=checkpoint)
            self._seen[partition_id] = checkpoint
            return checkpoint

    def write(self, partition_id: str, generation: int, mac: str) -> None:
        generation, mac = _checkpoint((generation, mac))
        with self._lock:
            if partition_id not in self._seen:
                self.read(partition_id)
            previous = self._seen[partition_id]
            if previous is not None and (generation < previous[0] or (generation == previous[0] and mac != previous[1])):
                raise IntegrityError("memory deletion checkpoint cannot move backwards or fork")
            account, token, marker, key = self._identity(partition_id)
            self._request({"operation": "advance", "account": account, "token": token,
                           "expected": list(previous) if previous is not None else None,
                           "checkpoint": [generation, mac]})
            self._seen[partition_id] = (generation, mac)
            self._marker(marker, account, key, create=True, checkpoint=(generation, mac))


class UnavailableLedgerMirror:
    """An enrolled host can load its UI, but no memory operation can downgrade protection."""
    def __init__(self, reason: str):
        self.reason = reason

    def read(self, partition_id: str):
        raise VaultLocked(self.reason)

    def write(self, partition_id: str, generation: int, mac: str):
        raise VaultLocked(self.reason)


def build_memory_guard(app_dir: Path, edition: str, keys) -> KeychainLedgerMirror | UnavailableLedgerMirror | None:
    """Return host capability, without enrolling or contacting Keychain yet."""
    app_dir = Path(app_dir)
    enrolled = bool(list((app_dir / "memory-guard").glob("*.json")))
    helper = _helper_path() if sys.platform == "darwin" else None
    if helper is None:
        if enrolled:
            return UnavailableLedgerMirror("this profile requires the signed Locus memory guard helper")
        return None
    try:
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], check=True, capture_output=True, timeout=10)
        info = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(helper)], check=True, capture_output=True, text=True, timeout=10)
        if f'identifier "{HELPER_ID}"' not in info.stdout + info.stderr:
            raise ValueError("unexpected helper identity")
    except (OSError, ValueError, subprocess.SubprocessError):
        return UnavailableLedgerMirror("the memory guard helper signature is invalid")
    return KeychainLedgerMirror(app_dir, edition, keys, helper)


def _checkpoint(value) -> tuple[int, str]:
    if (not isinstance(value, (tuple, list)) or len(value) != 2 or type(value[0]) is not int
            or not 0 <= value[0] < 2**63 - 1 or not isinstance(value[1], str)
            or (value[0] == 0 and value[1] != "")
            # The package ledger uses its 20-byte blind token, encoded as 40
            # lowercase hex characters. Enrollment/proof HMACs remain 64 hex.
            or (value[0] > 0 and (len(value[1]) != 40 or any(c not in "0123456789abcdef" for c in value[1])))):
        raise IntegrityError("invalid memory deletion checkpoint")
    return value[0], value[1]


def restore_protection_status(app_dir: Path, edition: str, keys) -> dict:
    """Content-free status, including explicit unsupported-host reporting."""
    app_dir = Path(app_dir)
    enrolled = bool(list((app_dir / "memory-guard").glob("*.json")))
    try:
        guard = build_memory_guard(app_dir, edition, keys)
        if guard is None:
            return {"available": False, "enrolled": False, "state": "unavailable",
                    "reason": "unsupported_platform" if sys.platform != "darwin" else "signed_helper_missing"}
        from locus_memory.models import PartitionRef
        point = guard.read(PartitionRef(edition.lower(), "default").partition_id)
        return {"available": True, "enrolled": point is not None,
                "state": "protected" if point is not None else "not_enrolled",
                "generation": point[0] if point else None}
    except (IntegrityError, ReconciliationRequired, VaultLocked) as exc:
        return {"available": False, "enrolled": enrolled, "state": "recovery_required",
                "reason": exc.code, "message": str(exc), "offline_recovery": True}
