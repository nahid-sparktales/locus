# Locus Wallet Connections — Third-Party Notices

This notice is packaged only in the Direct-download Locus application. The
Mac App Store target contains none of the connector runtime or these notices.

The trusted connector page is built from `WalletConnectionsWeb/package-lock.json`.
Its complete machine-readable component, version, integrity, source, and
license inventory is `WalletConnectionsSBOM.cdx.json` in the application
resources. The audited direct dependencies are:

- `@metamask/connect-evm` 2.1.1
- `@phantom/browser-sdk` 2.0.2
- `@mysten/slush-wallet` 1.1.23
- `@solana/wallet-standard` 1.1.6
- `@wallet-standard/core` 1.1.2
- `@mysten/sui` 2.29.0
- `@mysten/wallet-standard` 0.21.22
- `@solana/web3.js` 1.98.4
- `esbuild` 0.28.2 (build-time only)

The npm lock currently contains nine transitive packages whose published
package metadata omits a license declaration. The SBOM resolves these using
version-and-integrity-bound license evidence: Phantom's MIT license at commit
`87ad8fac24721cbe00377e92f429a500b0da4139`, the packaged `eyes` MIT license,
and the packaged `text-encoding-utf-8` public-domain/Unlicense text. The exact
texts ship as `phantom-wallet-sdk-87ad8fac.LICENSE`, `eyes-0.1.8.LICENSE`, and
`text-encoding-utf-8-1.0.2.LICENSE`. Source-license verification does not replace
separate counsel approval of Reown's terms or Phantom's embedded-wallet beta terms.

Locus also incorporates the Sign-only product from a patched, file-digested
vendor tree of Reown Swift 2.3.2.
Portions © 2025 Reown, Inc. All Rights Reserved.
The complete governing license is packaged as `LICENSE`; its
SHA-256 is `e30bbba6782f025ba0b6ced7d36840ac8587073d8df06a21be369a5cfcfc5830`.
