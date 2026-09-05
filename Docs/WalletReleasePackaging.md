# Dormant wallet release packaging

The canary candidate uses this sequence: clean source → dormant Xcode archive →
Developer ID export → audit → notarize/staple → zip verification and signed
appcast → evidence review → signed activation. The candidate never contains an
activating capability manifest, which removes the cycle between a manifest and
the hash of its own packaged app.

GA promotes the exact notarized canary archive bytes after its complete soak;
it does not rebuild or re-zip an artifact and inherit the previous candidate's
evidence. The two designated Macs independently verify that same archive.

## Connector build toolchain

The wallet CI input jobs use exact Node `24.20.0` (supported Node 24 LTS) and
npm `11.8.0`, not the runner image's defaults. The official
[`actions/setup-node` v6.5.0 release](https://github.com/actions/setup-node/releases/tag/v6.5.0)
is pinned to verified commit `249970729cb0ef3589644e2896645e5dc5ba9c38`, with
automatic package-manager caching and latest-version lookup disabled. npm is
installed with lifecycle scripts disabled into the runner's temporary directory;
both versions are asserted before the unchanged locked connector install.

This is a resolver compatibility pin, not an SDK or lockfile update. The
macOS runner's npm `10.9.8` rejects the unchanged lockfile with a missing optional
`utf-8-validate@5.0.10` entry; that failure was reproduced with only npm changed.
Node `24.20.0` with npm `11.8.0` installs it without ignoring peer dependencies
or omitting packages, and reproduces the checked-in connector bundle and SBOM.
Local release operators must use the same exact pair and rerun the dependency,
advisory, and byte-comparison gates. Future tool changes require fresh evidence.

The independently downloaded official macOS arm64 Node archive matched
[`SHASUMS256.txt`](https://nodejs.org/download/release/v24.20.0/SHASUMS256.txt):
`40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8`.
The published npm `11.8.0` package integrity is
`sha512-n19sJeW+RGKdkHo8SCc5xhSwkKhQUFfZaFzSc+EsYXLjSqIV0tl72aDYQVuzVvfrbysGwdaQsNLNy58J10EBSQ==`.
These build tools are distinct from the application dependency SBOM; a local
toolchain reproduction does not establish a passing remote CI run or release
approval. Earlier Node 25 reproductions remain historical evidence only.

## Archive and export

Commit the candidate and regenerate the Xcode project before beginning. Use an
external, new artifact directory; the archive tool rejects dirty source, an
existing destination, or a destination under the checkout. Debug, Release, and
ReleaseMAS use separate DerivedData directories.

Set `LOCUS_WALLET_RELEASE_CHANNEL` to `canary` for the candidate. Supply the public
verification key, distinct signed non-activating review ceiling, exact provider URLs, connector
identifiers, approved redirects, and activation endpoint through the release
environment. Use `LOCUS_WALLET_REVIEW_CEILING_BASE64`; both
`LOCUS_WALLET_CAPABILITY_MANIFEST_BASE64` and the legacy
`LOCUS_WALLET_REVIEW_MANIFEST_BASE64` must be empty. Missing
configuration fails closed. The archive tool lists the required variable names;
credentials and evidence files stay outside the repository.

The archive also seals `LOCUS_CANARY_UPDATE_FEED_URL` and
`LOCUS_WALLET_CANDIDATE_ARCHIVE_URL`. These public HTTPS locations must identify
a distinct non-`latest` canary feed and the retained immutable candidate ZIP.
The stable `SUFeedURL` remains unchanged. Both channels use the same sealed
archive URL on promotion; do not rewrite either URL after signing.

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

## Isolated canary updates and same-archive promotion

Canary packaging writes `canary/appcast.xml`, never the stable feed. Its entries
carry the explicit Sparkle `canary` channel. The generator requires an explicit
`canary` or `stable` argument, verifies the preceding feed's signature and channel,
and rejects mixed-channel histories. To initialize the first canary feed, set
`LOCUS_APPCAST_INITIAL_CHANNEL=canary`; initialization succeeds only when its
distinct endpoint returns HTTP 404, not on a timeout or other network failure.
Component assets must still accompany the release that serves the configured
component feed. No tool publishes or changes GitHub's latest release selection.

Dormant wallet candidates without a current verified admission cannot check for
updates. An admitted active canary selects its sealed canary feed and the exact
candidate archive/version; verified GA promotion selects stable. Normal builds
without wallet candidate configuration retain ordinary stable updates. The
App Store artifact must contain neither candidate configuration nor its updater
authority code. These controls do not replace signed device admissions.

`ArchiveWalletRelease.sh` refuses fresh GA archives and packaging refuses to
repackage GA. Preserve the final notarized canary ZIP. For promotion, first
independently reverify its existing signed canary feed and unchanged archive as
GA evidence, then sign the **unpublished** GA promotion. Generate its stable feed:

```sh
LOCUS_NOTARIZE=1 LOCUS_WALLET_GA_PROMOTION=/external/signed-ga-promotion.json \
  Tools/GenerateAppcast.sh /external/retained/Locus-macOS.zip \
  /external/new-stable-feed/appcast.xml stable
```

This read-only promotion preflight verifies the signature against the sealed
wallet public key and matches the actual retained ZIP hash, source, version,
outer-app/signer CodeDirectory identities, and review ceiling. It does not
re-sign, re-zip, or modify the app. Independently audit the generated stable feed
before publishing it and the promotion together. That final stable-feed audit is
a **publication gate**, not an artifact prerequisite embedded in the very
promotion needed to generate it; this avoids a new approval cycle.

## Sign activation only after evidence exists

Collect the exact source revision, bundle version, outer-app and signer
CodeDirectory hashes, final stapled archive hash, signed review ceiling, signed
restriction, capability manifest, and schema-v2 launch evidence. Run
`Tools/SignWalletReleaseActivation.swift` with the complete evidence index and
its attributable approvals and the preceding signed envelope (or `initial`).
See [WalletReleaseEvidence.md](WalletReleaseEvidence.md) for the separate
rehearsal-authorization, observed rehearsal, and counted-mainnet phases;
canonical identity/fingerprint generation; and candidate-bound admissions.
The review restriction must be identical to or
narrower than the bundled ceiling; exact connector ownership/configuration and
reviewed provider identities must match the intended activated networks.

The app fetches activation outside WebKit and both app and authenticated signer
verify it independently. Missing, invalid, expired, mismatched, or rolled-back
activation leaves mainnet disabled. Higher-revision restrictions narrow
authority and are the mechanism exercised by the incident drill. Initial
production activation requires all three mainnets and signed device admissions.
Unchanged-scope renewal can extend an operational lease up to 31 days without
changing the immutable ceiling or resetting the soak. Permanent restrictions
cannot be removed by renewal or promotion. The chosen outage tolerance means
offline clients can retain cached authority until expiry; it does not promise
instant offline revocation.

Developer ID export, live provisioning, notarization, second-Mac audit,
independently verified updates, and external approvals remain uncompleted until
actual attributable results exist. Script syntax and fixture tests alone cannot
mark these gates complete.

Local fixture results are recorded separately from release evidence and must be
rerun on the final committed candidate. The credentialed archive/export flow has not been
executed on this uncommitted implementation tree; its first real run remains a
release gate, including investigation of any archive/export provenance drift.
