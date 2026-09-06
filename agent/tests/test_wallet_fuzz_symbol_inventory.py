"""Keep upstream interpreter/library allowances bound to path, image and symbol."""
from __future__ import annotations

import importlib.util
import struct
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fuzz_symbol_inventory", ROOT / "Tools/WalletFuzzSymbolInventory.py")
assert SPEC and SPEC.loader
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)

LOCAL = b"00000001009a8a5c t _LLVMFuzzerTestOneInput\n"
OTHER = (
    b"0000000100fad4a4 b _LLVMFuzzerTestOneInput.JSON_LOADS_INITIALIZED\n"
    b"00000001009a89cc T _PyInit__xxtestfuzz\n"
)


def image(signature_size=32, file_type=2):
    def segment(name, vmaddr, file_offset, file_size, protections):
        return struct.pack(
            "<II16sQQQQIIII", 0x19, 72, name, vmaddr, 0x4000,
            file_offset, file_size, protections, protections, 0, 0,
        )

    commands = segment(b"__TEXT", 0x100000000, 0, 256, 5)
    commands += segment(b"__LINKEDIT", 0x100004000, 256, 256 + signature_size, 1)
    commands += struct.pack("<4I", 0x1D, 16, 512, signature_size)
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, file_type, 3, len(commands), 0, 0)
    unsigned = (header + commands).ljust(512, b"x")
    signature = struct.pack(">3I", 0xFADE0CC0, 12, 0).ljust(signature_size, b"\0")
    return unsigned + signature


@pytest.fixture(params=[(inventory.INTERPRETER_SUFFIX, 2), (inventory.LIBRARY_SUFFIX, 6)])
def interpreter(tmp_path, monkeypatch, request):
    suffix, file_type = request.param
    candidate = tmp_path / "Locus.app" / Path(*suffix)
    candidate.parent.mkdir(parents=True)
    data = image(file_type=file_type)
    candidate.write_bytes(data)
    # Synthetic image pins exercise the policy without requiring a downloaded
    # interpreter or signing identities on every test runner.
    digest = inventory.normalized_image_digest(data)
    assert digest is not None
    monkeypatch.setattr(inventory, "PINNED_IMAGES", {suffix: digest})
    return candidate


def mock_nm(monkeypatch, output, *, returncode=0, stderr=b""):
    def inspect(command, **kwargs):
        assert command[0] == "/usr/bin/nm"
        assert kwargs["check"] is False and kwargs["timeout"] == 60
        return SimpleNamespace(returncode=returncode, stdout=output, stderr=stderr)

    monkeypatch.setattr(inventory.subprocess, "run", inspect)


def test_production_pins_are_the_verified_upstream_arm64_images():
    assert inventory.PINNED_IMAGES == {
        inventory.INTERPRETER_SUFFIX: "305e5c0154a61abdab75e0120e36d7f663a98cbe4726990e8ec873aa2a5fb055",
        inventory.LIBRARY_SUFFIX: "bab9a728c32eeae132219b771e68199dde47ff7efb10be791c555ecd974e787f",
    }


def test_matching_image_filters_only_the_local_callback(interpreter, monkeypatch):
    output = LOCAL + OTHER + b"0000000100000100 T _LLVMFuzzerRunDriver\n"
    mock_nm(monkeypatch, output)
    assert inventory.symbol_inventory(interpreter) == OTHER + b"0000000100000100 T _LLVMFuzzerRunDriver\n"


def test_signature_reallocation_preserves_the_image_pin(interpreter, monkeypatch):
    file_type = struct.unpack_from("<I", interpreter.read_bytes(), 12)[0]
    interpreter.write_bytes(image(signature_size=64, file_type=file_type))
    mock_nm(monkeypatch, LOCAL + OTHER)
    assert inventory.symbol_inventory(interpreter) == OTHER


def test_one_changed_code_byte_removes_the_exception(interpreter, monkeypatch):
    data = bytearray(interpreter.read_bytes())
    data[220] ^= 1
    interpreter.write_bytes(data)
    mock_nm(monkeypatch, LOCAL + OTHER)
    assert inventory.symbol_inventory(interpreter) == LOCAL + OTHER


@pytest.mark.parametrize("symbol", [
    b"00000001009a8a5c T _LLVMFuzzerTestOneInput\n",
    b"                 U _LLVMFuzzerTestOneInput\n",
    b"00000001009a8a5c t _LLVMFuzzerRunDriver\n",
    b"00000001009a8a5c t _LLVMFuzzerInitialize\n",
    b"00000001009a8a5c t _walletSwiftFuzzerInput\n",
    b"00000001009a8a5c t _LLVMFuzzerTestOneInput.extra\n",
])
def test_exported_undefined_other_callbacks_and_suffixes_are_untouched(interpreter, monkeypatch, symbol):
    mock_nm(monkeypatch, symbol)
    assert inventory.symbol_inventory(interpreter) == symbol


def test_identical_image_outside_the_exact_app_interpreter_path_is_not_exempt(interpreter, tmp_path, monkeypatch):
    wrong_path = tmp_path / "python3.14"
    wrong_path.write_bytes(interpreter.read_bytes())
    mock_nm(monkeypatch, LOCAL + OTHER)
    assert inventory.symbol_inventory(wrong_path) == LOCAL + OTHER


def test_pin_cannot_be_reused_for_the_other_bundled_image_path(interpreter, tmp_path, monkeypatch):
    suffix = inventory.LIBRARY_SUFFIX if interpreter.name == "python3.14" else inventory.INTERPRETER_SUFFIX
    wrong_path = tmp_path / "Other.app" / Path(*suffix)
    wrong_path.parent.mkdir(parents=True)
    wrong_path.write_bytes(interpreter.read_bytes())
    mock_nm(monkeypatch, LOCAL)
    assert inventory.symbol_inventory(wrong_path) == LOCAL


@pytest.mark.parametrize("position,value", [
    (4, 0x01000007),  # Unreviewed architecture.
    (12, 8),  # Unreviewed Mach-O file type.
    (20, 1000000),  # Load commands leave the file.
    (36, 4),  # Segment command smaller than its header.
    (96, 200),  # Section count exceeds the segment command size.
    (188, 31),  # Signature no longer ends at EOF.
    (512 + 4, 64),  # Signature container exceeds its allocation.
    (512 + 8, 100),  # Signature indexes exceed their container.
])
def test_malformed_or_unreviewed_images_keep_raw_symbols(interpreter, monkeypatch, position, value):
    data = bytearray(interpreter.read_bytes())
    struct.pack_into(">I" if position >= 512 else "<I", data, position, value)
    interpreter.write_bytes(data)
    mock_nm(monkeypatch, LOCAL)
    assert inventory.symbol_inventory(interpreter) == LOCAL


def test_nm_failure_is_an_inspection_error_even_with_partial_benign_output(interpreter, monkeypatch):
    mock_nm(monkeypatch, LOCAL, returncode=1, stderr=b"inspection failed")
    with pytest.raises(inventory.InspectionError, match="nm failed.*inspection failed"):
        inventory.symbol_inventory(interpreter)


def test_nm_timeout_is_an_inspection_error(interpreter, monkeypatch):
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired("nm", 60)

    monkeypatch.setattr(inventory.subprocess, "run", timeout)
    with pytest.raises(inventory.InspectionError, match="could not inspect"):
        inventory.symbol_inventory(interpreter)


def test_image_read_failure_is_an_inspection_error(interpreter, monkeypatch):
    mock_nm(monkeypatch, LOCAL)

    def unreadable(path):
        raise PermissionError("unreadable image")

    monkeypatch.setattr(Path, "read_bytes", unreadable)
    with pytest.raises(inventory.InspectionError, match="unreadable image"):
        inventory.symbol_inventory(interpreter)


def test_distribution_still_scans_fuzzer_strings_without_filtering():
    source = (ROOT / "Tools/AuditDistribution.sh").read_text()
    call = source.split('wallet_audit_reject_matching_output "${wallet_fuzz_forbidden_strings}"', 1)[1]
    assert '/usr/bin/strings "${candidate}"' in call.split("\n    if ", 1)[0]


def test_command_line_inspection_failure_returns_nonzero_without_symbol_output(tmp_path):
    result = subprocess.run(
        [sys.executable, str(ROOT / "Tools/WalletFuzzSymbolInventory.py"), str(tmp_path / "missing")],
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode != 0
    assert result.stdout == ""
    assert "error:" in result.stderr
