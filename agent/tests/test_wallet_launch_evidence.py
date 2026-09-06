"""Synthetic offline evidence contracts; these records are never release evidence."""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "wallet_evidence", ROOT / "Tools/WalletLaunchEvidence.py"
)
E = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(E)
NOW = dt.datetime(2026, 9, 4, 12, tzinfo=dt.timezone.utc)


def token(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def public_transaction(network, n):
    if network.startswith("eip155:"):
        return "0x" + f"{n:064x}"
    size = 64 if network.startswith("solana:") else 32
    value = int.from_bytes(bytes([7]) * (size - 4) + n.to_bytes(4, "big"), "big")
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    result = ""
    while value:
        value, remainder = divmod(value, 58)
        result = alphabet[remainder] + result
    return result


class Case:
    def __init__(self, root: Path, phase="pre_canary_rehearsal"):
        self.root = root
        self.phase = phase
        self.cohort = token("synthetic-cohort")
        self.events = []
        report = b"Synthetic normalized fixture observation. Not an audit or release approval."
        (root / "observation.json").write_bytes(report)
        self.report = {"path": "observation.json", "sha256": E.digest(report)}
        self.index = {
            "schemaVersion": 2,
            "releaseRevision": 3,
            "sourceRevision": "a" * 40,
            "artifactIdentity": {
                "bundleVersion": "fixture",
                "outerAppCodeDirectoryHash": "b" * 40,
                "signerCodeDirectoryHash": "c" * 40,
                "archiveSHA256": "d" * 64,
            },
            "phase": phase,
            "candidateID": token("candidate"),
            "authoritySHA256": token("scope"),
            "eventLedger": {},
            "approvals": [],
        }
        self.manifest = {
            "revision": 3,
            "releaseStage": "invited_canary",
            "networkGrants": [
                {
                    "networkID": network,
                    "capabilities": ["native_transfer", "external_wallet"],
                    "connectors": [
                        {
                            "connector": connector,
                            "ownership": E.OWNERS[connector][0],
                            "directions": ["external_account_to_locus"],
                            "methods": ["send_transaction"],
                        }
                    ],
                }
                for network, connector in [
                    ("eip155:1", "metamask"),
                    ("solana:mainnet-beta", "phantom"),
                    ("sui:mainnet", "slush"),
                ]
            ],
        }

    def event(self, kind, payload, when=NOW - dt.timedelta(hours=1)):
        self.events.append(
            {
                "sequence": len(self.events) + 1,
                "previousEventSHA256": E.digest(E.canonical(self.events[-1]))
                if self.events
                else "0" * 64,
                "occurredAt": E.iso(when),
                "type": kind,
                "reporterID": token("fixture-observer"),
                "report": self.report,
                "payload": payload,
            }
        )

    def operation(self, network, connector, n=1, *, when=NOW - dt.timedelta(hours=1), **changes):
        owner, approval, direction = E.OWNERS[connector]
        tx = public_transaction(network, n)
        payload = {
            "operationID": token(f"{network}:{n}:{len(self.events)}"),
            "networkID": network,
            "connector": connector,
            "ownership": owner,
            "direction": direction,
            "method": "send_transaction",
            "action": "native_transfer",
            "approvalModel": approval,
            "outcome": "success",
            "reconciliation": "verified",
            "transactionID": tx,
            "testerID": token(f"tester-{n % 25}"),
            "testerClass": "external",
            "source": "human",
        }
        if self.phase == "pre_canary_rehearsal":
            payload["fixtureManifestSHA256"] = token("signed-fixture")
        else:
            payload.update(activationRevision=1, cohortID=self.cohort)
        payload.update(changes)
        for key in [key for key, value in payload.items() if value is None]:
            del payload[key]
        self.event("operation", payload, when)

    def publication(self, start=NOW - dt.timedelta(days=30, hours=1), *, revision=1):
        self.event(
            "publication",
            {
                "activationRevision": revision,
                "authoritySHA256": self.index["authoritySHA256"],
                "cohortID": self.cohort,
                "networks": sorted(E.MAINNETS),
                "leaseIssuedAt": E.iso(start - dt.timedelta(seconds=1)),
                "leaseExpiresAt": E.iso(start + dt.timedelta(days=31, seconds=-1)),
                "buildPublishedAt": E.iso(start - dt.timedelta(minutes=1)),
                "activationPublishedAt": E.iso(start),
                "cohortAvailableAt": E.iso(start),
            },
            start,
        )

    def checkpoint(self, *, revision=1, when=NOW):
        self.event(
            "checkpoint",
            {
                "activationRevision": revision,
                "authoritySHA256": self.index["authoritySHA256"],
                "cohortID": self.cohort,
                "networks": sorted(E.MAINNETS),
            },
            when,
        )

    def save(self, *, rechain=True):
        if rechain:
            previous = "0" * 64
            for n, event in enumerate(self.events, 1):
                event["sequence"], event["previousEventSHA256"] = n, previous
                previous = E.digest(E.canonical(event))
        ledger = {
            key: self.index[key]
            for key in (
                "schemaVersion",
                "sourceRevision",
                "artifactIdentity",
                "phase",
                "candidateID",
                "authoritySHA256",
            )
        }
        ledger["events"] = self.events
        raw = E.canonical(ledger)
        (self.root / "ledger.json").write_bytes(raw)
        self.index["eventLedger"] = {"path": "ledger.json", "sha256": E.digest(raw)}
        return self.index

    def derived(self):
        self.save()
        return E.derive(self.index, self.root, now=NOW)

    def verify(self):
        self.index.update(self.derived())
        return E.verify(self.index, self.manifest, self.root, now=NOW)


@pytest.fixture
def rehearsal(tmp_path):
    case = Case(tmp_path)
    for network, connector in [
        ("eip155:11155111", "metamask"),
        ("solana:devnet", "phantom"),
        ("sui:testnet", "slush"),
    ]:
        case.operation(network, connector)
    return case


def test_initial_canary_uses_observed_testnet_paths_not_preexisting_mainnet(rehearsal):
    derived = rehearsal.verify()
    assert all(row["successfulTransactions"] == 1 for row in derived["chainTotals"])
    assert derived["soak"] is None
    assert all(row["networkID"] not in E.MAINNETS for row in derived["actionCoverage"])


def test_initial_canary_must_enable_all_three_mainnets(rehearsal):
    rehearsal.manifest["networkGrants"].pop()
    with pytest.raises(ValueError, match="activate Ethereum, Solana, and Sui together"):
        rehearsal.verify()


def test_mainnet_cannot_be_smuggled_into_rehearsal(rehearsal):
    rehearsal.events[0]["payload"]["networkID"] = "eip155:1"
    with pytest.raises(ValueError, match="testnet fixture"):
        rehearsal.derived()


@pytest.mark.parametrize(
    "method,action,approval",
    [
        ("list_accounts", None, "not_applicable"),
        ("sign_in_with_ethereum", "standardized_sign_in", "locus_then_wallet"),
    ],
)
def test_real_nontransaction_operations_never_inflate_transaction_totals(
    rehearsal, method, action, approval
):
    rehearsal.operation(
        "eip155:11155111",
        "metamask",
        n=2,
        method=method,
        action=action,
        transactionID=None,
        reconciliation="not_applicable",
        approvalModel=approval,
    )
    result = rehearsal.derived()
    assert (
        next(row for row in result["chainTotals"] if row["chain"] == "evm")[
            "successfulTransactions"
        ]
        == 1
    )
    assert any(
        row["method"] == method and row["successfulOperations"] == 1
        for row in result["connectionCoverage"]
    )
    if action:
        assert (
            next(row for row in result["actionCoverage"] if row["action"] == action)[
                "successfulTransactions"
            ]
            == 0
        )


def test_rebroadcast_reconciliation_is_deduplicated(rehearsal):
    rehearsal.operation("eip155:11155111", "metamask")
    assert rehearsal.derived()["chainTotals"][0]["successfulTransactions"] == 1


def test_transaction_cannot_be_relabelled_for_coverage(rehearsal):
    rehearsal.operation("eip155:11155111", "metamask", action="nft_transfer")
    with pytest.raises(ValueError, match="different semantic effect"):
        rehearsal.derived()


@pytest.mark.parametrize(
    "mutation,error",
    [
        ({"approvalModel": "signer_policy"}, "required approval"),
        ({"ownership": "locus_vault"}, "ownership"),
        ({"reconciliation": "pending"}, "reconciled"),
        ({"privateKey": "never-record-this"}, "private fields"),
        ({"signature": "never-record-this"}, "private fields"),
        ({"transactionID": "not-a-transaction"}, "public transaction"),
    ],
)
def test_unsafe_observations_are_rejected(rehearsal, mutation, error):
    rehearsal.events[0]["payload"].update(mutation)
    with pytest.raises(ValueError, match=error):
        rehearsal.derived()


def test_duplicate_callback_is_rejected(rehearsal):
    rehearsal.events.append(copy.deepcopy(rehearsal.events[0]))
    with pytest.raises(ValueError, match="duplicate operation"):
        rehearsal.derived()


def test_duplicate_json_fields_fail_before_interpretation(tmp_path):
    path = tmp_path / "duplicate.json"
    path.write_text('{"schemaVersion":2,"schemaVersion":1}')
    with pytest.raises(ValueError, match="duplicate JSON"):
        E.load(path)


def test_hash_chain_and_report_substitution_are_detected(rehearsal):
    rehearsal.save()
    rehearsal.events[1]["previousEventSHA256"] = "f" * 64
    rehearsal.save(rechain=False)
    with pytest.raises(ValueError, match="lineage"):
        E.derive(rehearsal.index, rehearsal.root, now=NOW)
    rehearsal.save()
    (rehearsal.root / "observation.json").write_text("changed")
    with pytest.raises(ValueError, match="report digest"):
        E.derive(rehearsal.index, rehearsal.root, now=NOW)


def test_caller_supplied_metrics_and_duplicate_totals_are_not_trusted(rehearsal):
    rehearsal.index.update(rehearsal.derived())
    rehearsal.index["chainTotals"].append(copy.deepcopy(rehearsal.index["chainTotals"][0]))
    with pytest.raises(ValueError, match="counters differ"):
        E.verify(rehearsal.index, rehearsal.manifest, rehearsal.root, now=NOW)


def test_complete_synthetic_soak_counts_only_unique_reconciled_transactions(tmp_path):
    case = Case(tmp_path, "mainnet_soak")
    case.publication()
    for network, connector in [
        ("eip155:1", "metamask"),
        ("solana:mainnet-beta", "phantom"),
        ("sui:mainnet", "slush"),
    ]:
        for n in range(1, 101):
            case.operation(network, connector, n)
    case.checkpoint()
    case.manifest["releaseStage"] = "general_availability"
    result = case.verify()
    assert result["soak"]["externalTesters"] == 25
    assert result["soak"]["durationSeconds"] == 30 * 86400 + 3600
    assert all(row["successfulTransactions"] == 100 for row in result["chainTotals"])


def test_staff_do_not_count_toward_external_tester_threshold(tmp_path):
    case = Case(tmp_path, "mainnet_soak")
    case.publication()
    case.operation("eip155:1", "metamask", testerClass="staff")
    case.checkpoint()
    assert case.derived()["soak"]["externalTesters"] == 0


@pytest.mark.parametrize(
    "field,value",
    [
        ("cohortID", "0" * 64),
        ("activationRevision", 2),
        ("fixtureManifestSHA256", "0" * 64),
    ],
)
def test_soak_rejects_unadmitted_or_unknown_activation_path(tmp_path, field, value):
    case = Case(tmp_path, "mainnet_soak")
    case.publication()
    case.operation("eip155:1", "metamask", **{field: value})
    case.checkpoint()
    with pytest.raises(ValueError, match="counted mainnet cohort"):
        case.derived()


def test_expired_lease_breaks_continuity(tmp_path):
    case = Case(tmp_path, "mainnet_soak")
    case.publication(start=NOW - dt.timedelta(days=32))
    case.checkpoint()
    with pytest.raises(ValueError, match="continuity"):
        case.derived()


def test_unchanged_scope_renewal_keeps_original_soak_start(tmp_path):
    case = Case(tmp_path, "mainnet_soak")
    start = NOW - dt.timedelta(days=35)
    case.publication(start=start)
    renewal_time = start + dt.timedelta(days=28)
    case.event(
        "renewal",
        {
            "activationRevision": 2,
            "previousActivationRevision": 1,
            "authoritySHA256": case.index["authoritySHA256"],
            "cohortID": case.cohort,
            "networks": sorted(E.MAINNETS),
            "leaseIssuedAt": E.iso(renewal_time),
            "leaseExpiresAt": E.iso(renewal_time + dt.timedelta(days=31)),
        },
        renewal_time,
    )
    case.checkpoint(revision=2)
    result = case.derived()["soak"]
    assert result["startedAt"] == E.iso(start)
    assert result["activationRevisions"] == [1, 2]


def test_security_loss_cannot_be_erased_by_restart(tmp_path):
    case = Case(tmp_path, "mainnet_soak")
    case.publication()
    case.event("security_loss", {"category": "secret_exposure"})
    case.event("interruption", {"reason": "availability_gap"})
    case.publication(start=NOW - dt.timedelta(minutes=1), revision=2)
    case.checkpoint(revision=2)
    with pytest.raises(ValueError, match="new candidate"):
        case.derived()


def test_report_symlink_cannot_escape_evidence_directory(rehearsal, tmp_path_factory):
    other = tmp_path_factory.mktemp("outside-evidence") / "report"
    other.write_text("outside")
    link = rehearsal.root / "linked-report"
    link.symlink_to(other)
    rehearsal.events[0]["report"] = {"path": link.name, "sha256": E.digest(other.read_bytes())}
    with pytest.raises(ValueError, match="escapes"):
        rehearsal.derived()


def test_testnet_rehearsal_authorization_has_no_fabricated_successes(tmp_path):
    case = Case(tmp_path, "testnet_rehearsal_authorization")
    for grant in case.manifest["networkGrants"]:
        grant["networkID"] = E.REHEARSAL_NETWORKS[grant["networkID"]]
    result = case.verify()
    assert all(row["successfulTransactions"] == 0 for row in result["chainTotals"])
    assert result["actionCoverage"] == result["connectionCoverage"] == []


def test_testnet_authorization_cannot_enable_a_mainnet(tmp_path):
    case = Case(tmp_path, "testnet_rehearsal_authorization")
    with pytest.raises(ValueError, match="strictly testnet-only"):
        case.verify()


@pytest.mark.parametrize("connector", ["metamask", "phantom", "slush"])
def test_agent_initiation_never_removes_connector_confirmation(rehearsal, connector):
    event = next(event for event in rehearsal.events if event["payload"]["connector"] == connector)
    event["payload"].update(source="agent", approvalModel="signer_policy")
    with pytest.raises(ValueError, match="required approval"):
        rehearsal.derived()


@pytest.mark.parametrize("action", ["nft_transfer", "swap_allowance_setup", "standardized_sign_in"])
def test_nonautomatable_actions_cannot_claim_signer_policy(rehearsal, action):
    rehearsal.operation(
        "eip155:11155111",
        "locus",
        n=7,
        action=action,
        approvalModel="signer_policy",
        source="agent",
    )
    with pytest.raises(ValueError, match="cannot automate"):
        rehearsal.derived()


@pytest.mark.parametrize("failure", ["duration", "testers", "transactions"])
def test_ga_thresholds_are_computed_from_observations_not_entered_metrics(tmp_path, failure):
    case = Case(tmp_path, "mainnet_soak")
    start = NOW - dt.timedelta(days=29 if failure == "duration" else 30, hours=1)
    case.publication(start=start)
    for network, connector in [
        ("eip155:1", "metamask"),
        ("solana:mainnet-beta", "phantom"),
        ("sui:mainnet", "slush"),
    ]:
        for n in range(1, 100 if failure == "transactions" else 101):
            case.operation(
                network, connector, n, testerClass="staff" if failure == "testers" else "external"
            )
    case.checkpoint()
    case.manifest["releaseStage"] = "general_availability"
    with pytest.raises(ValueError, match="thresholds"):
        case.verify()


def test_unresolved_broadcast_ambiguity_cannot_disappear_from_zero_loss_metrics(rehearsal):
    rehearsal.operation(
        "eip155:11155111", "metamask", n=9, outcome="failed", reconciliation="ambiguous"
    )
    with pytest.raises(ValueError, match="unresolved broadcast ambiguity"):
        rehearsal.derived()


def test_explicit_report_bound_resolution_does_not_invent_a_success(rehearsal):
    rehearsal.operation(
        "eip155:11155111", "metamask", n=9, outcome="failed", reconciliation="ambiguous"
    )
    pending = rehearsal.events[-1]["payload"]
    rehearsal.event(
        "ambiguity_resolution",
        {
            "operationID": pending["operationID"],
            "outcome": "reconciled",
            "transactionID": pending["transactionID"],
        },
    )
    assert rehearsal.derived()["chainTotals"][0]["successfulTransactions"] == 1
