# Locus Vault security and launch gate

Status: implementation branch; mainnet default denied
Protocol: wallet signer v2

## Authority boundary

The direct-download app embeds two sandboxed XPC services:

- `WalletSigner.xpc` owns entropy, derived private keys, active policies,
  cumulative budgets, prepared intents, and final signatures. It has no network
  entitlement and accepts only the signed Locus host.
- `WalletRecovery.xpc` owns phrase display, backup verification, and restore
  input. It has no network entitlement. It connects to the signer through a
  single-use anonymous endpoint that accepts only the signed recovery service.

The main app receives recovery status and public accounts, never entropy or
phrase words. If the signer, recovery service, or their one-time channel is
interrupted, pending recovery state is cleared and signing authority locks.

The signer exports typed EVM, Solana, and Sui protocol-v2 operations. Arbitrary
digest signing, raw messages, opaque calldata, unresolved Solana instructions,
and unknown Move calls are not exported authority. Solana and Sui transaction
builders are fail-closed until their reviewed implementations and tests land.

## Mainnet capability manifest

Mainnet authorization is the intersection of:

1. a network and capability compiled into the app;
2. a schema-v2 Ed25519-signed manifest valid for at most 31 days;
3. a release stage (`invited_canary` or `general_availability`);
4. counsel-approved regions;
5. stage-specific completed approvals; and
6. an evidence-index SHA-256 bound into the manifest.

The signing tool checks attributable evidence artifacts and their hashes. It
requires zero unresolved critical/high audit findings. For GA it also enforces
at least 30 soak days, 25 external testers, 100 successful transactions per
chain, and zero unauthorized-signing, secret-exposure, unrecoverable-vault,
unresolved-broadcast, or loss-producing decoder events.

An emergency manifest may only intersect with the bundled authority. It cannot
silently enable a new network, capability, region, approval, release stage, or
signing adapter.

## Implemented foundation

- Deterministic 24-word recovery and one EVM/Solana/Sui public account.
- Production-vault rotation with the earlier vault retained recovery-only.
- Five-minute default idle lock, configurable to 30 minutes.
- EVM chain identity checks, EIP-1559 construction, simulation/recheck, exact
  confirmation, signer-owned policies, and single-provider broadcast.
- Alchemy primary, QuickNode fallback, optional user endpoint, provider identity
  checks, and critical preparation-evidence comparison.
- Signed, short-lived review manifests for curated assets, exact EVM contract
  code/ABI metadata, explorers, and compiled adapters. Emergency updates use
  intersection-only semantics and cannot add signing authority.
- Reviewed ERC-20, ERC-721, and ERC-1155 transfers plus indexed inbound and
  outbound Ethereum activity. Provider-discovered assets enter quarantine and
  provider numeric values are normalized from integer base units only.
- Versioned SQLite public store for activity, assets, contacts, and connections.
- Network-scoped EIP-1193/EIP-6963 browser grants; opaque message and typed-data
  signing remain rejected.
- Signed capability tooling and release packaging checks for recovery/signer
  entitlements, provider configuration, release stage, and evidence binding.

## Still closed

The code intentionally does not claim GA. These capabilities stay disabled
until their implementation and evidence gates pass:

- production Solana and Sui builders, signing, provider execution, token/NFT
  indexing, and local-chain suites;
- full v2/v3/v4 Universal Router, Jupiter `/build`, and pinned Cetus V3 swaps;
- live MetaMask, Phantom, Slush, and Reown WalletKit sessions;
- complete ERC-721/1155 holdings discovery, metadata/media sandboxing, and
  independent local-chain coverage for Ethereum asset paths;
- external audits, counsel approval, capacity testing, canary, soak, staffing,
  incident drill, notarization, and signed-update verification.

No manifest should be signed merely to make an incomplete feature visible.
