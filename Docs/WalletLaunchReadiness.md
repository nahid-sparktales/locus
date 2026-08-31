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
  verified existing source/destination token accounts, exact confirmation,
  simulation recheck, and signer-owned token rules.
- [ ] Ethereum curated token and ERC-721/1155 discovery/transfer complete.
- [ ] Solana associated-token-account creation, reviewed Token-2022 extension
  transfers, and NFT/compressed-collectible implementation complete.
- [ ] Sui gRPC/GraphQL native/Coin/object implementation complete.
- [ ] Uniswap v2/v3/v4, Jupiter `/build`, and Cetus V3 reviewed swap subsets complete.
- [ ] MetaMask, Phantom, Slush, Wallet Standards, and Reown WalletKit lifecycle complete.
- [ ] Sandboxed collectible media and complete current-holdings discovery.

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
