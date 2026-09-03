# Locus Vault threat model

Status: mainnet implementation in progress; launch authority defaults to none
Last reviewed: 2026-09-02

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
| Browser/WalletConnect identity | Native app session | Immutable origin or peer through prepare, simulate, confirm, sign, and broadcast |
| Public wallet metadata | Versioned SQLite store | No phrase, entropy, key, policy authority, signed bytes, or unrestricted diagnostics |
| Launch authority | Signed schema-v2 manifest | Short expiry; evidence hash; reviewed code intersection; stage and region bound |

The signer service initially exposes only a bootstrap interface. Its anonymous
host endpoint accepts signed Locus and excludes recovery methods; its anonymous
recovery endpoint accepts only the signed recovery helper. Signer authorization
is connection-local. The one-time recovery broker accepts one signed recovery
application connection and cannot be reached by the Locus host itself. Locus
launches the helper's exact executable and exchanges only bounded start,
cancel, presented, and terminal-result frames.

## Request-source policy

- Human UI, agent, embedded browser, and WalletConnect peer are distinct
  immutable sources.
- Human and connected-app mainnet signatures require exact confirmation and
  user presence. They cannot consume an autonomous agent policy.
- Agent automation is permitted only inside an active signer-owned policy that
  binds chain, account, asset, recipient, adapter, per-action and cumulative
  amounts, fee, slippage/minimum output, and expiry.
- NFT actions, novel contracts, unknown instructions/calls, arbitrary messages,
  typed data outside a reviewed format, and opaque bytes always reject or
  require a separately implemented exact adapter. They never fall through to
  generic signing.

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
| Remote manifest widens authority | Intersection-only restriction; cannot raise release stage or add a compiled capability |
| Poisoned NFT/token metadata | Unknown assets quarantined; active HTML/SVG/script never rendered as trusted wallet UI |
| Helper or signer interruption | Process EOF and XPC invalidation clear pending recovery, entropy, listeners, sessions, policies, intents, and grants; lock immediately |
| Diagnostics leak wallet behavior | Opt-in categorical data excludes addresses, amounts, assets, balances, origins, peers, policies, bytes, and recovery material |

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
