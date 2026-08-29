# Locus Vault threat model and response plan

Status: experimental, test networks only
Last reviewed: 2026-08-28

## Security objective

Locus Vault protects a dedicated, limited-fund recovery phrase from the UI,
browser content, agent runtime, network stack, and unrelated local processes.
It authorizes only transactions whose network, account, semantic action,
simulation, fee, nonce, contract identity, decoded effects, request source, and
session capability have been checked by the native app and the network-isolated
signer. It is not a general message-signing or raw-transaction API.

## Assets and trust boundaries

| Asset or authority | Owner | Boundary |
| --- | --- | --- |
| BIP-39 entropy and derived private keys | `WalletSigner.xpc` only | AES-GCM at rest; device-only Keychain wrapping key with user presence; zeroized in memory on lock or connection loss |
| Signing-session capability | One accepted XPC connection | Random session ID required on every privileged request; never sent to Python, web content, or a model |
| Prepared intent and agent spending rule | The same signer connection | In-memory only; maximum 32 pending intents and 32 active policies; removed on use, expiry, lock, interruption, invalidation, feature disablement, or process exit |
| RPC endpoint and chain evidence | Native app | HTTPS only; Sepolia chain ID checked; JSON-RPC version, request ID, envelope shape, and response size validated |
| Browser origin grant | Native app session | Main-frame origin derived from WebKit, never accepted from page payload; revoked on navigation, lock, provider disablement, interruption, update, or exit |
| Contract classification | Native app and signer | Runtime code hash, normalized ABI digest, exact functions/selectors, and signer-derived adapter identity |
| Durable activity | Native app preferences | Public metadata only: hash, intent ID, network/account IDs, summary, timestamps, receipt state, and bounded error detail; never raw signed bytes or secrets |
| Locked receive snapshot | Native app memory | Public address, cached base-unit balance, and freshness only; retained across lock so receiving works without signing authority |
| Copied alpha diagnostics | User-initiated local clipboard write | Whitelisted build, OS, signer protocol/reachability, effective gates, vault state, RPC category, and activity counts only; excludes addresses, origins, rules, ABIs, raw transactions, secrets, and unrestricted errors |

The XPC listener accepts only the signed Locus host identifier and production
team identifier. Each accepted connection receives a new signer service
instance, so authorization state cannot be shared with a second client. Debug
builds permit ad-hoc signing for local development but still require the Locus
bundle identifier.

## Request-source policy

Agent and browser requests are different capabilities. Their source is included
in the session-authorized envelope and copied into the immutable prepared
intent. It must match during preparation, re-simulation, confirmation, and
execution.

- Agent requests may use an active signer-owned policy when every decoded
  effect is covered.
- Browser requests always require exact confirmation. A browser cannot create,
  inspect, clear, or consume an autonomous policy.
- Origin access grants expose only the Sepolia address and the supported narrow
  RPC surface. Raw signing, personal-message signing, chain addition, contract
  calldata, and mainnet remain unavailable.
- Browser provider discovery is separately opt-in, uses a UUIDv4 per page,
  freezes EIP-6963 metadata/discovery objects, and never replaces an existing
  `window.ethereum`. Disabling it denies pending native requests before tabs
  reload without the injection.

## Reviewed effect adapters

Adapter identity is derived from the normalized ABI and exact permitted
function set; a registry request cannot self-assert a reviewed label. The signer
revalidates this classification before using it.

1. `native-eth-transfer-v1`: Sepolia native value to one explicit recipient.
2. `erc20-v1`: `transfer(address,uint256)` and finite
   `approve(address,uint256)` effects. Unlimited approval is always exact
   confirmation.
3. `uniswap-universal-router-v2-exact-in-v1`: exactly one `0x08`
   `V2_SWAP_EXACT_IN` command through
   `execute(bytes,bytes[],uint256)`, without allow-revert, Permit2, native
   wrapping, sub-plans, partial fills, exact-output, or extra commands. The
   signer requires a nonzero minimum output, two to four path tokens, the vault
   account as recipient, and a deadline no more than 20 minutes away.

Advanced contract spending rules additionally bind the registry ID, observed runtime code
hash, adapter, one input asset, decoded recipient or spender, per-action amount,
cumulative session amount, fee ceiling, account, network, and expiry. Unknown,
stale, mismatched, or additional effects fall back to exact confirmation.

## Primary threats and controls

| Threat | Required control and fail-closed behavior |
| --- | --- |
| Malicious page forges an origin or reuses a policy | Derive main-frame origin from WebKit; source-bind every intent; browser always exact confirmation |
| Model or app substitutes fields after review | Execute by opaque intent ID; signer stores canonical fields and rechecks digest, nonce, fee, simulation, code hash, source, and expiry |
| Unrelated process connects to signer | Validate host code identity before accepting; create per-connection service state |
| Stale or stolen session capability | Require protocol version and active per-connection session on every privileged request; clear on invalidation |
| RPC returns a different or ambiguous response | Require HTTPS, Sepolia, JSON-RPC `2.0`, exact numeric ID, exactly one result/error, and a 1 MiB response cap |
| Caller labels arbitrary code as reviewed | Derive adapter from normalized ABI and exact function set; bind runtime hash and registry ID |
| Router hides extra commands or weak output bounds | Decode only one exact-input command; reject allow-revert, zero minimum output, extra inputs, invalid payer, bad recipient, or stale deadline |
| Broadcast succeeds but client loses the response | Consume before signing; record `broadcast_unknown` with locally derived hash; reconcile through transaction receipt without allowing replay |
| Recovery phrase confusion or import phishing | Never provide in-app import; show phrase only at creation; identify standard paths and warn never to enter an external-wallet phrase |
| Activity log leaks signing material | Persist public transaction metadata only; cap records and error detail; never persist raw transaction bytes |
| QR service learns or substitutes a receive address | Generate the ERC-681 Sepolia QR locally with Core Image; encode no amount and call no QR service |
| A discoverability toggle is mistaken for authorization | Keep signer session/source binding, simulation, policy evaluation, and exact confirmation independent of feature settings; App Store builds force effective gates off |

## Verification and release gates

Every wallet change must run the Rust signer tests, focused Swift wallet tests,
Python bridge tests, SBOM generation, dependency advisory review, secret scan,
binary export audit, and a clean Xcode build. Direct-download verification also
launches the embedded signer process and checks that a new connection starts
without an unlocked session.

No gate opens native EVM mainnet, Solana signing, or Sui signing. MetaMask
Connect on Sepolia is the recommended next milestone only after the private
alpha meets its exit criteria; Phantom and Slush remain later separate work.
The current code exposes no live connection button. Each connector needs
pinned dependencies, callback/session
tests, origin/account-change tests, denial and disconnect tests, threat-model
review, and external audit before enablement.

## Incident response

1. Disable wallet discovery and browser injection in the next build; instruct
   users to lock the vault and stop funding affected test accounts.
2. Preserve public hashes, versions, timestamps, signer crash reports, RPC
   error categories, and code-signing information. Never request a recovery
   phrase, private key, raw Keychain item, or decrypted vault file.
3. Classify whether exposure affects the host, XPC caller boundary, dependency,
   adapter decoder, RPC evidence, external connector, or user-confirmation UI.
4. Reproduce with a dedicated limited-fund vault. Add the failing case as an
   adversarial boundary test before preparing a fix.
5. Rotate or revoke affected test accounts and external sessions. If secret
   confidentiality might have failed, treat the phrase as compromised and move
   funds with a known-good wallet; deleting local storage is not sufficient.
6. Ship a signed fix, verify the full gate, document scope and recovery steps,
   and require a new external review before reopening any affected feature.

Security reports should contain app version, macOS version, exact action,
network, public transaction hash if any, and sanitized logs. They must not
contain wallet recovery words or private signing material.
