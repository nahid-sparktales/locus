#!/bin/zsh
# Fails a release when the app bundle contains known-disallowed runtime
# components or is missing the license materials required by the release.
set -euo pipefail
setopt null_glob

# BEGIN wallet_audit_reject_matching_output
wallet_audit_reject_matching_output() {
    local pattern="$1"
    local failure_message="$2"
    shift 2
    local output_path="${audit_temp_dir}/inspection.stdout"
    # Finish and validate inspection before matching. An early grep match must
    # not turn producer SIGPIPE into a false-negative under pipefail.
    if ! "$@" >"${output_path}" 2>/dev/null; then
        echo "error: wallet binary inspection tool failed" >&2
        return 1
    fi
    if /usr/bin/grep -E -- "${pattern}" "${output_path}" >/dev/null; then
        echo "error: ${failure_message}" >&2
        return 1
    else
        local match_status=$?
        if (( match_status != 1 )); then
            echo "error: wallet binary output inspection failed" >&2
            return 1
        fi
    fi
    return 0
}
# END wallet_audit_reject_matching_output

app="${1:?usage: AuditDistribution.sh <Locus.app>}"
repo_root="${0:A:h:h}"
resources="${app}/Contents/Resources"
runtime="${resources}/AgentRuntime"
codex_helper="${app}/Contents/Helpers/codex"
code_mode_host="${app}/Contents/Helpers/codex-code-mode-host"
simulator_touch="${app}/Contents/Helpers/LocusSimulatorTouch"
simulator_tree="${app}/Contents/Helpers/LocusSimulatorTree"
wallet_signer="${app}/Contents/XPCServices/WalletSigner.xpc"
wallet_recovery="${app}/Contents/Helpers/WalletRecovery.app"
wallet_recovery_signer="${wallet_recovery}/Contents/XPCServices/WalletSigner.xpc"
licenses="${resources}/ThirdPartyLicenses/python-build-standalone-20260728"
info_plist="${app}/Contents/Info.plist"

github_client_id="$(/usr/bin/plutil -extract LocusGitHubOAuthClientID raw -o - \
    "${info_plist}" 2>/dev/null || true)"
if [[ -z "${github_client_id}" || "${github_client_id}" == *'$('* ]]; then
    echo "error: distribution is missing the public Locus GitHub App client ID" >&2
    exit 1
fi

[[ -d "${runtime}" ]] || {
    echo "error: bundled agent runtime is missing" >&2
    exit 1
}
[[ -f "${resources}/ThirdPartyNotices.md" ]] || {
    echo "error: ThirdPartyNotices.md is missing from the app" >&2
    exit 1
}
[[ -f "${resources}/PrivacyInfo.xcprivacy" ]] || {
    echo "error: PrivacyInfo.xcprivacy is missing from the app" >&2
    exit 1
}
[[ -f "${resources}/BuildProvenance.txt" ]] || {
    echo "error: BuildProvenance.txt is missing from the app" >&2
    exit 1
}
resolved="${repo_root}/Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "${resolved}" ]] \
    && /usr/bin/grep -Fq -- "7691f85b222a67a66b58499e1b2647443cf0dda7" "${resolved}" || {
    echo "error: SwiftTerm is not pinned to the audited 1.18.0 revision" >&2
    exit 1
}
[[ -f "${resolved}" ]] \
    && /usr/bin/grep -Fq -- "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a" "${resolved}" || {
    echo "error: Sparkle is not pinned to the audited 2.9.6 revision" >&2
    exit 1
}
[[ -f "${resolved}" ]] \
    && /usr/bin/grep -Fq -- "3c6f9523da3a1ec2fd829673e472d95b8097a3b8" "${resolved}" || {
    echo "error: Swift Markdown is not pinned to the audited 0.8.0 revision" >&2
    exit 1
}
[[ -f "${resolved}" ]] \
    && /usr/bin/grep -Fq -- "924936d0427cb25a61169739a7660230bffa6ea6" "${resolved}" || {
    echo "error: Swift CMark is not pinned to the audited 0.8.0 revision" >&2
    exit 1
}
[[ -f "${resources}/CodexAppServerProvenance.txt" ]] || {
    echo "error: Codex App Server provenance is missing" >&2
    exit 1
}
# The direct download fetches the Codex helpers as a signed component instead
# of embedding them. Which shape this bundle is must be stated in provenance,
# not inferred from a missing file — an accidentally dropped helper would
# otherwise audit clean as though it were deliberate.
codex_delivery="$(/usr/bin/awk -F= '$1 == "delivery" { print $2; exit }' \
    "${resources}/CodexAppServerProvenance.txt")"
case "${codex_delivery}" in
    bundled)
        [[ -x "${codex_helper}" ]] || {
            echo "error: bundled Codex App Server helper is missing" >&2
            exit 1
        }
        [[ -x "${code_mode_host}" ]] || {
            echo "error: bundled Codex code-mode host is missing" >&2
            exit 1
        }
        ;;
    component)
        [[ ! -e "${codex_helper}" && ! -e "${code_mode_host}" ]] || {
            echo "error: provenance says delivery=component but a helper is embedded" >&2
            exit 1
        }
        ;;
    *)
        echo "error: Codex provenance has no delivery= line (got '${codex_delivery}')" >&2
        exit 1
        ;;
esac
[[ -f "${resources}/ThirdPartyLicenses/openai-codex-0.147.0/LICENSE" ]] || {
    echo "error: Codex App Server Apache license is missing" >&2
    exit 1
}
[[ -f "${resources}/ThirdPartyLicenses/openai-codex-0.147.0/NOTICE" ]] || {
    echo "error: Codex App Server upstream notice is missing" >&2
    exit 1
}
for pin in \
    "tag=rust-v0.147.0" \
    "version=0.147.0" \
    "source_sha256=355bde4b40d5ba6deea2e469d36f91708315729f3e84c9c69cce6b041a5ba593" \
    "upstream_cargo_lock_sha256=eeab4e9d3466da54037032251e2f13ad1ed11eae18bb8ee7dd2c89dbb86f645d" \
    "cargo_lock_normalization=workspace_versions_0.0.0_to_0.147.0" \
    "cargo_lock_sha256=bc4fe450de929afe82928734f860ca83e5f9dc5f9f1211b0974ea47b57af77ca" \
    "v8_version=150.4.0" \
    "v8_aarch64_archive_sha256=00adbb48798848c77550441c68673a5e8529b8e1b73eabcdee232cb39b40f4a1" \
    "v8_aarch64_binding_sha256=ca5adf0cf89c9a70ad460ae73648b2fe89b74aa113b3cb7f757b6a02b758394f" \
    "v8_x86_64_archive_sha256=e0d9bb64e8b3a034c2930c83972f3f35760211148342fa0407b38250ef330856" \
    "v8_x86_64_binding_sha256=ca5adf0cf89c9a70ad460ae73648b2fe89b74aa113b3cb7f757b6a02b758394f"
do
    /usr/bin/grep -Fq -- "${pin}" "${resources}/CodexAppServerProvenance.txt" || {
        echo "error: Codex helper provenance is missing ${pin}" >&2
        exit 1
    }
done
if [[ "${codex_delivery}" == "bundled" ]]; then
expected_helper_sha="$(/usr/bin/awk -F= '$1 == "binary_sha256" { print $2 }' \
    "${resources}/CodexAppServerProvenance.txt")"
actual_helper_sha="$(/usr/bin/shasum -a 256 "${codex_helper}" | /usr/bin/awk '{print $1}')"
[[ -n "${expected_helper_sha}" && "${expected_helper_sha}" == "${actual_helper_sha}" ]] || {
    echo "error: bundled Codex helper checksum does not match provenance" >&2
    exit 1
}
expected_code_mode_host_sha="$(/usr/bin/awk -F= '$1 == "code_mode_host_sha256" { print $2 }' \
    "${resources}/CodexAppServerProvenance.txt")"
actual_code_mode_host_sha="$(/usr/bin/shasum -a 256 "${code_mode_host}" | /usr/bin/awk '{print $1}')"
[[ -n "${expected_code_mode_host_sha}" \
    && "${expected_code_mode_host_sha}" == "${actual_code_mode_host_sha}" ]] || {
    echo "error: bundled Codex code-mode host checksum does not match provenance" >&2
    exit 1
}
expected_archs="$(/usr/bin/awk -F= '$1 == "architectures" { print $2 }' \
    "${resources}/CodexAppServerProvenance.txt")"
actual_archs="$(/usr/bin/lipo -archs "${codex_helper}" | /usr/bin/tr ' ' '\n' \
    | /usr/bin/sort -u | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
[[ -n "${expected_archs}" && "${expected_archs}" == "${actual_archs}" ]] || {
    echo "error: bundled Codex helper architectures do not match provenance" >&2
    exit 1
}
actual_code_mode_host_archs="$(/usr/bin/lipo -archs "${code_mode_host}" | /usr/bin/tr ' ' '\n' \
    | /usr/bin/sort -u | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
[[ "${expected_archs}" == "${actual_code_mode_host_archs}" ]] || {
    echo "error: bundled Codex code-mode host architectures do not match provenance" >&2
    exit 1
}
fi

for notice in \
    "| websockets | 17.0 |" \
    "SwiftTerm 1.18.0" \
    "Swift Markdown 0.8.0" \
    "Swift CMark 0.8.0" \
    "Sparkle 2.9.6" \
    "ios-mcp-server Simulator bridge" \
    "Anthropic Frontend Design" \
    "Vercel React Best Practices" \
    "Superpowers (complete 14-skill suite)"
do
    /usr/bin/grep -Fq -- "${notice}" "${resources}/ThirdPartyNotices.md" || {
        echo "error: runtime notice is missing the pinned component: ${notice}" >&2
        exit 1
    }
done

for required in \
    "SwiftTerm-1.18.0/LICENSE" \
    "SwiftMarkdown-0.8.0/LICENSE" \
    "SwiftCMark-0.8.0/COPYING" \
    "Sparkle-2.9.6/LICENSE" \
    "builtin-skills-anthropic/LICENSE" \
    "builtin-skills-vercel/LICENSE" \
    "builtin-skills-superpowers/LICENSE"
do
    [[ -f "${resources}/ThirdPartyLicenses/${required}" ]] || {
        echo "error: missing terminal/skill license ${required}" >&2
        exit 1
    }
done

skills_root="${runtime}/source/ollama_code/builtin_skills"
[[ ! -e "${skills_root}/task-observer" \
    && ! -e "${resources}/ThirdPartyLicenses/builtin-skills-task-observer" ]] || {
    echo "error: removed Task Observer skill is still bundled" >&2
    exit 1
}
python3 - "${skills_root}" <<'PY'
import json
import pathlib
import sys

for source in pathlib.Path(sys.argv[1]).glob("*/SOURCE.json"):
    if json.loads(source.read_text()).get("activation") != "explicit":
        raise SystemExit("error: a bundled skill can activate without explicit user selection")
PY
for skill in \
    frontend-design \
    vercel-react-best-practices \
    systematic-debugging \
    test-driven-development \
    verification-before-completion
do
    [[ -f "${skills_root}/${skill}/SKILL.md" \
        && -f "${skills_root}/${skill}/SOURCE.json" ]] || {
        echo "error: bundled built-in skill is incomplete: ${skill}" >&2
        exit 1
    }
done
for pin in \
    f17010c9bb483898c1d9c9f42dde2b3a98889434 \
    7c180d9044c9ae2b442b567aad4e42a28dd5ed62 \
    b36e0829c6d0140e93cfef2ca599b1b07d4a7797 \
    bdcaab2c752d9a33a1a1ca9acf3a3c81fb991815 \
    068b6e0c62393147daf03530149cdce209c93da8
do
    /usr/bin/grep -Rq -- "${pin}" "${skills_root}" || {
        echo "error: built-in skill provenance is missing commit ${pin}" >&2
        exit 1
    }
done

mcp_catalog="${runtime}/source/ollama_code/catalogs/mcp-presets-v1.json"
[[ -f "${mcp_catalog}" ]] || {
    echo "error: missing bundled MCP preset catalog" >&2
    exit 1
}
/usr/bin/grep -Fq -- '"version": 2' "${mcp_catalog}" || {
    echo "error: bundled MCP preset catalog is not version 2" >&2
    exit 1
}

# Read each pinned version from the wheel's own metadata rather than by running
# the bundled interpreter. In the App Store configuration that interpreter is
# signed as an inheriting sandbox helper, so launching it standalone is killed
# by the kernel (SIGTRAP) — an exec-based check could only ever pass for the
# direct-download build, and failed every ReleaseMAS archive.
for pin in websockets:17.0
do
    name="${pin%%:*}"
    want="${pin##*:}"
    metadata=("${runtime}/site-packages/${name}-"*.dist-info/METADATA(N))
    (( ${#metadata} == 1 )) || {
        echo "error: expected exactly one ${name} dist-info in the bundled runtime, found ${#metadata}" >&2
        exit 1
    }
    got="$(/usr/bin/awk -F': ' '$1 == "Version" { print $2; exit }' "${metadata[1]}" \
        | /usr/bin/tr -d '\r')"
    [[ "${got}" == "${want}" ]] || {
        echo "error: bundled ${name} is ${got:-unknown}, expected ${want}" >&2
        exit 1
    }
done

for required in \
    LICENSE \
    LICENSE.bzip2.txt \
    LICENSE.cpython.txt \
    LICENSE.expat.txt \
    LICENSE.libffi.txt \
    LICENSE.liblzma.txt \
    LICENSE.mpdecimal.txt \
    LICENSE.openssl-3.txt \
    LICENSE.sqlite.txt \
    LICENSE.zlib.txt
do
    [[ -f "${licenses}/${required}" ]] || {
        echo "error: missing third-party license ${required}" >&2
        exit 1
    }
done

disallowed=(
    "${runtime}"/**/_dbm*.so(N)
    "${runtime}"/**/_tkinter*.so(N)
)
if (( ${#disallowed} > 0 )); then
    echo "error: disallowed runtime component(s) found:" >&2
    print -l -- "${disallowed[@]}" >&2
    exit 1
fi

if /usr/bin/grep -R -a -l -m 1 "GNU gdbm" "${runtime}" >/dev/null 2>&1; then
    echo "error: GNU gdbm content remains in the bundled runtime" >&2
    exit 1
fi

umask 077
audit_temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-distribution-inspection.XXXXXX")"
trap 'find "$audit_temp_dir" -depth -delete' EXIT
entitlements="$(/usr/bin/mktemp "${audit_temp_dir}/entitlements.XXXXXX")"
# --xml: without it codesign writes a human-readable dump plutil cannot parse,
# and every extraction below fails open. Dots in entitlement names must be
# escaped or plutil walks them as a key path and never finds the key.
sandboxed=0
if /usr/bin/codesign -d --entitlements "${entitlements}" --xml "${app}" >/dev/null 2>&1; then
    for forbidden in \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-library-validation
    do
        value="$(/usr/bin/plutil -extract "${forbidden//./\\.}" raw -o - "${entitlements}" 2>/dev/null || true)"
        [[ "${value}" != "true" ]] || {
            echo "error: forbidden release entitlement is enabled: ${forbidden}" >&2
            exit 1
        }
    done
    if [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${entitlements}" 2>/dev/null || true)" == "true" ]]
    then
        sandboxed=1
    fi
fi

sparkle="${app}/Contents/Frameworks/Sparkle.framework"
if [[ "${sandboxed}" == "1" ]]; then
    [[ ! -e "${wallet_signer}" ]] || {
        echo "error: the Mac App Store build contains WalletSigner.xpc" >&2
        exit 1
    }
    [[ ! -e "${app}/Contents/XPCServices/WalletConnections.xpc" ]] || {
        echo "error: the Mac App Store build contains obsolete WalletConnections.xpc" >&2
        exit 1
    }
    [[ ! -e "${wallet_recovery}" ]] || {
        echo "error: the Mac App Store build contains WalletRecovery.app" >&2
        exit 1
    }
    unexpected_wallet_helper="$(/usr/bin/find "${app}/Contents" \
        \( -name WalletSigner.xpc -o -name WalletConnections.xpc \
            -o -name WalletRecovery.app \) -print -quit)"
    [[ -z "${unexpected_wallet_helper}" ]] || {
        echo "error: the Mac App Store build contains wallet helper ${unexpected_wallet_helper}" >&2
        exit 1
    }
    unexpected_connector_resource="$(/usr/bin/find "${resources}" \
        \( -name 'WalletConnections*' -o -name 'LocusReownSwift_*' \
            -o -name 'ReownSwift*' -o -iname '*wallet*activation*' \
            -o -iname '*wallet*authority*' -o -iname '*wallet*admission*' -o -iname '*wallet*ceiling*' \
            -o -name 'WalletSignerSBOM*' -o -name 'phantom-wallet-sdk-*.LICENSE' \
            -o -name 'eyes-0.1.8.LICENSE' -o -name 'text-encoding-utf-8-1.0.2.LICENSE' \) -print -quit)"
    [[ -z "${unexpected_connector_resource}" ]] || {
        echo "error: the Mac App Store build contains Direct-only connector resource ${unexpected_connector_resource}" >&2
        exit 1
    }
    wallet_audit_reject_matching_output \
        'Locus(ReownProjectID|WalletConnectRedirectURL|PhantomAppID|PhantomRedirectURL|WalletReleaseActivation|WalletCapability|WalletReview|WalletAlchemy|WalletQuickNode|CanaryUpdateFeedURL|WalletCandidateArchiveURL)' \
        'the Mac App Store build contains connector configuration keys' \
        /usr/bin/plutil -p "${info_plist}"
    mas_access_group="$(/usr/bin/plutil -extract 'keychain-access-groups.0' raw -o - \
        "${entitlements}" 2>/dev/null || true)"
    [[ "${mas_access_group}" != "4X4RJA7GMD.io.sparktales.locus" ]] || {
        echo "error: the Mac App Store build contains the Direct connector access group" >&2
        exit 1
    }
    if /usr/bin/grep -a -Fq 'LocusWalletConnectPrivateBindingsV1' \
        "${app}/Contents/MacOS/Locus"; then
        echo "error: the Mac App Store executable contains the Direct WalletConnect runtime" >&2
        exit 1
    fi
    [[ ! -e "${simulator_touch}" && ! -e "${simulator_tree}" ]] || {
        echo "error: the Mac App Store build contains a Simulator bridge helper" >&2
        exit 1
    }
    registry="${runtime}/source/ollama_code/tool_registry.py"
    if [[ -f "${registry}" ]] && /usr/bin/grep -Eq \
        'simulator_(list_devices|attach|get_state|tap|swipe|type_text|press_button|open_url|build_and_launch|screenshot|detach)' \
        "${registry}"
    then
        echo "error: the Mac App Store runtime contains Simulator tool schemas" >&2
        exit 1
    fi
    [[ ! -e "${sparkle}" ]] || {
        echo "error: the Mac App Store build contains Sparkle.framework" >&2
        exit 1
    }
    wallet_audit_reject_matching_output '^  "SU[^" ]*"' \
        'the Mac App Store build contains Sparkle updater configuration' \
        /usr/bin/plutil -p "${app}/Contents/Info.plist"
    unexpected_updater="$(/usr/bin/find "${app}/Contents" \
        \( -name Updater.app -o -name Autoupdate -o -name Downloader.xpc -o -name Installer.xpc \) \
        -print -quit)"
    [[ -z "${unexpected_updater}" ]] || {
        echo "error: the Mac App Store build contains updater helper ${unexpected_updater}" >&2
        exit 1
    }
else
    [[ -x "${wallet_signer}/Contents/MacOS/WalletSigner" ]] || {
        echo "error: the direct-download build is missing WalletSigner.xpc" >&2
        exit 1
    }
    [[ ! -e "${app}/Contents/XPCServices/WalletConnections.xpc" ]] || {
        echo "error: the obsolete WalletConnections.xpc is still packaged" >&2
        exit 1
    }
    for connector_resource in \
        WalletConnections.html WalletConnections.css WalletConnections.bundle.js \
        WalletConnectionsNotices.md LICENSE
    do
        [[ -f "${resources}/${connector_resource}" ]] || {
            echo "error: direct-download build is missing ${connector_resource}" >&2
            exit 1
        }
    done
    connector_bundle_sha="$(/usr/bin/shasum -a 256 \
        "${resources}/WalletConnections.bundle.js" | /usr/bin/awk '{print $1}')"
    [[ "${connector_bundle_sha}" == "09aa8643956ae5e17ab004ccd85b62811a36f7f4e44535d2659ef43e512323bf" ]] || {
        echo "error: packaged wallet connector bundle does not match its reviewed digest" >&2
        exit 1
    }
    reown_license_sha="$(/usr/bin/shasum -a 256 \
        "${resources}/LICENSE" | /usr/bin/awk '{print $1}')"
    [[ "${reown_license_sha}" == "e30bbba6782f025ba0b6ced7d36840ac8587073d8df06a21be369a5cfcfc5830" ]] || {
        echo "error: packaged Reown license does not match the reviewed release" >&2
        exit 1
    }
    /usr/bin/grep -Fq 'Portions © 2025 Reown, Inc. All Rights Reserved' \
        "${resources}/WalletConnectionsNotices.md" || {
        echo "error: packaged wallet connector notices omit Reown attribution" >&2
        exit 1
    }
    for reown_resource in \
        LocusReownSwift_WalletConnectRelay.bundle \
        LocusReownSwift_WalletConnectPairing.bundle \
        LocusReownSwift_WalletConnectSign.bundle \
        LocusReownSwift_WalletConnectVerify.bundle
    do
        [[ -d "${resources}/${reown_resource}" ]] || {
            echo "error: direct-download build is missing reviewed Reown resource ${reown_resource}" >&2
            exit 1
        }
    done
    direct_access_group="$(/usr/bin/plutil -extract 'keychain-access-groups.0' raw -o - \
        "${entitlements}" 2>/dev/null || true)"
    [[ "${direct_access_group}" == "4X4RJA7GMD.io.sparktales.locus" ]] || {
        echo "error: direct-download app is missing its connector session access group" >&2
        exit 1
    }
    [[ -x "${wallet_recovery}/Contents/MacOS/WalletRecovery" ]] || {
        echo "error: the direct-download build is missing WalletRecovery.app" >&2
        exit 1
    }
    [[ -x "${wallet_recovery_signer}/Contents/MacOS/WalletSigner" ]] || {
        echo "error: WalletRecovery.app is missing its private WalletSigner.xpc" >&2
        exit 1
    }
    "${repo_root}/Tools/AuditWalletSignerBinary.sh" \
        "${wallet_signer}/Contents/MacOS/WalletSigner"
    "${repo_root}/Tools/AuditWalletSignerBinary.sh" \
        "${wallet_recovery_signer}/Contents/MacOS/WalletSigner"
    wallet_sbom="${resources}/WalletSignerSBOM.cdx.json"
    [[ -f "${wallet_sbom}" ]] || {
        echo "error: direct-download build is missing the WalletSigner SBOM" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract bomFormat raw -o - "${wallet_sbom}" 2>/dev/null || true)" \
        == "CycloneDX" ]] || {
        echo "error: WalletSigner SBOM is not valid CycloneDX JSON" >&2
        exit 1
    }
    connections_sbom="${resources}/WalletConnectionsSBOM.cdx.json"
    [[ -f "${connections_sbom}" ]] || {
        echo "error: direct-download build is missing the WalletConnections SBOM" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract bomFormat raw -o - \
        "${connections_sbom}" 2>/dev/null || true)" == "CycloneDX" ]] || {
        echo "error: WalletConnections SBOM is not valid CycloneDX JSON" >&2
        exit 1
    }
    /usr/bin/grep -Fq '"value": "true-direct-only"' "${connections_sbom}" || {
        echo "error: WalletConnections SBOM does not identify the Direct-only runtime" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "${wallet_signer}/Contents/Info.plist" 2>/dev/null || true)" \
        == "io.sparktales.locus.WalletSigner" ]] || {
        echo "error: WalletSigner.xpc has an unexpected bundle identifier" >&2
        exit 1
    }
    /usr/bin/codesign --verify --strict "${wallet_signer}" || {
        echo "error: WalletSigner.xpc signature is invalid" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "${wallet_recovery_signer}/Contents/Info.plist" 2>/dev/null || true)" \
        == "io.sparktales.locus.WalletSigner" ]] || {
        echo "error: recovery WalletSigner.xpc has an unexpected bundle identifier" >&2
        exit 1
    }
    /usr/bin/codesign --verify --strict "${wallet_recovery_signer}" || {
        echo "error: recovery WalletSigner.xpc signature is invalid" >&2
        exit 1
    }
    wallet_entitlements="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/locus-wallet-entitlements.XXXXXX")"
    /usr/bin/codesign -d --entitlements "${wallet_entitlements}" --xml \
        "${wallet_signer}" >/dev/null 2>&1 || {
        echo "error: WalletSigner.xpc entitlements cannot be read" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${wallet_entitlements}" 2>/dev/null || true)" == "true" ]] || {
        echo "error: WalletSigner.xpc is not sandboxed" >&2
        exit 1
    }
    wallet_access_group="$(/usr/bin/plutil -extract 'keychain-access-groups.0' raw -o - \
        "${wallet_entitlements}" 2>/dev/null || true)"
    [[ "${wallet_access_group}" == "4X4RJA7GMD.io.sparktales.locus.WalletSigner" ]] || {
        echo "error: WalletSigner.xpc is missing its secure-storage access group" >&2
        exit 1
    }
    [[ -f "${wallet_signer}/Contents/embedded.provisionprofile" ]] || {
        echo "error: WalletSigner.xpc is missing its provisioning profile" >&2
        exit 1
    }
    for forbidden in \
        com.apple.security.network.client \
        com.apple.security.network.server \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-library-validation
    do
        value="$(/usr/bin/plutil -extract "${forbidden//./\\.}" raw -o - \
            "${wallet_entitlements}" 2>/dev/null || true)"
        [[ "${value}" != "true" ]] || {
            echo "error: WalletSigner.xpc has forbidden entitlement ${forbidden}" >&2
            exit 1
        }
    done
    /bin/rm -f "${wallet_entitlements}"
    recovery_signer_entitlements="$(/usr/bin/mktemp \
        "${TMPDIR:-/tmp}/locus-recovery-signer-entitlements.XXXXXX")"
    /usr/bin/codesign -d --entitlements "${recovery_signer_entitlements}" --xml \
        "${wallet_recovery_signer}" >/dev/null 2>&1 || {
        echo "error: recovery WalletSigner.xpc entitlements cannot be read" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${recovery_signer_entitlements}" 2>/dev/null || true)" == "true" ]] || {
        echo "error: recovery WalletSigner.xpc is not sandboxed" >&2
        exit 1
    }
    recovery_signer_access_group="$(/usr/bin/plutil -extract \
        'keychain-access-groups.0' raw -o - \
        "${recovery_signer_entitlements}" 2>/dev/null || true)"
    [[ "${recovery_signer_access_group}" \
        == "4X4RJA7GMD.io.sparktales.locus.WalletSigner" ]] || {
        echo "error: recovery WalletSigner.xpc is missing its secure-storage access group" >&2
        exit 1
    }
    [[ -f "${wallet_recovery_signer}/Contents/embedded.provisionprofile" ]] || {
        echo "error: recovery WalletSigner.xpc is missing its provisioning profile" >&2
        exit 1
    }
    for forbidden in \
        com.apple.security.network.client \
        com.apple.security.network.server \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-library-validation
    do
        value="$(/usr/bin/plutil -extract "${forbidden//./\.}" raw -o - \
            "${recovery_signer_entitlements}" 2>/dev/null || true)"
        [[ "${value}" != "true" ]] || {
            echo "error: recovery WalletSigner.xpc has forbidden entitlement ${forbidden}" >&2
            exit 1
        }
    done
    /bin/rm -f "${recovery_signer_entitlements}"
    app_team="$(/usr/bin/codesign -dv --verbose=4 "${app}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { value=$2 } END { print value }')"
    wallet_team="$(/usr/bin/codesign -dv --verbose=4 "${wallet_signer}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { value=$2 } END { print value }')"
    [[ -n "${app_team}" && "${wallet_team}" == "${app_team}" ]] || {
        echo "error: WalletSigner.xpc Team ID does not match the containing app" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "${wallet_recovery}/Contents/Info.plist" 2>/dev/null || true)" \
        == "io.sparktales.locus.WalletRecovery" ]] || {
        echo "error: WalletRecovery.app has an unexpected bundle identifier" >&2
        exit 1
    }
    /usr/bin/codesign --verify --strict "${wallet_recovery}" || {
        echo "error: WalletRecovery.app signature is invalid" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -o - \
        "${wallet_recovery}/Contents/Info.plist" 2>/dev/null || true)" == "APPL" \
        && "$(/usr/bin/plutil -extract LSUIElement raw -o - \
        "${wallet_recovery}/Contents/Info.plist" 2>/dev/null || true)" == "true" ]] || {
        echo "error: WalletRecovery.app is not an accessory application" >&2
        exit 1
    }
    recovery_entitlements="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/locus-recovery-entitlements.XXXXXX")"
    /usr/bin/codesign -d --entitlements "${recovery_entitlements}" --xml \
        "${wallet_recovery}" >/dev/null 2>&1 || {
        echo "error: WalletRecovery.app entitlements cannot be read" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${recovery_entitlements}" 2>/dev/null || true)" == "true" ]] || {
        echo "error: WalletRecovery.app is not sandboxed" >&2
        exit 1
    }
    for forbidden in \
        com.apple.security.network.client \
        com.apple.security.network.server \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-library-validation
    do
        value="$(/usr/bin/plutil -extract "${forbidden//./\.}" raw -o - \
            "${recovery_entitlements}" 2>/dev/null || true)"
        [[ "${value}" != "true" ]] || {
            echo "error: WalletRecovery.app has forbidden entitlement ${forbidden}" >&2
            exit 1
        }
    done
    /bin/rm -f "${recovery_entitlements}"
    recovery_team="$(/usr/bin/codesign -dv --verbose=4 "${wallet_recovery}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { value=$2 } END { print value }')"
    [[ -n "${app_team}" && "${recovery_team}" == "${app_team}" ]] || {
        echo "error: WalletRecovery.app Team ID does not match the containing app" >&2
        exit 1
    }
    recovery_signer_team="$(/usr/bin/codesign -dv --verbose=4 \
        "${wallet_recovery_signer}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { value=$2 } END { print value }')"
    [[ "${recovery_signer_team}" == "${app_team}" ]] || {
        echo "error: recovery WalletSigner.xpc Team ID does not match the containing app" >&2
        exit 1
    }
    outer_signer_cdhash="$(/usr/bin/codesign -dv --verbose=4 "${wallet_signer}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "CDHash" { value=$2 } END { print value }')"
    inner_signer_cdhash="$(/usr/bin/codesign -dv --verbose=4 "${wallet_recovery_signer}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "CDHash" { value=$2 } END { print value }')"
    [[ -n "${outer_signer_cdhash}" && "${inner_signer_cdhash}" == "${outer_signer_cdhash}" ]] || {
        echo "error: the host and recovery WalletSigner executables differ" >&2
        exit 1
    }
    simulator_provenance="${resources}/SimulatorBridgeProvenance.txt"
    [[ -x "${simulator_touch}" && -x "${simulator_tree}" ]] || {
        echo "error: direct-download Simulator bridge helpers are missing" >&2
        exit 1
    }
    [[ -f "${simulator_provenance}" ]] || {
        echo "error: Simulator bridge provenance is missing" >&2
        exit 1
    }
    [[ -f "${resources}/ThirdPartyLicenses/ios-mcp-server-bd5aca7/LICENSE" ]] || {
        echo "error: Simulator bridge MIT license is missing" >&2
        exit 1
    }
    for pin in \
        "commit=bd5aca70704fe0fb5e974abaed205f54469799b0" \
        "license=MIT" \
        "touch_source_sha256=af01bb7412a7c4c1db14a49ea21b7c1a055f7cffd6440c04059348885832fb71" \
        "tree_source_sha256=b16c270de8121e5b53626949ff818aca8ee29ba0c8b8372edd957d41bd243b63"
    do
        /usr/bin/grep -Fq -- "${pin}" "${simulator_provenance}" || {
            echo "error: Simulator bridge provenance is missing ${pin}" >&2
            exit 1
        }
    done
    expected_touch_sha="$(/usr/bin/awk -F= '$1 == "touch_binary_sha256" {print $2}' \
        "${simulator_provenance}")"
    expected_tree_sha="$(/usr/bin/awk -F= '$1 == "tree_binary_sha256" {print $2}' \
        "${simulator_provenance}")"
    expected_touch_unsigned="$(/usr/bin/awk -F= '$1 == "touch_unsigned_sha256" {print $2}' "${simulator_provenance}")"
    expected_tree_unsigned="$(/usr/bin/awk -F= '$1 == "tree_unsigned_sha256" {print $2}' "${simulator_provenance}")"
    if [[ -n "${expected_touch_unsigned}" && -n "${expected_tree_unsigned}" ]]; then
        # Xcode export can replace a signing timestamp or certificate without
        # changing code. The pre-seal unsigned digest survives that operation.
        [[ "$(python3 "${repo_root}/Tools/WalletExportProvenance.py" unsigned-digest "${simulator_touch}")" \
            == "${expected_touch_unsigned}" \
            && "$(python3 "${repo_root}/Tools/WalletExportProvenance.py" unsigned-digest "${simulator_tree}")" \
            == "${expected_tree_unsigned}" ]] || {
            echo "error: Simulator helper executable content differs from build provenance" >&2; exit 1
        }
    else
    [[ "$(/usr/bin/shasum -a 256 "${simulator_touch}" | /usr/bin/awk '{print $1}')" \
        == "${expected_touch_sha}" ]] || {
        echo "error: Simulator touch helper checksum does not match provenance" >&2
        exit 1
    }
    [[ "$(/usr/bin/shasum -a 256 "${simulator_tree}" | /usr/bin/awk '{print $1}')" \
        == "${expected_tree_sha}" ]] || {
        echo "error: Simulator tree helper checksum does not match provenance" >&2
        exit 1
    }
    fi
    expected_simulator_archs="$(/usr/bin/awk -F= '$1 == "architectures" {print $2}' \
        "${simulator_provenance}")"
    [[ "$(/usr/bin/lipo -archs "${simulator_touch}")" == "${expected_simulator_archs}" \
        && "$(/usr/bin/lipo -archs "${simulator_tree}")" == "${expected_simulator_archs}" ]] || {
        echo "error: Simulator bridge architectures do not match provenance" >&2
        exit 1
    }
    /usr/bin/codesign --verify --strict "${simulator_touch}" || {
        echo "error: Simulator touch helper signature is invalid" >&2; exit 1
    }
    /usr/bin/codesign --verify --strict "${simulator_tree}" || {
        echo "error: Simulator tree helper signature is invalid" >&2; exit 1
    }
    [[ -d "${sparkle}" ]] || {
        echo "error: the direct-download build is missing Sparkle.framework" >&2
        exit 1
    }
    sparkle_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
        "${sparkle}/Resources/Info.plist" 2>/dev/null || true)"
    [[ "${sparkle_version}" == "2.9.6" ]] || {
        echo "error: bundled Sparkle is ${sparkle_version:-unknown}, expected 2.9.6" >&2
        exit 1
    }
    for required in \
        "Versions/B/Autoupdate" \
        "Versions/B/Updater.app/Contents/MacOS/Updater" \
        "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    do
        [[ -x "${sparkle}/${required}" ]] || {
            echo "error: Sparkle updater payload is missing ${required}" >&2
            exit 1
        }
    done
    expected_feed="https://github.com/nahid-sparktales/locus/releases/latest/download/appcast.xml"
    [[ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "${app}/Contents/Info.plist")" \
        == "${expected_feed}" ]] || {
        echo "error: direct-download update feed does not match ${expected_feed}" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "${app}/Contents/Info.plist")" \
        == "S/F9z1jR20s26+oHOxVjFend/ajDH04OY8Ietw+IDl4=" ]] || {
        echo "error: direct-download Sparkle public key is missing or unexpected" >&2
        exit 1
    }
    for boolean_key in \
        SUAllowsAutomaticUpdates \
        SUEnableAutomaticChecks \
        SUAutomaticallyUpdate \
        SURequireSignedFeed \
        SUVerifyUpdateBeforeExtraction
    do
        [[ "$(/usr/bin/plutil -extract "${boolean_key}" raw -o - \
            "${app}/Contents/Info.plist")" == "true" ]] || {
            echo "error: direct-download updater requires ${boolean_key}=true" >&2
            exit 1
        }
    done
    [[ "$(/usr/bin/plutil -extract SUEnableSystemProfiling raw -o - \
        "${app}/Contents/Info.plist")" == "false" ]] || {
        echo "error: direct-download updater must disable anonymous system profiling" >&2
        exit 1
    }
    [[ "$(/usr/bin/plutil -extract SUScheduledCheckInterval raw -o - \
        "${app}/Contents/Info.plist")" == "86400" ]] || {
        echo "error: direct-download updater must check every 24 hours" >&2
        exit 1
    }
    /usr/bin/codesign --verify --deep --strict "${sparkle}" || {
        echo "error: Sparkle.framework or a nested updater helper has an invalid signature" >&2
        exit 1
    }
fi

if [[ "${codex_delivery}" == "bundled" ]]; then
for sealed_helper in "${codex_helper}" "${code_mode_host}"; do
    helper_entitlements="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/locus-helper-entitlements.XXXXXX")"
    if /usr/bin/codesign -d --entitlements "${helper_entitlements}" --xml \
        "${sealed_helper}" >/dev/null 2>&1; then
        if /usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
            "${entitlements}" >/dev/null 2>&1; then
            inherit="$(/usr/bin/plutil -extract 'com\.apple\.security\.inherit' raw -o - \
                "${helper_entitlements}" 2>/dev/null || true)"
            [[ "${inherit}" == "true" ]] || {
                echo "error: sandboxed Codex helper is not signed with inherit: ${sealed_helper:t}" >&2
                exit 1
            }
        fi
        if [[ "${sealed_helper}" == "${code_mode_host}" ]]; then
            for required_jit_entitlement in \
                com.apple.security.cs.allow-jit \
                com.apple.security.cs.allow-unsigned-executable-memory
            do
                enabled="$(/usr/bin/plutil -extract "${required_jit_entitlement//./\\.}" raw -o - \
                    "${helper_entitlements}" 2>/dev/null || true)"
                [[ "${enabled}" == "true" ]] || {
                    echo "error: Codex code-mode host is missing ${required_jit_entitlement}" >&2
                    exit 1
                }
            done
        fi
    fi
    /bin/rm -f "${helper_entitlements}"
done
fi

# Audit the main executable and every embedded Mach-O. Signer-core exports may
# exist only in the two audited WalletSigner executables; the App Store artifact
# may contain neither those exports nor statically linked Direct connector code.
wallet_macho_count=0
mas_connector_forbidden='WalletConnectorWebRuntime|WalletConnectDriver|WalletConnectorDriverFactory|LocusWalletConnectPrivateBindingsV1|WalletConnectSign|WalletConnectRelay|WalletConnectPairing|WalletConnectVerify|WalletConnectKMS|WalletConnectJWT|WalletConnectNetworking|LOCUS_REOWN_PROJECT_ID|LOCUS_PHANTOM_APP_ID|LocusReownProjectID|LocusPhantomAppID|@metamask/connect-evm|@phantom/browser-sdk|@mysten/slush-wallet|WalletReleaseActivationVerifier|WalletReleaseActivationEnvelope|WalletReleaseActivationSource|WalletReleaseRevisionStore|WalletReleaseActivationCache|LocusWalletReleaseActivationURL|LOCUS_WALLET_RELEASE_ACTIVATION_URL'
mas_connector_forbidden+='|WalletConnectorReleaseConfiguration|locus-wallet-connector-config-v1'
mas_connector_forbidden+='|WalletCandidateUpdateAuthority|LocusCanaryUpdateFeedURL|LocusWalletCandidateArchiveURL|LOCUS_CANARY_UPDATE_FEED_URL|LOCUS_WALLET_CANDIDATE_ARCHIVE_URL'
mas_connector_forbidden+='|WalletReleaseHistoryVerifier|WalletReleaseHistorySource|WalletSignerReleaseAuthorityStore|WalletReleaseTransitionEnvelope|WalletSignedReviewCeiling|WalletCanaryAdmission|WalletReleaseAuthorityCheckpoint|LOCUS_WALLET_REVIEW_CEILING_BASE64'
while IFS= read -r candidate
do
    [[ "$(/usr/bin/file -b "${candidate}")" == *Mach-O* ]] || continue
    (( wallet_macho_count += 1 ))
    if [[ "${candidate}" != "${wallet_signer}/Contents/MacOS/WalletSigner" \
        && "${candidate}" != "${wallet_recovery_signer}/Contents/MacOS/WalletSigner" ]]
    then
        unexpected="$(/usr/bin/nm -gU "${candidate}" 2>/dev/null \
            | /usr/bin/awk '$NF ~ /^_locus_wallet_/ { print $NF }')"
        [[ -z "${unexpected}" ]] || {
            echo "error: non-signer executable links signer-core exports: ${candidate}" >&2
            exit 1
        }
    fi
    if [[ "${sandboxed}" == "1" ]]; then
        wallet_audit_reject_matching_output "${mas_connector_forbidden}" \
            "Mac App Store executable contains Direct connector code or credentials: ${candidate}" \
            /usr/bin/nm "${candidate}"
        wallet_audit_reject_matching_output "${mas_connector_forbidden}" \
            "Mac App Store executable contains Direct connector code or credentials: ${candidate}" \
            /usr/bin/strings "${candidate}"
    fi
done < <(/usr/bin/find "${app}/Contents" -type f -print)
(( wallet_macho_count > 0 )) || {
    echo "error: distribution executable inventory was empty" >&2
    exit 1
}

echo "Distribution audit passed: ${wallet_macho_count} Mach-O files and wallet boundary verified; gdbm and tkinter absent."
