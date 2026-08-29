# Locus Vault security gate

Locus Vault is a separate, limited-fund wallet. It does not import, extract, or impersonate Phantom, MetaMask, or Slush. Those wallets remain external approval surfaces and retain their own keys and confirmation behavior.

## Current build boundary

The app and local agent contain the chain-neutral gateway, transaction-intent model, policy engine, native broker protocol, and Wallet Hub surface. Wallet tools are not advertised to a model unless all conditions are true:

1. The build is the signed direct download, not the Mac App Store target.
2. The isolated native `WalletSigner` service is available.
3. The person has accepted the experimental-risk sheet and enabled the
   persisted **Sepolia Private Alpha** setting.

Even then, the native gateway withholds every agent wallet tool until the signer
has successfully authorized the current signing session. Guessed or unsolicited
wallet broker messages are rejected while the vault is locked.

Direct-download builds now ship the private, sandboxed `WalletSigner.xpc`
service. The service has no network entitlement, seals the 256-bit vault
entropy with AES-GCM, protects its wrapping key with device-only Keychain user
presence, and keeps decrypted material, intents, policies, and spending rules only in
its memory. It validates the signed Locus host before accepting XPC, creates a
separate signer instance for every connection, requires the active session and
request source on every privileged message, bounds pending state, and clears
secrets when that connection ends. The Mac App Store target does not embed the
signer.

The in-app private-alpha and browser-provider settings are off by default.
Disabling alpha synchronously locks the signer, withdraws the agent capability,
cancels prepared work, revokes browser grants, and leaves the encrypted vault
intact. Legacy environment activation migrates into these settings once and is
not authoritative afterward. Activation, receive, and recovery instructions
are in [WalletActivation.md](WalletActivation.md).

## Signer acceptance criteria

Before the signer can satisfy the native protocol, it must:

- Run as a sandboxed XPC service with no network entitlement.
- Generate BIP-39 recovery material and derive distinct EVM, Solana, and Sui accounts inside the signer.
- Seal the seed with a device-only Keychain key and require Local Authentication for each signing session.
- Use exact-version-pinned, reviewed Rust dependencies for each chain.
- Return only public accounts, decoded transaction data, canonical digests, simulations, and signed transaction results.
- Wipe decrypted material on manual lock, sleep, crash/interruption, Locus quit,
  update, and relaunch. The selected phase-one behavior has no idle timeout.
- Recheck digest, nonce, network, fee, and expiry immediately before signing.

## Rollout

1. **Implemented for the private alpha:** in-app activation, one 24-word vault,
   a locked-state receive flow with local ERC-681 QR generation, cached balance
   display, EVM/Solana/Sui public accounts, native EVM Sepolia transactions,
   signer-owned spending rules,
   registered ABI calls with signer-owned calldata and exact confirmation, and
   a session-scoped EIP-1193/EIP-6963 provider for Sepolia native transfers.
2. **Implemented behind experimental gates:** signer-derived ERC-20 semantics
   and a separate, narrow Universal Router V2 exact-input adapter, each with
   exact contract, asset, counterparty, fee, cumulative allowance, and expiry
   constraints. Unknown effects and unlimited approvals stay exact-confirmation.
3. **Recommended next milestone after alpha exit:** MetaMask Connect on
   Sepolia, preserving the external wallet's keys and confirmation surface.
   Phantom Connect on devnet and Slush Wallet Standard on Sui testnet remain
   unavailable future capabilities.
4. **Security gated:** EVM mainnet and every live external-wallet connection.
5. **Security gated:** native Solana/Sui signing and live Phantom/Slush connections.

Each mainnet gate remains off until local-chain integration tests, dependency and SBOM review, secret scanning, threat-model review, and an external security audit have passed.

## Private-alpha exit criteria

The next milestone stays closed until 3–5 invited testers can set up and
receive without Terminal or external instructions, and at least 20
limited-fund Sepolia transactions complete across agent and browser paths.
There must be no unauthorized signing, replay, secret exposure,
unrecoverable stuck state, or unresolved broadcast ambiguity. Public beta,
external-wallet enablement, and every mainnet gate still require an external
security audit.

The current RustSec audit reports no vulnerability advisories. It does report
two transitive maintenance warnings (`derivative` 2.2.0 and `paste` 1.0.15);
those crates are captured in the locked SBOM and must be removed or explicitly
accepted during the dependency review before any mainnet gate can open.

The formal trust boundaries, adapter language, adversarial checks, release
criteria, and incident procedure are in
[WalletThreatModel.md](WalletThreatModel.md).
