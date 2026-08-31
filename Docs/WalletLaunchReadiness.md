# Locus Vault launch readiness

This is the authoritative release checklist. A checked box requires an
attributable artifact in the release evidence index; prose or a manually edited
manifest is not evidence. The checked-in state is intentionally incomplete.

## Engineering implementation

- [x] Isolated branch/worktree from recorded `origin/main` commit.
- [x] Signer protocol v2 and canonical Ethereum/Solana/Sui network identities.
- [x] Network-disabled recovery window and one-time authenticated signer channel.
- [x] Preview-vault rotation and recovery-only retention.
- [x] Public SQLite store and network-scoped browser grants.
- [x] Evidence-bound canary/GA manifest and default-deny packaging.
- [x] Signed review manifests for curated assets, exact EVM contracts,
  explorers, and compiled adapters, with intersection-only emergency updates.
- [x] Indexed Ethereum inbound/outbound activity reconciliation and quarantine
  for provider-discovered ERC-20/ERC-721/ERC-1155 assets.
- [x] Bounded, chain-verified Alchemy ERC-20 holding discovery with exact owner,
  unique canonical contracts, uint256 base-unit balances, stable pagination,
  metadata exclusion, and default quarantine for unknown contracts.
- [x] Metadata-free Alchemy ERC-721/1155 owner discovery with one stable block
  snapshot, canonical unique contract/token identities, exact integer balances,
  strict standard binding, and default quarantine.
- [x] Native SOL legacy message reconstruction, signing, simulation recheck,
  expiry handling, single-provider broadcast, status finality, and capped rules.
- [x] Account-local Solana priority fees for reviewed legacy transfers. A
  provisional maximum-limit/zero-price message is simulated, the measured units
  receive a capped ten-percent margin, the newest 20 fee samples use a
  deterministic 75th percentile, and the selected price is reduced to the
  user's exact fee ceiling. Swift and Rust independently rebuild the two fixed
  Compute Budget instructions; final fee, bytes, simulation, and recheck must
  agree before signing.
- [x] Strict SPL and Token-2022 account discovery with raw base-unit balances,
  program/mint/owner validation, signed curation, and unknown-mint quarantine.
- [x] Classic SPL `TransferChecked` with independently rebuilt signer message,
  signer-derived recipient associated token account, exact idempotent creation
  when unallocated, simulation recheck, and signer-owned token rules.
- [x] Solana associated-token-account derivation and exact idempotent creation.
- [x] Token-2022 `TransferChecked` for the fail-closed extension subset:
  metadata-only mint extensions and `immutableOwner` token accounts, with
  program-scoped ATA derivation and extension evidence rebound before signing.
- [x] Read-only Solana Digital Asset Standard discovery for validated Metaplex
  Token Metadata, Core, and compressed Bubblegum holdings, with canonical
  identities, strict ownership/compression evidence, quarantine, bounded
  pagination, and active-media exclusion.
- [x] Signed-manifest transfer of one uncompressed, standalone, plugin-free
  Metaplex Core `AssetV1`. Preparation reparses the exact program-owned account,
  binds owner/update-authority/data digest, rebuilds the sentinel-account
  `TransferV1` message independently in Swift and Rust, proves the exact owner
  transition in simulation, repeats evidence before signing, and never exposes
  NFT policy authority. Collection, plugin, compression, Token Metadata, and
  Bubblegum transfer shapes remain absent.
- [x] Bounded finalized Solana activity through genesis-verified
  `getSignaturesForAddress` pagination and exact `getTransaction` evidence.
  Signature order, finality, slot, version, signer/account keys, balances, fees,
  token program/mint/owner/decimals, and Core instruction accounts are checked;
  every accepted transaction keeps a generic record, reviewed effects are
  additive, unknown programs are not guessed, and unknown assets are
  quarantined. v0 lookup counts/order/privileges are rebound to recorded loaded
  addresses, while v1 requires its exact resource configuration and rejects
  lookup tables. Public SQLite retains the newest 500 normalized records.
- [x] Read-only Sui GraphQL network health and native SUI balances with full
  genesis-digest verification, bounded/error-free response envelopes, fresh
  checkpoint and epoch/gas evidence, and exact reconciliation of coin-object
  plus balance-accumulator holdings.
- [x] Read-only Sui Coin discovery with canonical non-generic Move marker types,
  stable bounded pagination, exact two-store balance reconciliation, signed
  curation, and default quarantine for unknown assets.
- [x] Checkpoint-bound owned Coin-object discovery and deterministic single-
  object selection for curated non-native Sui Coins. Exact generic object type,
  owner, ID/version/digest, canonical 40-byte Coin BCS, embedded UID, raw u64
  balance, pagination, and aggregate object-balance reconciliation are required;
  fragmented or accumulator-only funds do not silently add merge commands.
- [x] Read-only Sui owned-object discovery with checkpoint-pinned pagination,
  exact address owner/object ID/version/digest/type/public-transfer evidence,
  Coin-object exclusion, signed curation, and metadata-free quarantine.
- [x] Finalized Sui transaction and owner Coin-balance activity through a
  checkpoint-pinned GraphQL connection, with exact transaction/effects digest,
  sender, status, timestamp, checkpoint, signed-delta, owner, and Coin-type
  validation; failed, duplicate, unstable, or truncated evidence fails closed.
- [x] Finalized Sui non-Coin ownership-change activity with terminal object
  effects, exact input/output object identity, version, digest, owner, type, and
  public-transfer validation. Same-owner and Coin/gas mutations are excluded;
  unknown transferred objects enter metadata-free quarantine.
- [x] Finalized Sui non-Coin creation/deletion activity. Creation requires only
  canonical output state owned by the tracked address; deletion requires only
  canonical input state owned by it. Lifecycle flags, state presence, object
  identity/type, owner, version, digest, and public-transfer evidence are bound;
  contradictory, shared/object-owned, Coin/gas, and malformed effects cannot be
  presented as collectible activity and new identities enter quarantine.
- [x] Canonical signer-core builder for one object-backed native SUI transfer:
  exact `SplitCoins(GasCoin)` plus `TransferObjects`, current-epoch expiry,
  one owned gas object, reviewed reference gas price, maximum gas budget, and
  deterministic BCS/digest/signature fixtures.
- [x] Checkpoint-bound native SUI gas-coin discovery and deterministic
  single-coin selection. The provider validates exact `Coin<SUI>` type, owner,
  object ID/version/digest, canonical 40-byte Coin BCS, embedded UID, raw u64
  balance, stable pagination, and reconciliation with the checkpoint's total
  coin-object balance. Fragmented funds remain unsignable in this subset.
- [x] Non-broadcasting GraphQL simulation for signer-built native SUI transfer
  bytes. The provider must return the exact transaction and effects digests,
  selected gas object, successful terminal balance changes, and a complete gas
  cost summary; recipient credit and sender debit are recomputed exactly and
  bounded by the reviewed maximum fee.
- [x] End-to-end native SUI staged intent for testnet: checkpoint-bound gas
  selection, isolated signer rebuild, exact GraphQL simulation, human approval,
  fresh object/version/digest/balance and effects recheck, signer consumption,
  one-provider GraphQL execution, finality evidence, and broadcast-unknown
  handling. Mainnet activation still requires both signed launch capability and
  signed adapter-review evidence; the checked-in manifests enable neither.
- [x] End-to-end curated Sui `Coin<T>` staged intent for the single-object
  subset: signed-manifest asset identity, exact owned Coin plus distinct SUI gas
  object, isolated signer rebuild without Move calls, exact Coin debit/credit
  and native gas simulation, dual-object freshness recheck, exact approval,
  one-provider execution, and frozen BCS/digest/signature fixtures. Fragmented
  Coin balances and mainnet activation remain gated.
- [x] End-to-end signed-manifest Sui object transfer for one exact publicly
  transferable, non-generic owned object: checkpoint-bound owner/version/digest/
  type evidence, one distinct SUI gas object, isolated `TransferObjects` rebuild,
  exact object-ownership and gas simulation, fresh dual-object recheck, exact
  approval, one-provider execution, and frozen BCS/digest/signature fixtures.
  Shared objects, batches, Move calls, and mainnet activation remain gated.
- [x] Wallet Hub Send eligibility for every implemented human transfer subset.
  One chain-native sheet routes native, fungible, and reviewed collectible
  snapshots through the same semantic preparation and signer recheck as other
  request sources. Canonical network/asset identity, exact trust level, static
  compiled capability, raw destination, and nonzero native fee ceiling are
  required. Curated Sui Coin/object and Solana Core snapshots are distinct from
  locally trusted assets; safe Token-2022 remains subject to live extension
  evidence in the provider and signer path. Signed launch/review manifests
  remain independently required for any mainnet signature.
- [x] Version-separated Universal Router V2/V3 exact-input command decoding.
  Existing `uniswap-universal-router-v2-exact-in-v1` registry entries retain
  their legacy V2-only authority. The new v2 adapter accepts exactly one
  non-allow-revert V2 or V3 exact-input command using the current six-field
  input ABI, the current account as literal recipient and payer, a deadline no
  more than 20 minutes away, 1-3 acyclic hops, a nonzero global minimum output,
  canonical dynamic offsets/padding, and either an empty per-hop price array or
  one nonzero floor per hop. The protocol-v2 semantic preparation path now also
  requires a signed router and complete curated-token route, quoted output,
  slippage bound, minimum output, deadline, and per-hop floors. The isolated
  signer—not the main process—materializes the sole permitted command, encodes
  it through the Rust ABI boundary, decodes it again, and binds the verified
  runtime code hash and RPC simulation. Autonomous eligibility additionally
  requires a signer-owned exact-input policy with router, adapter, input asset,
  recipient, amount, fee, slippage, minimum-output, and expiry bounds. V4,
  Permit2 forms, native wrapping, sub-plans, live quote acquisition, Swap UI,
  and Anvil execution fixtures remain incomplete.
- [ ] Ethereum sandboxed collectible metadata/media rendering complete. Curated
  token/NFT transfers, metadata-free ERC-20/721/1155 holdings, and indexed
  transfer-based quarantine are implemented.
- [ ] Solana transfer-altering Token-2022 extensions, Core collection/plugin
  variants, Token Metadata/programmable NFT transfers, and compressed-
  collectible transfer implementation complete. The standalone plugin-free
  Core subset is implemented but not mainnet-enabled. Finalized legacy/v0/v1
  activity indexing and reviewed legacy-transfer priority fees are implemented;
  versioned-message signing remains closed.
- [ ] Sui gRPC execution migration, multi-object Coin merge/object batching,
  and localnet coverage complete. The
  exact native, single-object curated Coin, and publicly transferable object
  GraphQL subsets are implemented but not mainnet-enabled.
- [ ] Uniswap v2/v3/v4, Jupiter `/build`, and Cetus V3 reviewed swap subsets
  complete. Universal Router V2/V3 decoding is implemented as described above;
  its semantic preparation, signer reconstruction, and RPC simulation path is
  implemented, while live quotes, UI, V4, and independent local-chain execution
  coverage remain closed.
- [ ] MetaMask, Phantom, Slush, Wallet Standards, and Reown WalletKit lifecycle complete.
- [ ] Sandboxed remote collectible-media fetch and rendering complete.

## Automated and adversarial verification

- [x] Deterministic EVM/Solana/Sui derivation fixture in the signer core.
- [ ] Fixture independently reproduced by three external implementations.
- [ ] Anvil native/token/NFT/swap/rejection/expiry/crash/finality suite.
- [ ] Solana local-validator equivalent suite.
- [ ] Sui localnet equivalent suite using the production gRPC/GraphQL path.
- [ ] Fuzz corpora for calldata, instructions, BCS, messages, metadata, providers,
  WalletConnect payloads, and quotes.
- [ ] Browser fixtures for EIP-1193/EIP-6963, Solana Wallet Standard, Sui Wallet
  Standard, and WalletConnect lifecycle/revocation.
- [ ] Release binary, entitlement, identity, symbol, SBOM, advisory, and
  reproducibility audit green from a clean branch.

## Invited mainnet canary evidence

- [ ] Independent cryptography/signer audit: zero unresolved critical/high.
- [ ] Separate application/dapp penetration test: zero unresolved critical/high.
- [ ] Counsel-approved regional capability matrix.
- [ ] Provider capacity, identity, disagreement, and failover load test.
- [ ] Incident drill: disable one chain/adapter, revoke sessions, ship signed
  update, restore on a clean Mac, and prove funds remain recoverable.
- [ ] Notarized canary artifact and stapled-ticket verification.
- [ ] Signed update feed verification.

Only after these artifacts exist may a schema-v2 `invited_canary` manifest be
signed. Canary distribution remains invited and limited-fund.

## Public GA evidence

- [ ] At least 30 days of invited release-candidate soak.
- [ ] At least 25 external testers.
- [ ] At least 100 successful transactions per chain covering every supported
  action and connection path.
- [ ] Zero unauthorized signing, secret exposure, unrecoverable vault,
  unresolved broadcast ambiguity, or loss-producing decoder discrepancy.
- [ ] Wallet terms, privacy, recovery, provider disclosures, support, security
  contact, incident response, and funded reward program approved for publication.
- [ ] Support and security response staffed for the published service levels.
- [ ] All CI/release gates green from a clean branch.
- [ ] Final notarized artifact and signed update feed independently verified.

The signing tool enforces the numeric soak thresholds and binds the evidence
index hash into a `general_availability` manifest. Packaging rejects a GA build
whose signed manifest has another stage.
