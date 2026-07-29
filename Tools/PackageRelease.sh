#!/bin/zsh
# Signs, seals, and zips a built Locus.app for release — in an order that
# cannot ship a broken signature:
#   1. sign every Mach-O in the bundled agent runtime, then the app
#   2. verify the seal
#   3. exercise the bundled runtime (import check, byte-code writing off)
#   4. verify the seal AGAIN — fails the release if step 3 dirtied the bundle
#   5. zip, extract to a temp dir, verify the extracted copy
#
# Usage: PackageRelease.sh /path/to/Locus.app /path/to/Locus-macOS.zip
# Identity comes from LOCUS_SIGN_IDENTITY, or the first "Apple Development"/
# "Developer ID Application" identity in the keychain.
set -euo pipefail
setopt null_glob

app="${1:?usage: PackageRelease.sh <Locus.app> <output.zip>}"
zip_out="${2:?usage: PackageRelease.sh <Locus.app> <output.zip>}"
runtime="${app}/Contents/Resources/AgentRuntime"

identity="${LOCUS_SIGN_IDENTITY:-}"
if [[ -z "${identity}" ]]; then
    identity="$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')"
fi
if [[ -z "${identity}" ]]; then
    echo "error: no codesigning identity found; set LOCUS_SIGN_IDENTITY." >&2
    exit 1
fi
echo "Signing with: ${identity}"

if [[ -d "${runtime}" ]]; then
    /usr/bin/find "${runtime}" -type f \( -name "*.so" -o -name "*.dylib" \) \
        -exec /usr/bin/codesign --force --sign "${identity}" {} +
    for interp in "${runtime}/python/bin"/python3.*(N); do
        /usr/bin/codesign --force --sign "${identity}" "${interp}"
    done
fi
/usr/bin/codesign --force --timestamp --sign "${identity}" "${app}"
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

check_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-zipcheck.XXXXXX")"
trap '/bin/rm -rf "${check_dir}"' EXIT
/usr/bin/ditto -x -k "${zip_out}" "${check_dir}"
/usr/bin/codesign --verify --deep --strict "${check_dir}/$(basename "${app}")" \
    || { echo "error: zip round-trip broke the signature." >&2; exit 1; }
echo "Zip round-trip verified."
/usr/bin/shasum -a 256 "${zip_out}"
/bin/ls -lh "${zip_out}"
