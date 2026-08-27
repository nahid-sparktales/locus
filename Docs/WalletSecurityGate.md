# Locus Vault security gate

Locus Vault is a separate, limited-fund wallet. It does not import, extract, or impersonate Phantom, MetaMask, or Slush. Those wallets remain external approval surfaces and retain their own keys and confirmation behavior.

## Current build boundary

The app and local agent contain the chain-neutral gateway, transaction-intent model, policy engine, native broker protocol, and Wallet Settings surface. Wallet tools are not advertised to a model unless both conditions are true:

1. An audited native `WalletSigner` service is available.
2. `LOCUS_ENABLE_EXPERIMENTAL_WALLET=1` was set for that build or launch.

Even then, the native gateway withholds every agent wallet tool until the signer
has successfully authorized the current signing session. Guessed or unsolicited
wallet broker messages are rejected while the vault is locked.

Direct-download builds now ship the private, sandboxed `WalletSigner.xpc`
service. The service has no network entitlement, seals the 256-bit vault
entropy with AES-GCM, protects its wrapping key with device-only Keychain user
presence, and keeps decrypted material, intents, policies, and budgets only in
its memory. The Mac App Store target does not embed the signer.

The experimental runtime gate is still off by default. Activation and recovery
instructions are in [WalletActivation.md](WalletActivation.md).

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

1. **Implemented behind experimental gates:** one 24-word vault, EVM/Solana/Sui
   public accounts, native EVM Sepolia transactions, signer-owned budgets,
   registered ABI calls with signer-owned calldata and exact confirmation, and
   a session-scoped EIP-1193/EIP-6963 provider for Sepolia native transfers.
2. **Security gated:** autonomous reviewed ERC-20 and Uniswap effect adapters
   and their pinned testnet acceptance fixtures.
3. **Security gated:** EVM mainnet and MetaMask Connect.
4. **Security gated:** Solana signing and Phantom Connect.
5. **Security gated:** Sui signing and Slush Wallet Standard.

Each mainnet gate remains off until local-chain integration tests, dependency and SBOM review, secret scanning, threat-model review, and an external security audit have passed.

The current RustSec audit reports no vulnerability advisories. It does report
two transitive maintenance warnings (`derivative` 2.2.0 and `paste` 1.0.15);
those crates are captured in the locked SBOM and must be removed or explicitly
accepted during the dependency review before any mainnet gate can open.
