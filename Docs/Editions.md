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

Both local editions have `LocusUpdateMode=manual` and no app update feed. They
never start Sparkle or honor old automatic-update preferences. The independently
verified Codex component feed remains available. Separate public app feeds,
notarization, LocusX Google registration, and public wallet migration are deferred.
Do not publish these local artifacts through the old appcast.
