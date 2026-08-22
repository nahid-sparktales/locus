#!/bin/zsh
# Builds, strips, signs, and publishes the ChatGPT-plan component that the
# direct-download build fetches at runtime.
#
# The helpers are ~270 MB installed and do nothing unless a ChatGPT-plan
# account is signed in, so Release ships without them (LOCUS_BUNDLE_CODEX is
# defaulted to "component" for that configuration by BundleBackend.sh) and this
# script produces the payload plus the components.json feed that describes it.
#
# The signature applied here is the whole trust story on the client: a
# downloaded binary lands outside the app's notarized seal, so Locus verifies it
# against `identifier "io.sparktales.locus.<name>" and anchor apple generic and
# certificate leaf[subject.OU] = "4X4RJA7GMD"` before it is ever moved into
# place. Both halves of that requirement are established below — do not drop
# --identifier, or a published component will be rejected by every client.
#
# Usage: PackageComponents.sh <output-directory>
# LOCUS_NOTARIZE=1 additionally submits the archive to Apple.
set -euo pipefail
setopt null_glob

out_dir="${1:?usage: PackageComponents.sh <output-directory>}"
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
codex_cache="${LOCUS_CODEX_CACHE:-${repo_root}/.codex-app-server}"
arch="${LOCUS_COMPONENT_ARCH:-arm64}"
min_app_version="${LOCUS_COMPONENT_MIN_APP_VERSION:-2.0.0}"
feed_base="${LOCUS_COMPONENT_BASE_URL:-https://github.com/nahid-sparktales/locus/releases/latest/download}"

identity="${LOCUS_SIGN_IDENTITY:-}"
if [[ -z "${identity}" ]]; then
    identity="$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
[[ "${identity}" == Developer\ ID\ Application:* ]] || {
    echo "error: a Developer ID Application identity is required; set LOCUS_SIGN_IDENTITY." >&2
    exit 1
}
echo "Signing component with: ${identity}"

LOCUS_CODEX_ARCHS="${arch}" "${script_dir}/PrepareCodexAppServer.sh"

version="$(/usr/bin/awk -F= '$1 == "version" { print $2; exit }' "${codex_cache}/PROVENANCE")"
[[ -n "${version}" ]] || { echo "error: no version in Codex provenance" >&2; exit 1; }

/bin/mkdir -p "${out_dir}"
staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-component.XXXXXX")"
trap '/bin/rm -rf "${staging}"' EXIT
payload="${staging}/payload"
/bin/mkdir -p "${payload}"

/usr/bin/ditto --norsrc --noextattr --noqtn "${codex_cache}/bin/codex" "${payload}/codex"
/usr/bin/ditto --norsrc --noextattr --noqtn "${codex_cache}/bin/codex-code-mode-host" \
    "${payload}/codex-code-mode-host"
# Apache-2.0 travels with the binaries it covers.
/usr/bin/ditto --norsrc --noextattr --noqtn "${codex_cache}/source-rust-v${version}/LICENSE" \
    "${payload}/LICENSE"
/usr/bin/ditto --norsrc --noextattr --noqtn "${codex_cache}/source-rust-v${version}/NOTICE" \
    "${payload}/NOTICE"
/usr/bin/ditto --norsrc --noextattr --noqtn "${codex_cache}/PROVENANCE" "${payload}/PROVENANCE"

# Same reasoning as BundleBackend.sh: upstream defers stripping to packaging,
# and strip invalidates a signature, so it must run first.
/usr/bin/strip -S -x "${payload}/codex" "${payload}/codex-code-mode-host"
/bin/chmod 755 "${payload}/codex" "${payload}/codex-code-mode-host"
/usr/bin/xattr -cr "${payload}"

# --timestamp and --options runtime on both: notarization rejects either
# without them, and the code-mode host's JIT entitlements only take effect
# under the hardened runtime.
/usr/bin/codesign --force --timestamp --options runtime \
    --identifier "io.sparktales.locus.codex" \
    --sign "${identity}" "${payload}/codex"
/usr/bin/codesign --force --timestamp --options runtime \
    --identifier "io.sparktales.locus.codex-code-mode-host" \
    --entitlements "${repo_root}/Config/CodexCodeModeHost.entitlements" \
    --sign "${identity}" "${payload}/codex-code-mode-host"

# Prove the published payload satisfies the exact requirement the client
# enforces, rather than merely "is signed". A component that fails here would
# install nowhere, so failing the build is the only useful outcome.
for binary in codex codex-code-mode-host; do
    requirement="identifier \"io.sparktales.locus.${binary}\" and anchor apple generic"
    requirement+=" and certificate leaf[subject.OU] = \"4X4RJA7GMD\""
    # -R takes a requirement *file* unless the argument begins with "=", in
    # which case the rest is requirement source text.
    /usr/bin/codesign --verify --strict -R="${requirement}" "${payload}/${binary}" || {
        echo "error: ${binary} does not satisfy the client's signing requirement" >&2
        exit 1
    }
done
echo "Both helpers satisfy the client signing requirement."

"${payload}/codex" --version | /usr/bin/grep -Fq "${version}" || {
    echo "error: stripped helper does not report version ${version}" >&2
    exit 1
}
echo "Stripped helper reports ${version}."

# Stripping and signing both rewrite Mach-O bytes, so the build cache's hashes
# no longer describe what ships. Record the sealed payload, exactly as
# BundleBackend.sh does for the embedded path, and state how it was delivered.
shipped_sha="$(/usr/bin/shasum -a 256 "${payload}/codex" | /usr/bin/awk '{print $1}')"
/usr/bin/sed -i '' "s/^binary_sha256=.*/binary_sha256=${shipped_sha}/" "${payload}/PROVENANCE"
shipped_sha="$(/usr/bin/shasum -a 256 "${payload}/codex-code-mode-host" \
    | /usr/bin/awk '{print $1}')"
/usr/bin/sed -i '' "s/^code_mode_host_sha256=.*/code_mode_host_sha256=${shipped_sha}/" \
    "${payload}/PROVENANCE"
echo "delivery=component" >> "${payload}/PROVENANCE"

archive_name="chatgpt-plan-${version}-${arch}.zip"
archive="${out_dir}/${archive_name}"
/bin/rm -f "${archive}"
# No --keepParent: the client extracts straight into its staging directory and
# expects codex at the archive root.
/usr/bin/ditto -c -k --sequesterRsrc "${payload}" "${archive}"

if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    key_id="${LOCUS_ASC_KEY_ID:?set LOCUS_ASC_KEY_ID}"
    issuer_id="${LOCUS_ASC_ISSUER_ID:?set LOCUS_ASC_ISSUER_ID}"
    key_path="${LOCUS_ASC_KEY_PATH:?set LOCUS_ASC_KEY_PATH}"
    echo "Submitting the component for notarization (this waits on Apple)…"
    /usr/bin/xcrun notarytool submit "${archive}" \
        --key "${key_path}" --key-id "${key_id}" --issuer "${issuer_id}" \
        --wait --timeout 30m \
        || { echo "error: component notarization failed." >&2; exit 1; }
    # A bare Mach-O cannot be stapled — there is no bundle to hold the ticket.
    # Locus clears quarantine after verifying the signature itself, so the
    # ticket is belt-and-braces for anyone who obtains the zip by other means.
    echo "Component notarized (tickets for loose binaries are served online)."
fi

download_bytes="$(/usr/bin/stat -f%z "${archive}")"
installed_bytes="$(( $(/usr/bin/stat -f%z "${payload}/codex") \
    + $(/usr/bin/stat -f%z "${payload}/codex-code-mode-host") ))"
sha="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{print $1}')"

/usr/bin/python3 - "$out_dir/components.json" <<PYEOF
import json, sys
feed = {
    "schemaVersion": 1,
    "components": [
        {
            "id": "chatgpt-plan",
            "version": "${version}",
            "arch": "${arch}",
            "minAppVersion": "${min_app_version}",
            "url": "${feed_base}/${archive_name}",
            "sha256": "${sha}",
            "downloadBytes": ${download_bytes},
            "installedBytes": ${installed_bytes},
        }
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(feed, handle, indent=2)
    handle.write("\n")
PYEOF

echo
echo "Component:     ${archive}"
echo "Feed:          ${out_dir}/components.json"
echo "Version:       ${version} (${arch})"
echo "Download:      $(( download_bytes / 1000000 )) MB"
echo "Installed:     $(( installed_bytes / 1000000 )) MB"
echo "SHA-256:       ${sha}"
echo
echo "Upload ${archive_name} and components.json to the same GitHub release as Locus-macOS.zip."
