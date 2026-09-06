#!/bin/zsh
# A unit-test build embeds LocusTests.xctest in its host app. A later normal
# Build can reuse that app directory without rebuilding or signing the tests,
# and the unsigned stale bundle then makes the app's final CodeSign fail.
#
# Run as a pre-build phase so cleanup completes before dependent test targets
# begin producing their fresh bundles. The Test action recreates and signs the
# bundle normally after the host app has finished building.
set -euo pipefail

is_test_action() {
    [[ "${LOCUS_TEST_ACTION:-0}" == "1" ]] && return 0

    # Build phases do not receive a distinct ACTION value for `xcodebuild
    # test`; both Test and Build report ACTION=build. Walk the short build
    # service ancestry instead so the cleanup cannot race the test target's
    # own output graph and remove its active executable.
    local process_id="${PPID}"
    local command_line
    local parent_id
    for _ in {1..8}; do
        [[ -n "${process_id}" && "${process_id}" != "1" ]] || break
        command_line="$(/bin/ps -p "${process_id}" -o command= 2>/dev/null || true)"
        if [[ "${command_line}" == *"xcodebuild"* ]] && {
            [[ "${command_line}" == *" test "* ]] \
                || [[ "${command_line}" == *" build-for-testing "* ]] \
                || [[ "${command_line}" == *" test-without-building "* ]]
        }; then
            return 0
        fi
        parent_id="$(/bin/ps -p "${process_id}" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ' || true)"
        process_id="${parent_id}"
    done
    return 1
}

if is_test_action; then
    echo "note: Preserving LocusTests.xctest for the active test action."
    exit 0
fi

# These are generated products only. Keep the containment/symlink checks below.
case "${TARGET_NAME:-}:${FULL_PRODUCT_NAME:-}" in
    Locus:Locus.app|LocusMAS:Locus.app)
        test_bundle_name="LocusTests.xctest" ;;
    LocusX:LocusX.app)
        test_bundle_name="LocusXTests.xctest" ;;
    LocusX:LocusX\ Experimental.app)
        [[ "${CONFIGURATION:-}" == "ReleaseExperimental" ]] || {
            echo "error: Refusing to clean an experimental app from another configuration." >&2
            exit 1
        }
        test_bundle_name="LocusXTests.xctest" ;;
    *) echo "error: Refusing to clean an unknown app build product." >&2; exit 1 ;;
esac
expected_plugins="${FULL_PRODUCT_NAME}/Contents/PlugIns"
if [[ "${TARGET_BUILD_DIR:-}" != /* || "${TARGET_BUILD_DIR:-}" == "/" \
    || ! -d "${TARGET_BUILD_DIR:-}" || "${PLUGINS_FOLDER_PATH:-}" != "${expected_plugins}" ]]; then
    echo "error: Refusing to clean a test bundle outside the exact Locus build product." >&2
    exit 1
fi
build_root="${TARGET_BUILD_DIR:A}"
stale_test_bundle="${build_root}/${expected_plugins}/${test_bundle_name}"
# A symlinked app, plug-in directory, or test bundle must not redirect cleanup
# outside the build output. Child symlinks are not followed by rm -r.
if [[ "${stale_test_bundle:A}" != "${stale_test_bundle}" ]]; then
    echo "error: Refusing to clean a redirected test bundle." >&2
    exit 1
fi

if [[ -e "${stale_test_bundle}" ]]; then
    /bin/rm -rf "${stale_test_bundle}"
    echo "note: Removed stale generated LocusTests.xctest before app signing."
fi
