# Locus Vault threat model

Status: mainnet implementation in progress; launch authority defaults to none
Last reviewed: 2026-09-04

## Security objective

Protect one production recovery phrase from the UI, browser content, agent
runtime, network stack, unrelated local processes, and recovery confusion.
Release signed bytes only for a fully decoded, network-bound semantic action
whose source, account, fee, simulation, expiry, and effects are independently
checked at the signer boundary.

## Assets and boundaries

| Asset or authority | Owner | Required behavior |
| --- | --- | --- |
| Phrase generation/display/restore input | sandboxed `WalletRecovery.app`, its private signer, and one-time signer broker | Never enters Locus; no network entitlement; cancel and lock on interruption |
| Entropy and private keys | `WalletSigner.xpc` | AES-GCM at rest; device-only Keychain wrapping key; user presence; zeroize on lock |
| Active policies and cumulative budgets | Signer connection | Re-evaluate and reserve at signature release; clear on lock/invalidation |
| Network evidence | Native app plus signer recheck | Canonical chain identity; primary/fallback comparison; never concurrent duplicate broadcast |
| External-wallet and dapp sessions | Unsandboxed Direct Locus process and its isolated trusted WebKit runtime | This is an explicitly accepted boundary: the process can access SDK session state, but agents, logs, the public wallet store, and signer APIs cannot; the entire runtime is absent from the Mac App Store build |
| Browser/WalletConnect identity | Native app session plus Direct connector-driver peer session | Immutable normalized origin or stable peer ID through prepare, simulate, confirm, sign, and broadcast |
| Public wallet metadata | Versioned SQLite store | No phrase, entropy, key, policy authority, signed bytes, or unrestricted diagnostics |
| Launch authority | Post-package signed activation envelope, independently verified by app and signer | Exact installed source/version/CodeDirectory identity; schema-v3 per-network capability and exact connector/direction/method/ownership grants; provider/configuration identities; signed review-ceiling intersection; expiry and signer-owned monotonic revision |

The signer service initially exposes only a bootstrap interface. Its anonymous
host endpoint accepts signed Locus and excludes recovery methods; its anonymous
recovery endpoint accepts only the signed recovery helper. Signer authorization
is connection-local. The one-time recovery broker accepts one signed recovery
application connection and cannot be reached by the Locus host itself. Locus
launches the helper's exact executable and exchanges only bounded start,
cancel, presented, and terminal-result frames.

The connector runtime intentionally lives in the unsandboxed Direct Locus app;
there is no `WalletConnections.xpc`. Vendor and WalletConnect state stays in a
dedicated persistent WebKit data store and native connector drivers. The trusted
bundled page uses an isolated content world, strict CSP, a vendor-origin
navigation allowlist, bounded reply messages, disabled developer extras, and
no arbitrary-page loading. Public protocols and persistence cannot represent a
relay key, vendor token, recovery secret, signer policy, raw provider object,
unsigned/signed transaction bytes, or signature. Release-scoped configuration,
pinned runtime identity, and signed review identity are all required. Direct
connector Swift, JavaScript, Reown code, resources, configuration, and
credentials are compile- and package-excluded from the Mac App Store product.

## Request-source policy

- Human UI, agent, embedded browser, and WalletConnect peer are distinct
  immutable sources.
- Human and connected-app Locus-owned mainnet signatures require exact Locus
  review and user presence. MetaMask and Slush require exact Locus review
  followed by wallet-owned approval.
  Phantom's connector-managed embedded account has no second wallet prompt or
  additional local authentication; exact Locus review is its sole confirmation.
  External and connector-managed accounts cannot consume an autonomous signer policy.
- Agent automation is permitted only inside an active signer-owned policy that
  binds chain, account, asset, recipient, adapter, per-action and cumulative
  amounts, fee, slippage/minimum output, and expiry.
- NFT actions, novel contracts, unknown instructions/calls, arbitrary messages,
  typed data outside a reviewed format, and opaque bytes always reject or
  require a separately implemented exact adapter. They never fall through to
  generic signing.
- Sign-in is restricted to canonical SIWE and SIWS. The signer reconstructs the
  message from typed fields and binds domain, origin, chain, account, nonce,
  timestamps, request ID, and resources before requiring user presence. Sui
  personal-message signing and arbitrary EVM/Solana messages remain disabled.

## Primary threats and controls

| Threat | Control and fail-closed result |
| --- | --- |
| Main app or page reads recovery words | Phrase UI/input lives in the sandboxed recovery application; its private signer and one-time broker authenticate each boundary; the framed result to Locus contains only status/public accounts |
| Preview vault silently reaches mainnet | Production v2 vault is separate; preview vault becomes recovery-only; rotation requires a new verified phrase |
| Malicious provider changes chain | Verify EVM chain ID, Solana genesis hash, or Sui chain identifier on every provider switch |
| Provider substitutes preparation | Compare critical evidence across primary/fallback where configured; signer rechecks authoritative fields |
| Duplicate or ambiguous broadcast | Sign once, consume intent before bytes leave signer, broadcast through one provider, reconcile local transaction ID |
| Caller labels arbitrary code reviewed | Derive adapter from pinned manifests, code/package/program identity, exact function/instruction subset, and decoded effects |
| Browser reuses approval after network switch | Grants are keyed by normalized origin and canonical network; switch emits empty accounts until separately approved |
| Dapp substitutes origin or WalletConnect peer | The public connection stores the normalized browser origin or stable peer ID; the immutable request binding and callback must match it exactly |
| Malformed WalletConnect namespace widens methods | The Direct driver normalizes proposals into bounded typed namespaces; duplicate namespaces, cross-chain IDs, unsupported methods, unknown events, and excessive entries reject before review |
| MetaMask or Slush bypasses wallet approval | Locus never receives signing authority for these external accounts; their drivers submit only through wallet-owned confirmation and return a public transaction ID |
| Phantom action bypasses review | Phantom accounts are `connectorManaged`, never silently migrated from legacy `external` records, and every action requires exact Locus review; signer policies and silent agent execution are unavailable |
| Compromised connector runtime reaches signer authority | The accepted main-process boundary can access connector state but not signer entropy; ownership and direction are revalidated by the semantic router, while signer XPC independently restricts authority to Locus-owned accounts and exact signed adapters |
| Callback replay or account/chain mutation | Request IDs have a bounded replay cache; connection, direction, connector, origin/peer, account, network, method, and expiry must match exactly on callback |
| Remote activation substitutes or rolls back a release | App and authenticated signer independently verify exact installed identity, signature, expiry, and revision; the signer persists its highest accepted revision and accepts only intersection restrictions under the bundled review ceiling |
| Poisoned NFT/token metadata | Unknown assets quarantined; active HTML/SVG/script never rendered as trusted wallet UI |
| Helper or signer interruption | Process EOF and XPC invalidation clear pending recovery, entropy, listeners, sessions, policies, intents, and grants; lock immediately |
| Diagnostics leak wallet behavior | Opt-in categorical data excludes addresses, amounts, assets, balances, origins, peers, policies, bytes, and recovery material |

The dormant candidate is archived and exported by Xcode using Developer ID
provisioning. Packaging verifies that exact export and never rewrites its
configuration, resources, or signatures. The two signer copies require valid
Developer ID provisioning profiles authorizing their Keychain access group.
Post-package activation removes the former circular dependency between a
bundled activating manifest and the hash of its notarized containing archive.

### Release authority, invitations, and offline behavior

The separately signed `WalletReviewCeiling` is non-activating scope, with no
operational expiry. Connector initialization may inspect that scope for pinned
SDK/configuration identities, but it cannot use it as an operational grant.
The app and authenticated signer independently verify schema-v2 activation
history, time-limited schema-v3 capabilities, and fresh schema-v2 review
restrictions. Source revisions and installed CDHashes are 40 lowercase hex
characters; archive SHA-256 values are separate 64-character identities.

Each transition binds the exact candidate, ceiling digest, predecessor digest,
and normalized resulting authority. Initial production canary activation
includes Ethereum, Solana, and Sui. Renewal changes lease/evidence data without
restoring removed scope or resetting budgets. Restrictions preserve removed
grants and lowered permanent limits. Promotion retains the exact candidate,
tested scope, and permanent restrictions while removing temporary canary gates.
The signer appends its accepted high-water mark before enabling authority;
the app must acknowledge the same protected checkpoint.

Canary invitations are separately signed, installation-bound admissions. The
installation identifier is random signer-owned, device-only state, not a wallet
key or caller-selected database field. Admission and release history have
separate append-only records so importing an invitation cannot rewrite the
global release history. Lease renewal cannot change its allocation or serial.
Replacement generations require explicit prior-serial revocation. Cumulative
reservation keys bind the candidate rather than the lease revision, and remain
reserved across ambiguous broadcasts and admission/activation renewal.

Preparation and the final vault-signing or connector-submission boundary check
live admission. A revoked or expired invitation cannot block persistence of an
emergency restriction; it leaves the installation dormant instead. The signer
accepts expired historical records only as lineage proof, never as current
authority. Missing or broken history fails closed. Fetches are bounded and occur
outside WebKit; the present reader accepts at most 64 linked transitions per
request and requires a verified signer checkpoint to resume.

Leases last at most 31 days. An offline installation may retain its previously
verified permissions until its current activation or admission expires. There
is no promise of immediate offline revocation. Distribution operators must
renew at least 72 hours before expiry and record any availability gap; tooling
does not automatically publish, renew, approve, or declare a successful soak.

New installed candidates start a fresh all-chain canary only at a higher global
revision, with a changed source/code identity and fresh admission. The protected
checkpoint retains retired candidate IDs; an older candidate cannot be restored
with a higher revision. Repacking the same source does not reset budgets.
Canary restrictions retain every limit identity, including inactive ones, so
promotion cannot silently turn a removed quota into uncapped authority.
GA expiry uses the current activation lease, not an obsolete canary invitation.

Candidate automatic updates remain bound to the sealed canary/stable feeds,
exact candidate archive, build version, and admitted release stage. A dormant
or expired candidate does not silently fall back to the stable feed. A person
may explicitly choose **Check for Safety Updates**, after a warning that a new
build ends the candidate and requires fresh wallet authorization. This separate
manual cycle uses the sealed stable feed, a strictly newer build, approved HTTPS
archive hosts, and Sparkle's normal cryptographic verification. It conveys no
wallet signing authority and is never treated as same-artifact GA promotion.

Sui's GA transport is GraphQL for reads, simulation, execution, and
reconciliation. Debug localnet may use an explicitly bounded loopback path;
Release transport remains HTTPS-only. gRPC migration and batching are deferred.

## Verification gates

Every wallet change runs signer tests, focused Swift tests, a clean app/test
build, binary export audit, SBOM/dependency review, secret scan, distribution
audit, and the applicable local-chain/browser/adversarial suites. Release
requirements and external evidence are tracked in
[WalletLaunchReadiness.md](WalletLaunchReadiness.md).

GA requires two independent assessments: cryptography/signer and
application/dapp-connection. Both must report zero unresolved critical or high
findings and verify fixes. Operational response follows
[WalletIncidentPlaybook.md](WalletIncidentPlaybook.md).
