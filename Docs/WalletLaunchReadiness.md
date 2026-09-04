# Locus Vault launch readiness

This is the authoritative release checklist. A checked box requires an
attributable artifact in the release evidence index; prose or a manually edited
manifest is not evidence. The checked-in state is intentionally incomplete.

## Public GA scope contract

The GA action surface is intentionally narrow: native transfers, curated
fungible transfers, ERC-721/1155 transfers, standalone plugin-free Metaplex
Core transfers, publicly transferable Sui objects, Universal Router V2/V3
exact-input swaps, and canonical SIWE/SIWS. Locus Vault may serve embedded-
browser and WalletConnect dapps. MetaMask, Phantom, and Slush accounts may be
used without importing recovery material. Agents may initiate the same actions
as people. MetaMask and Slush retain wallet-owned confirmation after exact
Locus review; Phantom's connector-managed embedded account requires exact
Locus review but no second wallet prompt. Collectibles and finite allowance
setup always require exact confirmation, and only signer-owned
native/fungible/Uniswap rules can execute automatically.

The following are explicitly deferred and are not GA requirements: advanced
Token-2022 behavior, programmable or compressed NFT transfers, Core collection
and plugin variants, Sui batching or gRPC migration, Uniswap V4, Jupiter or
Cetus swaps, arbitrary messages or broad typed data, Sui personal-message
signing, and remote collectible media. Their adapters and methods must remain
absent from release manifests.

## Engineering implementation

Checked implementation entries identify source and fixture coverage, not release
approval. Every execution result must be repeated and attributed to the final
clean candidate revision before canary activation.

- [x] Isolated branch/worktree from recorded `origin/main` commit.
- [x] Signer protocol v3 and canonical Ethereum/Solana/Sui network identities.
- [x] Schema-v2 public connection records with account ownership, connection
  direction, connector, network/method grants, lifecycle, expiry, and
  revocation; relay keys, vendor tokens, signed bytes, and policy authority are
  excluded.
- [x] One semantic request router binds origin/peer, connection, account,
  network, method, action, and expiry, rejects replay/substitution, and cancels
  pending authority on lock, signer loss, disablement, navigation, disconnect,
  account/network change, or expiry.
- [x] Direct-only connector runtime with a dedicated persistent WebKit store,
  isolated content world, strict CSP and navigation allowlist, bounded reply
  messages, disabled developer extras, and no arbitrary-page loading. The
  accepted boundary places SDK sessions in the unsandboxed Direct app; its
  Swift, JavaScript, Reown code, resources, and credentials are compile- and
  package-excluded from the Mac App Store target.
- [x] Structured SIWE/SIWS signer path reconstructs the canonical message,
  binds domain/origin/chain/account/nonce/timestamps/resources, requires device
  owner approval, consumes the nonce before signing, and exposes no arbitrary
  message or broad typed-data endpoint. The embedded EIP-1193 provider accepts
  `personal_sign` only when its UTF-8 payload parses and round-trips as the
  exact reviewed canonical SIWE form; all other message content still rejects.
- [x] Schema-v3 capability manifests grant capabilities per network and gate
  exact connector/direction/method tuples. Schema-v2 review manifests pin
  connector versions/digests, sign-in adapters, and program/code identities;
  emergency updates remain intersection-only.
- [x] Network-disabled recovery window and one-time authenticated signer channel.
- [x] Preview-vault rotation and recovery-only retention.
- [x] Public SQLite store and network-scoped browser grants.
- [x] Evidence-bound canary/GA capability manifest and default-deny packaging.
- [ ] Post-package activation, signer-owned rollback protection, signed finite
  canary limits, exact connector ownership/configuration, and reviewed provider
  identity gates pass the integrated candidate regression suite.
- [ ] Dormant archive/export packaging passes on the release-signing Mac and an
  independent clean Mac. `Tools/ArchiveWalletRelease.sh` uses Xcode Developer ID
  export with the nested signer provisioning profiles; exported-artifact
  packaging performs no plist/resource/signature rewriting.
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
  one nonzero floor per hop. The protocol-v3 semantic preparation path now also
  requires a signed router and complete curated-token route, quoted output,
  slippage bound, minimum output, deadline, and per-hop floors. The isolated
  signer—not the main process—materializes the sole permitted command, encodes
  it through the Rust ABI boundary, decodes it again, and binds the verified
  runtime code hash and RPC simulation. Autonomous eligibility additionally
  requires a signer-owned exact-input policy with router, adapter, input asset,
  recipient, amount, fee, slippage, minimum-output, and expiry bounds. Native
  dual-provider on-chain V2/V3 quote reproduction, 60-second evidence, 500-bps
  maximum slippage, the Swap UI, exact finite ERC-20/Permit2 setup, dapp
  `needsAllowance`, and post-submit semantic reconciliation are implemented.
  V4, native wrapping, and sub-plans remain unavailable. The remaining
  stateful Anvil settlement and failure fixtures are tracked as unchecked
  engineering gates below.
- [x] MetaMask, Phantom, Slush, embedded EIP-1193/EIP-6963, Solana/Sui Wallet
  Standard, and WalletConnect runtime/lifecycle paths are present behind exact
  signed connector gates. Reown Swift 2.3.2 is vendored from its exact archive,
  patched only for the audited Foundation import, and links the Sign product;
  Pay and Yttrium products are omitted. Missing release configuration or
  identity evidence remains fail-closed.

## Deferred non-GA backlog

These items are deliberately outside the GA contract and are not launch
blockers: remote collectible media; transfer-altering Token-2022 behavior;
Core collection/plugin variants; Token Metadata, programmable, or compressed
NFT transfers; Solana v1 signing; Sui gRPC migration, Coin merging, and
batching; Uniswap V4; Jupiter; and Cetus.

## Automated and adversarial verification

- [x] Deterministic EVM/Solana/Sui derivation fixture in the signer core.
- [ ] Fixture independently reproduced by three external implementations.
- [x] Pinned Anvil signer/provider fixtures cover native, ERC-20, ERC-721,
  ERC-1155, and reviewed Universal Router calldata preparation, Rust encoding
  and signing, broadcast, receipt/input reconciliation, nonce replay,
  simulation rejection, changed runtime code, finality, and receipt recovery.
- [x] Anvil fixtures exercise dual-provider on-chain V2 quote reproduction at a
  common block, checked slippage and per-hop floors, quote/pool code-identity
  drift rejection, and exact finite ERC-20 and Permit2 allowance state
  transitions through production adapters and signer-generated transactions.
  Expired quote evidence is rejected before allowance reads or signer
  preparation.
- [ ] Stateful V2/V3 pool settlement, on-chain slippage failure, and crash
  injection are complete.
- [x] Pinned Agave `solana-test-validator` native-transfer suite covers exact
  local genesis binding, production preparation and simulation, signer-core
  reconstruction/signing, broadcast, finality, sender/recipient reconciliation,
  malformed signatures, wrong-chain substitution, and HTTPS-only production
  transport. Stateful SPL/Core fixtures remain part of the unchecked full
  local-chain matrix below.
- [ ] Solana local-validator SPL and standalone Core state-transition fixtures
  cover every enabled fungible and collectible path.
- [ ] Sui `testnet-v1.79.0` localnet equivalent suite using the production
  GraphQL path and Debug-only loopback initialization. gRPC migration is deferred.
- [x] Checked-in deterministic fuzz-smoke corpora mutate EVM calldata, Solana
  messages/instructions, Sui BCS, connection metadata, namespace proposals,
  provider envelopes, canonical sign-in, quote arithmetic, and Rust FFI
  requests with bounded inputs and responses on every CI run.
- [ ] Continuous sanitizer-backed fuzz campaigns and their release-duration
  evidence are complete: PR corpus replay and 60 seconds/target, nightly
  30 minutes/target, and 24 clean CPU-hours/target on the exact canary revision.
- [x] Connector-driver fixtures cover approval, rejection, timeout/vendor
  failure, missing configuration, restore, account/network change, disconnect,
  expiry, and suspend/reconnect behavior.
- [x] WebKit fixtures cover EIP-1193/EIP-6963 plus the exact Solana and Sui
  Wallet Standard registration surfaces; typed driver fixtures cover
  WalletConnect proposal approval/rejection, lifecycle, and revocation.
- [x] Connection SDK source pins, lockfile integrity, deterministic bundle
  digest, licenses, patched Reown tree/archive digests, enabled-runtime SBOM,
  zero-vulnerability npm audit, and Direct/Mac-App-Store target boundary gates
  are recorded and checked. Reviewed transitive overrides keep Axios at
  `1.20.0`, affected UUID consumers at `11.1.1`, and Solana's Jayson dependency
  at `4.1.3` without changing the approved connector SDK versions.
- [ ] Release binary, entitlement, identity, symbol, full enabled-runtime SBOM,
  advisory, legal-license, and reproducibility audit green from a clean branch.

## Invited mainnet canary evidence

- [ ] Independent cryptography/signer audit: zero unresolved critical/high.
- [ ] Separate application/dapp penetration test: zero unresolved critical/high.
- [ ] Counsel-approved regional capability matrix.
- [ ] Counsel approves Reown terms and Phantom embedded-wallet beta terms.
- [ ] `derivation_reproduction`: three independently maintained stacks reproduce
  the public derivation fixture with attributable source/library identities.
- [ ] `release_candidate_build`: the exact dormant export, CodeDirectory
  identities, archive hash, and source revision are approved after packaging.
- [ ] Provider capacity, identity, disagreement, and failover load test.
- [ ] Incident drill: disable one chain/adapter, revoke sessions, ship signed
  update, restore on a clean Mac, and prove funds remain recoverable.
- [ ] Notarized canary artifact and stapled-ticket verification.
- [ ] Signed update feed verification.

Only after these artifacts exist may the post-package activation envelope for
the schema-v3 `invited_canary` capability manifest be signed and published.
Ethereum, Solana, and Sui activate together. Every enabled asset/action and
ownership model requires signed finite per-action and cumulative limits;
collectibles are restricted to explicitly reviewed low-value identities.
The soak begins only when the exact notarized build, activation revision, and
invited cohort are simultaneously available.

## Public GA evidence

- [ ] At least 30 days of invited release-candidate soak.
- [ ] At least 25 external testers.
- [ ] At least 100 successful transactions per chain covering every supported
  action and connection path, with explicit connector/direction/method coverage
  rather than an inferred global capability cross-product.
- [ ] Zero unauthorized signing, secret exposure, unrecoverable vault,
  unresolved broadcast ambiguity, or loss-producing decoder discrepancy.
- [ ] Wallet terms, privacy, recovery, provider disclosures, support, security
  contact, incident response, and funded reward program approved for publication.
- [ ] Support and security response staffed for the published service levels.
- [ ] Attributable `release_candidate_soak`, `publication_disclosures`, and
  `support_security_readiness` approvals accompany schema-v2 launch evidence.
- [ ] All CI/release gates green from a clean branch.
- [ ] Final notarized artifact and signed update feed independently verified.

The signing tool enforces the numeric soak thresholds and binds the schema-v2
evidence index hash into a `general_availability` manifest. Both canary and GA
artifacts are packaged dormant; their post-package activation binds the exact
exported identities, archive hash, source revision, release stage, issue/expiry
times, and monotonic revision. See [WalletReleasePackaging.md](WalletReleasePackaging.md).

Any security-boundary, dependency, decoder, preparer, signer, manifest, or
connector change after activation invalidates downstream evidence and restarts
the soak. A defined security-loss event requires a new candidate. Reports,
credentials, provider contracts, tester identities, and staffing evidence remain
outside the repository and are never completed automatically by these tools.
