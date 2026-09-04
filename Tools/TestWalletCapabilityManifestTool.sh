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
canary = [
    "signer_audit",
    "application_penetration_test",
    "legal_regional_matrix",
    "provider_failover_load_test",
    "incident_drill",
    "notarized_artifact",
    "signed_update_feed",
]

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
    payload = {"schemaVersion": 1, "releaseRevision": 1, "approvals": rows}
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

ga = canary + ["release_candidate_soak"]
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
