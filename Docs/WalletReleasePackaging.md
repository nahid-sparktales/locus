# Dormant wallet release packaging

Canary and GA use the same sequence: clean source → dormant Xcode archive →
Developer ID export → audit → notarize/staple → zip verification and signed
appcast → evidence review → signed activation. The candidate never contains an
activating capability manifest, which removes the cycle between a manifest and
the hash of its own packaged app.

## Archive and export

Commit the candidate and regenerate the Xcode project before beginning. Use an
external, new artifact directory; the archive tool rejects dirty source, an
existing destination, or a destination under the checkout. Debug, Release, and
ReleaseMAS use separate DerivedData directories.

Set `LOCUS_WALLET_RELEASE_CHANNEL` to `canary` or `ga`. Supply the public
verification key, signed schema-v2 review ceiling, exact provider URLs, connector
identifiers, approved redirects, and activation endpoint through the release
environment. `LOCUS_WALLET_CAPABILITY_MANIFEST_BASE64` must be empty. Missing
configuration fails closed. The archive tool lists the required variable names;
credentials and evidence files stay outside the repository.

Run:

```sh
Tools/ArchiveWalletRelease.sh /absolute/external/candidate-artifacts
```

The tool performs locked connector dependency/advisory checks and bundle
reproduction, then runs Xcode's archive and `-exportArchive` actions with
`method=developer-id` and automatic provisioning. A signed-in Xcode account may
provide provisioning; an explicitly supplied App Store Connect key is also
supported. The signer requires the production Keychain entitlement and its
exported Developer ID profile. There is no fallback to ad-hoc entitlements or
manual post-export signing.

SBOMs and source provenance are placed in the app during the archive build,
before Xcode seals it. Export provenance compares archived and exported code
with signatures removed only from disposable copies, requires unchanged
resources, records the exported CodeDirectory identities and file hashes, and
validates both signer profiles, their expiry, team and authorized Keychain group.
The receipt is build provenance for later attributable review; it is not a
signature, an auditor approval, or wallet activation.

### Connector configuration identities

Every enabled connector review entry has `configurationSHA256`: lowercase
SHA-256 of compact ASCII JSON with lexicographically sorted keys, unescaped
slashes and no trailing newline. The payload includes the domain separator
`format: locus-wallet-connector-config-v1` and exact connector ID. Shared public
test vectors are in `ProtocolFixtures/wallet-connector-configuration-v1.json`.

| Connector | Additional canonical inputs |
| --- | --- |
| Phantom | `appID`, canonical HTTPS `redirectURL`, `providers: [phantom]`, `addressTypes: [solana]`, `embeddedWalletType: user-wallet`, `autoConnect: true` |
| WalletConnect | `projectID`, exact `redirectURL: locus-wallet://walletconnect`, `mode: walletconnect-sign`, `dappURL: https://locus.app` |
| MetaMask | `rpcURLs` keyed by Ethereum mainnet/Sepolia network IDs, `dappName: Locus`, `dappURL: https://locus.app`, `analyticsEnabled: false`, `skipAutoAnnounce: true` |
| Slush | `mode: wallet-standard`, `walletName: Slush`, `dappName: Locus`, `origin: https://my.slush.app` |
| Embedded browser | `mode: embedded-browser`, `signerProtocolVersion: 3` |

MetaMask's map is exactly the runtime map: choose the reviewed Alchemy endpoint
for each network, otherwise reviewed QuickNode; omit unavailable networks and
reject an empty map. Endpoint identity includes provider, network, configuration
ID, URL digest, and chain identity. Removing a selected provider can therefore
disable the connector; a restriction cannot silently authorize a different map.

Configuration strings trim only ASCII space, tab, CR and LF, identically in
the runtime and Python audit. URLs must
already be canonical, bounded ASCII HTTPS URLs without user information,
fragments, invalid percent escapes or raw bracket/escape characters. Release
drivers use only sealed bundle values; Debug environment overrides still must
match a signed digest. Legacy entries missing a digest can be decoded for
compatibility but never enable a connector. The signing tool requires a digest
for new connector entries, and a restriction must retain the identical digest.
`VerifyWalletProviderBindings.py`, invoked by the dormant-artifact audit,
independently reproduces the same bytes. It prints only check counts, never app
IDs, provider URLs, redirects, or configuration payloads.

## Package the exact export

Set `LOCUS_WALLET_EXPORT_PROVENANCE` to the emitted
`WalletExportProvenance.json`, then run:

```sh
Tools/PackageRelease.sh /absolute/external/candidate-artifacts/export/Locus.app \
  /absolute/external/release-assets/Locus-macOS.zip
```

For canary/GA this command requires the export receipt and immediately routes to
`PackageExportedWalletRelease.sh`, before any legacy signing or plist mutation.
It verifies the unchanged clean source revision, exact exported identities and
sealed content, dormant configuration, exact reviewed provider bindings, runtime
import, distribution audit, and zip round trip. It neither rewrites the app's
configuration/resources nor re-signs a nested or outer executable. Simulator
provenance uses signature-independent code hashes, so Xcode's certificate or
timestamp replacement does not require altering a sealed resource.

Set `LOCUS_NOTARIZE=1` to request Apple notarization, stapling, Gatekeeper
assessment, ticket validation after extraction, and signed appcast generation.
Supply the App Store Connect credentials and component release assets required
by the existing update-feed workflow. A run without notarization is explicitly a
private verification artifact and is not eligible for activation. The tool does
not publish a release or sign an activation.

## Sign activation only after evidence exists

Collect the exact source revision, bundle version, outer-app and signer
CodeDirectory hashes, final stapled archive hash, signed review ceiling, signed
restriction, capability manifest, and schema-v2 launch evidence. Run
`Tools/SignWalletReleaseActivation.swift` with the complete evidence index and
its attributable approvals. The review restriction must be identical to or
narrower than the bundled ceiling; exact connector ownership/configuration and
reviewed provider identities must match the intended activated networks.

The app fetches activation outside WebKit and both app and authenticated signer
verify it independently. Missing, invalid, expired, mismatched, or rolled-back
activation leaves mainnet disabled. Higher-revision restrictions narrow
authority and are the mechanism exercised by the incident drill.

Developer ID export, live provisioning, notarization, second-Mac audit,
independently verified updates, and external approvals remain uncompleted until
actual attributable results exist. Script syntax and fixture tests alone cannot
mark these gates complete.

Local verification on 2026-09-04 passed 16 packaging fixtures, the complete
814-test Python suite, lint and shell syntax checks. Xcode's installed export
help confirms the selected Developer ID, automatic-signing and
`stripSwiftSymbols` options. The credentialed archive/export flow has not been
executed on this uncommitted implementation tree; its first real run remains a
release gate, including investigation of any archive/export provenance drift.
