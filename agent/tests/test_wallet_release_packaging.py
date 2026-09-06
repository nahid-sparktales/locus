"""Release tool boundaries; no real signing identities or credentials are used."""

import copy
import datetime as dt
import importlib.util
import plistlib
import re
import subprocess
import sys
from pathlib import Path

import pytest
from artifact_fixtures import make_synthetic_app

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "wallet_export_provenance", ROOT / "Tools/WalletExportProvenance.py"
)
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


def test_packaged_connector_notice_preserves_attribution_and_resolved_license_evidence():
    notice = (ROOT / "WalletConnectionsRuntime/Resources/WalletConnectionsNotices.md").read_text()
    audit = (ROOT / "Tools/AuditDistribution.sh").read_text()
    attribution = "Portions © 2025 Reown, Inc. All Rights Reserved"
    assert attribution in notice
    assert attribution in audit
    assert "NOASSERTION" not in notice
    assert "87ad8fac24721cbe00377e92f429a500b0da4139" in notice
    for name in ("phantom-wallet-sdk-87ad8fac.LICENSE", "eyes-0.1.8.LICENSE",
                 "text-encoding-utf-8-1.0.2.LICENSE"):
        assert name in notice
        assert (ROOT / "WalletConnectionsWeb/licenses" / name).is_file()
    assert "separate counsel approval" in notice


def _snapshot():
    return {
        "sourceRevision": "a" * 40,
        "bundleVersion": "24",
        "outerApp": {
            "CDHash": "b" * 40,
            "TeamIdentifier": "ABCDEFGHIJ",
            "Identifier": "io.sparktales.locusx",
        },
        "signers": {"signer": {"CDHash": "c" * 40, "profileSHA256": "d" * 64}},
        "files": {"Contents/Info.plist": "e" * 64, "Contents/MacOS/LocusX": "f" * 64},
    }


@pytest.mark.parametrize(
    "field", ["sourceRevision", "bundleVersion", "outerApp", "signers", "files"]
)
def test_export_receipt_rejects_changed_source_signature_profile_or_content(monkeypatch, field):
    recorded = _snapshot()
    receipt = {"schemaVersion": 1, "exportMethod": "developer-id", **recorded}
    current = copy.deepcopy(recorded)
    if field == "files":
        current[field]["Contents/MacOS/LocusX"] = "0" * 64
    else:
        current[field] = "changed"
    monkeypatch.setattr(provenance, "snapshot", lambda _app: current)
    with pytest.raises(ValueError, match="changed"):
        provenance.verify(receipt, Path("unused"))


def test_export_receipt_rejects_an_empty_inventory(monkeypatch):
    current = _snapshot()
    receipt = {"schemaVersion": 1, "exportMethod": "developer-id", **current, "files": {}}
    monkeypatch.setattr(provenance, "snapshot", lambda _app: current)
    with pytest.raises(ValueError, match="empty"):
        provenance.verify(receipt, Path("unused"))


def test_export_receipt_rejects_a_non_developer_id_export():
    with pytest.raises(ValueError, match="Developer ID"):
        provenance.verify({"schemaVersion": 1, "exportMethod": "development"}, Path("unused"))


@pytest.mark.parametrize(
    "mutation", ["expired", "wrong_team", "development", "wrong_group", "wrong_identifier"]
)
def test_signer_profile_validation_requires_distribution_authority(tmp_path, monkeypatch, mutation):
    team = "ABCDEFGHIJ"
    signer = tmp_path / "WalletSigner.xpc"
    (signer / "Contents").mkdir(parents=True)
    (signer / "Contents/embedded.provisionprofile").write_bytes(b"fixture CMS")
    profile = {
        "ExpirationDate": dt.datetime(2099, 1, 1),
        "TeamIdentifier": [team],
        "ProvisionsAllDevices": True,
        "Entitlements": {
            "keychain-access-groups": [f"{team}.io.sparktales.locus.WalletSigner"],
            "com.apple.application-identifier": f"{team}.io.sparktales.locus.WalletSigner",
        },
    }
    if mutation == "expired":
        profile["ExpirationDate"] = dt.datetime(2000, 1, 1)
    elif mutation == "wrong_team":
        profile["TeamIdentifier"] = ["WRONGTEAM1"]
    elif mutation == "development":
        profile["ProvisionsAllDevices"] = False
    elif mutation == "wrong_group":
        profile["Entitlements"]["keychain-access-groups"] = [f"{team}.another-app"]
    else:
        profile["Entitlements"]["com.apple.application-identifier"] = f"{team}.another-app"
    monkeypatch.setattr(provenance, "run", lambda *_command: plistlib.dumps(profile))
    with pytest.raises(ValueError):
        provenance.validate_profile(signer, team)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS code signatures")
def test_unsigned_provenance_survives_resigning_and_never_modifies_the_input(tmp_path):
    executable = tmp_path / "fixture"
    subprocess.run(
        ["xcrun", "clang", "-x", "c", "-", "-o", str(executable)],
        input=b"int main(void) { return 0; }\n",
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--identifier", "fixture.one", str(executable)],
        check=True,
        capture_output=True,
    )
    displayed = subprocess.run(
        ["codesign", "-dv", "--verbose=4", str(executable)], check=True, capture_output=True
    )
    # This is Apple's actual CDHash output, not a made-up 64-hex fixture.
    cdhash = re.search(rb"^CDHash=([0-9a-f]{40})$", displayed.stderr, re.MULTILINE)
    assert cdhash
    security_identity = subprocess.run(
        [
            "xcrun",
            "swift",
            "-e",
            """
import Foundation
import Security
var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
    [], &code) == errSecSuccess, let code else { exit(1) }
var raw: CFDictionary?
guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
    &raw) == errSecSuccess, let raw,
    let bytes = (raw as NSDictionary)[kSecCodeInfoUnique] as? Data else { exit(1) }
print(bytes.map { String(format: "%02x", $0) }.joined())
""",
            str(executable),
        ],
        check=True,
        capture_output=True,
    )
    assert security_identity.stdout.strip() == cdhash.group(1)
    first_bytes = executable.read_bytes()
    first = provenance.unsigned_digest(executable)
    assert executable.read_bytes() == first_bytes
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--identifier", "fixture.two", str(executable)],
        check=True,
        capture_output=True,
    )
    second_bytes = executable.read_bytes()
    assert first_bytes != second_bytes
    assert provenance.unsigned_digest(executable) == first
    assert executable.read_bytes() == second_bytes


@pytest.mark.parametrize("channel", ["canary", "ga"])
def test_canary_packaging_rejects_unprovenanced_edition_before_any_mutation(tmp_path, channel):
    app, _ = make_synthetic_app(tmp_path, "locusx")
    marker = app / "marker"
    marker.write_text("unchanged")
    result = subprocess.run(
        ["zsh", str(ROOT / "Tools/PackageRelease.sh"), str(app), str(tmp_path / "candidate.zip")],
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LOCUS_WALLET_RELEASE_CHANNEL": channel},
        capture_output=True,
    )
    assert result.returncode != 0
    assert b"ArchiveWalletRelease.sh" in result.stderr
    assert marker.read_text() == "unchanged"
    assert not (tmp_path / "candidate.zip").exists()


def test_export_packaging_cannot_write_an_archive_inside_the_sealed_app(tmp_path):
    app = tmp_path / "Locus.app"
    app.mkdir()
    marker = app / "marker"
    marker.write_text("unchanged")
    receipt = tmp_path / "receipt.json"
    receipt.write_text("{}")
    result = subprocess.run(
        [
            "zsh",
            str(ROOT / "Tools/PackageExportedWalletRelease.sh"),
            str(app),
            str(app / "candidate.zip"),
        ],
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LOCUS_WALLET_EXPORT_PROVENANCE": str(receipt),
        },
        capture_output=True,
    )
    assert result.returncode != 0
    assert b"outside the app" in result.stderr
    assert marker.read_text() == "unchanged"
    assert not (app / "candidate.zip").exists()
