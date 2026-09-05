#!/bin/zsh
# Canary/GA package an immutable Xcode Developer ID export with its receipt.
# The legacy wallet-disabled path signs, seals, and zips a built Locus.app:
#   1. sign every Mach-O in the bundled agent runtime, then the app
#   2. verify the seal
#   3. exercise the bundled runtime (import check, byte-code writing off)
#   4. verify the seal AGAIN — fails the release if step 3 dirtied the bundle
#   5. zip, extract to a temp dir, verify the extracted copy
#
# Usage: PackageRelease.sh /path/to/Locus.app /path/to/Locus-macOS.zip
# Identity comes from LOCUS_SIGN_IDENTITY, or the first Developer ID
# Application identity in the keychain.
set -euo pipefail
setopt null_glob

app="${1:?usage: PackageRelease.sh <Locus.app> <output.zip>}"
zip_out="${2:?usage: PackageRelease.sh <Locus.app> <output.zip>}"
runtime="${app}/Contents/Resources/AgentRuntime"
repo_root="${0:A:h:h}"
resources="${app}/Contents/Resources"
info_plist="${app}/Contents/Info.plist"
sparkle="${app}/Contents/Frameworks/Sparkle.framework"
wallet_signer="${app}/Contents/XPCServices/WalletSigner.xpc"
wallet_recovery="${app}/Contents/Helpers/WalletRecovery.app"
wallet_recovery_signer="${wallet_recovery}/Contents/XPCServices/WalletSigner.xpc"

# Wallet candidates can only originate from Xcode's Developer ID export flow.
# Route before this legacy packager can mutate a plist or replace a signature.
if [[ "${LOCUS_WALLET_RELEASE_CHANNEL:-disabled}" != "disabled" \
    || -n "${LOCUS_WALLET_EXPORT_PROVENANCE:-}" ]]; then
    [[ -n "${LOCUS_WALLET_EXPORT_PROVENANCE:-}" ]] || {
        echo "error: canary/GA require Tools/ArchiveWalletRelease.sh and its export provenance receipt" >&2
        exit 1
    }
    exec "${repo_root}/Tools/PackageExportedWalletRelease.sh" "${app}" "${zip_out}"
fi

identity="${LOCUS_SIGN_IDENTITY:-}"
if [[ -z "${identity}" ]]; then
    identity="$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/awk -F'"' '/Developer ID Application/ && !value { value=$2 } END { print value }')"
fi
if [[ -z "${identity}" ]]; then
    echo "error: no Developer ID Application identity found; set LOCUS_SIGN_IDENTITY." >&2
    exit 1
fi
if [[ "${identity}" != Developer\ ID\ Application:* ]]; then
    echo "error: direct-download releases require a Developer ID Application identity." >&2
    exit 1
fi
echo "Signing with: ${identity}"

[[ -f "${info_plist}" ]] || {
    echo "error: app Info.plist is missing" >&2
    exit 1
}
github_client_id="${LOCUS_GITHUB_OAUTH_CLIENT_ID:-}"
if [[ -z "${github_client_id}" || "${github_client_id}" == *'$('* ]]; then
    echo "error: set LOCUS_GITHUB_OAUTH_CLIENT_ID to the public client ID of the Locus GitHub App." >&2
    exit 1
fi
if ! /usr/bin/plutil -insert LocusGitHubOAuthClientID -string "${github_client_id}" "${info_plist}" \
    2>/dev/null
then
    /usr/bin/plutil -replace LocusGitHubOAuthClientID -string "${github_client_id}" "${info_plist}"
fi
wallet_release_channel="${LOCUS_WALLET_RELEASE_CHANNEL:-disabled}"
case "${wallet_release_channel}" in
    disabled|canary|ga) ;;
    *)
        echo "error: LOCUS_WALLET_RELEASE_CHANNEL must be disabled, canary, or ga" >&2
        exit 1
        ;;
esac
if [[ "${wallet_release_channel}" != "disabled" ]]; then
    # These identifiers and provider endpoints are public runtime
    # configuration, but must still be scoped to the reviewed release. They
    # are inserted only into the Direct artifact immediately before signing.
    connector_values=(
        LocusReownProjectID LOCUS_REOWN_PROJECT_ID
        LocusWalletConnectRedirectURL LOCUS_WALLETCONNECT_REDIRECT_URL
        LocusPhantomAppID LOCUS_PHANTOM_APP_ID
        LocusPhantomRedirectURL LOCUS_PHANTOM_REDIRECT_URL
        LocusWalletAlchemyEthereumMainnetRPCURL LOCUS_WALLET_ALCHEMY_ETHEREUM_MAINNET_RPC_URL
        LocusWalletQuickNodeEthereumMainnetRPCURL LOCUS_WALLET_QUICKNODE_ETHEREUM_MAINNET_RPC_URL
        LocusWalletAlchemyEthereumSepoliaRPCURL LOCUS_WALLET_ALCHEMY_ETHEREUM_SEPOLIA_RPC_URL
        LocusWalletQuickNodeEthereumSepoliaRPCURL LOCUS_WALLET_QUICKNODE_ETHEREUM_SEPOLIA_RPC_URL
        LocusWalletAlchemySolanaMainnetRPCURL LOCUS_WALLET_ALCHEMY_SOLANA_MAINNET_RPC_URL
        LocusWalletQuickNodeSolanaMainnetRPCURL LOCUS_WALLET_QUICKNODE_SOLANA_MAINNET_RPC_URL
        LocusWalletAlchemySolanaDevnetRPCURL LOCUS_WALLET_ALCHEMY_SOLANA_DEVNET_RPC_URL
        LocusWalletQuickNodeSolanaDevnetRPCURL LOCUS_WALLET_QUICKNODE_SOLANA_DEVNET_RPC_URL
        LocusWalletAlchemySuiMainnetGraphQLURL LOCUS_WALLET_ALCHEMY_SUI_MAINNET_GRAPHQL_URL
        LocusWalletQuickNodeSuiMainnetGraphQLURL LOCUS_WALLET_QUICKNODE_SUI_MAINNET_GRAPHQL_URL
        LocusWalletAlchemySuiTestnetGraphQLURL LOCUS_WALLET_ALCHEMY_SUI_TESTNET_GRAPHQL_URL
        LocusWalletQuickNodeSuiTestnetGraphQLURL LOCUS_WALLET_QUICKNODE_SUI_TESTNET_GRAPHQL_URL
    )
    for (( index = 1; index <= ${#connector_values}; index += 2 )); do
        plist_key="${connector_values[index]}"
        environment_key="${connector_values[index + 1]}"
        value="$(/usr/bin/printenv "${environment_key}" 2>/dev/null || true)"
        [[ -n "${value}" && "${value}" != *'$('* ]] || {
            echo "error: wallet ${wallet_release_channel} requires ${environment_key}" >&2
            exit 1
        }
        if ! /usr/bin/plutil -insert "${plist_key}" -string "${value}" "${info_plist}" \
            2>/dev/null
        then
            /usr/bin/plutil -replace "${plist_key}" -string "${value}" "${info_plist}"
        fi
    done
    reown_project_id="${LOCUS_REOWN_PROJECT_ID}"
    phantom_app_id="${LOCUS_PHANTOM_APP_ID}"
    [[ "${reown_project_id}" =~ '^[A-Za-z0-9_-]+$' \
        && "${#reown_project_id}" -ge 16 && "${#reown_project_id}" -le 128 ]] || {
        echo "error: LOCUS_REOWN_PROJECT_ID has an invalid release value" >&2
        exit 1
    }
    [[ "${phantom_app_id}" =~ '^[A-Za-z0-9._-]+$' \
        && "${#phantom_app_id}" -le 128 ]] || {
        echo "error: LOCUS_PHANTOM_APP_ID has an invalid release value" >&2
        exit 1
    }
    [[ "${LOCUS_WALLETCONNECT_REDIRECT_URL}" == "locus-wallet://walletconnect" ]] || {
        echo "error: WalletConnect redirect must be locus-wallet://walletconnect" >&2
        exit 1
    }
    for endpoint in \
        "${LOCUS_PHANTOM_REDIRECT_URL}" \
        "${LOCUS_WALLET_ALCHEMY_ETHEREUM_MAINNET_RPC_URL}" \
        "${LOCUS_WALLET_QUICKNODE_ETHEREUM_MAINNET_RPC_URL}" \
        "${LOCUS_WALLET_ALCHEMY_ETHEREUM_SEPOLIA_RPC_URL}" \
        "${LOCUS_WALLET_QUICKNODE_ETHEREUM_SEPOLIA_RPC_URL}" \
        "${LOCUS_WALLET_ALCHEMY_SOLANA_MAINNET_RPC_URL}" \
        "${LOCUS_WALLET_QUICKNODE_SOLANA_MAINNET_RPC_URL}" \
        "${LOCUS_WALLET_ALCHEMY_SOLANA_DEVNET_RPC_URL}" \
        "${LOCUS_WALLET_QUICKNODE_SOLANA_DEVNET_RPC_URL}" \
        "${LOCUS_WALLET_ALCHEMY_SUI_MAINNET_GRAPHQL_URL}" \
        "${LOCUS_WALLET_QUICKNODE_SUI_MAINNET_GRAPHQL_URL}" \
        "${LOCUS_WALLET_ALCHEMY_SUI_TESTNET_GRAPHQL_URL}" \
        "${LOCUS_WALLET_QUICKNODE_SUI_TESTNET_GRAPHQL_URL}"
    do
        [[ "${endpoint}" == https://* && "${endpoint}" != *'@'* \
            && "${endpoint}" != *'#'* ]] || {
            echo "error: wallet release connector endpoints must be credential-free HTTPS URLs" >&2
            exit 1
        }
    done
fi
revision="$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)"
built_revision="$(
    /usr/bin/awk -F= '$1 == "source_revision" { print $2; exit }' \
        "${resources}/BuildProvenance.txt"
)"
dirty=0
if [[ -n "$(/usr/bin/git -C "${repo_root}" status --porcelain)" ]]; then
    dirty=1
fi
if [[ "${LOCUS_NOTARIZE:-0}" == "1" && "${dirty}" == "1" ]]; then
    echo "error: notarization candidates must be built from a clean source tree." >&2
    exit 1
fi
if [[ "${LOCUS_NOTARIZE:-0}" == "1" && "${built_revision}" != "${revision}" ]]; then
    echo "error: app was built from ${built_revision:-unknown}, not clean source ${revision}." >&2
    echo "Rebuild the Release configuration before notarization." >&2
    exit 1
fi
if [[ "${LOCUS_NOTARIZE:-0}" == "1" && "${zip_out:t}" != "Locus-macOS.zip" ]]; then
    echo "error: public direct-download releases must be named Locus-macOS.zip" >&2
    exit 1
fi
component_archives=()
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    # The shipped app resolves LocusComponentFeedURL against
    # releases/latest/download, so the release this zip is destined for must
    # also republish components.json and the archive(s) it points at.
    # Checked before any signing so a missing component fails in seconds,
    # not after the notarization wait.
    component_archives=("${(@f)$("${repo_root}/Tools/VerifyComponentAssets.sh" "${zip_out:h}")}")
fi
revision_label="${revision}"
if [[ "${dirty}" == "1" ]]; then
    revision_label="${revision}-dirty"
fi
if ! /usr/bin/plutil -insert LocusSourceRevision -string "${revision_label}" "${info_plist}" \
    2>/dev/null
then
    /usr/bin/plutil -replace LocusSourceRevision -string "${revision_label}" "${info_plist}"
fi
for signer_plist in \
    "${wallet_signer}/Contents/Info.plist" \
    "${wallet_recovery_signer}/Contents/Info.plist"
do
    if ! /usr/bin/plutil -insert LocusSourceRevision -string "${revision_label}" \
        "${signer_plist}" 2>/dev/null
    then
        /usr/bin/plutil -replace LocusSourceRevision -string "${revision_label}" \
            "${signer_plist}"
    fi
done
/bin/mkdir -p "${resources}"
{
    echo "source_revision=${revision_label}"
    echo "built_source_revision=${built_revision:-unknown}"
    echo "bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")"
    echo "short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
    echo "xcode=$(/usr/bin/xcodebuild -version | /usr/bin/tr '\n' ' ')"
} > "${resources}/BuildProvenance.txt"

if [[ -d "${runtime}" ]]; then
    # --options runtime and --timestamp on every Mach-O: notarization
    # rejects a bundle where anything lacks either. Hardened runtime turns on
    # library validation, which is only safe because every file here is signed
    # with the one identity — the interpreter and its extension modules end up
    # with the same Team ID, so it can load them.
    /usr/bin/find "${runtime}" -type f \( -name "*.so" -o -name "*.dylib" \) \
        -exec /usr/bin/codesign --force --timestamp --options runtime \
            --sign "${identity}" {} +
    for interp in "${runtime}/python/bin"/python3.*(N); do
        /usr/bin/codesign --force --timestamp --options runtime \
            --sign "${identity}" "${interp}"
    done
fi
if [[ -d "${sparkle}" ]]; then
    for nested in \
        "${sparkle}/Versions/B/Autoupdate" \
        "${sparkle}/Versions/B/Updater.app" \
        "${sparkle}/Versions/B/XPCServices/Downloader.xpc" \
        "${sparkle}/Versions/B/XPCServices/Installer.xpc" \
        "${sparkle}"
    do
        /usr/bin/codesign --force --timestamp --options runtime \
            --sign "${identity}" "${nested}"
    done
fi
[[ -x "${wallet_signer}/Contents/MacOS/WalletSigner" ]] || {
    echo "error: direct-download release is missing WalletSigner.xpc" >&2
    exit 1
}
[[ ! -e "${app}/Contents/XPCServices/WalletConnections.xpc" ]] || {
    echo "error: direct-download release contains obsolete WalletConnections.xpc" >&2
    exit 1
}
[[ -x "${wallet_recovery}/Contents/MacOS/WalletRecovery" ]] || {
    echo "error: direct-download release is missing WalletRecovery.app" >&2
    exit 1
}
[[ -x "${wallet_recovery_signer}/Contents/MacOS/WalletSigner" ]] || {
    echo "error: WalletRecovery.app is missing its private WalletSigner.xpc" >&2
    exit 1
}
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    signer_info="${wallet_signer}/Contents/Info.plist"
    capability_key="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletCapabilityPublicKey' \
        "${signer_info}" 2>/dev/null || true)"
    capability_manifest="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletCapabilityManifestBase64' \
        "${signer_info}" 2>/dev/null || true)"
    review_manifest="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletReviewManifestBase64' \
        "${signer_info}" 2>/dev/null || true)"
    review_ceiling="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletReviewCeilingBase64' \
        "${signer_info}" 2>/dev/null || true)"
    if [[ "${wallet_release_channel}" == "disabled" ]]; then
        [[ -z "${capability_key}" && -z "${capability_manifest}" && -z "${review_manifest}" && -z "${review_ceiling}" ]] || {
            echo "error: a wallet-disabled release must not embed wallet manifests" >&2
            exit 1
        }
    else
        # Defensive backstop: candidate routes above must have exec'd the
        # immutable Xcode-export packager before this legacy signing path.
        echo "error: wallet candidates require ArchiveWalletRelease.sh export provenance" >&2
        exit 1
    fi
fi
# Sign the deepest privileged component first, then each containing boundary.
# The connector runtime is linked into the Direct app and has no independent
# signing boundary. The outer signer remains sealed independently.
/usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "${repo_root}/Config/WalletSigner.entitlements" \
    --sign "${identity}" "${wallet_recovery_signer}"
/usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "${repo_root}/Config/WalletRecovery.entitlements" \
    --sign "${identity}" "${wallet_recovery}"
/usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "${repo_root}/Config/WalletSigner.entitlements" \
    --sign "${identity}" "${wallet_signer}"
for simulator_helper in \
    "${app}/Contents/Helpers/LocusSimulatorTouch" \
    "${app}/Contents/Helpers/LocusSimulatorTree"
do
    [[ -x "${simulator_helper}" ]] || {
        echo "error: Simulator bridge helper is missing: ${simulator_helper:t}" >&2
        exit 1
    }
    /usr/bin/codesign --force --timestamp --options runtime \
        --sign "${identity}" "${simulator_helper}"
done
simulator_provenance="${resources}/SimulatorBridgeProvenance.txt"
[[ -f "${simulator_provenance}" ]] || {
    echo "error: Simulator bridge provenance is missing" >&2
    exit 1
}
signed_touch_sha="$(/usr/bin/shasum -a 256 \
    "${app}/Contents/Helpers/LocusSimulatorTouch" | /usr/bin/awk '{print $1}')"
signed_tree_sha="$(/usr/bin/shasum -a 256 \
    "${app}/Contents/Helpers/LocusSimulatorTree" | /usr/bin/awk '{print $1}')"
/usr/bin/sed -i '' "s/^touch_binary_sha256=.*/touch_binary_sha256=${signed_touch_sha}/" \
    "${simulator_provenance}"
/usr/bin/sed -i '' "s/^tree_binary_sha256=.*/tree_binary_sha256=${signed_tree_sha}/" \
    "${simulator_provenance}"
python3 "${repo_root}/Tools/WalletSignerSBOM.py" \
    "${repo_root}/WalletSignerCore" "${resources}/WalletSignerSBOM.cdx.json"
python3 "${repo_root}/Tools/WalletConnectionsSBOM.py" \
    "${repo_root}/Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "${repo_root}/project.yml" "${resources}/WalletConnectionsSBOM.cdx.json"
/usr/bin/codesign --force --timestamp --options runtime --sign "${identity}" "${app}"
"${repo_root}/Tools/AuditDistribution.sh" "${app}"
/usr/bin/codesign --verify --deep --strict "${app}"
echo "Seal valid after signing."

if [[ -d "${runtime}" ]]; then
    interp=""
    for candidate in "${runtime}/python/bin"/python3.*(N); do
        interp="${candidate}"
        break
    done
    if [[ -n "${interp}" ]]; then
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${runtime}/source:${runtime}/site-packages" \
            "${interp}" -B -c "import ollama_code.server" \
            || { echo "error: bundled runtime failed its import check." >&2; exit 1; }
        /usr/bin/codesign --verify --deep --strict "${app}" \
            || { echo "error: exercising the runtime modified the bundle — seal broken." >&2; exit 1; }
        echo "Seal still valid after exercising the runtime."
    fi
fi

/bin/rm -f "${zip_out}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${zip_out}"

if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    # See the note in ArchiveAppStore.sh: not defaulted in a public repo.
    key_id="${LOCUS_ASC_KEY_ID:?set LOCUS_ASC_KEY_ID (App Store Connect API key id)}"
    issuer_id="${LOCUS_ASC_ISSUER_ID:?set LOCUS_ASC_ISSUER_ID (App Store Connect issuer id)}"
    key_path="${LOCUS_ASC_KEY_PATH:?set LOCUS_ASC_KEY_PATH (path to the App Store Connect .p8 key)}"
    [[ -f "${key_path}" ]] || {
        echo "error: App Store Connect key not found at ${key_path}" >&2
        exit 1
    }
    echo "Submitting for notarization (this waits on Apple)…"
    /usr/bin/xcrun notarytool submit "${zip_out}" \
        --key "${key_path}" --key-id "${key_id}" --issuer "${issuer_id}" \
        --wait --timeout 30m \
        || { echo "error: notarization failed." >&2; exit 1; }
    # Staple the .app, not the zip: the ticket has to be inside the bundle
    # that gets extracted, so the zip is rebuilt afterwards. Without this the
    # app still launches, but only while the machine can reach Apple.
    /usr/bin/xcrun stapler staple "${app}" \
        || { echo "error: stapling failed." >&2; exit 1; }
    /bin/rm -f "${zip_out}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${zip_out}"
    echo "Notarized and stapled."
else
    echo "Notarization deferred: this zip is a private verification artifact, not a public release."
fi

check_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-zipcheck.XXXXXX")"
trap '/bin/rm -rf "${check_dir}"' EXIT
/usr/bin/ditto -x -k "${zip_out}" "${check_dir}"
/usr/bin/codesign --verify --deep --strict "${check_dir}/$(basename "${app}")" \
    || { echo "error: zip round-trip broke the signature." >&2; exit 1; }
echo "Zip round-trip verified."
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    # The real question is not whether it is signed but whether a Mac that has
    # never seen it will run it. spctl lives in /usr/sbin, not /usr/bin — the
    # wrong path here reported a missing binary as a Gatekeeper rejection, and
    # went unnoticed because no notarization had ever got this far to run it.
    [[ -x /usr/sbin/spctl ]] || {
        echo "error: /usr/sbin/spctl not found; cannot assess Gatekeeper." >&2
        exit 1
    }
    /usr/sbin/spctl --assess --type execute -vv "${check_dir}/$(basename "${app}")" \
        || { echo "error: Gatekeeper rejected the packaged app." >&2; exit 1; }
    /usr/bin/xcrun stapler validate "${check_dir}/$(basename "${app}")" \
        || { echo "error: the notarization ticket did not survive the zip." >&2; exit 1; }
    echo "Gatekeeper accepts it, ticket stapled."
fi
/usr/bin/shasum -a 256 "${zip_out}"
/bin/ls -lh "${zip_out}"
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    "${repo_root}/Tools/GenerateAppcast.sh" "${zip_out}" "${zip_out:h}/appcast.xml" stable
    echo "Upload Locus-macOS.zip, appcast.xml, components.json, and" \
        "${(j:, :)component_archives} to the same draft GitHub release."
    echo "They travel together: installed apps resolve both the appcast and the"
    echo "component feed via releases/latest/download, so a release published"
    echo "without the component pair 404s the ChatGPT-plan download for every"
    echo "installed copy."
fi
