#!/bin/zsh
# Fails a release when the app bundle contains known-disallowed runtime
# components or is missing the license materials required by the release.
set -euo pipefail
setopt null_glob

app="${1:?usage: AuditDistribution.sh <Locus.app>}"
resources="${app}/Contents/Resources"
runtime="${resources}/AgentRuntime"
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

for notice in \
    "| websockets | 15.0.1 |"
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
for pin in websockets:15.0.1
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
if /usr/bin/codesign -d --entitlements "${entitlements}" "${app}" >/dev/null 2>&1; then
    for forbidden in \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-library-validation
    do
        value="$(/usr/bin/plutil -extract "${forbidden}" raw -o - "${entitlements}" 2>/dev/null || true)"
        [[ "${value}" != "true" ]] || {
            echo "error: forbidden release entitlement is enabled: ${forbidden}" >&2
            exit 1
        }
    done
fi

echo "Distribution audit passed: notices present; gdbm and tkinter absent."
