## Locus WalletSigner cryptography

LocusX builds include a network-isolated Rust signing core. Its direct
dependencies are exact-version pinned and all transitive packages are sealed by
`WalletSignerCore/Cargo.lock`. The release bundle includes
`WalletSignerSBOM.cdx.json`, a CycloneDX inventory with every resolved package,
version, dependency edge, declared SPDX license expression, and the lockfile
SHA-256. Packaging stops when a dependency, source, or license expression has
not been reviewed.

The primary direct crates are Alloy 2.4.1, bip39 2.2.2,
slip10_ed25519 0.1.3, solana-pubkey 4.3.0, sui-crypto 0.3.1,
sui-sdk-types 0.3.2, and zeroize 1.9.0. Wallet-free Locus and the App Store build do not contain
the signer.
