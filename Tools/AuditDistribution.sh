#!/bin/zsh
# Fails a release when the app bundle contains known-disallowed runtime
# components or is missing the license materials required by the release.
set -euo pipefail
setopt null_glob

app="${1:?usage: AuditDistribution.sh <Locus.app>}"
resources="${app}/Contents/Resources"
runtime="${resources}/AgentRuntime"
codex_helper="${app}/Contents/Helpers/codex"
code_mode_host="${app}/Contents/Helpers/codex-code-mode-host"
licenses="${resources}/ThirdPartyLicenses/python-build-standalone-20260728"

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
[[ -x "${codex_helper}" ]] || {
    echo "error: bundled Codex App Server helper is missing" >&2
    exit 1
}
[[ -x "${code_mode_host}" ]] || {
    echo "error: bundled Codex code-mode host is missing" >&2
    exit 1
}
[[ -f "${resources}/CodexAppServerProvenance.txt" ]] || {
    echo "error: Codex App Server provenance is missing" >&2
    exit 1
}
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

for notice in \
    "| websockets | 17.0 |"
do
    /usr/bin/grep -Fq -- "${notice}" "${resources}/ThirdPartyNotices.md" || {
        echo "error: runtime notice is missing the pinned component: ${notice}" >&2
        exit 1
    }
done

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
fi

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

echo "Distribution audit passed: notices present; gdbm and tkinter absent."
