"""Synthetic experimental issuer contracts, not signed-app/mainnet evidence.

The positive binary replaces ONLY the Security identity reader in a temporary
source copy. The actual CLI separately rejects unsigned bundles (including an
extra unsealed resource); this does not prove valid-signature tamper detection. No
production test switch, real key, configured provider or network call is used.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def run(*arguments):
    return subprocess.run(
        [str(value) for value in arguments], capture_output=True, text=True, timeout=90, check=False
    )


@pytest.fixture(scope="module")
def issuer_tools(tmp_path_factory):
    if sys.platform != "darwin" or shutil.which("xcrun") is None:
        pytest.skip("the experimental CLI requires macOS Security/CryptoKit")
    directory = tmp_path_factory.mktemp("experimental-issuer").resolve()
    source = (ROOT / "Tools/SignWalletExperimentalMainnet.swift").read_text()
    runtime_identity = (ROOT / "WalletConnectionsRuntime/WalletReleaseActivation.swift").read_text()
    assert "Contents/XPCServices/WalletSigner.xpc" in source
    assert "Contents/XPCServices/WalletSigner.xpc" in runtime_identity
    start = source.index("func verifiedCodeIdentity(")
    end = source.index("\nfunc runValidator(", start)
    fixture_reader = """func verifiedCodeIdentity(_ url: URL, identifier: String) throws -> CodeIdentity {
    let info = try plist(url.appendingPathComponent("Contents/Info.plist"))
    try require(info["CFBundleIdentifier"] as? String == identifier,
                "synthetic fixture identifier mismatch")
    return CodeIdentity(codeDirectoryHash: String(repeating: identifier.hasSuffix(".WalletSigner") ? "c" : "b", count: 40))
}
"""
    fixture_source = directory / "fixture-issuer.swift"
    fixture_source.write_text(source[:start] + fixture_reader + source[end:])
    assert source[:start] == fixture_source.read_text()[:start]
    helper_source = directory / "fixture-sign.swift"
    # Sign synthetic documents in the actual runtime's JSONEncoder domain.
    # Python below independently reconstructs the emitted authority digests.
    canonical_start = source.index("struct CanonicalJSON:")
    canonical_end = source.index("\nfunc hash(", canonical_start)
    helper = r"""
import CryptoKit
let mode = CommandLine.arguments[1], keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
if mode == "key" {
    try Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedData().write(to: keyURL)
} else {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: Data(contentsOf: keyURL))!)
    if mode == "public" { print(key.publicKey.rawRepresentation.base64EncodedString()); exit(0) }
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
    if mode == "verify" {
        guard key.publicKey.isValidSignature(Data(base64Encoded: value["signatureBase64"] as! String)!, for: try canonical(value["envelope"]!)) else { exit(1) }
    } else {
        let field = mode == "sign-ceiling" ? "ceiling" : "manifest"
        FileHandle.standardOutput.write(try canonical([field: value, "signatureBase64": key.signature(for: canonical(value)).base64EncodedString()]))
    }
}
"""
    helper_source.write_text(
        "import Foundation\n"
        "enum InputError: Error { case invalid(String) }\n"
        "func require(_ value: Bool, _ message: String) throws { if !value { throw InputError.invalid(message) } }\n"
        + source[canonical_start:canonical_end]
        + "\n"
        + helper
    )
    for name in ("SignWalletReviewManifest.swift", "VerifyWalletProviderBindings.py"):
        shutil.copyfile(ROOT / "Tools" / name, directory / name)
    binaries = {}
    for name, path in {
        "real": ROOT / "Tools/SignWalletExperimentalMainnet.swift",
        "synthetic": fixture_source,
        "helper": helper_source,
    }.items():
        binaries[name] = directory / name
        result = run("xcrun", "swiftc", path, "-o", binaries[name])
        assert result.returncode == 0, result.stderr
    binaries["directory"] = directory
    return binaries


@pytest.fixture
def issuer_case(tmp_path, issuer_tools):
    folder = tmp_path.resolve()
    key = folder / "disposable-key.base64"
    result = run(issuer_tools["helper"], "key", key)
    assert result.returncode == 0, result.stderr
    key.chmod(0o600)
    public = run(issuer_tools["helper"], "public", key).stdout.strip()
    app = folder / "Synthetic Experimental.app"
    signer = app / "Contents/XPCServices/WalletSigner.xpc"
    (signer / "Contents").mkdir(parents=True)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    issued = (now - timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
    expires = (now + timedelta(hours=1)).isoformat().replace("+00:00", "Z")

    # Build metadata starts with actual plist layout; unresolved build values are
    # blanked, then only externally supplied fixture build inputs are filled.
    def template(name):
        value = plistlib.loads((ROOT / "Config" / name).read_bytes())
        return {
            key: "" if isinstance(item, str) and "$(" in item else item
            for key, item in value.items()
        }

    info = template("LocusExperimental-Info.plist")
    info.update(
        {
            "CFBundleIdentifier": "io.sparktales.locus",
            "CFBundleVersion": "fixture-1",
            "LocusSourceRevision": "a" * 40,
            "LocusWalletExperimentalMainnetEnabled": True,
            "LocusWalletAlchemyEthereumMainnetRPCURL": "https://alchemy.example/fixture",
            "LocusWalletQuickNodeEthereumMainnetRPCURL": "https://quicknode.example/fixture",
        }
    )
    providers = [
        {
            "networkID": "eip155:1",
            "provider": provider.lower(),
            "configurationID": f"{provider.lower()}:eip155:1",
            "endpointSHA256": hashlib.sha256(
                info[f"LocusWallet{provider}EthereumMainnetRPCURL"].encode()
            ).hexdigest(),
            "expectedIdentity": {"kind": "eip155_chain_id", "value": "1"},
        }
        for provider in ("Alchemy", "QuickNode")
    ]
    scope = {
        "assets": [
            {
                "canonicalID": "eip155:1/slip44:60",
                "networkID": "eip155:1",
                "chain": "evm",
                "kind": "native",
                "name": "Synthetic Ether",
                "symbol": "TEST",
                "decimals": 18,
                "trust": "curated",
                "manifestRevision": 1,
            }
        ],
        "adapterIDs": [],
        "evmContracts": [],
        "explorerTemplates": {},
        "connectors": [],
        "providerIdentities": sorted(providers, key=canonical),
        "signInAdapters": [],
        "programIdentities": [],
        "uniswapConfigurations": [],
    }
    ceiling = {
        "schemaVersion": 1,
        "domain": "locus-wallet-review-ceiling-v1",
        "reviewRevision": 1,
        "reviewedAt": issued,
        "scope": scope,
    }
    review = copy.deepcopy(scope)
    review.update({"schemaVersion": 2, "revision": 7, "issuedAt": issued, "expiresAt": expires})
    review["assets"][0]["manifestRevision"] = 7
    cap = {
        "schemaVersion": 3,
        "revision": 7,
        "releaseStage": "experimental_mainnet",
        "evidenceIndexSHA256": "",
        "issuedAt": issued,
        "expiresAt": expires,
        "networkGrants": [
            {"networkID": "eip155:1", "capabilities": ["native_transfer"], "connectors": []}
        ],
        "approvedRegions": [],
        "completedApprovals": [],
        "canaryLimits": [],
    }
    signer_info = template("WalletSignerExperimental-Info.plist")
    signer_info.update(
        {
            "CFBundleIdentifier": "io.sparktales.locus.WalletSigner",
            "CFBundleVersion": "fixture-1",
            "LocusSourceRevision": "a" * 40,
            "LocusWalletExperimentalMainnetEnabled": True,
            "LocusWalletCapabilityPublicKey": public,
        }
    )
    archive = folder / "synthetic-archive.bin"
    archive.write_bytes(b"Synthetic archive; deliberately not claimed to contain a signed app.")
    return {
        "tools": issuer_tools,
        "folder": folder,
        "app": app,
        "signer": signer,
        "info": info,
        "signer_info": signer_info,
        "cap": cap,
        "review": review,
        "ceiling": ceiling,
        "key": key,
        "archive": archive,
        "public": public,
    }


def prepare(case):
    folder = case["folder"]
    for name, mode in (("review", "sign"), ("ceiling", "sign-ceiling")):
        unsigned = folder / f"unsigned-{name}.json"
        unsigned.write_bytes(canonical(case[name]))
        signed = run(case["tools"]["helper"], mode, case["key"], unsigned)
        assert signed.returncode == 0, signed.stderr
        (folder / f"signed-{name}.json").write_text(signed.stdout)
    encoded = base64.b64encode((folder / "signed-ceiling.json").read_bytes()).decode()
    for info, root in ((case["info"], case["app"]), (case["signer_info"], case["signer"])):
        if root == case["signer"] and not info.get("LocusWalletReviewCeilingBase64"):
            info["LocusWalletReviewCeilingBase64"] = encoded
        (root / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (folder / "capability.json").write_bytes(canonical(case["cap"]))


def issue(case, *, real=False, prepare_inputs=True):
    if prepare_inputs:
        prepare(case)
    folder = case["folder"]
    return run(
        case["tools"]["real" if real else "synthetic"],
        case["app"],
        case["archive"],
        folder / "capability.json",
        folder / "signed-review.json",
        folder / "signed-ceiling.json",
        case["key"],
        folder / "history.json",
    )


def assert_rejected(case, **kwargs):
    result = issue(case, **kwargs)
    assert result.returncode != 0
    assert not (case["folder"] / "history.json").exists()
    assert case["key"].read_text().strip() not in result.stdout + result.stderr
    assert "alchemy.example" not in result.stdout + result.stderr
    return result


def test_synthetic_initial_history_has_exact_independent_digests_and_no_release_claims(issuer_case):
    case = issuer_case
    result = issue(case)
    assert result.returncode == 0, result.stderr
    history = json.loads((case["folder"] / "history.json").read_text())
    assert set(history) == {"schemaVersion", "transitions"}
    assert history["schemaVersion"] == 1 and len(history["transitions"]) == 1
    signed = history["transitions"][0]
    envelope = signed["envelope"]
    cap = envelope["capabilityManifest"]["manifest"]
    assert envelope["revision"] == cap["revision"] == 7  # Caller allocated; never forced to one.
    assert envelope["purpose"] == envelope["releaseStage"] == "experimental_mainnet"
    assert envelope["transition"] == "initial"
    assert not {"cohortID", "previousEnvelopeSHA256"} & envelope.keys()
    assert envelope["admissionGeneration"] == 0 and envelope["revokedAdmissionSerials"] == []
    assert cap["completedApprovals"] == cap["approvedRegions"] == cap["canaryLimits"] == []
    assert cap["evidenceIndexSHA256"] == ""
    installed = {
        key: envelope[key]
        for key in (
            "sourceRevision",
            "bundleVersion",
            "outerAppCodeDirectoryHash",
            "signerCodeDirectoryHash",
        )
    }
    archive_hash = hashlib.sha256(case["archive"].read_bytes()).hexdigest()
    assert envelope["archiveSHA256"] == archive_hash
    assert envelope["reviewCeilingSHA256"] == digest(case["ceiling"])
    assert envelope["candidateID"] == digest(
        {
            "installedIdentity": installed,
            "archiveSHA256": archive_hash,
            "reviewCeilingSHA256": digest(case["ceiling"]),
        }
    )
    assert envelope["authoritySHA256"] == digest(
        {
            "networkGrants": cap["networkGrants"],
            "approvedRegions": [],
            "reviewScope": case["ceiling"]["scope"],
            "releaseStage": "experimental_mainnet",
            "canaryLimits": [],
            "permanentLimits": [],
            "admissionGeneration": 0,
            "revokedAdmissionSerials": [],
        }
    )
    for name, value in (
        ("outer", signed),
        (
            "inner",
            {
                "envelope": cap,
                "signatureBase64": envelope["capabilityManifest"]["signatureBase64"],
            },
        ),
    ):
        path = case["folder"] / f"verify-{name}.json"
        path.write_bytes(canonical(value))
        verified = run(case["tools"]["helper"], "verify", case["key"], path)
        assert verified.returncode == 0, verified.stderr
    assert (case["folder"] / "history.json").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize(
    "field,value",
    [
        ("revision", 0),
        ("revision", True),
        ("releaseStage", "invited_canary"),
        ("evidenceIndexSHA256", "a" * 64),
        ("completedApprovals", ["release_candidate_build"]),
        ("approvedRegions", ["CA"]),
        ("canaryLimits", [{}]),
        ("unexpected", True),
        ("issuedAt", "2026-01-01T00:00:00.000Z"),
        ("expiresAt", "2099-01-01T00:00:00Z"),
    ],
)
def test_issuer_rejects_fabricated_claims_and_invalid_lease(issuer_case, field, value):
    issuer_case["cap"][field] = value
    assert_rejected(issuer_case)


@pytest.mark.parametrize("bundle", ["info", "signer_info"])
@pytest.mark.parametrize("value", [False, "true", 1])
def test_both_bundles_require_actual_experimental_boolean(issuer_case, bundle, value):
    issuer_case[bundle]["LocusWalletExperimentalMainnetEnabled"] = value
    assert_rejected(issuer_case)


@pytest.mark.parametrize(
    "mutation",
    [
        "duplicate_network",
        "unsupported_capability",
        "wrong_ownership",
        "unreviewed_connector",
        "missing_provider",
        "changed_provider",
        "changed_chain",
        "broader_asset",
        "wrong_revision",
        "wrong_key",
        "wrong_ceiling",
        "wrong_source",
        "wrong_version",
    ],
)
def test_exact_scope_identity_and_configuration(issuer_case, mutation):
    case = issuer_case
    grant = case["cap"]["networkGrants"][0]
    if mutation == "duplicate_network":
        case["cap"]["networkGrants"].append(copy.deepcopy(grant))
    elif mutation == "unsupported_capability":
        grant["capabilities"].append("arbitrary_signing")
    elif mutation in {"wrong_ownership", "unreviewed_connector"}:
        grant["capabilities"].append("external_wallet")
        grant["connectors"] = [
            {
                "connector": "metamask",
                "ownership": "locus_vault" if mutation == "wrong_ownership" else "external",
                "directions": ["external_account_to_locus"],
                "methods": ["send_transaction"],
            }
        ]
    elif mutation == "missing_provider":
        case["info"].pop("LocusWalletQuickNodeEthereumMainnetRPCURL")
    elif mutation == "changed_provider":
        case["info"]["LocusWalletAlchemyEthereumMainnetRPCURL"] = (
            "https://different.example/fixture"
        )
    elif mutation == "changed_chain":
        case["review"]["providerIdentities"][0]["expectedIdentity"]["value"] = "11155111"
    elif mutation == "broader_asset":
        case["review"]["assets"][0]["decimals"] = 17
    elif mutation == "wrong_revision":
        case["cap"]["revision"] = 8
    elif mutation == "wrong_key":
        case["signer_info"]["LocusWalletCapabilityPublicKey"] = base64.b64encode(bytes(32)).decode()
    elif mutation == "wrong_ceiling":
        case["info"]["LocusWalletReviewCeilingBase64"] = base64.b64encode(b"{}").decode()
    elif mutation == "wrong_source":
        case["signer_info"]["LocusSourceRevision"] = "d" * 40
    else:
        case["signer_info"]["CFBundleVersion"] = "different"
    assert_rejected(case)


def test_signature_tamper_is_rejected(issuer_case):
    prepare(issuer_case)
    path = issuer_case["folder"] / "signed-review.json"
    signed = json.loads(path.read_text())
    signed["signatureBase64"] = base64.b64encode(bytes(64)).decode()
    path.write_bytes(canonical(signed))
    assert_rejected(issuer_case, prepare_inputs=False)


def test_authority_cannot_predate_its_valid_signed_ceiling(issuer_case):
    # Both documents are independently current and correctly signed. Only the
    # cross-document proof-time ordering is invalid; runtime rejects it too.
    issued = datetime.fromisoformat(issuer_case["cap"]["issuedAt"].replace("Z", "+00:00"))
    issuer_case["ceiling"]["reviewedAt"] = (
        (issued + timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
    )
    result = assert_rejected(issuer_case)
    assert "predates the bundled review ceiling" in result.stderr


def test_synthetic_all_three_mainnets_remain_explicit(issuer_case):
    case = issuer_case
    for network, name, chain, reference, identity in (
        (
            "solana:mainnet-beta",
            "SolanaMainnet",
            "solana",
            "slip44:501",
            {"kind": "solana_genesis_hash", "value": "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2d"},
        ),
        (
            "sui:mainnet",
            "SuiMainnet",
            "sui",
            "coin:0x2::sui::SUI",
            {
                "kind": "sui_chain_identifier",
                "value": "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S",
            },
        ),
    ):
        case["cap"]["networkGrants"].append(
            {
                "networkID": network,
                "capabilities": ["native_transfer"],
                "connectors": [],
            }
        )
        for provider in ("Alchemy", "QuickNode"):
            endpoint = f"https://{provider.lower()}.example/{chain}"
            case["info"][
                f"LocusWallet{provider}{name}{'GraphQLURL' if chain == 'sui' else 'RPCURL'}"
            ] = endpoint
            row = {
                "networkID": network,
                "provider": provider.lower(),
                "configurationID": f"{provider.lower()}:{network}",
                "endpointSHA256": hashlib.sha256(endpoint.encode()).hexdigest(),
                "expectedIdentity": identity,
            }
            case["review"]["providerIdentities"].append(copy.deepcopy(row))
            case["ceiling"]["scope"]["providerIdentities"].append(row)
        asset = {
            "canonicalID": f"{network}/{reference}",
            "networkID": network,
            "chain": chain,
            "kind": "native",
            "name": "Synthetic Native",
            "symbol": "TEST",
            "decimals": 9,
            "trust": "curated",
            "manifestRevision": 1,
        }
        case["ceiling"]["scope"]["assets"].append(asset)
        reviewed_asset = copy.deepcopy(asset)
        reviewed_asset["manifestRevision"] = 7
        case["review"]["assets"].append(reviewed_asset)
    for field in ("assets", "providerIdentities"):
        case["ceiling"]["scope"][field].sort(key=canonical)
    result = issue(case)
    assert result.returncode == 0, result.stderr
    history = json.loads((case["folder"] / "history.json").read_text())
    grants = history["transitions"][0]["envelope"]["capabilityManifest"]["manifest"][
        "networkGrants"
    ]
    assert {item["networkID"] for item in grants} == {
        "eip155:1",
        "solana:mainnet-beta",
        "sui:mainnet",
    }
    assert all(
        item["capabilities"] == ["native_transfer"] and item["connectors"] == [] for item in grants
    )


def test_sui_automation_remains_unavailable(issuer_case):
    issuer_case["cap"]["networkGrants"] = [
        {
            "networkID": "sui:mainnet",
            "capabilities": ["autonomous_policy"],
            "connectors": [],
        }
    ]
    assert_rejected(issuer_case)


@pytest.mark.parametrize("substitute_digest", [False, True])
def test_connector_requires_exact_sealed_configuration(issuer_case, substitute_digest):
    case = issuer_case
    config = {
        "format": "locus-wallet-connector-config-v1",
        "connector": "metamask",
        "rpcURLs": {"eip155:1": case["info"]["LocusWalletAlchemyEthereumMainnetRPCURL"]},
        "dappName": "Locus",
        "dappURL": "https://locus.app",
        "analyticsEnabled": False,
        "skipAutoAnnounce": True,
    }
    grant = {
        "connector": "metamask",
        "ownership": "external",
        "directions": ["external_account_to_locus"],
        "methods": ["send_transaction"],
    }
    reviewed = {
        **grant,
        "version": "2.1.1",
        "artifactSHA256": "e" * 64,
        "configurationSHA256": "f" * 64 if substitute_digest else digest(config),
    }
    case["review"]["connectors"] = [copy.deepcopy(reviewed)]
    case["ceiling"]["scope"]["connectors"] = [reviewed]
    case["cap"]["networkGrants"][0]["capabilities"].append("external_wallet")
    case["cap"]["networkGrants"][0]["connectors"] = [grant]
    if substitute_digest:
        assert_rejected(case)
    else:
        result = issue(case)
        assert result.returncode == 0, result.stderr


def test_incomplete_outer_authority_override_is_rejected(issuer_case):
    issuer_case["info"]["LocusWalletCapabilityPublicKey"] = issuer_case["public"]
    assert_rejected(issuer_case)


def test_private_key_requires_exclusive_permissions(issuer_case):
    issuer_case["key"].chmod(0o644)
    assert_rejected(issuer_case)


def test_symlink_key_is_rejected(issuer_case):
    original = issuer_case["key"]
    link = original.with_name("key-link")
    link.symlink_to(original)
    issuer_case["key"] = link
    assert_rejected(issuer_case)


def test_existing_output_is_never_overwritten(issuer_case):
    prepare(issuer_case)
    output = issuer_case["folder"] / "history.json"
    output.write_bytes(b"retain existing authority")
    result = issue(issuer_case, prepare_inputs=False)
    assert result.returncode != 0
    assert output.read_bytes() == b"retain existing authority"


@pytest.mark.parametrize("tamper", [False, True])
def test_unmodified_cli_rejects_unsigned_app_including_unsealed_resource(issuer_case, tamper):
    prepare(issuer_case)
    if tamper:
        (issuer_case["app"] / "Contents/unsealed-resource").write_bytes(b"tampered fixture")
    result = assert_rejected(issuer_case, real=True, prepare_inputs=False)
    assert "signature" in result.stderr or "signed executable" in result.stderr
