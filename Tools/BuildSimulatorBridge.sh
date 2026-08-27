#!/bin/zsh
# Builds the pinned direct-download-only Simulator bridge into the app. The
# Mac App Store target must never contain either helper or its private schemas.
set -euo pipefail

if [[ "${TARGET_NAME:-}" != "Locus" || "${CONFIGURATION:-}" == "ReleaseMAS" ]]; then
    exit 0
fi

repo_root="${SRCROOT:?}"
source_root="${repo_root}/SimulatorBridge"
helpers="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
clang="${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
sdk_root="${SDKROOT:-$(DEVELOPER_DIR="${developer_dir}" /usr/bin/xcrun --sdk macosx --show-sdk-path)}"
private_frameworks="/Library/Developer/PrivateFrameworks"
xcode_private_frameworks="${developer_dir}/Library/PrivateFrameworks"
bridge_arch="${NATIVE_ARCH_ACTUAL:-arm64}"
if [[ -z "${bridge_arch}" || "${bridge_arch}" == "undefined_arch" ]]; then
    bridge_arch="$(/usr/bin/uname -m)"
fi

[[ -x "${clang}" ]] || { echo "error: full Xcode is required for Simulator bridge" >&2; exit 1; }

touch_source_sha="af01bb7412a7c4c1db14a49ea21b7c1a055f7cffd6440c04059348885832fb71"
tree_source_sha="b16c270de8121e5b53626949ff818aca8ee29ba0c8b8372edd957d41bd243b63"
actual_touch_source_sha="$(/usr/bin/shasum -a 256 "${source_root}/simtouch.m" | /usr/bin/awk '{print $1}')"
actual_tree_source_sha="$(/usr/bin/shasum -a 256 "${source_root}/simtree.m" | /usr/bin/awk '{print $1}')"
[[ "${actual_touch_source_sha}" == "${touch_source_sha}" ]] || {
    echo "error: Simulator touch source does not match the audited pin" >&2; exit 1
}
[[ "${actual_tree_source_sha}" == "${tree_source_sha}" ]] || {
    echo "error: Simulator tree source does not match the audited pin" >&2; exit 1
}

/bin/mkdir -p "${helpers}" "${resources}"
common=(
    -arch "${bridge_arch}"
    -isysroot "${sdk_root}"
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    -framework Foundation -framework CoreGraphics
    -F"${private_frameworks}" -framework CoreSimulator
    -Wl,-rpath,"${private_frameworks}"
    -Wl,-rpath,"${xcode_private_frameworks}"
    -O2
)
"${clang}" "${source_root}/simtouch.m" "${common[@]}" -fno-objc-arc \
    -o "${helpers}/LocusSimulatorTouch"
"${clang}" "${source_root}/simtree.m" "${common[@]}" -fobjc-arc \
    -o "${helpers}/LocusSimulatorTree"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    /usr/bin/codesign --force --sign "${identity}" "${helpers}/LocusSimulatorTouch"
    /usr/bin/codesign --force --sign "${identity}" "${helpers}/LocusSimulatorTree"
fi

touch_binary_sha="$(/usr/bin/shasum -a 256 "${helpers}/LocusSimulatorTouch" | /usr/bin/awk '{print $1}')"
tree_binary_sha="$(/usr/bin/shasum -a 256 "${helpers}/LocusSimulatorTree" | /usr/bin/awk '{print $1}')"
{
    echo "upstream=https://github.com/martingeidobler/ios-mcp-server"
    echo "commit=bd5aca70704fe0fb5e974abaed205f54469799b0"
    echo "license=MIT"
    echo "touch_source_sha256=${touch_source_sha}"
    echo "tree_source_sha256=${tree_source_sha}"
    echo "touch_binary_sha256=${touch_binary_sha}"
    echo "tree_binary_sha256=${tree_binary_sha}"
    echo "architectures=$(/usr/bin/lipo -archs "${helpers}/LocusSimulatorTouch")"
} > "${resources}/SimulatorBridgeProvenance.txt"
