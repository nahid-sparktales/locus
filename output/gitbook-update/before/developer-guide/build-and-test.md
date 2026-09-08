> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/developer-guide/build-and-test.md).

# Build & Test

Prepare the Locus V2 native app, bundled agent, mobile companion, and optional Codex component.

## Prerequisites

Source builds require Xcode 26 and Rust 1.95 installed with rustup. XcodeGen is needed only when changing `project.yml` or adding source files.

```bash
brew install xcodegen
rustup toolchain install 1.95.0 --profile minimal --component rust-src
rustup target add aarch64-apple-darwin x86_64-apple-darwin --toolchain 1.95.0
xcodegen generate
open Locus.xcodeproj
```

Select the Locus scheme and My Mac. The first build downloads the relocatable Python runtime and pinned Codex dependencies; later builds reuse them.

## Native tests

```bash
xcodebuild test \
  -project Locus.xcodeproj \
  -scheme Locus \
  -destination 'platform=macOS' \
  -only-testing:LocusTests
```

Run UI tests with the LocusUITests target when changing navigation, Browser, permissions, split panes, or inspector behavior.

## Agent tests

```bash
cd agent
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/python -m pytest -q
```

## Mobile checks

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

## Codex component packaging

Release deliberately does not embed the helpers; it records component delivery provenance. `Tools/PackageComponents.sh <output-directory>` builds, strips, signs, and publishes the helpers and `components.json` feed. Debug and ReleaseMAS embed them for local work. Override with `LOCUS_BUNDLE_CODEX=build|component|skip`.

Run the distribution and third-party audits before publishing.
