#!/bin/zsh
# A unit-test build embeds LocusTests.xctest in its host app. A later normal
# Build can reuse that app directory without rebuilding or signing the tests,
# and the unsigned stale bundle then makes the app's final CodeSign fail.
#
# Run as a pre-build phase so cleanup completes before dependent test targets
# begin producing their fresh bundles. The Test action recreates and signs the
# bundle normally after the host app has finished building.
set -euo pipefail

stale_test_bundle="${TARGET_BUILD_DIR:-}/${PLUGINS_FOLDER_PATH:-}/LocusTests.xctest"
if [[ "${stale_test_bundle}" != *"/Locus.app/Contents/PlugIns/LocusTests.xctest" ]]; then
    echo "error: Refusing to clean a test bundle outside Locus.app." >&2
    exit 1
fi

if [[ -e "${stale_test_bundle}" ]]; then
    /bin/rm -rf "${stale_test_bundle}"
    echo "note: Removed stale generated LocusTests.xctest before app signing."
fi
