#!/bin/zsh
# Build and export a dormant wallet candidate with Xcode-owned provisioning.
# Usage: LOCUS_WALLET_RELEASE_CHANNEL=canary Tools/ArchiveWalletRelease.sh /external/artifacts
set -euo pipefail
repo_root="${0:A:h:h}"
artifact_dir="${1:?usage: ArchiveWalletRelease.sh <new artifact directory outside the repository>}"
artifact_dir="${artifact_dir:A}"
[[ "${artifact_dir}" != "${repo_root}" && "${artifact_dir}" != "${repo_root}"/* \
    && ! -e "${artifact_dir}" ]] || {
    echo "error: choose a new artifact directory outside the source checkout" >&2
    exit 1
}
channel="${LOCUS_WALLET_RELEASE_CHANNEL:?set LOCUS_WALLET_RELEASE_CHANNEL=canary or ga}"
[[ "${channel}" == "canary" || "${channel}" == "ga" ]] || exit 1
[[ "${channel}" == "canary" ]] || {
    echo "error: GA promotes the retained notarized canary ZIP; a fresh GA archive would invalidate its soak" >&2
    exit 1
}
[[ -z "$(/usr/bin/git -C "${repo_root}" status --porcelain)" ]] || {
    echo "error: commit the candidate before archiving; a clean revision is required" >&2
    exit 1
}
revision="$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)"
team="${LOCUS_TEAM_ID:-4X4RJA7GMD}"
[[ "${team}" =~ '^[A-Z0-9]{10}$' ]] || exit 1
[[ -n "${LOCUS_WALLET_CAPABILITY_PUBLIC_KEY:-}" \
    && -n "${LOCUS_WALLET_REVIEW_CEILING_BASE64:-}" \
    && -z "${LOCUS_WALLET_REVIEW_MANIFEST_BASE64:-}" \
    && -z "${LOCUS_WALLET_CAPABILITY_MANIFEST_BASE64:-}" ]] || {
    echo "error: a dormant candidate requires the verification key and signed review ceiling, with no capability manifest" >&2
    exit 1
}

/bin/mkdir -m 700 -p "${artifact_dir}"
# Resolve licenses and advisories before regenerating any derived bundle. These
# input reports are outside the app; the build also creates its sealed SBOMs.
(cd "${repo_root}/WalletConnectionsWeb" && npm ci --ignore-scripts --no-audit --no-fund \
    && npm audit --omit=dev --audit-level=high)
python3 "${repo_root}/Tools/WalletSignerSBOM.py" \
    "${repo_root}/WalletSignerCore" "${artifact_dir}/WalletSignerSBOM.inputs.json"
python3 "${repo_root}/Tools/WalletConnectionsSBOM.py" \
    "${repo_root}/Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "${repo_root}/project.yml" "${artifact_dir}/WalletConnectionsSBOM.inputs.json"
cargo audit --file "${repo_root}/WalletSignerCore/Cargo.lock"
(cd "${repo_root}/WalletConnectionsWeb" && npm run build)
/usr/bin/git -C "${repo_root}" diff --exit-code -- WalletConnectionsRuntime/Resources/WalletConnections.bundle.js
export_options="${artifact_dir}/ExportOptions.plist"
/usr/bin/plutil -create xml1 "${export_options}"
/usr/bin/plutil -insert method -string developer-id "${export_options}"
/usr/bin/plutil -insert signingStyle -string automatic "${export_options}"
/usr/bin/plutil -insert teamID -string "${team}" "${export_options}"
/usr/bin/plutil -insert destination -string export "${export_options}"
/usr/bin/plutil -insert stripSwiftSymbols -bool NO "${export_options}"

settings=(
    DEVELOPMENT_TEAM="${team}" CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="Developer ID Application"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
    LOCUS_WALLET_SIGNER_ENTITLEMENTS=Config/WalletSigner.entitlements
    PROVISIONING_PROFILE_SPECIFIER= LOCUS_WALLET_ARCHIVE=1
    LOCUS_SOURCE_REVISION="${revision}" LOCUS_BUNDLE_MODE=standalone
    LOCUS_WALLET_CAPABILITY_MANIFEST_BASE64= LOCUS_WALLET_REVIEW_MANIFEST_BASE64=
)
required_settings=(
    LOCUS_WALLET_CAPABILITY_PUBLIC_KEY LOCUS_WALLET_REVIEW_CEILING_BASE64
    LOCUS_REOWN_PROJECT_ID LOCUS_WALLETCONNECT_REDIRECT_URL
    LOCUS_PHANTOM_APP_ID LOCUS_PHANTOM_REDIRECT_URL
    LOCUS_WALLET_RELEASE_ACTIVATION_URL
    LOCUS_CANARY_UPDATE_FEED_URL LOCUS_WALLET_CANDIDATE_ARCHIVE_URL
    LOCUS_WALLET_ALCHEMY_ETHEREUM_MAINNET_RPC_URL LOCUS_WALLET_QUICKNODE_ETHEREUM_MAINNET_RPC_URL
    LOCUS_WALLET_ALCHEMY_ETHEREUM_SEPOLIA_RPC_URL LOCUS_WALLET_QUICKNODE_ETHEREUM_SEPOLIA_RPC_URL
    LOCUS_WALLET_ALCHEMY_SOLANA_MAINNET_RPC_URL LOCUS_WALLET_QUICKNODE_SOLANA_MAINNET_RPC_URL
    LOCUS_WALLET_ALCHEMY_SOLANA_DEVNET_RPC_URL LOCUS_WALLET_QUICKNODE_SOLANA_DEVNET_RPC_URL
    LOCUS_WALLET_ALCHEMY_SUI_MAINNET_GRAPHQL_URL LOCUS_WALLET_QUICKNODE_SUI_MAINNET_GRAPHQL_URL
    LOCUS_WALLET_ALCHEMY_SUI_TESTNET_GRAPHQL_URL LOCUS_WALLET_QUICKNODE_SUI_TESTNET_GRAPHQL_URL
)
for name in "${required_settings[@]}"; do
    value="$(/usr/bin/printenv "${name}" 2>/dev/null || true)"
    [[ -n "${value}" && "${value}" != *'$('* ]] || {
        echo "error: missing release configuration ${name}" >&2; exit 1
    }
    settings+=("${name}=${value}")
done
auth=()
if [[ -n "${LOCUS_ASC_KEY_PATH:-}" ]]; then
    [[ -f "${LOCUS_ASC_KEY_PATH}" ]] || exit 1
    auth=(-authenticationKeyPath "${LOCUS_ASC_KEY_PATH}"
        -authenticationKeyID "${LOCUS_ASC_KEY_ID:?}"
        -authenticationKeyIssuerID "${LOCUS_ASC_ISSUER_ID:?}")
fi
archive="${artifact_dir}/Locus.xcarchive"
export_dir="${artifact_dir}/export"
xcodebuild -quiet -project "${repo_root}/Locus.xcodeproj" -scheme Locus \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "${archive}" -derivedDataPath "${artifact_dir}/DerivedData-Release" \
    -allowProvisioningUpdates "${auth[@]}" "${settings[@]}" archive
[[ -z "$(/usr/bin/git -C "${repo_root}" status --porcelain)" \
    && "$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)" == "${revision}" ]] || {
    echo "error: source changed during archive" >&2; exit 1
}
xcodebuild -quiet -exportArchive -archivePath "${archive}" -exportPath "${export_dir}" \
    -exportOptionsPlist "${export_options}" -allowProvisioningUpdates "${auth[@]}"
python3 "${repo_root}/Tools/WalletExportProvenance.py" record "${archive}" \
    "${export_dir}/Locus.app" "${export_options}" "${artifact_dir}/WalletExportProvenance.json" \
    --channel "${channel}"
LOCUS_WALLET_RELEASE_CHANNEL="${channel}" \
    "${repo_root}/Tools/VerifyDormantWalletArtifact.sh" "${export_dir}/Locus.app"
"${repo_root}/Tools/AuditDistribution.sh" "${export_dir}/Locus.app"
echo "Dormant Developer ID export verified: ${export_dir}/Locus.app"
echo "Package it with LOCUS_WALLET_EXPORT_PROVENANCE=${artifact_dir}/WalletExportProvenance.json."
