# Use Locus Vault

Locus Vault is a self-custodial wallet in the notarized direct-download build.
The Mac App Store build contains no signer, recovery service, connector runtime,
or wallet activation configuration. Direct release candidates are dormant.
Mainnet stays disabled until the app and authenticated signer independently
verify a post-notarization, evidence-bound activation for that exact build.

## Create or restore

1. Open **Settings → Wallets** and enable **Locus Vault**.
2. Choose **Create Locus Vault** or **Restore from 24 Words**.
3. Complete the separate recovery window. It owns generation, phrase display,
   backup verification, and restoration. The main Locus process receives only
   ceremony status and public accounts.
4. Store the 24 words offline. Locus has no cloud backup, passphrase, or account
   recovery service.
5. Unlock the signer with Touch ID or the Mac password when you need to sign.

One phrase deterministically creates one account per chain:

- Ethereum: `m/44'/60'/0'/0/0`
- Solana: `m/44'/501'/0'/0'`
- Sui: `m/44'/784'/0'/0'/0'`

Never enter a MetaMask, Phantom, Slush, or other wallet phrase into Locus.
MetaMask and Slush keep their own keys and show their own approval after exact
Locus review. Phantom uses a connector-managed embedded Solana account: exact
Locus review is its approval, without a second Phantom prompt or extra local
authentication. None of these accounts can use Locus signer automation.

An earlier preview vault is never promoted to mainnet silently. **Rotate for
Mainnet** creates a new production phrase and leaves the earlier encrypted vault
in recovery-only state until you explicitly delete it.

## Wallet Hub

The Wallet Hub provides Portfolio, Activity, Send, Receive, Swap,
Collectibles, Connections, Agent Rules, and Security/Recovery sections. A
receive QR is generated locally and binds its canonical network. Unknown
assets remain quarantined until explicitly trusted.

Human Send, browser, WalletConnect, and agent requests share typed preparation,
simulation, and decoded-effect review. Locus-owned accounts then use signer
reconstruction and exact confirmation or an eligible signer-owned policy.
Every exactly confirmed Locus-owned mainnet signature requires user presence.
External and Phantom-managed accounts use independent connector preparation and
their approval model above, followed by public transaction reconciliation.

## Locking and recovery

The default idle lock is five minutes and can be set to 10, 15, or 30 minutes.
Sleep, screen lock, quit, update, signer interruption, or recovery-window
interruption locks immediately. Locking clears decrypted material, prepared
intents, website grants, and active agent rules while preserving public receive
addresses and public activity metadata.

See [WalletRecoveryGuide.md](WalletRecoveryGuide.md) before funding the wallet.

## Release stages

- Test networks are under Developer Mode.
- An invited all-chain mainnet canary requires independent signer and application audits,
  legal region approval, provider failover testing, an incident drill, a
  notarized artifact, and a signed update feed.
- Public GA additionally requires the 30-day/25-tester release-candidate soak
  and transaction thresholds in [WalletLaunchReadiness.md](WalletLaunchReadiness.md).

The checked-in production capability, review, evidence, and activation templates
remain empty/default-deny. The candidate contains the verification key and
signed review ceiling, but no activating capability manifest. After export,
notarization, stapling, zip verification, and signed appcast generation, the
release activation binds the source revision, version, app/signer CodeDirectory
identities, archive hash, release stage, expiry, monotonic revision, schema-v3
capabilities, and a review restriction no broader than the bundled ceiling.

Missing, invalid, expired, mismatched, or rolled-back activation keeps mainnet
disabled. Newer restrictions can only narrow effective authority and revoke
affected sessions, requests, callbacks, and policies. The all-chain 30-day soak
starts when the exact notarized build, activation revision, and invited cohort
are available together. See [WalletReleasePackaging.md](WalletReleasePackaging.md)
for the dormant archive/export and post-package sequence.

The Direct app checks for a new activation at startup, once per minute while
running, and after wake or foreground activation. Concurrent checks share one
fetch. Both processes apply verified restrictions before best-effort cache
persistence; a cache-write failure must not skip cancellation or expiry.
All authenticated bootstrap endpoints in a signer process share one authority
state machine. Signer-owned, append-only Keychain revision records preserve the
highest accepted revision even if another process finishes an older update late.
Mainnet transaction and sign-in release rechecks that high-water identity.

Canary budgets are explicit signed per-network/asset/action/ownership limits,
including transaction amount, fees, counts, and cumulative amount/fees. They
are reserved before signing or connector submission and are not refunded after
an ambiguous submission. Missing exact limits deny the action. Tests of this
mechanism are engineering evidence only; they do not replace the invited soak.
