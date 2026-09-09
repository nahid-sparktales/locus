#!/bin/zsh
set -euo pipefail
[[ "${LOCUS_EDITION:-locus}" == "locus" && "${CONFIGURATION:-}" != "ReleaseMAS" ]] || exit 0
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
helper_dir="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
agent_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
/bin/mkdir -p "${helper_dir}" "${agent_dir}"
architecture="${CURRENT_ARCH:-arm64}"
[[ "${architecture}" == "undefined_arch" ]] && architecture="arm64"
/usr/bin/xcrun swiftc -O -target "${architecture}-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "${repo_root}/RuntimeHelper/main.swift" -o "${helper_dir}/LocusRuntime"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "${identity}" ]] || identity="-"
/usr/bin/codesign --force --options runtime --sign "${identity}" "${helper_dir}/LocusRuntime"
/bin/cp "${repo_root}/Config/io.sparktales.locus.runtime.plist" "${agent_dir}/"
