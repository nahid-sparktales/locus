#!/bin/zsh
# Runs in the build phase before Xcode seals the archive. Never run on an export.
set -euo pipefail
[[ "${LOCUS_WALLET_ARCHIVE:-0}" == "1" ]] || exit 0
[[ "${TARGET_NAME:-}" == "LocusX" && "${LOCUS_EDITION:-}" == "locusx" \
    && "${CONFIGURATION:-}" == "Release" \
    && "${ACTION:-}" == "install" ]] || {
    echo "error: wallet archive preparation requires the Direct Release archive action" >&2
    exit 1
}
[[ "${LOCUS_BUNDLE_MODE:-standalone}" == "standalone" ]] || {
    echo "error: release archives require the standalone runtime" >&2
    exit 1
}
repo_root="${0:A:h:h}"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
[[ "${resources}" == *.app/Contents/Resources ]] || exit 1
[[ -z "$(/usr/bin/git -C "${repo_root}" status --porcelain)" ]] || {
    echo "error: wallet archive source became dirty during the build" >&2
    exit 1
}
revision="$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)"
[[ "${LOCUS_SOURCE_REVISION:-}" == "${revision}" ]] || {
    echo "error: archive source revision is not pinned to this checkout" >&2
    exit 1
}
python3 "${repo_root}/Tools/WalletSignerSBOM.py" \
    "${repo_root}/WalletSignerCore" "${resources}/WalletSignerSBOM.cdx.json"
python3 "${repo_root}/Tools/WalletConnectionsSBOM.py" \
    "${repo_root}/Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "${repo_root}/project.yml" "${resources}/WalletConnectionsSBOM.cdx.json"
