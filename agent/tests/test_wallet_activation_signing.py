"""Exercise the real activation CLI with disposable, non-activating test fixtures.

These tests prove signing-tool restrictions, not release evidence or runtime
activation. No mainnet grant, real credential, or externally published file is used.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SWIFT_HELPER = r"""
import CryptoKit
import Foundation

let mode = CommandLine.arguments[1]
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
if mode == "key" {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedData().write(to: keyURL, options: .atomic)
} else {
    let keyData = Data(base64Encoded: try Data(contentsOf: keyURL))!
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let object = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    if mode == "sign" {
        let canonical = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let signed: [String: Any] = ["manifest": object,
            "signatureBase64": try key.signature(for: canonical).base64EncodedString()]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]))
    } else {
        let canonical = try JSONSerialization.data(withJSONObject: object["envelope"]!,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let signature = Data(base64Encoded: object["signatureBase64"] as! String)!
        guard key.publicKey.isValidSignature(signature, for: canonical) else { exit(1) }
    }
}
"""


def _run(arguments: list[str | Path]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(value) for value in arguments], capture_output=True, text=True, timeout=90, check=False
    )


def _write(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, separators=(",", ":"), sort_keys=True), encoding="utf-8")


@pytest.fixture(scope="module")
def activation_tools(tmp_path_factory):
    if sys.platform != "darwin" or shutil.which("xcrun") is None:
        pytest.skip("the release activation CLI requires macOS CryptoKit and Swift")
    directory = tmp_path_factory.mktemp("wallet-activation-cli")
    helper_source = directory / "fixture-signing.swift"
    helper_source.write_text(SWIFT_HELPER, encoding="utf-8")
    helper = directory / "fixture-signing"
    cli = directory / "sign-activation"
    for source, binary in [
        (helper_source, helper),
        (ROOT / "Tools/SignWalletReleaseActivation.swift", cli),
    ]:
        compiled = _run(["xcrun", "swiftc", source, "-o", binary])
        assert compiled.returncode == 0, compiled.stderr
    key_path = directory / "disposable-test-key.base64"
    key_result = _run([helper, "key", key_path])
    assert key_result.returncode == 0, key_result.stderr
    key_path.chmod(0o600)
    return cli, helper, key_path


@pytest.fixture
def activation_case(tmp_path, activation_tools):
    now = datetime.now(timezone.utc).replace(microsecond=0)

    def iso(value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    issued = iso(now - timedelta(minutes=1))
    expiry = iso(now + timedelta(hours=1))
    metadata = {
        "schemaVersion": 1,
        "sourceRevision": "a" * 40,
        "bundleVersion": "fixture-1",
        "outerAppCodeDirectoryHash": "b" * 40,
        "signerCodeDirectoryHash": "c" * 40,
        "archiveSHA256": "d" * 64,
        "releaseStage": "invited_canary",
        "issuedAt": issued,
        "expiresAt": expiry,
        "revision": 2,
    }
    evidence = {
        "schemaVersion": 2,
        "sourceRevision": metadata["sourceRevision"],
        "releaseRevision": 2,
        "artifactIdentity": {
            "bundleVersion": metadata["bundleVersion"],
            "outerAppCodeDirectorySHA256": metadata["outerAppCodeDirectoryHash"],
            "signerCodeDirectorySHA256": metadata["signerCodeDirectoryHash"],
            "archiveSHA256": metadata["archiveSHA256"],
        },
    }
    ceiling = {
        "schemaVersion": 2,
        "revision": 1,
        "issuedAt": issued,
        "expiresAt": expiry,
        "assets": [{"id": "testnet-fixture-asset", "manifestRevision": 1, "symbol": "TEST"}],
        "adapterIDs": [],
        "evmContracts": [],
        "explorerTemplates": {},
        "providerIdentities": [],
        "signInAdapters": [],
        "programIdentities": [],
        "uniswapConfigurations": [],
        "connectors": [
            {
                "connector": "metamask",
                "ownership": "external",
                "version": "2.1.1",
                "artifactSHA256": "e" * 64,
                "configurationSHA256": "f" * 64,
                "directions": ["external_account_to_locus"],
                "methods": ["send_transaction"],
            }
        ],
    }
    restriction = copy.deepcopy(ceiling)
    restriction["revision"] = 2
    restriction["assets"][0]["manifestRevision"] = 2
    capability = {
        "schemaVersion": 3,
        "revision": 2,
        "releaseStage": "invited_canary",
        "issuedAt": issued,
        "expiresAt": expiry,
        # Dormant fixture: deliberately no network authority is granted.
        "networkGrants": [],
        "approvedRegions": [],
        "completedApprovals": [],
    }
    cli, helper, key_path = activation_tools

    def invoke(*, tamper_signature=False, tamper_evidence_hash=False):
        paths = {
            name: tmp_path / f"{name}.json"
            for name in [
                "metadata",
                "capability",
                "restriction",
                "ceiling",
                "evidence",
                "output",
            ]
        }
        _write(paths["metadata"], metadata)
        _write(paths["evidence"], evidence)
        capability["evidenceIndexSHA256"] = hashlib.sha256(
            paths["evidence"].read_bytes()
        ).hexdigest()
        if tamper_evidence_hash:
            capability["evidenceIndexSHA256"] = "0" * 64
        for name, value in [
            ("capability", capability),
            ("restriction", restriction),
            ("ceiling", ceiling),
        ]:
            _write(paths[name], value)
            result = _run([helper, "sign", key_path, paths[name]])
            assert result.returncode == 0, result.stderr
            signed = json.loads(result.stdout)
            if tamper_signature and name == "restriction":
                signed["signatureBase64"] = base64.b64encode(bytes(64)).decode()
            _write(paths[name], signed)
        result = _run(
            [
                cli,
                paths["metadata"],
                paths["capability"],
                paths["restriction"],
                paths["ceiling"],
                paths["evidence"],
                key_path,
                paths["output"],
            ]
        )
        return result, paths["output"]

    return metadata, evidence, restriction, invoke


def _rejected(result, output: Path, message: str) -> None:
    assert result.returncode != 0
    assert message in result.stderr
    assert not output.exists(), "a rejected input must not produce a signed envelope"


def test_newer_asset_provenance_is_not_broader_authority(activation_case, activation_tools):
    _, _, _, invoke = activation_case
    result, output = invoke()
    assert result.returncode == 0, result.stderr
    document = json.loads(output.read_text())
    assert (
        document["envelope"]["reviewRestriction"]["manifest"]["assets"][0]["manifestRevision"] == 2
    )
    _, helper, key_path = activation_tools
    verified = _run([helper, "verify", key_path, output])
    assert verified.returncode == 0, verified.stderr


def test_connector_configuration_substitution_is_rejected(activation_case):
    _, _, restriction, invoke = activation_case
    restriction["connectors"][0]["configurationSHA256"] = "0" * 64
    result, output = invoke()
    _rejected(result, output, "metadata or review restriction is invalid")


@pytest.mark.parametrize("addition", ["asset", "provider", "method"])
def test_broadened_review_is_rejected(activation_case, addition):
    _, _, restriction, invoke = activation_case
    if addition == "asset":
        restriction["assets"][0]["symbol"] = "SUBSTITUTED"
    elif addition == "provider":
        restriction["providerIdentities"] = [{"identity": "unreviewed-fixture-provider"}]
    else:
        restriction["connectors"][0]["methods"].append("sign_in_with_ethereum")
    result, output = invoke()
    _rejected(result, output, "metadata or review restriction is invalid")


@pytest.mark.parametrize(
    "field",
    [
        "sourceRevision",
        "bundleVersion",
        "outerAppCodeDirectoryHash",
        "signerCodeDirectoryHash",
        "archiveSHA256",
    ],
)
def test_evidence_identity_mismatch_is_rejected(activation_case, field):
    metadata, _, _, invoke = activation_case
    metadata[field] = "1" * len(metadata[field])
    result, output = invoke()
    _rejected(result, output, "build identity differs")


def test_evidence_bytes_must_match_signed_hash(activation_case):
    _, _, _, invoke = activation_case
    result, output = invoke(tamper_evidence_hash=True)
    _rejected(result, output, "build identity differs")


@pytest.mark.parametrize("suffix", [".000Z", "+00:00"])
def test_noncanonical_date_is_rejected(activation_case, suffix):
    metadata, _, _, invoke = activation_case
    metadata["issuedAt"] = metadata["issuedAt"].removesuffix("Z") + suffix
    result, output = invoke()
    _rejected(result, output, "metadata or review restriction is invalid")


def test_tampered_inner_signature_is_rejected(activation_case):
    _, _, _, invoke = activation_case
    result, output = invoke(tamper_signature=True)
    _rejected(result, output, "invalid signature")
