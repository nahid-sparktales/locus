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
    if mode == "public" { print(key.publicKey.rawRepresentation.base64EncodedString()); exit(0) }
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let object = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    if mode == "sign" || mode == "sign-ceiling" || mode == "sign-envelope" {
        let canonical = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let field = mode == "sign-ceiling" ? "ceiling" : mode == "sign-envelope" ? "envelope" : "manifest"
        let signed: [String: Any] = [field: object,
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
        (ROOT / "Tools/SignWalletReviewManifest.swift", directory / "sign-review"),
    ]:
        compiled = _run(["xcrun", "swiftc", source, "-o", binary])
        assert compiled.returncode == 0, compiled.stderr
    key_path = directory / "disposable-test-key.base64"
    key_result = _run([helper, "key", key_path])
    assert key_result.returncode == 0, key_result.stderr
    key_path.chmod(0o600)
    return cli, helper, key_path


@pytest.fixture(scope="module")
def review_time_validator(tmp_path_factory):
    """Compile the actual ceiling validator with a deterministic, non-CLI clock."""
    if sys.platform != "darwin" or shutil.which("xcrun") is None:
        pytest.skip("the release review validator requires macOS CryptoKit and Swift")
    source = (ROOT / "Tools/SignWalletReviewManifest.swift").read_text()
    # Keep every validator definition byte-identical; replace only the top-level
    # CLI entry point. No release command or environment variable overrides time.
    marker = "\ndo {\n"
    assert source.count(marker) == 1
    definitions = source.split(marker)[0]
    harness = r"""
let input = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
) as! [String: Any]
let now = Date(timeIntervalSince1970: Double(CommandLine.arguments[2])!)
let result = try validatedCeiling(input, requireNormalized: true, now: now)
FileHandle.standardOutput.write(try canonicalObject(result))
"""
    directory = tmp_path_factory.mktemp("wallet-review-clock")
    source_path = directory / "review-clock.swift"
    source_path.write_text(definitions + harness)
    binary = directory / "review-clock"
    result = _run(["xcrun", "swiftc", source_path, "-o", binary])
    assert result.returncode == 0, result.stderr
    return binary


@pytest.fixture
def activation_case(tmp_path, activation_tools):
    now = datetime.now(timezone.utc).replace(microsecond=0)

    def iso(value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    issued = iso(now - timedelta(minutes=1))
    expiry = iso(now + timedelta(hours=1))
    # Derive real CLI fixtures from the shipped template so schema drift cannot
    # leave release operators with an unusable starting document.
    metadata = json.loads((ROOT / "Config/WalletReleaseActivationMetadata.template.json").read_text())
    metadata.pop("cohortID")  # The isolated testnet rehearsal has no invited cohort.
    metadata.update({
        "schemaVersion": 2,
        "sourceRevision": "a" * 40,
        "bundleVersion": "fixture-1",
        "outerAppCodeDirectoryHash": "b" * 40,
        "signerCodeDirectoryHash": "c" * 40,
        "archiveSHA256": "d" * 64,
        "releaseStage": "invited_canary",
        "issuedAt": issued,
        "expiresAt": expiry,
        "revision": 2,
        "transition": "initial",
        "purpose": "testnet_rehearsal",
        "admissionGeneration": 0,
        "revokedAdmissionSerials": [],
        "permanentLimits": [],
    })
    evidence = {
        "schemaVersion": 2,
        "sourceRevision": metadata["sourceRevision"],
        "releaseRevision": 2,
        "phase": "testnet_rehearsal_authorization",
        "artifactIdentity": {
            "bundleVersion": metadata["bundleVersion"],
            "outerAppCodeDirectoryHash": metadata["outerAppCodeDirectoryHash"],
            "signerCodeDirectoryHash": metadata["signerCodeDirectoryHash"],
            "archiveSHA256": metadata["archiveSHA256"],
        },
    }
    review = {
        "schemaVersion": 2,
        "revision": 1,
        "issuedAt": issued,
        "expiresAt": expiry,
        "assets": [
            {
                "canonicalID": "eip155:11155111/slip44:60",
                "networkID": "eip155:11155111",
                "chain": "evm",
                "kind": "native",
                "name": "Fixture Ether",
                "symbol": "TEST",
                "decimals": 18,
                "trust": "curated",
                "manifestRevision": 1,
            }
        ],
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
    ceiling = {
        "schemaVersion": 1,
        "domain": "locus-wallet-review-ceiling-v1",
        "reviewRevision": 1,
        "reviewedAt": issued,
        "scope": {
            key: value
            for key, value in review.items()
            if key not in {"schemaVersion", "revision", "issuedAt", "expiresAt"}
        },
    }
    restriction = copy.deepcopy(review)
    restriction["revision"] = 2
    restriction["assets"][0]["manifestRevision"] = 2
    capability = {
        "schemaVersion": 3,
        "revision": 2,
        "releaseStage": "invited_canary",
        "issuedAt": issued,
        "expiresAt": expiry,
        # Testnet rehearsal fixture: deliberately no mainnet authority is granted.
        "networkGrants": [
            {"networkID": "eip155:11155111", "capabilities": ["native_transfer"], "connectors": []}
        ],
        "approvedRegions": [],
        "completedApprovals": ["release_candidate_build"],
    }
    cli, helper, key_path = activation_tools

    invocation_count = 0

    def invoke(
        *,
        tamper_signature=False,
        tamper_evidence_hash=False,
        previous=None,
        tamper_inner_date=False,
    ):
        nonlocal invocation_count
        invocation_count += 1
        paths = {
            name: tmp_path / f"{name}.json"
            for name in [
                "metadata",
                "capability",
                "restriction",
                "ceiling",
                "evidence",
                "output",
                "ledger",
                "build-report",
            ]
        }
        paths["output"] = tmp_path / f"output-{invocation_count}.json"
        capability["revision"] = restriction["revision"] = evidence["releaseRevision"] = metadata[
            "revision"
        ]
        for item in restriction["assets"]:
            item["manifestRevision"] = metadata["revision"]
        if previous is not None:
            metadata["previousEnvelopeSHA256"] = hashlib.sha256(
                json.dumps(previous["envelope"], sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
        if tamper_inner_date:
            capability["issuedAt"] = capability["issuedAt"].removesuffix("Z") + ".000Z"
        # Describe computes the same normalization as the issuer, before any
        # evidence or signature can depend on these identifiers.
        for name, value in [
            ("metadata", metadata),
            ("capability", capability),
            ("restriction", restriction),
        ]:
            _write(paths[name], value)
        _write(paths["ceiling"], {"ceiling": ceiling})
        described = _run(
            [
                cli,
                "--describe",
                paths["metadata"],
                paths["capability"],
                paths["restriction"],
                paths["ceiling"],
            ]
        )
        assert described.returncode == 0, described.stderr
        metadata.update(json.loads(described.stdout))
        evidence.update(
            candidateID=metadata["candidateID"], authoritySHA256=metadata["authoritySHA256"]
        )
        if previous is not None and metadata["transition"] in {"restriction", "promotion"}:
            evidence["authoritySHA256"] = previous["envelope"]["authoritySHA256"]
        ledger = {
            key: evidence[key]
            for key in [
                "schemaVersion",
                "sourceRevision",
                "artifactIdentity",
                "phase",
                "candidateID",
                "authoritySHA256",
            ]
        }
        ledger["events"] = []
        _write(paths["ledger"], ledger)
        _write(paths["build-report"], {"synthetic": True, "notReleaseEvidence": True})
        evidence.update(
            eventLedger={
                "path": paths["ledger"].name,
                "sha256": hashlib.sha256(paths["ledger"].read_bytes()).hexdigest(),
            },
            approvals=[
                {
                    "approval": "release_candidate_build",
                    "status": "passed",
                    "reviewer": "Synthetic fixture",
                    "organization": "Tests only",
                    "completedAt": issued,
                    "artifactPath": paths["build-report"].name,
                    "artifactSHA256": hashlib.sha256(
                        paths["build-report"].read_bytes()
                    ).hexdigest(),
                }
            ],
            chainTotals=[
                {"chain": chain, "successfulTransactions": 0} for chain in ["evm", "solana", "sui"]
            ],
            actionCoverage=[],
            connectionCoverage=[],
            soak=None,
        )
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
            result = _run(
                [helper, "sign-ceiling" if name == "ceiling" else "sign", key_path, paths[name]]
            )
            assert result.returncode == 0, result.stderr
            signed = json.loads(result.stdout)
            if tamper_signature and name == "restriction":
                signed["signatureBase64"] = base64.b64encode(bytes(64)).decode()
            _write(paths[name], signed)
        previous_argument = "initial"
        if previous is not None:
            previous_argument = tmp_path / "previous-envelope.json"
            _write(previous_argument, previous)
        result = _run(
            [
                cli,
                paths["metadata"],
                paths["capability"],
                paths["restriction"],
                paths["ceiling"],
                paths["evidence"],
                previous_argument,
                key_path,
                paths["output"],
            ]
        )
        return result, paths["output"]

    invoke.capability = capability
    invoke.ceiling = ceiling
    return metadata, evidence, restriction, invoke


def _rejected(result, output: Path, message: str) -> None:
    assert result.returncode != 0
    assert message in result.stderr
    assert not output.exists(), "a rejected input must not produce a signed envelope"


def test_unfilled_release_template_remains_nonactivating(activation_tools, tmp_path):
    template_path = ROOT / "Config/WalletReleaseActivationMetadata.template.json"
    template = json.loads(template_path.read_text())
    assert template["schemaVersion"] == 2
    assert template["revision"] == template["admissionGeneration"] == 0
    assert template["revokedAdmissionSerials"] == template["permanentLimits"] == []
    for field in ("sourceRevision", "outerAppCodeDirectoryHash", "signerCodeDirectoryHash",
                  "archiveSHA256", "candidateID", "reviewCeilingSHA256", "authoritySHA256",
                  "cohortID", "issuedAt", "expiresAt"):
        assert template[field] == ""
    cli, _, _ = activation_tools
    empty = tmp_path / "empty.json"
    ceiling = tmp_path / "ceiling.json"
    _write(empty, {})
    _write(ceiling, {"ceiling": {"scope": {}}})
    result = _run([cli, "--describe", template_path, empty, empty, ceiling])
    assert result.returncode != 0
    assert "sourceRevision is required" in result.stderr
    assert not result.stdout


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


def test_noncanonical_nested_lease_date_is_rejected(activation_case):
    _, _, _, invoke = activation_case
    result, output = invoke(tamper_inner_date=True)
    _rejected(result, output, "metadata or review restriction is invalid")


def test_unchanged_scope_renewal_requires_previous_signed_history(activation_case):
    metadata, _, _, invoke = activation_case
    result, output = invoke()
    assert result.returncode == 0, result.stderr
    previous = json.loads(output.read_text())
    metadata.update(revision=3, transition="renewal")
    result, output = invoke(previous=previous)
    assert result.returncode == 0, result.stderr
    assert (
        json.loads(output.read_text())["envelope"]["authoritySHA256"]
        == previous["envelope"]["authoritySHA256"]
    )


def test_renewal_cannot_change_reviewed_authority(activation_case):
    metadata, _, _, invoke = activation_case
    result, output = invoke()
    assert result.returncode == 0, result.stderr
    previous = json.loads(output.read_text())
    metadata.update(revision=3, transition="renewal")
    invoke.capability["approvedRegions"] = ["US"]
    result, output = invoke(previous=previous)
    _rejected(result, output, "renewal changed authority")


def test_narrowing_floor_cannot_restore_a_removed_grant(activation_case):
    metadata, _, _, invoke = activation_case
    invoke.capability["networkGrants"][0]["capabilities"] = [
        "fungible_token_transfer",
        "native_transfer",
    ]
    result, output = invoke()
    assert result.returncode == 0, result.stderr
    initial = json.loads(output.read_text())
    metadata.update(revision=3, transition="restriction")
    invoke.capability["networkGrants"][0]["capabilities"] = ["native_transfer"]
    result, output = invoke(previous=initial)
    assert result.returncode == 0, result.stderr
    narrowed = json.loads(output.read_text())
    metadata["revision"] = 4
    invoke.capability["networkGrants"][0]["capabilities"] = [
        "fungible_token_transfer",
        "native_transfer",
    ]
    result, output = invoke(previous=narrowed)
    _rejected(result, output, "restore previously restricted authority")


@pytest.mark.parametrize("fraction", [0.0, 0.5, 0.9994, 0.9995, 0.9999, 0.999999])
def test_nonactivating_review_ceiling_accepts_valid_identities_at_second_boundary(
    activation_case, review_time_validator, tmp_path, fraction
):
    _, _, _, invoke = activation_case
    ceiling = copy.deepcopy(invoke.ceiling)
    ceiling["reviewedAt"] = "2023-11-14T22:12:00Z"
    path = tmp_path / "reviewed-ceiling.json"
    _write(path, ceiling)
    result = _run([review_time_validator, path, str(1_700_000_000 + fraction)])
    assert result.returncode == 0, result.stderr
    # The synthetic projection is only a validation aid. It must not change any
    # signed ceiling bytes or add an operational lease to the nonactivating scope.
    assert json.loads(result.stdout) == ceiling


@pytest.mark.parametrize("mutation", ["future-review", "ownership", "method"])
def test_second_boundary_never_relaxes_review_time_or_identity_validation(
    activation_case, review_time_validator, tmp_path, mutation
):
    _, _, _, invoke = activation_case
    ceiling = copy.deepcopy(invoke.ceiling)
    ceiling["reviewedAt"] = "2023-11-14T22:12:00Z"
    if mutation == "future-review":
        ceiling["reviewedAt"] = "2023-11-14T22:13:21Z"
    elif mutation == "ownership":
        ceiling["scope"]["connectors"][0]["ownership"] = "locus_vault"
    else:
        ceiling["scope"]["connectors"][0]["methods"] = ["arbitrary_signing"]
    path = tmp_path / "invalid-ceiling.json"
    _write(path, ceiling)
    result = _run([review_time_validator, path, "1700000000.9999"])
    assert result.returncode != 0
    assert not result.stdout
    expected = "schema, date, or signature domain" if mutation == "future-review" else "invalid reviewed identities"
    assert expected in result.stderr


def test_missing_previous_history_cannot_issue_renewal(activation_case):
    metadata, _, _, invoke = activation_case
    metadata["transition"] = "renewal"
    result, output = invoke()
    _rejected(result, output, "initial activation requires explicit initial lineage")


def test_restriction_cannot_delete_an_existing_canary_limit_identity(activation_case):
    metadata, _, _, invoke = activation_case
    invoke.capability["canaryLimits"] = [
        {
            "networkID": "eip155:11155111",
            "assetID": "eip155:11155111/slip44:60",
            "action": "native_transfer",
            "ownership": "locus_vault",
            "maximumTransactionBaseUnits": "10",
            "maximumCumulativeBaseUnits": "100",
            "maximumFeeBaseUnits": "10",
            "maximumCumulativeFeeBaseUnits": "100",
            "maximumTransactions": 10,
        }
    ]
    result, output = invoke()
    assert result.returncode == 0, result.stderr
    previous = json.loads(output.read_text())
    metadata.update(revision=3, transition="restriction")
    invoke.capability["canaryLimits"] = []
    result, output = invoke(previous=previous)
    _rejected(result, output, "emergency limit reduction must remain permanent")


@pytest.mark.parametrize(
    "mutation",
    [
        None,
        "archiveSHA256",
        "sourceRevision",
        "outerAppCodeDirectoryHash",
        "signerCodeDirectoryHash",
        "signature",
        "canary",
    ],
)
def test_stable_feed_promotion_requires_exact_retained_archive(
    activation_case, activation_tools, tmp_path, mutation
):
    metadata, _, review, invoke = activation_case
    cli, helper, key = activation_tools
    metadata.update(
        transition="promotion",
        purpose="production",
        releaseStage="general_availability",
        previousEnvelopeSHA256="9" * 64,
    )
    capability = copy.deepcopy(invoke.capability)
    capability["releaseStage"] = "general_availability"
    capability["evidenceIndexSHA256"] = "8" * 64
    review["revision"] = metadata["revision"]
    paths = {
        name: tmp_path / f"promotion-{name}.json"
        for name in ["metadata", "capability", "review", "ceiling", "signed", "identity"]
    }
    for name, value in [
        ("metadata", metadata),
        ("capability", capability),
        ("review", review),
        ("ceiling", {"ceiling": invoke.ceiling}),
    ]:
        _write(paths[name], value)
    described = _run(
        [
            cli,
            "--describe",
            *[paths[name] for name in ["metadata", "capability", "review", "ceiling"]],
        ]
    )
    assert described.returncode == 0, described.stderr
    metadata.update(json.loads(described.stdout))
    for name, field, value, mode in [
        ("capability", "capabilityManifest", capability, "sign"),
        ("review", "reviewRestriction", review, "sign"),
    ]:
        _write(paths[name], value)
        signed = _run([helper, mode, key, paths[name]])
        assert signed.returncode == 0, signed.stderr
        metadata[field] = json.loads(signed.stdout)
    _write(paths["ceiling"], invoke.ceiling)
    signed = _run([helper, "sign-ceiling", key, paths["ceiling"]])
    _write(paths["ceiling"], json.loads(signed.stdout))
    if mutation == "canary":
        metadata["releaseStage"] = "invited_canary"
    _write(paths["metadata"], metadata)
    signed = json.loads(_run([helper, "sign-envelope", key, paths["metadata"]]).stdout)
    if mutation == "signature":
        signed["signatureBase64"] = base64.b64encode(bytes(64)).decode()
    _write(paths["signed"], signed)
    identity = {
        field: metadata[field]
        for field in [
            "sourceRevision",
            "bundleVersion",
            "outerAppCodeDirectoryHash",
            "signerCodeDirectoryHash",
            "archiveSHA256",
        ]
    }
    if mutation in identity:
        identity[mutation] = "0" * len(identity[mutation])
    _write(paths["identity"], identity)
    public = _run([helper, "public", key]).stdout.strip()
    result = _run(
        [cli, "--verify-promotion", paths["signed"], public, paths["identity"], paths["ceiling"]]
    )
    assert (result.returncode == 0) == (mutation is None), result.stderr


def test_ceiling_issuer_normalizes_nonactivating_scope(activation_case, activation_tools, tmp_path):
    _, _, _, invoke = activation_case
    cli, _, key = activation_tools
    input_path, output_path = tmp_path / "ceiling-input.json", tmp_path / "signed-ceiling.json"
    _write(input_path, invoke.ceiling)
    result = _run([cli.parent / "sign-review", "--sign-ceiling", input_path, key, output_path])
    assert result.returncode == 0, result.stderr
    ceiling = json.loads(output_path.read_text())["ceiling"]
    assert "expiresAt" not in ceiling and "issuedAt" not in ceiling
    assert ceiling["domain"] == "locus-wallet-review-ceiling-v1"
    public_key = next(
        line.split("=", 1)[1]
        for line in result.stdout.splitlines()
        if line.startswith("public_key_base64=")
    )
    verified = _run([cli.parent / "sign-review", "--verify-ceiling", output_path, public_key])
    assert verified.returncode == 0, verified.stderr


def test_ceiling_rejects_operational_expiry(activation_case, activation_tools, tmp_path):
    metadata, _, _, invoke = activation_case
    cli, _, key = activation_tools
    invoke.ceiling["expiresAt"] = metadata["expiresAt"]
    input_path, output_path = tmp_path / "ceiling-input.json", tmp_path / "signed-ceiling.json"
    _write(input_path, invoke.ceiling)
    result = _run([cli.parent / "sign-review", "--sign-ceiling", input_path, key, output_path])
    _rejected(result, output_path, "signature domain is invalid")


@pytest.fixture
def admission_case(activation_case, activation_tools, tmp_path):
    metadata, _, restriction, invoke = activation_case
    cli, helper, key = activation_tools
    # Signature-layer fixture only: no mainnet grants and no installed identity.
    metadata.update(purpose="production", cohortID="1" * 64, admissionGeneration=1)
    limit = {
        "networkID": "eip155:11155111",
        "assetID": "eip155:11155111/slip44:60",
        "action": "native_transfer",
        "ownership": "locus_vault",
        "maximumTransactionBaseUnits": "10",
        "maximumCumulativeBaseUnits": "100",
        "maximumFeeBaseUnits": "10",
        "maximumCumulativeFeeBaseUnits": "100",
        "maximumTransactions": 10,
    }
    invoke.capability["canaryLimits"] = [limit]
    paths = {
        name: tmp_path / f"admission-{name}.json"
        for name in ["metadata", "capability", "review", "ceiling", "envelope", "input", "output"]
    }
    for name, value in [
        ("metadata", metadata),
        ("capability", invoke.capability),
        ("review", restriction),
        ("ceiling", {"ceiling": invoke.ceiling}),
    ]:
        _write(paths[name], value)
    result = _run(
        [
            cli,
            "--describe",
            paths["metadata"],
            paths["capability"],
            paths["review"],
            paths["ceiling"],
        ]
    )
    assert result.returncode == 0, result.stderr
    metadata.update(json.loads(result.stdout))
    envelope = copy.deepcopy(metadata)
    for field, name in [("capabilityManifest", "capability"), ("reviewRestriction", "review")]:
        signed = _run([helper, "sign", key, paths[name]])
        assert signed.returncode == 0, signed.stderr
        envelope[field] = json.loads(signed.stdout)
    _write(paths["envelope"], envelope)
    signed = _run([helper, "sign-envelope", key, paths["envelope"]])
    assert signed.returncode == 0, signed.stderr
    _write(paths["envelope"], json.loads(signed.stdout))
    admission = {
        "schemaVersion": 1,
        "domain": "locus-wallet-canary-admission-v1",
        "candidateID": metadata["candidateID"],
        "cohortID": metadata["cohortID"],
        "installationID": "2" * 64,
        "serial": "3" * 64,
        "generation": 1,
        "issuedAt": metadata["issuedAt"],
        "expiresAt": metadata["expiresAt"],
        "allocation": [copy.deepcopy(limit)],
    }

    def issue():
        _write(paths["input"], admission)
        result = _run(
            [cli, "--sign-admission", paths["input"], paths["envelope"], key, paths["output"]]
        )
        return result, paths["output"]

    return admission, issue


def test_admission_binds_device_and_finite_allocation(admission_case):
    admission, issue = admission_case
    result, output = issue()
    assert result.returncode == 0, result.stderr
    signed = json.loads(output.read_text())
    assert signed["admission"] == admission
    assert len(base64.b64decode(signed["signatureBase64"])) == 64


@pytest.mark.parametrize(
    "mutation", ["candidate", "device", "generation", "expiry", "amount", "arbitrary_field"]
)
def test_admission_rejects_substitution_and_broader_authority(admission_case, mutation):
    admission, issue = admission_case
    if mutation == "candidate":
        admission["candidateID"] = "0" * 64
    elif mutation == "device":
        admission["installationID"] = "an-unbound-address-or-device-name"
    elif mutation == "generation":
        admission["generation"] = 2
    elif mutation == "expiry":
        admission["expiresAt"] = (
            (datetime.now(timezone.utc) + timedelta(days=32))
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    elif mutation == "amount":
        admission["allocation"][0]["maximumTransactionBaseUnits"] = "11"
    else:
        admission["rawRequest"] = "not-permitted"
    result, output = issue()
    _rejected(
        result,
        output,
        "admission identity, expiry, revocation state, or finite allocation is invalid",
    )
