# Build & Test

Build wallet-free Locus from the repository's `main` branch with Xcode 26 and XcodeGen. `project.yml` is the source of truth for the generated Xcode project.

## Build for Ollama and API accounts

From the repository root:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/locus \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements \
  LOCUS_BUNDLE_CODEX=skip build
open build/locus/Build/Products/Debug/Locus.app
```

The first build downloads the standalone Python runtime. `LOCUS_BUNDLE_CODEX=skip` omits optional ChatGPT helpers and avoids their Rust build. To include them, install Rust through rustup and remove that setting; the pinned Codex source selects its toolchain. LocusX additionally needs the signer toolchain pinned in `WalletSignerCore/rust-toolchain.toml`.

Use separate build directories for Locus and LocusX. Locus and LocusMAS exclude wallet code, SDKs, resources, signer helpers, and wallet browser injection. A backend setting cannot enable wallet tools in the standard staged app.

## Native tests

For common native tests, replace the final `build` above with `test -only-testing:LocusTests`. LocusX uses its own scheme, build directory, and `LocusXTests`. Run relevant UI checks for interface changes. Consult the repository's CI workflow for the exact release checks.

## Backend tests

From the repository root, use Python 3.10 or later:

```sh
python3 -m venv agent/.venv
agent/.venv/bin/pip install -e './agent[dev]'
agent/.venv/bin/python -m pytest -q
```

Tests use disposable application data. CI currently uses Python 3.14.

## Mobile checks

From the mobile checkout with its pinned Flutter SDK:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

## Packaging

Packaged apps must include the agent runtime. `LOCUS_BUNDLE_MODE=skip` is a compile-only shortcut, not a deliverable app. Direct release builds normally deliver ChatGPT helpers separately; Debug and ReleaseMAS bundle them. Component delivery verifies checksums and signing identity before execution.

Locus 2.6.0 uses manual app updates. Follow the version's release procedures and edition audit; do not publish wallet-free Locus through the preserved legacy app feed. See the repository's [Contributing guide](https://github.com/nahid-sparktales/locus/blob/main/CONTRIBUTING.md) and [Editions guide](https://github.com/nahid-sparktales/locus/blob/main/Docs/Editions.md) for current source build and packaging details, which may advance beyond these release docs.
