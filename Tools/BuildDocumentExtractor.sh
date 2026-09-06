#!/bin/zsh
# Public PDFKit/Vision helper shared by Direct and Mac App Store builds.
set -euo pipefail
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
helper_dir="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
/bin/mkdir -p "${helper_dir}"
output="${helper_dir}/LocusDocumentExtractor"
source_file="${repo_root}/DocumentExtractor/main.swift"
deployment="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
architecture="${CURRENT_ARCH:-arm64}"
[[ "${architecture}" == "undefined_arch" ]] && architecture="arm64"
/usr/bin/xcrun swiftc -O -whole-module-optimization \
    -target "${architecture}-apple-macosx${deployment}" \
    -framework AppKit -framework PDFKit -framework Vision -framework CryptoKit \
    "${source_file}" -o "${output}"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "${identity}" ]] && identity="-"
if [[ "${ENABLE_APP_SANDBOX:-NO}" == "YES" || "${CONFIGURATION:-}" == "ReleaseMAS" ]]; then
    /usr/bin/codesign --force --options runtime --entitlements "${repo_root}/Config/AgentRuntime.entitlements" --sign "${identity}" "${output}"
else
    /usr/bin/codesign --force --options runtime --sign "${identity}" "${output}"
fi
