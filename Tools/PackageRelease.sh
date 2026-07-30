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
/usr/bin/codesign --force --timestamp --options runtime --sign "${identity}" "${app}"
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
    key_id="${LOCUS_ASC_KEY_ID:-QYV9PN42QS}"
    issuer_id="${LOCUS_ASC_ISSUER_ID:-3675bb71-8667-42ca-a9ae-2b6091f0c076}"
    key_path="${LOCUS_ASC_KEY_PATH:-${0:A:h:h:h}/SparkTales_Master/api-keys/AuthKey_${key_id}.p8}"
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
fi

check_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-zipcheck.XXXXXX")"
trap '/bin/rm -rf "${check_dir}"' EXIT
/usr/bin/ditto -x -k "${zip_out}" "${check_dir}"
/usr/bin/codesign --verify --deep --strict "${check_dir}/$(basename "${app}")" \
    || { echo "error: zip round-trip broke the signature." >&2; exit 1; }
echo "Zip round-trip verified."
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    # The real question is not whether it is signed but whether a Mac that has
    # never seen it will run it.
    /usr/bin/spctl --assess --type execute -vv "${check_dir}/$(basename "${app}")" \
        || { echo "error: Gatekeeper rejected the packaged app." >&2; exit 1; }
    /usr/bin/xcrun stapler validate "${check_dir}/$(basename "${app}")" \
        || { echo "error: the notarization ticket did not survive the zip." >&2; exit 1; }
    echo "Gatekeeper accepts it, ticket stapled."
fi
/usr/bin/shasum -a 256 "${zip_out}"
/bin/ls -lh "${zip_out}"
