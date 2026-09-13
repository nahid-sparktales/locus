"""Notarization preflight for the independently launched runtime; no signing credentials."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "verify_runtime_helper", ROOT / "Tools/VerifyRuntimeHelper.py"
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

TEAM = "ABCDEFGHIJ"
SIGNATURE = f"""CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+2 location=embedded
Authority=Developer ID Application: Fixture ({TEAM})
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 12, 2026 at 9:00:00 PM
TeamIdentifier={TEAM}
"""


@pytest.fixture
def signed_fixture(tmp_path, monkeypatch):
    app = tmp_path / "Locus.app"
    helper = app / "Contents/Helpers/LocusRuntime"
    helper.parent.mkdir(parents=True)
    helper.write_bytes(b"fixture executable")
    helper.chmod(0o755)
    signatures = {"arm64": SIGNATURE, "x86_64": SIGNATURE}
    calls = []

    def inspect(command):
        calls.append(command)
        if command[-1] == str(app):
            return f"TeamIdentifier={TEAM}\n"
        assert command[-1] == str(helper)
        if "--verify" in command:
            return ""
        if "-archs" in command:
            return "arm64 x86_64"
        return signatures[command[command.index("--arch") + 1]]

    monkeypatch.setattr(verifier, "inspect", inspect)
    return app, helper, signatures, calls


def test_accepts_distribution_signed_helper_and_verifies_every_slice(signed_fixture):
    app, helper, _signatures, calls = signed_fixture
    verifier.verify(app)
    assert ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(helper)] in calls
    assert {command[command.index("--arch") + 1] for command in calls if "--arch" in command} == {
        "arm64", "x86_64",
    }


@pytest.mark.parametrize(("before", "after", "error"), [
    ("Authority=Developer ID Application: Fixture", "Authority=Apple Development: Fixture",
     "Developer ID"),
    ("Authority=Developer ID Application: Fixture", "Signature=adhoc", "Developer ID"),
    (f"TeamIdentifier={TEAM}", "TeamIdentifier=KLMNOPQRST", "signing team"),
    ("Timestamp=Sep 12, 2026 at 9:00:00 PM", "Signed Time=Sep 12, 2026 at 9:00:00 PM",
     "secure timestamp"),
    ("Timestamp=Sep 12, 2026 at 9:00:00 PM", "Timestamp=none", "secure timestamp"),
    ("Timestamp=Sep 12, 2026 at 9:00:00 PM", "Timestamp=", "secure timestamp"),
    ("flags=0x10000(runtime)", "flags=0x0(none)", "hardened runtime"),
])
def test_rejects_non_distributable_second_architecture(signed_fixture, before, after, error):
    app, _helper, signatures, _calls = signed_fixture
    signatures["x86_64"] = SIGNATURE.replace(before, after)
    with pytest.raises(ValueError, match=error):
        verifier.verify(app)


@pytest.mark.parametrize("missing", [True, False])
def test_requires_executable_runtime_helper(signed_fixture, missing):
    app, helper, _signatures, _calls = signed_fixture
    if missing:
        helper.unlink()
    else:
        helper.chmod(0o644)
    with pytest.raises(ValueError, match="executable is missing"):
        verifier.verify(app)


def test_does_not_accept_metadata_when_signature_verification_fails(signed_fixture, monkeypatch):
    app, _helper, _signatures, _calls = signed_fixture
    original = verifier.inspect

    def inspect(command):
        if "--verify" in command:
            raise subprocess.CalledProcessError(1, command, stderr="invalid signature")
        return original(command)

    monkeypatch.setattr(verifier, "inspect", inspect)
    with pytest.raises(subprocess.CalledProcessError):
        verifier.verify(app)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS signing regression")
def test_real_adhoc_signature_passes_seal_check_but_fails_distribution_preflight(tmp_path, monkeypatch):
    app = tmp_path / "Locus.app"
    helper = app / "Contents/Helpers/LocusRuntime"
    helper.parent.mkdir(parents=True)
    source = tmp_path / "launcher.c"
    source.write_text("int main(void) { return 0; }\n")
    subprocess.run(["/usr/bin/xcrun", "clang", str(source), "-o", str(helper)], check=True)
    subprocess.run([
        "/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", str(helper),
    ], check=True, capture_output=True)
    original = verifier.inspect

    def inspect(command):
        # Only the containing app's team is synthetic. All helper metadata and
        # verification come from the actual Mach-O and Apple's codesign tool.
        if command[-1] == str(app):
            return f"TeamIdentifier={TEAM}\n"
        return original(command)

    monkeypatch.setattr(verifier, "inspect", inspect)
    original(["/usr/bin/codesign", "--verify", "--strict", str(helper)])
    with pytest.raises(ValueError, match="Developer ID"):
        verifier.verify(app)
