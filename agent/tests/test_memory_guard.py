"""Guard protocol tests use an isolated in-memory Keychain stand-in."""
import json
import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
from locus_memory.crypto import StaticKeyProvider
from locus_memory.errors import IntegrityError, ReconciliationRequired, VaultLocked

from ollama_code.memory_guard import KeychainLedgerMirror, _checkpoint, build_memory_guard

CHECKPOINT_CASES = [
    ([0, ""], True), ([1, "a" * 40], True), ([12, "0123456789abcdef" * 2 + "01234567"], True),
    ([0, "a" * 40], False), ([1, ""], False), ([1, "a" * 39], False),
    ([1, "a" * 64], False), ([1, "A" * 40], False), ([1, "ａ" * 40], False),
    ([-1, "a" * 40], False), ([True, "a" * 40], False), ([1.5, "a" * 40], False),
    ([2**63 - 1, "a" * 40], False), ([1], False), ("checkpoint", False),
]


@pytest.mark.parametrize("value,valid", CHECKPOINT_CASES)
def test_checkpoint_contract(value, valid):
    if valid:
        assert _checkpoint(value) == tuple(value)
    else:
        with pytest.raises(IntegrityError):
            _checkpoint(value)


@pytest.fixture(scope="module")
def native_checkpoint_validator(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("macOS Swift checkpoint parser")
    root = Path(__file__).resolve().parents[2]
    # Compile the real helper's pure parser without its Keychain request entry
    # point. No test reads or mutates the user's login Keychain.
    parser = (root / "MemoryGuard/main.swift").read_text().split("func run() throws", 1)[0]
    directory = tmp_path_factory.mktemp("native-memory-checkpoint")
    source = directory / "main.swift"
    source.write_text(parser + '''
let input = FileHandle.standardInput.readDataToEndOfFile()
do {
    let value = try JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])
    guard try checkpoint(value) != nil else { throw GuardError(message: "missing") }
    print("accepted")
} catch { print("rejected") }
''')
    binary = directory / "checkpoint-validator"
    subprocess.run(["/usr/bin/xcrun", "swiftc", str(source), "-o", str(binary)], check=True, capture_output=True)
    return binary


@pytest.mark.parametrize("value,valid", CHECKPOINT_CASES)
def test_native_and_host_checkpoint_contract_agree(native_checkpoint_validator, value, valid):
    result = subprocess.run([str(native_checkpoint_validator)], input=json.dumps(value),
                            text=True, capture_output=True, check=True)
    assert result.stdout.strip() == ("accepted" if valid else "rejected")


class Keychain:
    def __init__(self):
        self.entries = {}
        self.locked = False
        self._lock = threading.Lock()

    def run(self, command, **kwargs):
        assert "input" in kwargs and kwargs["timeout"] == 15
        assert len(command) == 1  # enrollment secret travels only over stdin
        body = json.loads(kwargs["input"])
        with self._lock:
            if self.locked:
                return SimpleNamespace(returncode=1, stdout='{"ok":false}')
            current = self.entries.get(body["account"])
            if current and current[0] != body["token"]:
                return SimpleNamespace(returncode=1, stdout='{"ok":false}')
            if body["operation"] == "advance":
                expected = current[1] if current else None
                next_value = body["checkpoint"]
                if body["expected"] != expected or (expected and (next_value[0] < expected[0] or
                        (next_value[0] == expected[0] and next_value != expected))):
                    return SimpleNamespace(returncode=1, stdout='{"ok":false}')
                current = (body["token"], next_value)
                self.entries[body["account"]] = current
            return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "checkpoint": current[1] if current else None}))


def mirror(tmp_path, chain, edition="locus", keys=None):
    return KeychainLedgerMirror(tmp_path, edition, keys or StaticKeyProvider({"k": b"x" * 32}),
                                Path("/fake/LocusMemoryGuard"), runner=chain.run)


def test_enrollment_persists_authenticated_marker_and_partition_isolation(tmp_path):
    chain = Keychain()
    first = mirror(tmp_path, chain)
    assert first.read("p") is None
    first.write("p", 1, "a" * 40)
    assert mirror(tmp_path, chain).read("p") == (1, "a" * 40)
    assert mirror(tmp_path, chain).read("other") is None
    assert mirror(tmp_path, chain, "locusx").read("p") is None
    assert len(chain.entries) == 1
    marker = next((tmp_path / "memory-guard").glob("*.json"))
    assert marker.stat().st_mode & 0o777 == 0o600
    marker.write_text('{}')
    with pytest.raises(IntegrityError):
        first.read("p")


def test_enrolled_missing_checkpoint_locked_keychain_and_missing_helper_fail_closed(tmp_path, monkeypatch):
    chain = Keychain()
    first = mirror(tmp_path, chain)
    first.write("p", 0, "")
    chain.locked = True
    with pytest.raises(VaultLocked):
        first.read("p")
    chain.locked = False
    chain.entries.clear()
    with pytest.raises(ReconciliationRequired):
        first.read("p")
    monkeypatch.setattr("ollama_code.memory_guard._helper_path", lambda: None)
    unavailable = build_memory_guard(tmp_path, "locus", first.keys)
    assert unavailable is not None
    with pytest.raises(VaultLocked):
        unavailable.read("p")


def test_cas_prevents_concurrent_and_backward_advances(tmp_path):
    chain = Keychain()
    a, b = mirror(tmp_path, chain), mirror(tmp_path, chain)
    a.write("p", 0, "")
    assert b.read("p") == (0, "")
    a.write("p", 1, "a" * 40)
    with pytest.raises(VaultLocked):
        b.write("p", 2, "b" * 40)
    assert b.read("p") == (1, "a" * 40)
    b.write("p", 2, "b" * 40)
    for value in [(1, "a" * 40), (2, "c" * 40)]:
        with pytest.raises(IntegrityError):
            b.write("p", *value)


def test_recover_enrollment_after_checkpoint_committed_before_marker(tmp_path):
    chain = Keychain()
    guard = mirror(tmp_path, chain)
    guard.write("p", 2, "a" * 40)
    next((tmp_path / "memory-guard").glob("*.json")).unlink()
    assert mirror(tmp_path, chain).read("p") == (2, "a" * 40)
    assert list((tmp_path / "memory-guard").glob("*.json"))


def test_source_checkout_without_helper_reports_unavailable_without_keychain(tmp_path, monkeypatch):
    monkeypatch.setattr("ollama_code.memory_guard._helper_path", lambda: None)
    keys = StaticKeyProvider({"k": b"x" * 32})
    assert build_memory_guard(tmp_path, "locus", keys) is None
    assert not (tmp_path / "memory-guard").exists()


def test_timeouts_are_recoverable_memory_unavailable(tmp_path):
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 15)
    guard = KeychainLedgerMirror(tmp_path, "locus", StaticKeyProvider({"k": b"x" * 32}), Path("/fake"), runner=timeout)
    with pytest.raises(VaultLocked):
        guard.read("p")


def test_checkpoint_proof_and_marker_are_authenticated_and_monotonic(tmp_path):
    chain = Keychain()
    guard = mirror(tmp_path, chain)
    guard.write("p", 1, "a" * 40)
    exported = guard.export_checkpoint("p")
    assert guard.verify_checkpoint_proof("p", exported) == (1, "a" * 40)
    changed = {**exported, "checkpoint": [10, "b" * 40]}
    with pytest.raises(IntegrityError):
        guard.verify_checkpoint_proof("p", changed)
    with pytest.raises(IntegrityError):
        mirror(tmp_path, chain, "locusx").verify_checkpoint_proof("p", exported)
    guard.write("p", 2, "b" * 40)
    account = next(iter(chain.entries))
    chain.entries[account] = (chain.entries[account][0], [1, "a" * 40])
    with pytest.raises(ReconciliationRequired):
        guard.read("p")


def test_missing_checkpoint_preview_requires_external_proof_and_rejects_older_proof(tmp_path):
    chain = Keychain()
    guard = mirror(tmp_path, chain)
    guard.write("p", 1, "a" * 40)
    old_proof = guard.export_checkpoint("p")
    guard.write("p", 2, "b" * 40)
    proof = guard.export_checkpoint("p")
    chain.entries.clear()
    no_proof = guard.recovery_preview("p", local_checkpoint=(1, "a" * 40), proof=None)
    assert no_proof["recoverable"] is False and no_proof["next_generation"] is None
    with pytest.raises(ReconciliationRequired):
        guard.recovery_preview("p", local_checkpoint=(1, "a" * 40), proof=old_proof)
    ready = guard.recovery_preview("p", local_checkpoint=(1, "a" * 40), proof=proof)
    assert ready["known_generation"] == 2 and ready["next_generation"] == 3
    assert not chain.entries  # preview does not re-enroll or reset anything
    guard.restore_missing_checkpoint("p", proof)
    assert guard.read("p") == (2, "b" * 40)


def test_non_macos_reports_unavailable_but_enrolled_never_downgrades(tmp_path, monkeypatch):
    from ollama_code.memory_guard import restore_protection_status
    monkeypatch.setattr("ollama_code.memory_guard.sys.platform", "linux")
    keys = StaticKeyProvider({"k": b"x" * 32})
    status = restore_protection_status(tmp_path, "locus", keys)
    assert status["state"] == "unavailable" and status["reason"] == "unsupported_platform"
    guard = mirror(tmp_path, Keychain())
    guard.write("p", 0, "")
    status = restore_protection_status(tmp_path, "locus", keys)
    assert status["state"] == "recovery_required" and status["enrolled"]
    assert not status["available"]


def test_corrupt_marker_has_no_generation_guess_or_force_reset(tmp_path):
    chain = Keychain()
    guard = mirror(tmp_path, chain)
    guard.write("p", 4, "a" * 40)
    proof = guard.export_checkpoint("p")
    marker = next((tmp_path / "memory-guard").glob("*.json"))
    marker.write_text("corrupt")
    chain.entries.clear()
    with pytest.raises(IntegrityError):
        guard.recovery_preview("p", local_checkpoint=(0, ""), proof=proof)
    assert not chain.entries


def test_offline_recovery_requires_human_ack_and_advances_beyond_external_checkpoint(tmp_path):
    import shutil
    from contextlib import nullcontext

    from locus_memory import MemoryEngine
    from locus_memory.bootstrap import initialize_fresh_profile
    from locus_memory.host import HostCapabilities
    from locus_memory.models import (
        AccessContext,
        Actor,
        ForgetTarget,
        Operation,
        PartitionRef,
        RememberRequest,
        ScopeGrants,
    )

    from ollama_code.memory_guard_recovery import recover

    keys = StaticKeyProvider({"k": b"x" * 32})
    chain = Keychain()
    guard = mirror(tmp_path, chain, keys=keys)
    partition = PartitionRef("locus", "default")
    root = tmp_path / "memory-engine"
    initialize_fresh_profile(root, tmp_path / "memory/legacy.sqlite3", keys, partition=partition,
                             initialization_lock=tmp_path / "init.lock", lease=nullcontext,
                             host=HostCapabilities(ledger_mirror=guard))
    access = AccessContext(principal="user", partition=partition, actor=Actor.USER,
                           operations=frozenset(Operation), grants=ScopeGrants())
    with MemoryEngine(root, keys, host=HostCapabilities(ledger_mirror=guard)) as engine:
        record = engine.remember(access, RememberRequest(content="restore fixture")).record
    backup = tmp_path / "backup"
    shutil.copytree(root, backup)
    with MemoryEngine(root, keys, host=HostCapabilities(ledger_mirror=guard)) as engine:
        engine.forget(access, ForgetTarget("memory", record.id))
    proof = guard.export_checkpoint(partition.partition_id)
    shutil.rmtree(root)
    shutil.copytree(backup, root)
    chain.entries.clear()
    preview = recover(tmp_path, "locus", guard, keys, proof=proof)
    assert preview["preview"] and preview["next_generation"] == 2
    with pytest.raises(ReconciliationRequired):
        recover(tmp_path, "locus", guard, keys, proof=proof, apply=True)
    with pytest.raises(ReconciliationRequired):
        recover(tmp_path, "locus", guard, keys, proof=proof, apply=True, acknowledge_lost_history=True)
    result = recover(tmp_path, "locus", guard, keys, proof=proof, apply=True,
                     acknowledge_lost_history=True, acknowledge_latest_proof=True)
    assert result["recovered"] and result["deletion_generation"] > proof["checkpoint"][0]
    assert result["history_reconstructed"] is False
    assert guard.read(partition.partition_id)[0] == result["deletion_generation"]


def test_memory_status_survives_unavailable_custody_and_rolled_back_local_store(tmp_path, monkeypatch):
    from ollama_code.api import continuity
    from ollama_code.memory import MemoryError
    service = SimpleNamespace(core=SimpleNamespace(workspace_root=str(tmp_path), cwd=str(tmp_path)))
    def protection(*args):
        return {"available": True, "enrolled": True, "state": "protected", "generation": 5}
    monkeypatch.setattr("ollama_code.memory_guard.restore_protection_status", protection)
    def unavailable(*args, **kwargs):
        raise MemoryError("the local ledger needs recovery")
    monkeypatch.setattr(continuity, "memory_vault", unavailable)
    result = continuity.memory_status(service, workspace=str(tmp_path), agent_id="primary")
    assert result["memory_available"] is False and result["counts_available"] is False
    assert result["restore_protection"]["state"] == "recovery_required"


def test_unavailable_guard_allows_adapter_start_without_legacy_fallback(tmp_path, monkeypatch):
    from locus_memory.host import HostCapabilities
    from locus_memory.models import PartitionRef

    from ollama_code.memory_adapter import MemoryAdapter, ensure_memory_profile
    from ollama_code.memory_guard import UnavailableLedgerMirror
    # Initialization uses disposable custody and no external helper.
    monkeypatch.setattr("ollama_code.memory_guard._helper_path", lambda: None)
    assert ensure_memory_profile(tmp_path, "locus") == "package_authoritative"
    monkeypatch.setattr("ollama_code.memory_capabilities.memory_capabilities",
                        lambda *_: HostCapabilities(ledger_mirror=UnavailableLedgerMirror("restore required")))
    adapter = MemoryAdapter(app_dir=tmp_path, edition="locus", hold_profile_lease=True)
    try:
        assert adapter.mode == "enabled"
        with pytest.raises(VaultLocked):
            adapter.engine.partition_context(PartitionRef("locus", "default"))
    finally:
        adapter.close()
