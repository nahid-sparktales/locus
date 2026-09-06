"""Exercise shipped-product fuzz exclusions using synthetic files/output only."""

import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = (
    ROOT / "Tools/AuditWalletBuildBoundary.sh",
    ROOT / "Tools/AuditDistribution.sh",
)


def block(script, name):
    return script.read_text().split(f"# BEGIN {name}\n", 1)[1].split(
        f"# END {name}", 1
    )[0]


@pytest.fixture(params=SCRIPTS, ids=["build-boundary", "distribution"])
def script(request):
    return request.param


def inspect_output(tmp_path, script, kind, output):
    exclusions = block(script, "wallet_audit_fuzz_host_exclusions")
    pattern = re.search(rf"^wallet_fuzz_forbidden_{kind}='([^']+)'$", exclusions, re.M)[1]
    helper = block(script, "wallet_audit_reject_matching_output")
    body = (
        "set -euo pipefail\n" + helper
        + '\naudit_temp_dir="$1"; pattern="$2"; shift 2\n'
        + 'wallet_audit_reject_matching_output "$pattern" "forbidden fuzz output" "$@"\n'
    )
    return subprocess.run(
        ["/bin/zsh", "-c", body, "synthetic-fuzz-output", str(tmp_path), pattern,
         sys.executable, "-c", f"import sys; sys.stdout.write({output!r})"],
        capture_output=True, text=True, timeout=10,
    )


def inspect_resources(tmp_path, script, app):
    body = (
        "set -euo pipefail\n"
        + block(script, "wallet_audit_reject_matching_output")
        + block(script, "wallet_audit_fuzz_host_exclusions")
        + '\naudit_temp_dir="$1"; wallet_audit_reject_fuzz_host_resources "$2"\n'
    )
    return subprocess.run(
        ["/bin/zsh", "-c", body, "synthetic-fuzz-resources", str(tmp_path), str(app)],
        capture_output=True, text=True, timeout=10,
    )


def test_product_audits_share_identical_fuzz_exclusions():
    assert block(SCRIPTS[0], "wallet_audit_fuzz_host_exclusions") == block(
        SCRIPTS[1], "wallet_audit_fuzz_host_exclusions"
    )


@pytest.mark.parametrize("output", [
    "0000000100000000 T _LLVMFuzzerRunDriver\n",
    "                 U _LLVMFuzzerTestOneInput\n",
    "0000000100000000 T LLVMFuzzerCustomMutator\n",
    "0000000100000000 t __ZN6fuzzer6Fuzzer4LoopEv\n",
    "0000000100000000 t _$s14WalletFuzzHostAA4mainyyFZ\n",
    "0000000100000000 t _$s5Locus21walletSwiftFuzzerInput33_ABCLLys5Int32VSrySg_SitF\n",
    "0000000100000000 s _$s5Locus16WalletLibFuzzer33_ABCLLON\n",
])
def test_host_and_driver_symbols_are_rejected_even_in_renamed_payloads(tmp_path, script, output):
    result = inspect_output(tmp_path, script, "symbols", output)
    assert result.returncode == 1
    assert "forbidden fuzz output" in result.stderr


@pytest.mark.parametrize("output", [
    "_LLVMFuzzerRunDriver\n",
    "LLVMFuzzerTestOneInput\n",
    "walletSwiftFuzzerInput\n",
    "LOCUS_FUZZ_RECEIPT\n",
    "LOCUS_WALLET_FUZZ_HOST\n",
    "io.sparktales.locus.wallet-fuzz-host\n",
    "WalletFuzzMetrics\n",
    "$s14WalletFuzzHostAA4mainyyFZ\n",
])
def test_stripped_binary_runtime_identities_are_rejected(tmp_path, script, output):
    result = inspect_output(tmp_path, script, "strings", output)
    assert result.returncode == 1
    assert "forbidden fuzz output" in result.stderr


@pytest.mark.parametrize("kind, output", [
    ("symbols", "0000000100000000 T _$s5Locus21WalletBaseUnitsV5parseyyF\n"),
    ("symbols", "                 U ___sanitizer_cov_trace_pc_guard\n"),
    ("strings", "Debug builds may use ASan coverage without linking a fuzz host.\n"),
    ("strings", "Documentation describes WalletFuzzHost and LLVMFuzzerRunDriver.\n"),
    ("strings", "WalletFuzzHost.md\n"),
    ("strings", "LLVMFuzzerRunDriverDocumentation\n"),
])
def test_benign_production_symbols_and_prose_do_not_trigger_fuzz_exclusion(tmp_path, script, kind, output):
    result = inspect_output(tmp_path, script, kind, output)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ""


@pytest.mark.parametrize("relative", [
    "Helpers/WalletFuzzHost.app",
    "MacOS/WalletFuzzHost",
    "Frameworks/WalletFuzzHost.debug.dylib",
    "Resources/WalletFuzzHost/Info.plist",
    "Resources/WalletFuzzHost.swift",
    "Resources/WalletFuzzHost.swiftmodule/arm64.swiftmodule",
    "Resources/WalletFuzzHost.o",
    "Resources/WalletLibFuzzerTests.swift",
    "Resources/WalletSwiftFuzzWorker.py",
    "Resources/libclang_rt.fuzzer_no_main_osx.a",
    "Frameworks/libclang_rt.fuzzer_osx.dylib",
    "Helpers/Renamed.app/Contents/MacOS/WalletFuzzHost",
])
def test_all_payload_locations_are_rejected(tmp_path, script, relative):
    app = tmp_path / "Locus.app"
    fixture = app / "Contents" / relative
    fixture.parent.mkdir(parents=True)
    fixture.write_bytes(b"synthetic inert payload")
    result = inspect_resources(tmp_path, script, app)
    assert result.returncode == 1
    assert "test-only wallet fuzz payload" in result.stderr


def test_broken_host_symlink_is_not_treated_as_absent(tmp_path, script):
    app = tmp_path / "Locus.app"
    payload = app / "Contents/Helpers/WalletFuzzHost.app"
    payload.parent.mkdir(parents=True)
    payload.symlink_to("nonexistent-synthetic-target")
    result = inspect_resources(tmp_path, script, app)
    assert result.returncode == 1
    assert "test-only wallet fuzz payload" in result.stderr


def test_notice_text_and_unrelated_asan_runtime_are_not_host_payloads(tmp_path, script):
    app = tmp_path / "Locus.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    for name in ["ThirdPartyNotices.md", "WalletFuzzHost.md", "libclang_rt.asan_osx_dynamic.dylib"]:
        (resources / name).write_text("WalletFuzzHost, LLVMFuzzerRunDriver, walletSwiftFuzzerInput")
    result = inspect_resources(tmp_path, script, app)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ""


def test_failed_inventory_is_not_accepted_as_no_fuzz_payload(tmp_path, script):
    result = inspect_resources(tmp_path, script, tmp_path / "Missing.app")
    assert result.returncode == 1
    assert "inspection tool failed" in result.stderr


def test_both_audits_cover_all_products_and_every_embedded_macho():
    boundary, distribution = (script.read_text() for script in SCRIPTS)
    assert 'wallet_audit_reject_fuzz_host_resources "${direct_app}"' in boundary
    assert 'wallet_audit_reject_fuzz_host_resources "${mas_app}"' in boundary
    assert 'wallet_audit_reject_fuzz_host_resources "${app}"' in distribution
    for text, count in [(boundary, 2), (distribution, 1)]:
        for kind in ["symbols", "strings"]:
            assert text.count(
                f'wallet_audit_reject_matching_output "${{wallet_fuzz_forbidden_{kind}}}"'
            ) == count
    for counter in ["direct_macho_count", "mas_macho_count"]:
        loop = boundary.split(f"(( {counter} += 1 ))", 1)[1].split("done <", 1)[0]
        # These must run before the signer-specific exemption, not inside it.
        assert loop.index('"${wallet_fuzz_forbidden_symbols}"') < loop.index("unexpected")
        assert loop.index('"${wallet_fuzz_forbidden_strings}"') < loop.index("unexpected")
    loop = distribution.split("(( wallet_macho_count += 1 ))", 1)[1].split("done <", 1)[0]
    assert loop.index('"${wallet_fuzz_forbidden_symbols}"') < loop.index('if [[ "${candidate}"')
    assert loop.index('"${wallet_fuzz_forbidden_strings}"') < loop.index('if [[ "${candidate}"')
