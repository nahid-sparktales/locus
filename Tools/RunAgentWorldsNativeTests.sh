#!/usr/bin/env bash
# Build and test the real app host under a disposable bundle identity. This avoids
# colliding with a running Locus app without changing app/test binaries or assertions.
# LOCUS_AGENT_WORLDS_TEST_PLUGIN: absolute extracted, verified artifact (optional).
# LOCUS_NATIVE_TEST_SELECTION: comma-separated target/class[/method] (default: all LocusTests).
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${LOCUS_NATIVE_TEST_BUILD_ROOT:-${TMPDIR:-/tmp}/locus-agent-worlds-native-tests}"
derived_root="${LOCUS_NATIVE_TEST_DERIVED_DATA:-$build_root/derived}"
mkdir -p "$build_root"
cd "$repo_root"
xcodegen generate > "$build_root/generate.log" 2>&1
xcodebuild build-for-testing -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$derived_root" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements \
  LOCUS_BUNDLE_MODE=skip LOCUS_BUNDLE_CODEX=skip LOCUS_BUNDLE_CLAUDE=skip > "$build_root/build.log" 2>&1
products_root="$derived_root/Build/Products"
app_root="$products_root/Debug/Locus.app"
host_container="$(mktemp -d "$build_root/host.XXXXXX")"
host_root="$host_container/LocusNativeTests.app"
host_identifier="io.sparktales.locus.agent-worlds-tests.$(basename "$host_container")"
/usr/bin/ditto "$app_root" "$host_root"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $host_identifier" "$host_root/Contents/Info.plist"
codesign --force --deep --sign - --preserve-metadata=entitlements,flags,runtime "$host_root" > "$host_container/sign.log" 2>&1
python3 - "$products_root" "$host_container" "$host_root" "$host_identifier" <<'PY'
import os, pathlib, plistlib, sys
products, output, host, identity = sys.argv[1:]
configs = list(pathlib.Path(products).glob('Locus_macosx*.xctestrun'))
if len(configs) != 1:
    raise SystemExit('Expected one generated macOS Locus .xctestrun')
config = plistlib.loads(configs[0].read_bytes())
# Preserve the genuine Xcode app-hosted injection/lifecycle. UI automation targets
# are separate; this script runs the complete unit/regression target only.
config = {key: value for key, value in config.items() if key in ('LocusTests', '__xctestrun_metadata__')}
old_host = str(pathlib.Path(products) / 'Debug/Locus.app')
def resolve(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', products).replace(old_host, host)
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    return value
config = resolve(config)
target = config['LocusTests']
target['TestHostPath'] = host
target['TestHostBundleIdentifier'] = identity
target['DependentProductPaths'] = [path for path in target['DependentProductPaths'] if 'LocusUITests' not in path]
plugin = os.environ.get('LOCUS_AGENT_WORLDS_TEST_PLUGIN')
if plugin:
    if not pathlib.Path(plugin).is_absolute() or not (pathlib.Path(plugin) / 'ui/index.html').is_file():
        raise SystemExit('Provide an absolute extracted plugin root containing ui/index.html')
    target['EnvironmentVariables']['LOCUS_AGENT_WORLDS_TEST_PLUGIN'] = plugin
    target['EnvironmentVariables']['LOCUS_AGENT_WORLDS_TEST_SNAPSHOT'] = str(pathlib.Path(output) / 'packaged-wk.png')
pathlib.Path(output, 'Tests.xctestrun').write_bytes(plistlib.dumps(config))
PY
command_args=(test-without-building -xctestrun "$host_container/Tests.xctestrun" -destination 'platform=macOS' -resultBundlePath "$host_container/tests.xcresult")
if [[ -n "${LOCUS_NATIVE_TEST_SELECTION:-}" ]]; then
  IFS=',' read -r -a selections <<< "$LOCUS_NATIVE_TEST_SELECTION"
  for selection in "${selections[@]}"; do command_args+=("-only-testing:${selection/./\/}"); done
fi
set +e
xcodebuild "${command_args[@]}" > "$build_root/tests.log" 2>&1
result=$?
set -e
tail -12 "$build_root/tests.log"
echo "Native evidence: $build_root (app host and result bundle: $host_container)"
exit "$result"
