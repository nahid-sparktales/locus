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
- [x] Native SOL legacy message reconstruction, signing, simulation recheck,
  expiry handling, single-provider broadcast, status finality, and capped rules.
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
- [x] Read-only Sui GraphQL network health and native SUI balances with full
  genesis-digest verification, bounded/error-free response envelopes, fresh
  checkpoint and epoch/gas evidence, and exact reconciliation of coin-object
  plus balance-accumulator holdings.
- [x] Read-only Sui Coin discovery with canonical non-generic Move marker types,
  stable bounded pagination, exact two-store balance reconciliation, signed
  curation, and default quarantine for unknown assets.
- [x] Read-only Sui owned-object discovery with checkpoint-pinned pagination,
  exact address owner/object ID/version/digest/type/public-transfer evidence,
  Coin-object exclusion, signed curation, and metadata-free quarantine.
- [x] Finalized Sui transaction and owner Coin-balance activity through a
  checkpoint-pinned GraphQL connection, with exact transaction/effects digest,
  sender, status, timestamp, checkpoint, signed-delta, owner, and Coin-type
  validation; failed, duplicate, unstable, or truncated evidence fails closed.
- [x] Canonical signer-core builder for one object-backed native SUI transfer:
  exact `SplitCoins(GasCoin)` plus `TransferObjects`, current-epoch expiry,
  one owned gas object, reviewed reference gas price, maximum gas budget, and
  deterministic BCS/digest/signature fixtures. The XPC capability remains
  closed pending provider preparation, simulation, and recheck.
- [x] Checkpoint-bound native SUI gas-coin discovery and deterministic
  single-coin selection. The provider validates exact `Coin<SUI>` type, owner,
  object ID/version/digest, canonical 40-byte Coin BCS, embedded UID, raw u64
  balance, stable pagination, and reconciliation with the checkpoint's total
  coin-object balance. Fragmented funds remain unsignable in this subset.
- [ ] Ethereum curated token and ERC-721/1155 discovery/transfer complete.
- [ ] Solana transfer-altering Token-2022 extensions and reviewed
  NFT/compressed-collectible transfer implementation complete.
- [ ] Sui gRPC/GraphQL native transfer, Coin transfer, object/NFT transfer,
  object-effect activity, simulation, execution, and finality implementation complete.
- [ ] Uniswap v2/v3/v4, Jupiter `/build`, and Cetus V3 reviewed swap subsets complete.
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
