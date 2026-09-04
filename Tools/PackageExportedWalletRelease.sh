#!/bin/zsh
# Audit/package the exact Xcode export. No plist edits, resource writes, or signing.
set -euo pipefail
setopt null_glob
app="${1:?usage: PackageExportedWalletRelease.sh <exported Locus.app> <new output.zip>}"
zip_out="${2:?usage: PackageExportedWalletRelease.sh <exported Locus.app> <new output.zip>}"
repo_root="${0:A:h:h}"
receipt="${LOCUS_WALLET_EXPORT_PROVENANCE:?set LOCUS_WALLET_EXPORT_PROVENANCE to the archive/export receipt}"
app="${app:A}"
zip_out="${zip_out:A}"
receipt="${receipt:A}"
[[ "${zip_out}" != "${app}"/* && "${zip_out}" != "${repo_root}"/* ]] || {
    echo "error: release output must be outside the app and source checkout" >&2; exit 1
}
[[ -f "${receipt}" && -d "${app}" && ! -e "${zip_out}" ]] || {
    echo "error: exported app and receipt are required, and output.zip must not already exist" >&2; exit 1
}
[[ -z "$(/usr/bin/git -C "${repo_root}" status --porcelain)" ]] || {
    echo "error: wallet packaging requires the unchanged clean candidate revision" >&2; exit 1
}
revision="$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)"
built_revision="$(/usr/bin/plutil -extract sourceRevision raw -o - "${receipt}")"
channel="$(/usr/bin/plutil -extract releaseChannel raw -o - "${receipt}")"
[[ "${built_revision}" == "${revision}" \
    && ( "${channel}" == "canary" || "${channel}" == "ga" ) \
    && "${LOCUS_WALLET_RELEASE_CHANNEL:-${channel}}" == "${channel}" ]] || {
    echo "error: export revision or channel does not match packaging inputs" >&2; exit 1
}
python3 "${repo_root}/Tools/WalletExportProvenance.py" verify "${app}" "${receipt}"
"${repo_root}/Tools/VerifyDormantWalletArtifact.sh" "${app}"
"${repo_root}/Tools/AuditDistribution.sh" "${app}"

temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-export-package.XXXXXX")"
trap '/bin/rm -rf "${temporary}"' EXIT
runtime="${app}/Contents/Resources/AgentRuntime"
interpreters=("${runtime}/python/bin"/python3.<->(N))
(( ${#interpreters} > 0 )) || { echo "error: bundled Python runtime is absent" >&2; exit 1; }
OLLAMA_CODE_HOME="${temporary}/runtime-home" LOCUS_CODEX_HOME="${temporary}/codex-home" \
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${runtime}/source:${runtime}/site-packages" \
    "${interpreters[1]}" -B -c 'import ollama_code.server'
python3 "${repo_root}/Tools/WalletExportProvenance.py" verify "${app}" "${receipt}"

component_archives=()
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    [[ "${zip_out:t}" == "Locus-macOS.zip" ]] || {
        echo "error: public release archive must be named Locus-macOS.zip" >&2; exit 1
    }
    component_archives=("${(@f)$("${repo_root}/Tools/VerifyComponentAssets.sh" "${zip_out:h}")}")
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${zip_out}"
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    key_path="${LOCUS_ASC_KEY_PATH:?set LOCUS_ASC_KEY_PATH}"
    [[ -f "${key_path}" ]] || exit 1
    /usr/bin/xcrun notarytool submit "${zip_out}" \
        --key "${key_path}" --key-id "${LOCUS_ASC_KEY_ID:?}" \
        --issuer "${LOCUS_ASC_ISSUER_ID:?}" --wait --timeout 30m
    /usr/bin/xcrun stapler staple "${app}"
    # Stapling adds Apple's ticket; it must not alter any recorded sealed file
    # or executable identity from the Xcode export.
    python3 "${repo_root}/Tools/WalletExportProvenance.py" verify "${app}" "${receipt}"
    /bin/rm "${zip_out}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${app}" "${zip_out}"
fi
/usr/bin/ditto -x -k "${zip_out}" "${temporary}/roundtrip"
roundtrip="${temporary}/roundtrip/${app:t}"
python3 "${repo_root}/Tools/WalletExportProvenance.py" verify "${roundtrip}" "${receipt}"
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    /usr/sbin/spctl --assess --type execute -vv "${roundtrip}"
    /usr/bin/xcrun stapler validate "${roundtrip}"
    "${repo_root}/Tools/GenerateAppcast.sh" "${zip_out}" "${zip_out:h}/appcast.xml"
fi
/usr/bin/shasum -a 256 "${zip_out}"
[[ -z "$(/usr/bin/git -C "${repo_root}" status --porcelain)" \
    && "$(/usr/bin/git -C "${repo_root}" rev-parse HEAD)" == "${revision}" ]] || {
    echo "error: source changed during packaging; do not use this result as release evidence" >&2; exit 1
}
echo "Dormant ${channel} archive verified. No activation has been signed or published."
if [[ "${LOCUS_NOTARIZE:-0}" != "1" ]]; then
    echo "Notarization and signed-update evidence remain incomplete; this is a private verification artifact."
fi
