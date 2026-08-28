#!/bin/zsh
# Fails a release when the app bundle contains known-disallowed runtime
# components or is missing the license materials required by the release.
set -euo pipefail
setopt null_glob

app="${1:?usage: AuditDistribution.sh <Locus.app>}"
repo_root="${0:A:h:h}"
resources="${app}/Contents/Resources"
runtime="${resources}/AgentRuntime"
codex_helper="${app}/Contents/Helpers/codex"
code_mode_host="${app}/Contents/Helpers/codex-code-mode-host"
simulator_touch="${app}/Contents/Helpers/LocusSimulatorTouch"
simulator_tree="${app}/Contents/Helpers/LocusSimulatorTree"
wallet_signer="${app}/Contents/XPCServices/WalletSigner.xpc"
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
    && /usr/bin/grep -Fq -- "b6496a74a087257ef5e6da1c5b29a447a60f5bd7" "${resolved}" || {
    echo "error: Sparkle is not pinned to the audited 2.9.4 revision" >&2
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
    "Sparkle 2.9.4" \
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
    "Sparkle-2.9.4/LICENSE" \
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
    281f13466cd3a73e9ebc9d210907748e1941a3dd \
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

entitlements="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/locus-entitlements.XXXXXX")"
trap '/bin/rm -f "${entitlements}"' EXIT
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
    ! /usr/bin/plutil -p "${app}/Contents/Info.plist" | /usr/bin/grep -Eq '^  "SU[^" ]*"' || {
        echo "error: the Mac App Store build contains Sparkle updater configuration" >&2
        exit 1
    }
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
    "${repo_root}/Tools/AuditWalletSignerBinary.sh" \
        "${wallet_signer}/Contents/MacOS/WalletSigner"
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
    app_team="$(/usr/bin/codesign -dv --verbose=4 "${app}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    wallet_team="$(/usr/bin/codesign -dv --verbose=4 "${wallet_signer}" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    [[ -n "${app_team}" && "${wallet_team}" == "${app_team}" ]] || {
        echo "error: WalletSigner.xpc Team ID does not match the containing app" >&2
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
    [[ "${sparkle_version}" == "2.9.4" ]] || {
        echo "error: bundled Sparkle is ${sparkle_version:-unknown}, expected 2.9.4" >&2
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

echo "Distribution audit passed: wallet boundary and notices verified; gdbm and tkinter absent."
