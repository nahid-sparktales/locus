#!/usr/bin/env python3
"""Derive wallet release evidence from bounded, attributable observation records.

This offline tool does not turn an observation into an independent chain audit.
It verifies identities, hash-linked records and report bytes, then recomputes
counts/coverage/continuity. Auditors remain responsible for observation truth.
No command signs, publishes, contacts a provider, or imports wallet secrets.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
from pathlib import Path

MAX_BYTES = 16 * 1024 * 1024
MAX_EVENTS = 50_000
MAINNETS = {"eip155:1", "solana:mainnet-beta", "sui:mainnet"}
REHEARSAL_NETWORKS = {
    "eip155:1": "eip155:11155111",
    "solana:mainnet-beta": "solana:devnet",
    "sui:mainnet": "sui:testnet",
}
CHAINS = {
    "eip155:1": "evm",
    "eip155:11155111": "evm",
    "solana:mainnet-beta": "solana",
    "solana:devnet": "solana",
    "sui:mainnet": "sui",
    "sui:testnet": "sui",
}
TRANSACTION_ACTIONS = {
    "native_transfer",
    "fungible_token_transfer",
    "nft_transfer",
    "exact_input_swap",
    "reviewed_call",
    "swap_allowance_setup",
}
ACTION_CAPABILITIES = TRANSACTION_ACTIONS | {"standardized_sign_in"}
METHODS = {
    "list_accounts",
    "switch_network",
    "send_transaction",
    "sign_in_with_ethereum",
    "sign_in_with_solana",
}
OWNERS = {
    "metamask": ("external", "locus_then_wallet", "external_account_to_locus"),
    "slush": ("external", "locus_then_wallet", "external_account_to_locus"),
    "phantom": ("connector_managed", "exact_locus", "external_account_to_locus"),
    "embedded_browser": (
        "locus_vault",
        "locus_review_or_policy",
        "locus_vault_to_dapp",
    ),
    "wallet_connect": ("locus_vault", "locus_review_or_policy", "locus_vault_to_dapp"),
    "locus": ("locus_vault", "locus_review_or_policy", "local"),
}
LOSS_EVENTS = {
    "unauthorized_signing",
    "secret_exposure",
    "unrecoverable_vaults",
    "unresolved_broadcast_ambiguity",
    "loss_producing_decoder_discrepancy",
}
DERIVED_FIELDS = {"chainTotals", "actionCoverage", "connectionCoverage", "soak"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def hex_value(value: object, length: int = 64) -> bool:
    return (
        isinstance(value, str)
        and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None
    )


def exact_keys(
    value: object, required: set[str], optional: set[str] | None = None
) -> dict:
    require(isinstance(value, dict), "expected an object")
    require(
        required <= value.keys() <= required | (optional or set()),
        "record contains missing, unsupported, or private fields",
    )
    return value


def timestamp(value: object) -> dt.datetime:
    require(
        isinstance(value, str)
        and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value) is not None,
        "timestamps must use canonical whole-second UTC",
    )
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=dt.timezone.utc
    )


def iso(value: dt.datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def bounded_bytes(path: Path) -> bytes:
    require(
        path.is_file() and path.stat().st_size <= MAX_BYTES,
        "missing or oversized evidence file",
    )
    value = path.read_bytes()
    require(len(value) <= MAX_BYTES, "evidence file grew beyond its limit")
    return value


def load(path: Path) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON member")
            result[key] = value
        return result

    value = json.loads(
        bounded_bytes(path),
        object_pairs_hook=pairs,
        parse_constant=lambda _: require(False, "non-finite JSON number"),
    )
    require(isinstance(value, dict), "expected an evidence object")
    return value


def referenced_bytes(root: Path, reference: dict) -> bytes:
    exact_keys(reference, {"path", "sha256"})
    require(
        isinstance(reference["path"], str) and hex_value(reference["sha256"]),
        "invalid evidence reference",
    )
    root = root.resolve()
    path = (root / reference["path"]).resolve()
    require(
        path.is_relative_to(root) and path != root,
        "evidence reference escapes its directory",
    )
    raw = bounded_bytes(path)
    require(digest(raw) == reference["sha256"], "evidence report digest differs")
    return raw


def validate_identity(identity: dict) -> None:
    exact_keys(
        identity,
        {
            "bundleVersion",
            "outerAppCodeDirectoryHash",
            "signerCodeDirectoryHash",
            "archiveSHA256",
        },
    )
    require(
        isinstance(identity["bundleVersion"], str)
        and 0 < len(identity["bundleVersion"].encode()) <= 64,
        "invalid bundle version",
    )
    require(
        hex_value(identity["outerAppCodeDirectoryHash"], 40)
        and hex_value(identity["signerCodeDirectoryHash"], 40)
        and hex_value(identity["archiveSHA256"]),
        "invalid archive or CDHash identity",
    )


def transaction_identifier(value: object, network: str) -> bool:
    if not isinstance(value, str):
        return False
    if network.startswith("eip155:"):
        return re.fullmatch(r"0x[0-9a-f]{64}", value) is not None
    size = 64 if network.startswith("solana:") else 32
    maximum = 88 if size == 64 else 44
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    if not size <= len(value) <= maximum or any(char not in alphabet for char in value):
        return False
    decoded = 0
    for char in value:
        decoded = decoded * 58 + alphabet.index(char)
    leading_zeroes = len(value) - len(value.lstrip("1"))
    return leading_zeroes + (decoded.bit_length() + 7) // 8 == size


def positive_integer(value: object) -> bool:
    return type(value) is int and 0 < value <= 2**53 - 1


def derive(index: dict, root: Path, *, now: dt.datetime | None = None) -> dict:
    """Recompute, never accept supplied counters. Every receipt is hash-bound."""
    now = now or dt.datetime.now(dt.timezone.utc)
    exact_keys(
        index,
        {
            "schemaVersion",
            "releaseRevision",
            "sourceRevision",
            "artifactIdentity",
            "phase",
            "candidateID",
            "authoritySHA256",
            "eventLedger",
            "approvals",
        },
        DERIVED_FIELDS,
    )
    require(
        index["schemaVersion"] == 2 and positive_integer(index["releaseRevision"]),
        "unsupported evidence schema or revision",
    )
    require(
        hex_value(index["sourceRevision"], 40)
        and hex_value(index["candidateID"])
        and hex_value(index["authoritySHA256"]),
        "invalid candidate identity",
    )
    validate_identity(index["artifactIdentity"])
    phase = index["phase"]
    require(
        phase
        in {"testnet_rehearsal_authorization", "pre_canary_rehearsal", "mainnet_soak"},
        "unknown evidence phase",
    )
    raw = referenced_bytes(root, index["eventLedger"])
    # Reuse strict JSON loading, including duplicate-member rejection.
    ledger_path = (root / index["eventLedger"]["path"]).resolve()
    ledger = load(ledger_path)
    require(
        digest(bounded_bytes(ledger_path)) == digest(raw),
        "ledger changed during verification",
    )
    exact_keys(
        ledger,
        {
            "schemaVersion",
            "sourceRevision",
            "artifactIdentity",
            "phase",
            "candidateID",
            "authoritySHA256",
            "events",
        },
    )
    require(ledger["schemaVersion"] == 2, "unsupported ledger schema")
    for field in (
        "sourceRevision",
        "artifactIdentity",
        "phase",
        "candidateID",
        "authoritySHA256",
    ):
        require(
            ledger[field] == index[field],
            "ledger belongs to another candidate, scope, or phase",
        )
    events = ledger["events"]
    require(
        isinstance(events, list)
        and len(events) <= MAX_EVENTS
        and (
            len(events) == 0
            if phase == "testnet_rehearsal_authorization"
            else len(events) > 0
        ),
        "authorization has no observations; other phases require bounded observations",
    )
    previous_hash = "0" * 64
    previous_time = dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    seen_operations: set[str] = set()
    seen_transactions: dict[tuple, tuple] = {}
    pending_ambiguities: dict[str, dict] = {}
    actions: dict[tuple, list[int]] = {}
    connections: dict[tuple, int] = {}
    totals = {chain: 0 for chain in ("evm", "solana", "sui")}
    testers: set[str] = set()
    segment_start = segment_end = lease_expiry = None
    active_revision = 0
    revisions: list[int] = []
    cohort = None
    losses = {name: 0 for name in sorted(LOSS_EVENTS)}
    for sequence, event in enumerate(events, 1):
        exact_keys(
            event,
            {
                "sequence",
                "previousEventSHA256",
                "occurredAt",
                "type",
                "reporterID",
                "report",
                "payload",
            },
        )
        require(
            type(event["sequence"]) is int
            and event["sequence"] == sequence
            and event["previousEventSHA256"] == previous_hash,
            "event lineage is broken",
        )
        previous_hash = digest(canonical(event))
        when = timestamp(event["occurredAt"])
        require(previous_time <= when <= now, "event time is reversed or in the future")
        previous_time = when
        require(
            hex_value(event["reporterID"]), "reporter must be a pseudonymous identifier"
        )
        referenced_bytes(root, event["report"])
        payload = event["payload"]
        kind = event["type"]
        if kind == "ambiguity_resolution":
            exact_keys(payload, {"operationID", "outcome", "transactionID"})
            require(
                payload["operationID"] in pending_ambiguities,
                "resolution has no pending ambiguous broadcast",
            )
            pending = pending_ambiguities[payload["operationID"]]
            require(payload["outcome"] == "reconciled", "unknown ambiguity resolution")
            require(
                transaction_identifier(
                    payload.get("transactionID"), pending["networkID"]
                )
                and (
                    "transactionID" not in pending
                    or pending["transactionID"] == payload["transactionID"]
                ),
                "ambiguity resolution substituted its public transaction",
            )
            del pending_ambiguities[payload["operationID"]]
            continue
        if kind == "security_loss":
            exact_keys(payload, {"category"})
            require(
                payload["category"] in LOSS_EVENTS, "unknown security-loss category"
            )
            losses[payload["category"]] += 1
            continue
        if kind == "interruption":
            exact_keys(payload, {"reason"})
            require(
                phase == "mainnet_soak"
                and payload["reason"]
                in {
                    "availability_gap",
                    "counted_scope_change",
                    "cohort_change",
                    "expired_lease",
                },
                "invalid soak interruption",
            )
            segment_start = segment_end = None
            continue
        if kind in {"publication", "renewal", "checkpoint"}:
            require(
                phase == "mainnet_soak", "mainnet lineage is not rehearsal evidence"
            )
            required = {"activationRevision", "authoritySHA256", "cohortID", "networks"}
            if kind != "checkpoint":
                required |= {"leaseIssuedAt", "leaseExpiresAt"}
            if kind == "publication":
                required |= {
                    "buildPublishedAt",
                    "activationPublishedAt",
                    "cohortAvailableAt",
                }
            if kind == "renewal":
                required |= {"previousActivationRevision"}
            exact_keys(payload, required)
            require(
                hex_value(payload["cohortID"])
                and payload["authoritySHA256"] == index["authoritySHA256"]
                and isinstance(payload["networks"], list)
                and len(payload["networks"]) == 3
                and set(payload["networks"]) == MAINNETS,
                "soak scope or all-chain cohort differs",
            )
            revision = payload["activationRevision"]
            require(
                positive_integer(revision) and revision < index["releaseRevision"],
                "soak must reference already-published activation revisions",
            )
            if kind == "publication":
                require(
                    segment_start is None and revision > active_revision,
                    "duplicate publication or rolled-back activation",
                )
                segment_start = max(
                    timestamp(payload[name])
                    for name in (
                        "buildPublishedAt",
                        "activationPublishedAt",
                        "cohortAvailableAt",
                    )
                )
                require(
                    segment_start <= when, "publication availability is in the future"
                )
                totals = {chain: 0 for chain in totals}
                actions, connections, testers = {}, {}, set()
                # Old transactions remain remembered: replay after a restart
                # cannot manufacture new confirmations or new coverage.
                cohort = payload["cohortID"]
                revisions = []
            else:
                require(
                    segment_start is not None
                    and lease_expiry is not None
                    and when <= lease_expiry
                    and cohort == payload["cohortID"],
                    "soak continuity was interrupted or its cohort changed",
                )
            if kind == "renewal":
                require(
                    payload["previousActivationRevision"] == active_revision
                    and revision > active_revision,
                    "renewal skips the recorded activation lineage",
                )
            if kind == "checkpoint":
                require(
                    revision == active_revision,
                    "checkpoint references an unknown activation",
                )
            else:
                issued, expiry = (
                    timestamp(payload["leaseIssuedAt"]),
                    timestamp(payload["leaseExpiresAt"]),
                )
                require(
                    issued <= when < expiry
                    and 0 < (expiry - issued).total_seconds() <= 31 * 86400,
                    "activation lease is invalid or exceeds 31 days",
                )
                require(
                    segment_start >= issued
                    if kind == "publication"
                    else issued <= lease_expiry,
                    "activation leases do not cover the soak",
                )
                lease_expiry, active_revision = expiry, revision
                revisions.append(revision)
            segment_end = when
            continue
        require(kind == "operation", "unknown observation event")
        exact_keys(
            payload,
            {
                "operationID",
                "networkID",
                "connector",
                "ownership",
                "direction",
                "method",
                "approvalModel",
                "outcome",
                "reconciliation",
                "testerID",
                "testerClass",
                "source",
            },
            {
                "action",
                "transactionID",
                "fixtureManifestSHA256",
                "activationRevision",
                "cohortID",
            },
        )
        require(
            hex_value(payload["operationID"])
            and payload["operationID"] not in seen_operations,
            "duplicate operation callback",
        )
        seen_operations.add(payload["operationID"])
        require(
            hex_value(payload["testerID"]), "tester must be a pseudonymous identifier"
        )
        require(payload["testerClass"] in {"external", "staff"}, "unknown tester class")
        require(
            payload["source"]
            in {
                "human",
                "agent",
                "embedded_browser",
                "wallet_connect",
                "release_harness",
            },
            "unknown request source",
        )
        require(
            payload["source"] != "release_harness" or phase == "pre_canary_rehearsal",
            "a release harness is not counted invited-mainnet activity",
        )
        require(
            payload["reconciliation"]
            in {"verified", "not_applicable", "pending", "failed", "ambiguous"},
            "unknown reconciliation result",
        )
        network, connector, method = (
            payload["networkID"],
            payload["connector"],
            payload["method"],
        )
        require(
            network in CHAINS and connector in OWNERS and method in METHODS,
            "unknown operation path",
        )
        require(
            payload["source"] not in {"embedded_browser", "wallet_connect"}
            or connector == payload["source"],
            "request source differs from its connection path",
        )
        if "transactionID" in payload:
            require(
                transaction_identifier(payload["transactionID"], network),
                "invalid public transaction identifier",
            )
        require(
            connector not in {"metamask", "phantom", "slush"}
            or CHAINS[network]
            == {"metamask": "evm", "phantom": "solana", "slush": "sui"}[connector],
            "connector is bound to another chain",
        )
        require(
            method != "sign_in_with_ethereum" or CHAINS[network] == "evm",
            "cross-chain SIWE",
        )
        require(
            method != "sign_in_with_solana" or CHAINS[network] == "solana",
            "cross-chain SIWS",
        )
        owner, expected_approval, direction = OWNERS[connector]
        require(
            payload["ownership"] == owner and payload["direction"] == direction,
            "operation ownership or direction differs",
        )
        action = payload.get("action")
        require(
            action is None or action in ACTION_CAPABILITIES, "unknown semantic action"
        )
        approval = payload["approvalModel"]
        if method in {"list_accounts", "switch_network"}:
            require(
                approval == "not_applicable" and action is None,
                "read is not a signing operation",
            )
        elif connector in {"metamask", "phantom", "slush"}:
            require(
                approval == expected_approval,
                "connector did not follow its required approval model",
            )
        else:
            require(
                approval in {"exact_locus", "signer_policy"},
                "invalid vault approval model",
            )
            if approval == "signer_policy":
                require(
                    action
                    in {
                        "native_transfer",
                        "fungible_token_transfer",
                        "exact_input_swap",
                    },
                    "collectibles, sign-in, and allowance setup cannot automate",
                )
        require(
            payload["outcome"]
            in {"success", "rejected", "timeout", "unavailable", "cancelled", "failed"},
            "unknown operation result",
        )
        success = payload["outcome"] == "success"
        is_transaction = method == "send_transaction"
        if payload["reconciliation"] == "ambiguous":
            require(
                is_transaction and not success,
                "only an unsuccessful broadcast can be ambiguous",
            )
            pending_ambiguities[payload["operationID"]] = payload
        if is_transaction:
            require(
                action in TRANSACTION_ACTIONS,
                "transaction lacks a supported semantic action",
            )
            if success:
                require(
                    transaction_identifier(payload.get("transactionID"), network)
                    and payload["reconciliation"] == "verified",
                    "success lacks reconciled public transaction",
                )
        else:
            require(
                "transactionID" not in payload
                and payload["reconciliation"] == "not_applicable",
                "non-transaction operation must not count a transaction",
            )
            if method.startswith("sign_in_"):
                require(
                    action == "standardized_sign_in",
                    "sign-in lacks canonical semantic action",
                )
        if phase == "pre_canary_rehearsal":
            require(
                network in REHEARSAL_NETWORKS.values()
                and hex_value(payload.get("fixtureManifestSHA256"))
                and "activationRevision" not in payload
                and "cohortID" not in payload,
                "rehearsals require signed testnet fixture identity, never counted mainnet",
            )
        else:
            require(
                network in MAINNETS
                and segment_start is not None
                and lease_expiry is not None
                and segment_start <= when <= lease_expiry
                and payload.get("activationRevision") == active_revision
                and payload.get("cohortID") == cohort
                and "fixtureManifestSHA256" not in payload,
                "operation is outside the active counted mainnet cohort",
            )
        if not success:
            continue
        if is_transaction:
            tx_key = (network, payload["transactionID"])
            semantics = (
                action,
                connector,
                owner,
                direction,
                method,
                payload["testerID"],
                payload["testerClass"],
            )
            if tx_key in seen_transactions:
                require(
                    seen_transactions[tx_key] == semantics,
                    "transaction reused for a different semantic effect",
                )
                continue
            seen_transactions[tx_key] = semantics
            totals[CHAINS[network]] += 1
        if payload["testerClass"] == "external":
            testers.add(payload["testerID"])
        if action:
            counts = actions.setdefault((network, action), [0, 0])
            counts[0] += 1
            counts[1] += int(is_transaction)
        if connector != "locus":
            key = (network, connector, direction, method)
            connections[key] = connections.get(key, 0) + 1
    require(
        not any(losses.values()),
        "a security-loss event requires a new candidate, not a reset counter",
    )
    require(
        not pending_ambiguities,
        "unresolved broadcast ambiguity blocks release evidence",
    )
    soak = None
    if phase == "mainnet_soak":
        require(
            segment_start is not None
            and segment_end is not None
            and lease_expiry is not None,
            "no continuous published all-chain soak segment",
        )
        require(
            events[-1]["type"] == "checkpoint",
            "counted observations require a final continuity checkpoint",
        )
        soak = {
            "startedAt": iso(segment_start),
            "through": iso(segment_end),
            "durationSeconds": int((segment_end - segment_start).total_seconds()),
            "externalTesters": len(testers),
            "cohortID": cohort,
            "authoritySHA256": index["authoritySHA256"],
            "activationRevisions": revisions,
            "securityLossEvents": losses,
        }
    return {
        "chainTotals": [
            {"chain": chain, "successfulTransactions": totals[chain]}
            for chain in sorted(totals)
        ],
        "actionCoverage": [
            {
                "networkID": key[0],
                "action": key[1],
                "successfulOperations": value[0],
                "successfulTransactions": value[1],
            }
            for key, value in sorted(actions.items())
        ],
        "connectionCoverage": [
            {
                "networkID": key[0],
                "connector": key[1],
                "direction": key[2],
                "method": key[3],
                "successfulOperations": value,
            }
            for key, value in sorted(connections.items())
        ],
        "soak": soak,
    }


def verify(
    index: dict, manifest: dict, root: Path, *, now: dt.datetime | None = None
) -> dict:
    result = derive(index, root, now=now)
    for field in DERIVED_FIELDS:
        require(
            index.get(field) == result[field],
            "supplied evidence counters differ from recorded observations",
        )
    require(
        index["releaseRevision"] == manifest["revision"], "evidence revision differs"
    )
    grants = manifest["networkGrants"]
    require(
        isinstance(grants, list)
        and len({grant["networkID"] for grant in grants}) == len(grants),
        "duplicate network grants",
    )
    stage, phase = manifest["releaseStage"], index["phase"]
    if phase == "testnet_rehearsal_authorization":
        require(
            stage == "invited_canary"
            and grants
            and all(
                grant["networkID"] in REHEARSAL_NETWORKS.values() for grant in grants
            ),
            "rehearsal authorization is strictly testnet-only",
        )
        return result
    if phase == "pre_canary_rehearsal":
        require(
            stage == "invited_canary"
            and MAINNETS <= {grant["networkID"] for grant in grants},
            "initial canary must activate Ethereum, Solana, and Sui together",
        )
    else:
        require(
            stage in {"invited_canary", "general_availability"},
            "unsupported release stage",
        )
    actions = {
        (item["networkID"], item["action"])
        for item in result["actionCoverage"]
        if item["successfulOperations"] > 0
    }
    connections = {
        (item["networkID"], item["connector"], item["direction"], item["method"])
        for item in result["connectionCoverage"]
        if item["successfulOperations"] > 0
    }
    for grant in grants:
        network = (
            REHEARSAL_NETWORKS.get(grant["networkID"], grant["networkID"])
            if phase == "pre_canary_rehearsal"
            else grant["networkID"]
        )
        for action in set(grant["capabilities"]) & ACTION_CAPABILITIES:
            require((network, action) in actions, "missing observed action coverage")
        for connector in grant["connectors"]:
            for direction in connector["directions"]:
                for method in connector["methods"]:
                    require(
                        (network, connector["connector"], direction, method)
                        in connections,
                        "missing observed connection operation coverage",
                    )
    if stage == "general_availability":
        require(
            phase == "mainnet_soak"
            and MAINNETS <= {grant["networkID"] for grant in grants},
            "GA requires the counted all-chain mainnet soak",
        )
        require(
            result["soak"]["durationSeconds"] >= 30 * 86400
            and result["soak"]["externalTesters"] >= 25
            and all(
                item["successfulTransactions"] >= 100 for item in result["chainTotals"]
            ),
            "observed soak does not meet duration, tester, or transaction thresholds",
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    collect = sub.add_parser("collect")
    collect.add_argument(
        "index", type=Path, help="identity/approval inputs plus eventLedger reference"
    )
    collect.add_argument("output", type=Path)
    check = sub.add_parser("verify")
    check.add_argument("index", type=Path)
    check.add_argument("manifest", type=Path)
    args = parser.parse_args()
    index = load(args.index)
    if args.command == "collect":
        require(
            not args.output.exists()
            and args.output.resolve().parent == args.index.resolve().parent,
            "choose a new output in the same evidence directory",
        )
        require(
            not DERIVED_FIELDS.intersection(index),
            "collector input must not contain caller-supplied counters",
        )
        index.update(derive(index, args.index.parent))
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(index, indent=2, sort_keys=True) + "\n")
        print(
            "Evidence derived from recorded observations; independent approvals remain mandatory."
        )
    else:
        manifest = load(args.manifest)
        verify(index, manifest.get("manifest", manifest), args.index.parent)
        print(
            "Recorded evidence identities, lineage, counts, coverage, and continuity verified."
        )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"wallet launch evidence failed: {error}") from None
