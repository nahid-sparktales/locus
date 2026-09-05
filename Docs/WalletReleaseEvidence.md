# Wallet release evidence and issuance

This is an operator workflow, not completed release evidence. The checked-in
templates contain no candidate identities, observations, admissions, or approvals.
Signing keys, provider credentials, enrollment records, and auditor reports stay
outside the repository. Never publish a fixture output.

## Evidence phases

Schema-v2 evidence has three explicit phases:

| Phase | Permitted release scope | Required observations and approvals |
| --- | --- | --- |
| `testnet_rehearsal_authorization` | Testnet-only rehearsal purpose; never mainnet or GA | An attributable `release_candidate_build` report. An empty observation ledger and zero derived counters are intentional: this authorizes the rehearsal before it can generate evidence. No unperformed incident/audit approval is claimed. |
| `pre_canary_rehearsal` | Initial production canary, Ethereum/Solana/Sui together | All canary approvals plus observed action/method coverage on the explicitly corresponding testnet. Mainnet counters are not required before mainnet activation. |
| `mainnet_soak` | Production continuation or same-artifact GA promotion | Observed admitted-cohort mainnet operations, published activation lineage, continuity checkpoints, and attributable approvals. GA additionally requires the complete derived 30-day/25-external-tester/100-per-chain thresholds. |

The fixed rehearsal mapping is Ethereum→Sepolia, Solana mainnet→devnet, and Sui
mainnet→testnet. There is no inferred network/capability cross-product. Account
queries, network changes, and SIWE/SIWS count as successful **operations**, not
transactions. Only a successful `send_transaction` with a public transaction
identifier and verified reconciliation contributes to chain transaction totals.

## Collect observations

Start with `Config/WalletLaunchEvidence.template.json` and
`Config/WalletLaunchObservations.template.json` in an external evidence directory.
Fill in the exact source, candidate/scope fingerprints, bundle version, 40-hex
app/signer CDHashes, and 64-hex hash of the final stapled zip. CDHash is Apple's
20-byte code identity; it must not be mislabeled as a full SHA-256 digest.

Every ledger event contains exactly:

- A consecutive `sequence`, `previousEventSHA256` (zero for the first event),
  canonical whole-second UTC `occurredAt`, and a known event `type`.
- A pseudonymous 64-hex `reporterID`, a relative `report` reference with `path`
  and `sha256`, and the typed `payload`.

The previous-event digest is SHA-256 of the previous event's UTF-8 JSON with
sorted object keys, compact separators, unescaped Unicode and slashes, and no
non-finite numbers. Duplicate JSON members, unknown/private payload fields,
out-of-order times, future observations, broken links, missing reports, changed
report bytes, and symlinks escaping the evidence directory are rejected. Files
are bounded to 16 MiB and a ledger to 50,000 events; an oversized input is a
blocking collection error, never silently truncated.

Operation payloads record `operationID`, `networkID`, `connector`, `ownership`,
`direction`, `method`, `source`, `approvalModel`, `outcome`, `reconciliation`,
`testerID`, and `testerClass`; signing operations also identify the semantic
`action`. `source` is human, agent, embedded browser, WalletConnect, or a
testnet-only release harness. Tester and operation identifiers are pseudonymous
64-hex values. Staff do not count toward the external-tester threshold.

Transactions include only their public `transactionID`; never include account
addresses, transaction bytes, raw requests, signatures, session credentials, or
recovery material. Rehearsal operations bind `fixtureManifestSHA256`. Counted
mainnet operations bind the published `activationRevision` and counted `cohortID`.
Approval models distinguish MetaMask/Slush's `locus_then_wallet`, Phantom's
`exact_locus`, and eligible Locus `signer_policy`. Collectibles and allowance
setup may never claim signer-policy approval.

Replay callbacks cannot increment counts. Repeated reconciliation of the same
network/transaction is counted once and cannot be relabeled as another effect
or connection path. Rejections, timeouts, cancellations, unavailable wallets,
and failures remain observations but contribute no successful transactions.
Ambiguous broadcasts remain open until an attributable `ambiguity_resolution`
references the original operation and its reconciled public transaction.
An unresolved ambiguity blocks issuance; a timeout or caller-entered zero loss
counter cannot erase it. Resolution alone does not add a successful transaction.

Use the collector to create a **new** index in the same evidence directory:

```sh
python3 Tools/WalletLaunchEvidence.py collect /external/evidence/input.json /external/evidence/index.json
python3 Tools/WalletLaunchEvidence.py verify /external/evidence/index.json /external/evidence/capability.json
```

The input contains no `chainTotals`, `actionCoverage`, `connectionCoverage`, or
`soak` counters. The collector derives those fields. Both the capability issuer
and activation issuer independently recompute them; editing a generated total
does not make it accepted. Approval artifacts remain hash-bound and attributable.
The `release_candidate_soak` approval must not supply its own numeric `metrics`.

This offline verifier cannot independently determine whether a reporter's
observation happened, whether the ledger omits an event, or whether an external
tester is truly independent. Attributable observation reports, enrollment
records, independent chain reconciliation, and audit review establish those
facts. A synthetic test passing this tool is not a release result.

## Continuous soak and renewal

A `publication` records exact build publication, activation publication, and
cohort-availability times; the latest of those is the start. It binds all three
mainnets, the authority fingerprint, cohort, published activation revision, and
lease issue/expiry. Only already-published revisions may precede the new
evidence index's issuance revision.

A `renewal` binds its previous activation revision, unchanged scope/cohort,
and the next issue/expiry times. Leases are at most 31 days. A renewal published
after the preceding lease expires cannot bridge a continuous soak. A final
`checkpoint` bounds the complete counted observation interval. Keep weekly
readiness reports and renew at least 72 hours before expiry.

The 31-day choice intentionally permits cached authority during an endpoint
outage. It does **not** provide immediate offline revocation. Online clients poll
for restrictions; offline clients fail closed at the applicable lease/admission
expiry. Evidence must not misrepresent polling as proof of instantaneous
revocation on a disconnected installation.

An `interruption` ends the counted segment. A later publication starts a fresh
segment without recounting old transactions. Counted scope/cohort changes need
fresh lineage and restart the soak; unchanged-scope lease renewal does not.
Any `security_loss` in the candidate's ledger blocks that candidate, even after
a restart. Independent reviewers must verify ledger completeness. Isolated
drill-cohort activity must not be counted as invited-cohort coverage.

## Ceiling, transition, and admission issuance

`SignWalletReviewManifest.swift --sign-ceiling` and `--verify-ceiling` operate on
the separate `locus-wallet-review-ceiling-v1` signature domain. Its scope is
normalized and structurally validated using the existing reviewed-entry checks.
It has `reviewRevision`/`reviewedAt` but no operational issue/expiry or activating
capability. Dormant artifacts bundle this ceiling and reject a legacy operational
review manifest as a substitute.

`SignWalletReleaseActivation.swift --describe` takes metadata, unsigned capability,
unsigned operational review, and the signed ceiling; it computes candidate,
ceiling, and authority fingerprints before the evidence hash is introduced.
Sign the evidence-bound capability and fresh operational review only after
their appropriate phase reports exist. The activation issuer then takes:

```text
metadata signed-capability signed-review signed-ceiling evidence-index previous-envelope|initial private-key output
```

Schema-v2 transitions are `initial`, `renewal`, `restriction`, or `promotion`.
Non-initial issuance requires the preceding signed envelope. Renewal cannot
change authority. Restriction cannot restore removed grants, and lowered
emergency budgets remain permanent. Promotion must retain the exact candidate
archive and tested scope; it may end explicitly temporary canary controls but
cannot erase permanent restrictions. The soak fingerprint remains that of the
preceding counted canary, not the deliberately different promoted-stage hash.

`--sign-admission admission.json signed-current-transition.json private-key output`
issues only a candidate/cohort/installation-bound canary admission with a finite
allocation no broader than its current canary and permanent limits. Its expiry
is bounded by 31 days and the current activation. Installation IDs come from
authenticated signer state. The issuer must separately approve enrollment,
prevent duplicate/replacement-Mac allocation resets, preserve old reservations,
and publish the appropriate admission/history. This tool neither enrolls a
person nor grants transaction signing power.

The two designated Macs must independently verify exported code identities,
entitlements, notarization/stapling, archive hash, evidence, and update signatures.
GA publishes the **same notarized canary archive bytes**. No new archive, re-zip,
configuration mutation, or re-signing may silently inherit its soak.
