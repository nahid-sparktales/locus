# Use Locus Vault

Locus Vault is a self-custodial wallet in the notarized direct-download build.
The Mac App Store build does not contain either the signer or recovery service.
Mainnet stays disabled unless the build contains a short-lived, evidence-bound,
Ed25519-signed capability manifest for an invited canary or public GA.

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
Those products are external approval surfaces and keep their own keys.

An earlier preview vault is never promoted to mainnet silently. **Rotate for
Mainnet** creates a new production phrase and leaves the earlier encrypted vault
in recovery-only state until you explicitly delete it.

## Wallet Hub

The Wallet Hub provides Portfolio, Activity, Send, Receive, Swap,
Collectibles, Connections, Agent Rules, and Security/Recovery sections. A
receive QR is generated locally and binds its canonical network. Unknown
assets remain quarantined until explicitly trusted.

Human Send uses the same typed preparation, simulation, decoded-effect review,
signer recheck, and opaque intent execution path as browser and agent requests.
Every exact-confirmed mainnet signature asks for user presence again.

## Locking and recovery

The default idle lock is five minutes and can be set to 10, 15, or 30 minutes.
Sleep, screen lock, quit, update, signer interruption, or recovery-window
interruption locks immediately. Locking clears decrypted material, prepared
intents, website grants, and active agent rules while preserving public receive
addresses and public activity metadata.

See [WalletRecoveryGuide.md](WalletRecoveryGuide.md) before funding the wallet.

## Release stages

- Test networks are under Developer Mode.
- An invited mainnet canary requires independent signer and application audits,
  legal region approval, provider failover testing, an incident drill, a
  notarized artifact, and a signed update feed.
- Public GA additionally requires the 30-day/25-tester release-candidate soak
  and transaction thresholds in [WalletLaunchReadiness.md](WalletLaunchReadiness.md).

The checked-in capability manifest is empty and enables no mainnet capability.
Remote manifests can disable or narrow authority but cannot add code, networks,
regions, approvals, or signing operations absent from the bundled release.
