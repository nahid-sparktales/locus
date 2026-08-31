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
and unknown Move calls are not exported authority. Implemented Solana builders
accept only one canonical native transfer or one reviewed SPL/Token-2022
`TransferChecked`, optionally preceded by one exact idempotent
associated-token-account creation; all other Solana and Sui transaction shapes
remain fail-closed.

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
- Reviewed native SOL transfers using one canonical legacy System Program
  message. The app and Rust signer rebuild it independently; genesis identity,
  blockhash lifetime, account privileges, fee, simulation, request source, and
  broadcast ID are rebound before the single signing operation. Capped SOL
  agent rules use the same signer-owned policy boundary.
- SPL Token and Token-2022 account discovery validates genesis, program owner,
  wallet owner, mint, token-account state, decimals, and canonical raw u64
  balances. Unknown mints are stored as public quarantine records and remain
  hidden until explicitly trusted.
- Reviewed classic SPL transfers require one initialized source account with
  sufficient raw balance and use the signer-derived recipient associated token
  account for the same mint. An existing account must pass provider validation;
  an unallocated address may be created only through the exact idempotent
  Associated Token Program instruction. The provider and signer independently
  bind both programs, account roles, mint, decimals, exact amount, blockhash,
  fee, and simulated effects. Signer-owned rules bind the exact mint and
  recipient.
- Token-2022 transfers use a separate reviewed adapter and program-scoped ATA.
  The mint is limited to no extensions or metadata-only `metadataPointer` and
  `tokenMetadata`; token accounts are limited to no extensions or
  `immutableOwner`. Every observed extension name is canonicalized and rebound
  during recheck. Transfer fees, hooks, confidentiality, pausing, permanent
  delegates, memo/CPI requirements, unknown/unparseable extensions, and other
  altered semantics are unsignable. See the
  [official extension catalogue](https://www.solana-program.com/docs/token-2022/extensions).
- Read-only Solana collectible discovery uses Digital Asset Standard
  `getAssetsByOwner` with verified genesis identity, canonical owner and asset
  addresses, bounded pagination, duplicate rejection, and strict ownership.
  Metaplex Token Metadata, Core, and compressed Bubblegum holdings receive
  distinct canonical identities and enter quarantine. Compressed items must
  carry canonical tree, hash, and leaf evidence. Metadata text is bounded and
  control-free; only credential-free HTTPS PNG, JPEG, WebP, or AVIF URLs are
  classified as raster images. SVG, HTML, script URLs, malformed items, and
  unknown interfaces are never promoted as trusted wallet content. No remote
  media URL currently crosses into the main-app asset store.
- Read-only Sui native balances use GraphQL following the official
  [JSON-RPC migration guidance](https://github.com/MystenLabs/sui/blob/main/docs/content/develop/accessing-data/grpc/what-is-grpc.mdx).
  Every response carries the chain identifier in the same query as
  checkpoint, epoch, gas-price, address, coin type, and balance evidence. Locus
  accepts only the canonical full Base58 genesis digest or its provably
  equivalent legacy four-byte form, rejects any GraphQL error or oversized or
  stale response, and requires `totalBalance` to equal the exact sum of coin
  objects and the address balance accumulator. This path exports no Sui signing
  or generic GraphQL authority.
- Sui Coin discovery accepts only a bounded connection whose pages all carry
  identical network, checkpoint, epoch, and reference-gas evidence. Coin marker
  types use a strict canonical Move identity with no generic nesting; duplicate,
  malformed, inconsistent, repeated-cursor, or truncated results fail closed.
  Unknown Coins are public metadata in SQLite quarantine, never implicit signing
  authority. Signed review manifests must bind network, Coin type, decimals,
  name, and symbol exactly before a Coin can be curated.
- Versioned SQLite public store for activity, assets, contacts, and connections.
- Network-scoped EIP-1193/EIP-6963 browser grants; opaque message and typed-data
  signing remain rejected.
- Signed capability tooling and release packaging checks for recovery/signer
  entitlements, provider configuration, release stage, and evidence binding.

## Still closed

The code intentionally does not claim GA. These capabilities stay disabled
until their implementation and evidence gates pass:

- Solana transfer-altering Token-2022 extensions,
  NFT/compressed-collectible transfer adapters, remote-media rendering,
  versioned-message and lookup-table
  decoding, indexed history, priority fees, and local-validator coverage; all
  Sui transaction builders, signing, provider execution, Coin transfers, object/NFT and
  activity adapters, gRPC execution, and localnet suites;
- full v2/v3/v4 Universal Router, Jupiter `/build`, and pinned Cetus V3 swaps;
- live MetaMask, Phantom, Slush, and Reown WalletKit sessions;
- complete ERC-721/1155 holdings discovery, metadata/media sandboxing, and
  independent local-chain coverage for Ethereum asset paths;
- external audits, counsel approval, capacity testing, canary, soak, staffing,
  incident drill, notarization, and signed-update verification.

No manifest should be signed merely to make an incomplete feature visible.
