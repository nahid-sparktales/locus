#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-capability-tool.XXXXXX")"
trap '/usr/bin/find "${work_dir}" -depth -delete' EXIT

/usr/bin/python3 - "${work_dir}" <<'PY'
import base64
import datetime
import hashlib
import json
import pathlib
import secrets
import sys

root = pathlib.Path(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
timestamp = (now - datetime.timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
release_approvals = [
    "signer_audit",
    "application_penetration_test",
    "legal_regional_matrix",
    "provider_failover_load_test",
    "incident_drill",
    "notarized_artifact",
    "signed_update_feed",
    "derivation_reproduction",
    "release_candidate_build",
]
canary = ["release_candidate_build"]

def evidence(approvals, destination):
    rows = []
    for approval in approvals:
        artifact = root / f"{approval}.txt"
        artifact.write_text(f"fixture evidence: {approval}\n", encoding="utf-8")
        row = {
            "approval": approval,
            "status": "passed",
            "reviewer": "Fixture Reviewer",
            "organization": "Fixture Organization",
            "completedAt": timestamp,
            "artifactPath": artifact.name,
            "artifactSHA256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
        }
        if approval in {"signer_audit", "application_penetration_test"}:
            row["unresolvedCritical"] = 0
            row["unresolvedHigh"] = 0
        if approval == "legal_regional_matrix":
            row["approvedRegions"] = ["CA"]
        if approval == "release_candidate_soak":
            row["metrics"] = {
                "duration_days": 1,
                "external_testers": 1,
                "ethereum_successful_transactions": 1,
                "solana_successful_transactions": 1,
                "sui_successful_transactions": 1,
                "unauthorized_signing": 0,
                "secret_exposure": 0,
                "unrecoverable_vaults": 0,
                "unresolved_broadcast_ambiguity": 0,
                "loss_producing_decoder_discrepancy": 0,
            }
        rows.append(row)
    payload = {
        "schemaVersion": 2,
        "releaseRevision": 1,
        "sourceRevision": "a" * 40,
        "artifactIdentity": {
            "bundleVersion": "1",
            "outerAppCodeDirectoryHash": "b" * 40,
            "signerCodeDirectoryHash": "c" * 40,
            "archiveSHA256": "d" * 64,
        },
        "approvals": rows,
        "phase": "testnet_rehearsal_authorization",
        "candidateID": "e" * 64,
        "authoritySHA256": "f" * 64,
        "chainTotals": [
            {"chain": "evm", "successfulTransactions": 0},
            {"chain": "solana", "successfulTransactions": 0},
            {"chain": "sui", "successfulTransactions": 0},
        ],
        "actionCoverage": [],
        "connectionCoverage": [],
        "soak": None,
    }
    ledger = {key: payload[key] for key in ("schemaVersion", "sourceRevision", "artifactIdentity",
                                          "phase", "candidateID", "authoritySHA256")}
    ledger["events"] = []
    ledger_path = destination.with_name(destination.stem + "-ledger.json")
    ledger_path.write_text(json.dumps(ledger, sort_keys=True, separators=(",", ":")), encoding="utf-8")
    payload["eventLedger"] = {"path": ledger_path.name, "sha256": hashlib.sha256(ledger_path.read_bytes()).hexdigest()}
    destination.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )

def manifest(evidence_path, destination, stage, approvals, network, connector, methods):
    payload = {
        "schemaVersion": 3,
        "revision": 1,
        "releaseStage": stage,
        "evidenceIndexSHA256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
        "issuedAt": timestamp,
        "expiresAt": (now + datetime.timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "networkGrants": [{
            "networkID": network,
            "capabilities": ["external_wallet"],
            "connectors": [{
                "connector": connector,
                "ownership": "connector_managed",
                "directions": ["external_account_to_locus"],
                "methods": methods,
            }],
        }],
        "approvedRegions": ["CA"],
        "completedApprovals": approvals,
    }
    destination.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )

canary_evidence = root / "canary-evidence.json"
evidence(canary, canary_evidence)
manifest(
    canary_evidence, root / "canary-manifest.json",
    "invited_canary", canary, "solana:devnet", "phantom",
    ["list_accounts", "send_transaction", "sign_in_with_solana"],
)
manifest(
    canary_evidence, root / "phantom-evm-manifest.json",
    "invited_canary", canary, "eip155:11155111", "phantom",
    ["list_accounts", "send_transaction", "sign_in_with_ethereum"],
)

ga = release_approvals + [
    "release_candidate_soak", "publication_disclosures", "support_security_readiness"
]
ga_evidence = root / "ga-evidence.json"
evidence(ga, ga_evidence)
manifest(
    ga_evidence, root / "under-threshold-ga-manifest.json",
    "general_availability", ga, "solana:devnet", "phantom",
    ["list_accounts", "send_transaction", "sign_in_with_solana"],
)
(root / "private-key.base64").write_text(
    base64.b64encode(secrets.token_bytes(32)).decode() + "\n",
    encoding="utf-8",
)
PY

/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletCapabilityManifest.swift" \
    "${work_dir}/canary-manifest.json" "${work_dir}/canary-evidence.json" \
    "${work_dir}/private-key.base64" "${work_dir}/signed.json" \
    > "${work_dir}/sign-result.txt"
/usr/bin/python3 - "${work_dir}/signed.json" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    signed = json.load(source)
assert len(base64.b64decode(signed["signatureBase64"], validate=True)) == 64
grant = signed["manifest"]["networkGrants"][0]
assert grant["networkID"] == "solana:devnet"
assert grant["connectors"][0]["connector"] == "phantom"
PY

if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletCapabilityManifest.swift" \
    "${work_dir}/phantom-evm-manifest.json" "${work_dir}/canary-evidence.json" \
    "${work_dir}/private-key.base64" "${work_dir}/phantom-evm-signed.json" \
    >/dev/null 2>&1
then
    echo "error: capability signer accepted Phantom on EVM" >&2
    exit 1
fi

if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletCapabilityManifest.swift" \
    "${work_dir}/under-threshold-ga-manifest.json" "${work_dir}/ga-evidence.json" \
    "${work_dir}/private-key.base64" "${work_dir}/ga-signed.json" \
    >/dev/null 2>&1
then
    echo "error: capability signer accepted an under-threshold GA soak" >&2
    exit 1
fi

echo "Wallet capability evidence and signing boundary verified."
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletCapabilityManifest.swift" \
    "${work_dir}/canary-manifest.json" "${work_dir}/canary-evidence.json" \
    "${work_dir}/private-key.base64" "${work_dir}/signed-repeat.json" >/dev/null
/usr/bin/python3 - "${work_dir}/signed.json" "${work_dir}/signed-repeat.json" <<'PY'
import json
import pathlib
import sys

first, repeated = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
assert first["manifest"] == repeated["manifest"], "Canonical manifest authority changed"
PY
# CryptoKit may use randomized Ed25519 nonces. Reproducibility concerns the
# signed authority bytes; both independent signatures must verify over those
# same bytes, not compare equal to one another.
public_key="$(/usr/bin/sed -n 's/^public_key_base64=//p' "${work_dir}/sign-result.txt")"
/usr/bin/xcrun swift -e '
import CryptoKit
import Foundation
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
for path in CommandLine.arguments.dropFirst(2) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let canonical = try JSONSerialization.data(withJSONObject: signed["manifest"]!, options: [.sortedKeys, .withoutEscapingSlashes])
    let signature = Data(base64Encoded: signed["signatureBase64"] as! String)!
    guard key.isValidSignature(signature, for: canonical) else { exit(1) }
}
' "${public_key}" "${work_dir}/signed.json" "${work_dir}/signed-repeat.json"
echo "Canonical capability authority and signatures verify across independent processes."
