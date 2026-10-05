#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
helper_dir="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
/bin/mkdir -p "${helper_dir}"
architecture="${CURRENT_ARCH:-arm64}"
[[ "${architecture}" == "undefined_arch" ]] && architecture="arm64"
/usr/bin/xcrun swiftc -O -target "${architecture}-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    "${script_dir:h}/MemoryGuard/main.swift" -o "${helper_dir}/LocusMemoryGuard"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "${identity}" ]] || identity="-"
/usr/bin/codesign --force --options runtime --identifier io.sparktales.locus.memory-guard \
    --sign "${identity}" "${helper_dir}/LocusMemoryGuard"
