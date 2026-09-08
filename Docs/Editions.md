# Locus and LocusX

Locus is the default wallet-free app. LocusX is a separate app with the optional
wallet implementation. Both use the same core app and agent sources.

## Build boundaries

`LOCUS_DIRECT_DOWNLOAD` selects desktop distribution features such as Sparkle,
Computer Control, and Simulator tools. `LOCUS_WALLET` selects the LocusX product.
Locus and LocusMAS exclude wallet Swift sources, connector SDKs and resources,
signer/recovery helpers, browser provider injection, and wallet settings.

The bundled backend has a fixed product factory. `Tools/StageBackendEdition.py`
selects that factory during packaging; only LocusX receives `_locusx/wallet.py`.
Changing a setting, environment variable, or capability message cannot enable
wallet support in the standard app. Source-checkout agent development defaults
to Locus. Use the staged LocusX backend for wallet development.

## Separate profiles

Locus retains its existing bundle identifier, app support files, credentials,
backend home, browser profile identifiers, and OAuth callbacks. LocusX uses
`io.sparktales.locusx`, `~/Library/Application Support/LocusX`, `~/.locusx/auth.json`,
and separate Keychain services. Its backend and Codex homes are inside its
Application Support folder. Both apps can run together. Workspace-owned files
such as `.locus/launch.json` and shared project documents keep their names.

LocusX registers `locusx://mcp/oauth`; Locus retains `locus://mcp/oauth`.
LocusX does not register Locus's Google callback. Until a dedicated Google client
and exact registered callback are configured, Gmail sign-in is unavailable in
LocusX. GitHub device flow remains available with isolated saved tokens.

The wallet signer/recovery identities and encrypted vault format are unchanged.
The signer authorizes LocusX and the recovery helper, not standard Locus. No old
wallet files or Keychain entries are deleted or automatically imported.

## Build and verify

Regenerate the project with `xcodegen generate`. Build each edition in a separate
DerivedData directory because their shared Swift module is named `Locus`:

```sh
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -derivedDataPath build/editions/locus build
xcodebuild -project Locus.xcodeproj -scheme LocusX -configuration Debug \
  -derivedDataPath build/editions/locusx build
xcodebuild -project Locus.xcodeproj -scheme LocusMAS -configuration ReleaseMAS \
  -derivedDataPath build/editions/mas build
```

`LocusTests` hosts common tests in Locus. `LocusXTests` hosts common and wallet
tests in LocusX. Wallet chain and fuzz schemes use only the wallet edition.
Normal builds bundle the standalone agent runtime; `LOCUS_BUNDLE_MODE=skip` is
for compile-only checks and is not a deliverable app.

Audit a complete app with `python3 Tools/AuditAppEdition.py <app> --edition locus`
or `--edition locusx`. The standard audit inspects every Mach-O, the bundled
backend, resources, metadata, and callback registration. `--allow-missing-runtime`
is permitted only for compile-only CI checks. Distribution audits retain signing,
license, runtime, and desktop capability checks separately from wallet checks.

## Local delivery

The local Locus artifact is placed under `output/wallet-free/` as `Locus.app` and
`Locus-macOS.zip`. It bundles its Python runtime and requires no separate Python
installation. Ollama/model downloads and hosted-provider accounts remain optional
user configuration.

Development Locus builds and every LocusX configuration have
`LocusUpdateMode=manual` and no app update feed. They never start Sparkle or honor
old automatic-update preferences. Locus's `Release` configuration selects
`Config/LocusRelease-Info.plist` and enables the separate standard-app feed.
The independently verified Codex component feed remains available in both direct
editions. LocusX updates, Google registration, and public wallet migration remain
deferred. Never publish wallet-free Locus through the old appcast.

## Automatic Locus releases

Released Locus uses
`https://github.com/nahid-sparktales/locus/releases/latest/download/appcast-locus.xml`.
It checks daily, downloads updates in the background, and installs on quit.
Sparkle may remind users after a week or ask for administrator approval when
installation needs it. Existing user opt-outs remain effective. Tests never
start the updater. The app reads and validates its edition, identity, update
mode and feed from its sealed bundle; a saved legacy feed URL cannot override it.

**One manual upgrade is required:** 2.6.0 and earlier manual builds cannot fetch
this change themselves. Wallet-era installations continue to see their unchanged
legacy feed. Installing new Locus preserves its existing chats, accounts,
settings and browser data without importing or deleting wallet data.

1. At release time, choose a build greater than 26 and greater than every build
   already in the Locus feed. Update the version and changelog and commit the
   generated project. This updater implementation itself does not bump versions.
2. Run the Python release tests, native updater tests and focused update-settings
   UI tests for Locus Debug and Release, LocusX, and the App Store edition. Build
   and audit all three editions in separate DerivedData directories. A complete
   deliverable must include its runtime; `LOCUS_BUNDLE_MODE=skip` is compile-only.
   Use scheme `LocusReleaseUpdates` for the Release UI check: it excludes unit
   tests that rely on Debug-only instrumentation. The focused method is
   `LocusUITests/LocusUITests/testUpdatesSettingsMatchTheBuildDistribution`.
3. In a fresh staging directory, place verified `components.json` and all its
   referenced archives. Copy `appcast.xml` from tag `v2.6.0` without changing its
   bytes. Its SHA-256 must be
   `fabc1d4450afce04a5931bde6dc9630994f7748d512d73a8a600630b52696ece`.
   Do not stage an existing `appcast-locus.xml`: the generator retrieves and
   verifies the current Locus feed itself, preserving only that feed's history.
4. Use the existing SparkTales Developer ID and Sparkle Keychain account
   `io.sparktales`, the pinned Sparkle 2.9.6 tools, and the notarization credentials
   described below. Build scheme `Locus`, configuration `Release`, with its full
   runtime from the clean release revision, then package:

   ```sh
   LOCUS_NOTARIZE=1 Tools/PackageRelease.sh \
     /absolute/path/Locus.app /absolute/staging/Locus-macOS.zip
   ```

   For the **first** Locus feed only, also set
   `LOCUS_APPCAST_INITIAL_CHANNEL=locus`. Initialization requires HTTP 404 from
   the new feed endpoint. HTTP errors, transport failures, and invalid existing
   signatures fail packaging; initialization never discards an existing feed.
   The generator's explicit mode is
   `Tools/GenerateAppcast.sh <zip> <new appcast-locus.xml> locus`.
5. The packager checks wallet exclusion, identity, Developer ID signatures,
   arm64 architecture, test-bundle exclusion, notarization, stapling, and the ZIP
   round trip. Feed entries use signed, version-pinned `Locus-macOS.zip` URLs,
   never a `latest` archive URL. Both the feed and archive signatures must verify.
   The legacy feed is checked again after generation and must remain unchanged.
6. Before publication, exercise a signed update between two increasing builds
   in an isolated macOS test account. Use a private fixture build/feed for this
   rehearsal; production routing remains pinned. Verify daily/default settings,
   preserved opt-outs, background download, installation on quit, relaunch, and
   retained data. Also exercise settings/note-save failures and active-work
   cleanup. Do not run this rehearsal against a user's installed application.
7. Upload `Locus-macOS.zip`, **both** `appcast-locus.xml` and the unchanged
   `appcast.xml`, `components.json`, and every component archive to one draft
   release. Review before publishing as latest. Verify the public asset hashes,
   both feed endpoints and signatures, and the component endpoint after publishing.

To withdraw a faulty update, restore the previous valid signed Locus feed and
verify the endpoint again; never alter the legacy feed. Already-updated apps
need a corrective release with a higher build. Do not delete archives referenced
by retained feeds. A rollback feed cannot undo an update already installed.

## Public manual Locus releases

An ordinary wallet-free Locus release may be signed and notarized for manual
download while retaining `LocusUpdateMode=manual`. This does not start Sparkle,
change update preferences, or migrate existing wallet data. LocusX is excluded
from this procedure. There is no automatic upgrade from earlier editions to
this manual release.

1. Commit the version, build number, changelog, and generated project. Run the
   Python and standard native tests. Build scheme `Locus`, configuration
   `Release`, explicitly overriding `INFOPLIST_FILE=Locus/Info.plist` and
   `LOCUS_UPDATE_MODE=manual`, from that clean revision in separate DerivedData with the full
   bundled runtime (`LOCUS_BUNDLE_MODE=skip` must not be set). Audit the complete
   app with `Tools/AuditAppEdition.py --edition locus`.
2. Prepare a release staging directory containing `components.json` and every
   referenced component archive. Copy the previous release's pair if unchanged,
   or run `Tools/PackageComponents.sh`. Run `Tools/VerifyComponentAssets.sh`.
3. Copy the signed `appcast.xml` from tag `v2.6.0` into staging without
   changing its bytes.
   This file remains necessary because older installed apps request
   `releases/latest/download/appcast.xml`. Every enclosure must point to a
   version-pinned prior release archive. Never point it at the new ZIP or a
   `latest` URL, and never add this manual release to the feed.
4. Have the SparkTales Developer ID Application identity, the existing Sparkle
   key (`io.sparktales`) in the login Keychain, and verified Sparkle 2.9.6 tools
   available. The tools default to `.release-tools/Sparkle-2.9.6`; an explicit
   verified location can be supplied with `LOCUS_SPARKLE_TOOLS_DIR`. Set the
   public `LOCUS_GITHUB_OAUTH_CLIENT_ID` and the notarization credential variables
   `LOCUS_ASC_KEY_ID`, `LOCUS_ASC_ISSUER_ID`, and `LOCUS_ASC_KEY_PATH` locally.
   Never place private credentials in the repository or release assets.
5. Package using the explicit manual-publication option:

   ```sh
   LOCUS_PUBLIC_MANUAL_RELEASE=1 LOCUS_NOTARIZE=1 \
     Tools/PackageRelease.sh /absolute/path/Locus.app /absolute/staging/Locus-macOS.zip
   ```

   The default rejection of public manual builds stays in place without this
   option. The packager audits the wallet-free edition, verifies the retained
   feed's signature and prior-version URLs, signs the full app, notarizes and
   staples it, verifies the extracted ZIP with Gatekeeper, and checks that the
   signed legacy feed is still unchanged. The signed app and extracted copy
   must retain the SparkTales Developer ID, contain only arm64, and exclude test
   bundles. It does not generate or promote an
   appcast. Builds without notarization remain private verification artifacts.
6. Upload `Locus-macOS.zip`, the unchanged `appcast.xml`, `components.json`, and
   every referenced component archive into one draft GitHub release. Once the
   automatic Locus feed is live, publish manual-only releases as **non-latest**
   downloads so they cannot remove `appcast-locus.xml` from the latest release.
   Verify asset hashes after publication. The release notes must identify this
   as a manual wallet-free download; older apps retain their existing feed.
