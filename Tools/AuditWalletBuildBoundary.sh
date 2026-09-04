#!/bin/zsh
# Audits the unsigned Direct and Mac App Store products as a pair. This
# complements AuditDistribution.sh by proving target separation in CI.
set -euo pipefail

direct_app="${1:?usage: AuditWalletBuildBoundary.sh <Direct Locus.app> <MAS Locus.app>}"
mas_app="${2:?usage: AuditWalletBuildBoundary.sh <Direct Locus.app> <MAS Locus.app>}"
repo_root="${0:A:h:h}"

[[ -d "${direct_app}" && -d "${mas_app}" ]] || {
    echo "error: both Direct and Mac App Store app bundles are required" >&2
    exit 1
}

direct_main="${direct_app}/Contents/MacOS/Locus"
mas_main="${mas_app}/Contents/MacOS/Locus"
direct_signer="${direct_app}/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner"
recovery_signer="${direct_app}/Contents/Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner"

for executable in "${direct_main}" "${mas_main}" "${direct_signer}" "${recovery_signer}"
do
    [[ -x "${executable}" ]] || {
        echo "error: required build executable is missing: ${executable}" >&2
        exit 1
    }
done

[[ ! -e "${direct_app}/Contents/XPCServices/WalletConnections.xpc" ]] || {
    echo "error: obsolete WalletConnections.xpc remains in the Direct app" >&2
    exit 1
}
for resource in \
    WalletConnections.html WalletConnections.css WalletConnections.bundle.js \
    WalletConnectionsNotices.md LICENSE
do
    [[ -f "${direct_app}/Contents/Resources/${resource}" ]] || {
        echo "error: Direct app is missing connector resource ${resource}" >&2
        exit 1
    }
done
for resource in \
    LocusReownSwift_WalletConnectRelay.bundle \
    LocusReownSwift_WalletConnectPairing.bundle \
    LocusReownSwift_WalletConnectSign.bundle \
    LocusReownSwift_WalletConnectVerify.bundle
do
    [[ -d "${direct_app}/Contents/Resources/${resource}" ]] || {
        echo "error: Direct app is missing Reown resource ${resource}" >&2
        exit 1
    }
done

bundle_sha="$(/usr/bin/shasum -a 256 \
    "${direct_app}/Contents/Resources/WalletConnections.bundle.js" \
    | /usr/bin/awk '{print $1}')"
[[ "${bundle_sha}" == "99ed4b87f3fcd5e3e328c89a69a2cb66153f1f3382ac1e85b12e1232c350ee30" ]] || {
    echo "error: Direct connector bundle does not match its reviewed digest" >&2
    exit 1
}

"${repo_root}/Tools/AuditWalletSignerBinary.sh" "${direct_signer}"
"${repo_root}/Tools/AuditWalletSignerBinary.sh" "${recovery_signer}"
/usr/bin/cmp "${direct_signer}" "${recovery_signer}" || {
    echo "error: host and recovery WalletSigner executables differ" >&2
    exit 1
}

# Signing functions belong only to the isolated signer executables. External
# preparers and the Direct connector runtime must not link signer-core exports.
unexpected_direct_signing_symbols="$(/usr/bin/nm -gU "${direct_main}" 2>/dev/null \
    | /usr/bin/awk '$NF ~ /^_locus_wallet_/ { print $NF }')"
[[ -z "${unexpected_direct_signing_symbols}" ]] || {
    echo "error: Direct app executable links signer-core exports" >&2
    echo "${unexpected_direct_signing_symbols}" >&2
    exit 1
}

unexpected_mas_resource="$(/usr/bin/find "${mas_app}/Contents" \
    \( -name WalletSigner.xpc -o -name WalletConnections.xpc \
        -o -name WalletRecovery.app -o -name 'WalletConnections*' \
        -o -name 'LocusReownSwift_*' -o -name 'ReownSwift*' \) \
    -print -quit)"
[[ -z "${unexpected_mas_resource}" ]] || {
    echo "error: Mac App Store app contains Direct-only wallet content: ${unexpected_mas_resource}" >&2
    exit 1
}

! /usr/bin/plutil -p "${mas_app}/Contents/Info.plist" | /usr/bin/grep -Eq \
    'Locus(ReownProjectID|WalletConnectRedirectURL|PhantomAppID|PhantomRedirectURL)' || {
    echo "error: Mac App Store Info.plist contains connector configuration" >&2
    exit 1
}

mas_forbidden='WalletConnectorWebRuntime|WalletConnectDriver|WalletConnectorDriverFactory|LocusWalletConnectPrivateBindingsV1|WalletConnectSign|WalletConnectRelay|WalletConnectPairing|WalletConnectVerify|WalletConnectKMS|WalletConnectJWT|WalletConnectNetworking|LOCUS_REOWN_PROJECT_ID|LOCUS_PHANTOM_APP_ID|LocusReownProjectID|LocusPhantomAppID|@metamask/connect-evm|@phantom/browser-sdk|@mysten/slush-wallet'
direct_macho_count=0
mas_macho_count=0

while IFS= read -r candidate
do
    [[ "$(/usr/bin/file -b "${candidate}")" == *Mach-O* ]] || continue
    (( direct_macho_count += 1 ))
    if [[ "${candidate}" != "${direct_signer}" \
        && "${candidate}" != "${recovery_signer}" ]]
    then
        unexpected="$(/usr/bin/nm -gU "${candidate}" 2>/dev/null \
            | /usr/bin/awk '$NF ~ /^_locus_wallet_/ { print $NF }')"
        [[ -z "${unexpected}" ]] || {
            echo "error: non-signer Direct executable links signer-core exports: ${candidate}" >&2
            exit 1
        }
    fi
done < <(/usr/bin/find "${direct_app}/Contents" -type f -print)

while IFS= read -r candidate
do
    [[ "$(/usr/bin/file -b "${candidate}")" == *Mach-O* ]] || continue
    (( mas_macho_count += 1 ))
    unexpected="$(/usr/bin/nm -gU "${candidate}" 2>/dev/null \
        | /usr/bin/awk '$NF ~ /^_locus_wallet_/ { print $NF }')"
    [[ -z "${unexpected}" ]] || {
        echo "error: Mac App Store executable links signer-core exports: ${candidate}" >&2
        exit 1
    }
    if /usr/bin/nm "${candidate}" 2>/dev/null | /usr/bin/grep -Eq "${mas_forbidden}" \
        || /usr/bin/strings "${candidate}" | /usr/bin/grep -Eq "${mas_forbidden}"
    then
        echo "error: Mac App Store executable contains Direct connector code or credentials: ${candidate}" >&2
        exit 1
    fi
done < <(/usr/bin/find "${mas_app}/Contents" -type f -print)

(( direct_macho_count > 0 && mas_macho_count > 0 )) || {
    echo "error: executable inventory was empty" >&2
    exit 1
}

echo "Wallet build boundary is locked (${direct_macho_count} Direct and ${mas_macho_count} App Store Mach-O files audited)."
