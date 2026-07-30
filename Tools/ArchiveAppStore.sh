#!/bin/zsh
# Creates a sandboxed Mac App Store archive and optionally uploads it.
#
# Archive only:
#   Tools/ArchiveAppStore.sh
#
# Archive and upload:
#   LOCUS_UPLOAD=1 Tools/ArchiveAppStore.sh
#
# Authentication uses the SparkTales App Store Connect API key. Override its
# location with LOCUS_ASC_KEY_PATH when it is stored elsewhere.
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
project_yml="${repo_root}/project.yml"
key_id="${LOCUS_ASC_KEY_ID:-QYV9PN42QS}"
issuer_id="${LOCUS_ASC_ISSUER_ID:-3675bb71-8667-42ca-a9ae-2b6091f0c076}"
key_path="${LOCUS_ASC_KEY_PATH:-${repo_root:h}/SparkTales_Master/api-keys/AuthKey_${key_id}.p8}"
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
xcodegen generate >/dev/null

xcodebuild -quiet \
    -project "${repo_root}/Locus.xcodeproj" \
    -scheme Locus \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -derivedDataPath "${repo_root}/.build-archive" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${key_path}" \
    -authenticationKeyID "${key_id}" \
    -authenticationKeyIssuerID "${issuer_id}" \
    DEVELOPMENT_TEAM="${team_id}" \
    CODE_SIGN_STYLE=Automatic \
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
