#!/bin/zsh
# Creates a sandboxed Mac App Store archive and optionally uploads it.
#
# Archive only:
#   Tools/ArchiveAppStore.sh
#
# Archive and upload:
#   LOCUS_UPLOAD=1 Tools/ArchiveAppStore.sh
#
# Authentication uses the SparkTales App Store Connect API key. Point
# LOCUS_ASC_KEY_PATH at the .p8 file; it lives outside the repository.
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
project_yml="${repo_root}/project.yml"
# Not defaulted in-tree: these are half of an App Store Connect credential
# pair, and this repository is public. Set them in your shell or a local
# untracked env file; the values live with the .p8 key, outside the repo.
key_id="${LOCUS_ASC_KEY_ID:?set LOCUS_ASC_KEY_ID (App Store Connect API key id)}"
issuer_id="${LOCUS_ASC_ISSUER_ID:?set LOCUS_ASC_ISSUER_ID (App Store Connect issuer id)}"
key_path="${LOCUS_ASC_KEY_PATH:?set LOCUS_ASC_KEY_PATH (path to the App Store Connect .p8 key)}"
github_client_id="${LOCUS_GITHUB_OAUTH_CLIENT_ID:?set LOCUS_GITHUB_OAUTH_CLIENT_ID (public Locus GitHub App client id)}"
if [[ "${github_client_id}" == *'$('* ]]; then
    echo "error: LOCUS_GITHUB_OAUTH_CLIENT_ID is still an unresolved build placeholder." >&2
    exit 1
fi
team_id="${LOCUS_TEAM_ID:-4X4RJA7GMD}"
version="${LOCUS_MARKETING_VERSION:-$(/usr/bin/awk '/MARKETING_VERSION/ { print $2; exit }' "${project_yml}" | /usr/bin/tr -d '"')}"
build="${LOCUS_BUILD_VERSION:-$(/usr/bin/awk '/CURRENT_PROJECT_VERSION/ { print $2; exit }' "${project_yml}")}"
artifact_dir="${LOCUS_ARTIFACT_DIR:-${repo_root}/artifacts/appstore}"
archive_path="${LOCUS_ARCHIVE_PATH:-${artifact_dir}/Locus-${version}-${build}.xcarchive}"
export_path="${LOCUS_EXPORT_PATH:-${artifact_dir}/export-${version}-${build}}"
export_options="${repo_root}/Config/ExportOptions-AppStore.plist"

command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen is required" >&2
    exit 1
}
[[ -f "${key_path}" ]] || {
    echo "error: App Store Connect key not found at ${key_path}" >&2
    exit 1
}
[[ ! -e "${archive_path}" ]] || {
    echo "error: archive already exists at ${archive_path}" >&2
    exit 1
}
[[ ! -e "${export_path}" ]] || {
    echo "error: export already exists at ${export_path}" >&2
    exit 1
}

/bin/mkdir -p "${artifact_dir}"
cd "${repo_root}"
if [[ "${LOCUS_UPLOAD:-0}" == "1" ]] \
    && [[ -n "$(/usr/bin/git status --porcelain)" ]]
then
    echo "error: App Store uploads must be built from a clean source tree." >&2
    exit 1
fi
xcodegen generate >/dev/null

xcodebuild -quiet \
    -project "${repo_root}/Locus.xcodeproj" \
    -scheme LocusMAS \
    -configuration ReleaseMAS \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -derivedDataPath "${repo_root}/.build-archive" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${key_path}" \
    -authenticationKeyID "${key_id}" \
    -authenticationKeyIssuerID "${issuer_id}" \
    DEVELOPMENT_TEAM="${team_id}" \
    CODE_SIGN_STYLE=Automatic \
    LOCUS_GITHUB_OAUTH_CLIENT_ID="${github_client_id}" \
    archive

echo "Archive: ${archive_path}"
"${script_dir}/AuditDistribution.sh" \
    "${archive_path}/Products/Applications/Locus.app"

if [[ "${LOCUS_UPLOAD:-0}" == "1" ]]; then
    /usr/bin/sed 's#<string>export</string>#<string>upload</string>#' \
        "${export_options}" > "${artifact_dir}/ExportOptions-Upload.plist"
    export_options="${artifact_dir}/ExportOptions-Upload.plist"
fi

xcodebuild -quiet -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist "${export_options}" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${key_path}" \
    -authenticationKeyID "${key_id}" \
    -authenticationKeyIssuerID "${issuer_id}"

echo "Export: ${export_path}"
