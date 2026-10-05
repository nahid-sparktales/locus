# Extraction packaging verification

This records the local macOS ARM64 checks on 2026-10-05. No runtime repository
was published, service registered, account used, or production installation changed.

## Immutable runtime input

The unpublished `locus-runtime` source commit is
`db1955b106d747ff715885ff6d68c834e2d3129d` on `codex/extract-runtime`, in the
local sibling repository `/Users/nahid/.codex/worktrees/b6b6/locus-runtime`.
There is no remote. The committed product wheel is
`agent/vendor/wheels/locus_runtime-0.1.0-py3-none-any.whl`, SHA-256
`8c7cdbc0d623f9c1cde600c2dd49af8460f3b558bd26d4576f794a759b292c36`.

Two independent `git archive` exports built byte-identical wheels with Python
3.14.6, build 1.5.0, setuptools 83.0.0, wheel 0.47.0 and
`SOURCE_DATE_EPOCH=1791228931`. Exact reproduction commands are in
`agent/vendor/wheels/README.md`; `runtime-release.json` binds the artifact to
this actual source revision and explicitly records its unpublished local state.

`pip-compile --generate-hashes --find-links=agent/vendor/wheels
--no-emit-find-links --output-file=agent/requirements-runtime.lock
agent/requirements-runtime.in` regenerated the lock. Only the new runtime
pin/hash and requests/websockets dependency comments changed; neighboring
dependency pins were preserved. The resulting lock SHA-256 is
`c274b978f5ea8875f2511c85b9ffdb58efa8664f68018acb7b715c4dfc5891fe`.

The runtime wheel owns the sole `locus-runtime` console script. Product staging
derives `ollama-code` metadata from `agent/pyproject.toml` and registers only
`locus_runtime.host` → `locus = ollama_code.runtime_host:main`. Both builders
verify the installed runtime files against the reviewed wheel; venv packaging
also rejects an absent or changed runtime before staging source or provenance.

The packaging/release tests passed **38 cases**, with Ruff, shell syntax and
`git diff --check` passing. Negative shell checks exercise failed registration
under a zsh conditional and an incomplete developer venv. A fresh Python 3.10
venv with `tomli` successfully ran `Tools/RuntimePackage.py verify`; Python
3.11+ uses stdlib `tomllib`. `tomli` is a conditional development dependency.

## Clean product checkout and portable archive

All composition outputs and test environments are outside the source repository:

```text
/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-runtime-composition-w2qanfa9
```

Call that directory `VERIFY_ROOT` in the commands below. `VERIFY_ROOT/product`
is a fresh `git clone --no-local` of Locus, without a sibling runtime repository
or editable installation. Existing checksum-pinned upstream archives and helper
caches were copied into isolated build destinations; their originals were only
read. Dependencies were installed with the actual hash lock into fresh targets.

The final portable archive was composed from clean Locus commit
`aeaea423d66d589d821c2f05833b10f3cda5f078`:

```sh
python3 "$VERIFY_ROOT/product/Tools/PrepareRemoteRuntime.py" \
  --target macos-arm64 --require-clean \
  --cache "$VERIFY_ROOT/downloads" \
  --output "$VERIFY_ROOT/locus-runtime-macos-arm64.tar.gz"
```

Build: **passed**, `source_dirty: false`. Archive SHA-256:
`a12ce6adf643afbb4fa64c91a0e94cb0cdf1722cfced38cc0dd047b2c0a69ce4`.
The `.build.json` records both source revisions, the wheel hash, the dependency
lock and the reviewed upstream Python/helper identities.

The smoke tooling venv contained only the runtime wheel, installed with
`pip install --no-deps`; it had no Locus distribution or source import path.
The scenario uses runtime-owned installer and snapshot APIs. The initial run
found a remaining product snapshot import in this tool, fixed in `aeaea423`
with an architecture regression test before the successful repeat.

```sh
"$VERIFY_ROOT/smoke-env/bin/python" \
  "$VERIFY_ROOT/product/Tools/SmokeRemoteRuntime.py" \
  --package "$VERIFY_ROOT/locus-runtime-macos-arm64.tar.gz" \
  --sha256 a12ce6adf643afbb4fa64c91a0e94cb0cdf1722cfced38cc0dd047b2c0a69ce4 \
  --output "$VERIFY_ROOT/macos-arm64.process-smoke.json"
```

Process smoke: **passed**. All seven reported checks passed: authenticated
loopback, signed-out helper handshake, detached schedule, verified result,
usage coverage, approved correction enforcement, and isolated cleanup. Three
runs recorded 84 deterministic fixture tokens. This is process execution, not
an OS service, real SSH connection or provider-account test.

## Native backend/resource composition

`Tools/BundleBackend.sh` passed from clean Locus
`425bda09e0c876ecd4ccfb68a39d5d293fca7726` with:

```sh
LOCUS_BUNDLE_MODE=standalone \
LOCUS_RUNTIME_CACHE="$VERIFY_ROOT/native-python-cache" \
LOCUS_CODEX_CACHE="$VERIFY_ROOT/native-codex-cache" \
LOCUS_BUNDLE_CODEX=build LOCUS_BUNDLE_CLAUDE=build \
TARGET_BUILD_DIR="$VERIFY_ROOT/native" \
UNLOCALIZED_RESOURCES_FOLDER_PATH=Locus.app/Contents/Resources \
CONTENTS_FOLDER_PATH=Locus.app/Contents TARGET_NAME=Locus LOCUS_EDITION=locus \
CONFIGURATION=Debug CODE_SIGNING_ALLOWED=NO ARCHS=arm64 CURRENT_ARCH=arm64 \
"$VERIFY_ROOT/product/Tools/BundleBackend.sh"
```

This assembled portable Python, the hash-pinned dependencies, edition-selected
product source, trusted host metadata, provenance, Memory Guard, both Codex
helpers and Claude helper under the isolated `.app` resources tree. No helper
was registered or provider account used. Provenance reports clean commit
`425bda09`; the Python interpreter imports both runtime and product host from
the app's own Resources, and `pip` is absent. The verification uses only the
packaged source/site-packages paths that the existing native launcher uses.

The earlier native resource output at clean `5673f68f` was itself archived
with `Tools/PackageRemoteRuntime.py` and passed the same seven process-smoke
checks (three runs, 84 fixture tokens and successful cleanup). That archive is
`locus-native-runtime-macos-arm64.tar.gz`, SHA-256
`bd3f2b6f4ab5378ad2ed6b7cfc44d335189d58c5768618a3886096380e0eb60e`.
After the shell/tooling fixes, all **4,272 Python/source/dependency files** in
the final resource build matched that smoked archive byte for byte, excluding
generated pip `RECORD` files whose removed script hashes vary across staging
directories. No claim of byte-identical arbitrary dependency installations is made.

The native backend/resource assembly and portable product archive work without
the runtime checkout or system pip. The complete application build was verified
separately below; UI launch remains a separate gate.

## Complete native application build

A full Locus Debug application build from the clean `425bda09` product clone
**passed**, with the standalone backend and both provider helpers bundled:

```sh
cd "$VERIFY_ROOT/product"
LOCUS_BUNDLE_MODE=standalone \
LOCUS_RUNTIME_CACHE="$VERIFY_ROOT/native-python-cache" \
LOCUS_CODEX_CACHE="$VERIFY_ROOT/native-codex-cache" \
LOCUS_BUNDLE_CODEX=build LOCUS_BUNDLE_CLAUDE=build \
xcodebuild build -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$VERIFY_ROOT/native-derived" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements
```

Result: exit 0, `BUILD SUCCEEDED`. The complete app is
`native-derived/Build/Products/Debug/Locus.app`. Its actual bundled interpreter
successfully imported the runtime, host adapter and product server in a
disposable profile outside the checkout; imports resolved only inside that
app's Resources. The runtime files matched the committed wheel, the trusted
host registration was present, and system/bundled pip was not required (`pip`
was absent). Provenance recorded the clean product revision and exact runtime
source/wheel identity. After the import check,
`codesign --verify --deep --strict` on the complete app **passed**, exit 0.

This establishes that a clean packaged Locus build contains and loads the
extracted runtime without a runtime source checkout. It is an **ad-hoc Debug
build**, not a Developer ID/notarization, signed SMAppService registration,
LocusX distribution, XCTest execution or native UI-launch claim. The app was
not launched and no runtime service was enabled.

## Evidence and remaining gates

Evidence retained beneath `VERIFY_ROOT`:

- `remote-build.log`, `locus-runtime-macos-arm64.tar.gz.build.json`, and
  `macos-arm64.process-smoke.json`.
- `native-build.log`, `native-import-verification.json`,
  `native-package.log`, and `macos-arm64.native-process-smoke.json`.
- `native-full-build.log`, `native-full-app-verification.json`, and the complete
  `native-derived/Build/Products/Debug/Locus.app`.
- `lock.log`, `tooling-py310.log`, both independently built wheels, and the
  clean product clone and isolated native resources.

Linux x86-64/ARM64 package execution, live SSH/Tailscale, launchd/systemd
service installation/recovery, real provider credentials, signed SMAppService
registration and reboot recovery remain unverified in this extraction session.
The existing CI target matrix and runbooks retain those separate gates.
