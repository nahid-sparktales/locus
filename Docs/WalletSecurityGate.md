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
accept only one canonical native transfer, one reviewed SPL/Token-2022
`TransferChecked` optionally preceded by one exact idempotent associated-token-
account creation, or one standalone plugin-free Metaplex Core `TransferV1`;
other Solana and Sui transaction shapes stay fail-closed except the separately
typed native SUI, single-object `Coin<T>`, and publicly transferable object
subsets described below.

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
- Alchemy ERC-20 holding discovery verifies chain identity before bounded
  pagination, requires the returned owner, canonical unique contract addresses,
  valid page keys, and one uint256 hex balance per row, and ignores zero
  balances. Provider token names, symbols, decimals, logos, prices, and remote
  media do not cross this path. Unknown contracts are stored as public SQLite
  quarantine records and remain hidden until explicitly trusted; signed assets
  keep only their reviewed manifest metadata. QuickNode and user endpoints do
  not impersonate this vendor-specific discovery method.
- Alchemy ERC-721/1155 ownership discovery is derived only from a validated
  `*.alchemy.com/v2/<public-key>` endpoint and requests `withMetadata=false`.
  Bounded pages must preserve one exact block number, block hash, and total.
  Every holding binds a canonical contract, explicit ERC-721 or ERC-1155
  standard, canonical uint256 token ID, and positive integer balance; ERC-721
  balance must be one. Duplicate holdings, changed snapshots, invalid page keys,
  and unexpected standards fail the batch. Names, descriptions, token URIs,
  images, collection metadata, and spam labels are never imported, and every
  unknown collectible begins in quarantine.
- Reviewed native SOL transfers using one canonical legacy System Program
  message. The app and Rust signer rebuild it independently; genesis identity,
  blockhash lifetime, account privileges, fee, simulation, request source, and
  broadcast ID are rebound before the single signing operation. Capped SOL
  agent rules use the same signer-owned policy boundary.
- Reviewed legacy SOL, SPL/Token-2022, and Core transfers use a fixed two-pass
  priority-fee protocol. The first exact message has the 1.4-million compute-unit
  maximum and zero unit price; its measured units receive a ten-percent margin.
  Locus samples recent fees for the exact writable accounts, uses the
  deterministic 75th percentile of the newest 20, and caps the price to the
  user's remaining maximum fee with integer ceiling arithmetic. The final
  message contains exactly one unit-limit and one unit-price instruction, is
  fee-quoted and simulated again, and is independently rebuilt by the signer.
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
- A Core collectible can be transferred only when its exact canonical identity
  and the Core adapter are both present in the signed review manifest. Locus
  ignores discovery claims for signing and reparses the live Core-owned
  `AssetV1` bytes instead. Only an uncompressed standalone asset with no trailing
  plugin registry is accepted; its owner, update authority, full data digest,
  fee, blockhash, and exact post-simulation owner transition are rebound before
  signing. Swift and Rust independently rebuild the seven-account `TransferV1`
  sentinel shape with a `None` compression proof. The signer request rejects
  unknown fields, no autonomous NFT policy exists, and collection-backed,
  plugin-bearing, Token Metadata, programmable, and compressed collectible
  transfers are not representable. The adapter is compiled for Solana devnet
  only; mainnet static authority remains absent until deployed upgradeable-
  program evidence is pinned and independently verified.
- Finalized Solana activity verifies genesis before bounded
  `getSignaturesForAddress` pagination and retrieves each signature with
  finalized `getTransaction` evidence. Signature order, slot, status, legacy/v0/
  v1 version, account privileges, fee, balances, token identity, and decoded
  Core accounts are validated as one batch. v0 lookup counts, ordering, and
  privileges must match recorded loaded addresses; v1 must carry its complete
  canonical resource configuration and no lookup tables. Every accepted
  signature produces a
  generic transaction record; exact owner balance effects and the narrow Core
  shape are added without guessing unknown programs. Unknown SPL, Token-2022,
  and Core identities are quarantined, and public SQLite retains only the newest
  500 normalized records.
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
- Sui Coin-object preparation uses a separate checkpoint-bound path for one
  exact non-native Coin type. Every object must have the exact
  `0x2::coin::Coin<T>` wrapper, canonical address owner/ID/version/digest, and
  canonical 40-byte BCS whose embedded UID matches the object ID. Enumerated
  balances must equal the checkpoint's coin-object subtotal. Selection chooses
  the smallest sufficient single object deterministically and rejects native
  SUI, fragmented holdings, accumulator-only holdings, type substitution, and
  any implicit merge expansion. The isolated signer can now rebuild exactly
  `SplitCoins(Input(owned Coin<T>))` followed by `TransferObjects`, with a
  distinct exact SUI gas object. Generic Move calls and caller-supplied BCS stay
  absent.
- Sui Coin simulation accepts exactly three terminal balance changes: sender
  Coin debit, recipient Coin credit, and sender native-SUI gas debit. The signer
  rechecks both object references, balances, checkpoint lineage, Coin type,
  amount, gas formula, fee ceiling, and effects digest before consuming an
  exactly approved intent. Mainnet additionally requires the Coin and adapter
  in the signed review manifest and the launch capability in the signed launch
  manifest.
- Read-only Sui object discovery pins every page to its first checkpoint and
  requires an exact address owner, canonical object ID, UInt53 version, Base58
  digest, bounded ASCII Move type, and public-transfer flag. Coin objects are
  excluded from the collectible path. BCS contents, display metadata, and
  remote media do not cross the provider boundary; every new object begins in
  quarantine, and discovery creates no transfer or Move-call authority.
- Reviewed Sui object transfer is limited to one exact non-generic Move object
  whose signed-manifest identity matches its canonical object ID. Preparation
  pins the provider checkpoint and binds the owner, version, digest, type, and
  `hasPublicTransfer` evidence plus one distinct SUI gas object. The signer
  independently rebuilds a transaction containing only
  `TransferObjects([Input(0)], Input(1))`; arbitrary object BCS, programmable
  Move calls, shared objects, dynamic fields, and batches are not accepted.
  Recheck requires a fresh checkpoint with unchanged owned-object and gas
  references. Simulation requires exactly the transferred object's input/output
  ownership change, the sender-owned gas object's input/output states, and one
  native-SUI sender debit equal to the recomputed bounded fee. Human approval is
  exact, and mainnet also requires signed launch and adapter-review authorization.
- Finalized Sui activity pins every page to the first verified checkpoint and
  requires matching transaction/effects digests, a canonical sender when one is
  present, a bounded timestamp and checkpoint, terminal nested balance-change
  pagination, canonical signed integer deltas, exact owner identity, and one
  change per Coin type. Failed effects with balance changes, duplicate digests
  or Coin types, unstable pages, and truncated results fail closed. Only public
  activity metadata enters SQLite; unknown Coins remain quarantined and no BCS,
  Move-call, or signing authority is exposed.
- Finalized Sui object activity uses the same pinned effects query and accepts
  only terminal object-change pagination. For a tracked ownership transition it
  requires matching canonical object IDs, increasing versions, valid digests,
  unchanged non-Coin Move type and public-transfer flag, and two exact address
  owners. Creation requires no input and one canonical address-owned output;
  deletion requires one canonical address-owned input and no output.
  Contradictory flags or state presence fail the batch. Shared/object-owned,
  Coin/gas, malformed, and same-owner effects never become collectible records;
  new identities enter public-metadata quarantine with an amount of one. BCS,
  display metadata, media, and signing authority remain absent.
- The isolated signer core can canonically rebuild one object-backed native SUI
  transfer from typed fields. It accepts exactly one gas coin, a positive split,
  one recipient transfer, the reviewed reference gas price and budget, and a
  current-epoch expiration; it rejects arbitrary BCS, Move calls, extra commands,
  role substitution, underfunding, and chain substitution.
- Native SUI gas discovery filters the GraphQL object connection to the exact
  `0x2::coin::Coin<0x2::sui::SUI>` type at one pinned checkpoint. It accepts
  only canonical owner/object/version/digest evidence and the exact 40-byte BCS
  layout of `Coin<SUI>`, verifies the embedded UID, and requires the enumerated
  balance sum to equal the checkpoint's coin-object balance. Selection chooses
  the smallest sufficient single coin, breaking ties by object ID. It never
  invents a merge command or spends the address balance accumulator.
- Native SUI dry-runs accept only canonical Base64 transaction bytes already
  produced by the isolated builder and send them through GraphQL
  `simulateTransaction` with checks enabled and provider gas selection disabled.
  Locus verifies a matching transaction digest, successful effects digest,
  exact selected gas-object ID, terminal two-party SUI balance changes, and the
  complete gas-cost formula. Recipient credit must equal the reviewed amount;
  sender debit must equal amount plus the computed fee, which must remain within
  the reviewed maximum.
- The native SUI XPC flow is staged around an opaque intent. Only the signer can
  produce the unsigned BCS, and it stores the exact typed request, gas reference,
  transaction/signing digests, and expiry. Before signing, the client reloads
  the selected coin at a fresh checkpoint and repeats the exact simulation; the
  signer requires unchanged object ID/version/digest/type/balance, epoch,
  reference gas price, amount, recipient, fee arithmetic, and effects. Exact
  human approval is mandatory and the intent is consumed before signing.
  GraphQL execution re-verifies the endpoint identity, never broadcasts through
  fallback concurrently or automatically, requires matching successful finality
  evidence, and treats every post-signing error as broadcast-unknown. Mainnet is
  still default-denied unless signed capability and adapter-review manifests
  independently authorize this exact compiled subset and region.
- Wallet Hub Send derives availability from the exact snapshot, canonical
  network descriptor, canonical asset identity, trust state, and compiled
  transfer capability. Sui Coin/object and Solana Core rows require curated
  review metadata; user-trusted Token-2022 rows may enter preparation only
  because the provider and signer subsequently bind the live mint and token-
  account extensions to the fail-closed subset. The sheet keeps the raw
  destination and fixed collectible/object identity visible, requires a
  nonzero native fee ceiling, and calls only the typed human semantic transfer
  APIs. It does not bypass signed mainnet launch or adapter-review gates.
- Versioned SQLite public store for activity, assets, contacts, and connections.
- Network-scoped EIP-1193/EIP-6963 browser grants; opaque message and typed-data
  signing remain rejected.
- Signed capability tooling and release packaging checks for recovery/signer
  entitlements, provider configuration, release stage, and evidence binding.

## Still closed

The code intentionally does not claim GA. These capabilities stay disabled
until their implementation and evidence gates pass:

- Solana transfer-altering Token-2022 extensions, Core collection/plugin
  variants, Token Metadata/programmable and compressed-collectible transfer
  adapters, remote-media rendering,
  versioned-message signing and local-validator coverage; all
  Sui gRPC execution migration, multi-object
  transfers, and localnet suites; native SUI, Coin, and object-transfer mainnet
  activation remain gated;
- full v2/v3/v4 Universal Router, Jupiter `/build`, and pinned Cetus V3 swaps;
- live MetaMask, Phantom, Slush, and Reown WalletKit sessions;
- ERC-721/1155 metadata/media sandboxing and independent local-chain coverage
  for Ethereum asset paths;
- external audits, counsel approval, capacity testing, canary, soak, staffing,
  incident drill, notarization, and signed-update verification.

No manifest should be signed merely to make an incomplete feature visible.
