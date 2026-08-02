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
    "| langgraph | 1.2.9 |" \
    "| langgraph-checkpoint-sqlite | 3.1.1 |" \
    "| websockets | 15.0.1 |"
do
    /usr/bin/grep -Fq -- "${notice}" "${resources}/ThirdPartyNotices.md" || {
        echo "error: runtime notice is missing the pinned component: ${notice}" >&2
        exit 1
    }
done

PYTHONPATH="${runtime}/site-packages:${runtime}/source" \
    "${runtime}/python/bin/python3" -c '
from importlib.metadata import version
from ollama_code.langgraph_runtime import LANGGRAPH_AVAILABLE
assert LANGGRAPH_AVAILABLE
assert version("langgraph") == "1.2.9"
assert version("langgraph-checkpoint-sqlite") == "3.1.1"
assert version("websockets") == "15.0.1"
' || {
    echo "error: bundled LangGraph runtime failed its import/version audit" >&2
    exit 1
}

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
