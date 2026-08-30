#!/bin/zsh
# Generates and validates the signed Sparkle feed placed beside a notarized
# Locus-macOS.zip. The signing key is read from the developer's login Keychain;
# it is never accepted on the command line or written inside the repository.
set -euo pipefail

zip_path="${1:?usage: GenerateAppcast.sh <Locus-macOS.zip> [appcast.xml]}"
appcast_out="${2:-${zip_path:h}/appcast.xml}"
repo_root="${0:A:h:h}"
sparkle_version="2.9.6"
sparkle_revision="ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
sparkle_archive_sha256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
sparkle_public_key="S/F9z1jR20s26+oHOxVjFend/ajDH04OY8Ietw+IDl4="
sparkle_key_account="io.sparktales"
feed_url="https://github.com/nahid-sparktales/locus/releases/latest/download/appcast.xml"
release_root="https://github.com/nahid-sparktales/locus/releases/download"
first_updater_build=17

[[ -f "${zip_path}" ]] || {
    echo "error: update archive not found: ${zip_path}" >&2
    exit 1
}
[[ "${zip_path:t}" == "Locus-macOS.zip" ]] || {
    echo "error: public updates must be named Locus-macOS.zip" >&2
    exit 1
}

# The appcast never travels alone: installed apps also resolve
# LocusComponentFeedURL against releases/latest/download, so the release that
# carries this feed must republish components.json and its archive(s) too.
# Missing components fail a public (notarized) run outright; a feed-generation
# dry run only warns, so it does not require building the component first.
if ! "${repo_root}/Tools/VerifyComponentAssets.sh" "${zip_path:h}" >/dev/null; then
    if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
        echo "error: refusing to prepare a public appcast without the component assets above." >&2
        exit 1
    fi
    echo "WARNING: continuing without verified component assets (details above)." >&2
    echo "Do not publish a release without components.json and its archive." >&2
fi

tools_root="${LOCUS_SPARKLE_TOOLS_DIR:-${repo_root}/.release-tools/Sparkle-${sparkle_version}}"
tools_archive="${tools_root:h}/Sparkle-${sparkle_version}.tar.xz"
if [[ ! -x "${tools_root}/bin/generate_appcast" ]]; then
    /bin/mkdir -p "${tools_root}" "${tools_archive:h}"
    if [[ ! -f "${tools_archive}" ]]; then
        echo "Downloading pinned Sparkle ${sparkle_version} release tools…"
        /usr/bin/curl --fail --location --show-error \
            "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz" \
            --output "${tools_archive}"
    fi
    actual_archive_sha="$(/usr/bin/shasum -a 256 "${tools_archive}" | /usr/bin/awk '{print $1}')"
    [[ "${actual_archive_sha}" == "${sparkle_archive_sha256}" ]] || {
        echo "error: Sparkle tools checksum mismatch; expected ${sparkle_archive_sha256}" >&2
        exit 1
    }
    /usr/bin/tar -xJf "${tools_archive}" -C "${tools_root}"
fi

generate_appcast="${tools_root}/bin/generate_appcast"
generate_keys="${tools_root}/bin/generate_keys"
sign_update="${tools_root}/bin/sign_update"
[[ -x "${generate_appcast}" && -x "${generate_keys}" && -x "${sign_update}" ]] || {
    echo "error: Sparkle ${sparkle_version} release tools are incomplete" >&2
    exit 1
}

resolved="${repo_root}/Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
/usr/bin/grep -Fq -- "${sparkle_revision}" "${resolved}" || {
    echo "error: Package.resolved is not pinned to Sparkle ${sparkle_version}" >&2
    exit 1
}

keychain_public_key="$("${generate_keys}" --account "${sparkle_key_account}" -p)" || {
    echo "error: the ${sparkle_key_account} Sparkle key is missing from the login Keychain" >&2
    exit 1
}
[[ "${keychain_public_key}" == "${sparkle_public_key}" ]] || {
    echo "error: Keychain Sparkle key does not match the public key embedded in Locus" >&2
    exit 1
}

stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-appcast.XXXXXX")"
trap '/bin/rm -rf "${stage}"' EXIT
/usr/bin/ditto -x -k "${zip_path}" "${stage}/extracted"
app="${stage}/extracted/Locus.app"
info="${app}/Contents/Info.plist"
[[ -f "${info}" ]] || {
    echo "error: update archive does not contain Locus.app" >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict "${app}" || {
    echo "error: archived app has an invalid code-signature seal" >&2
    exit 1
}
signature_details="$(/usr/bin/codesign -d --verbose=4 "${app}" 2>&1)"
/usr/bin/grep -Fq -- 'Authority=Developer ID Application:' <<< "${signature_details}" \
    && /usr/bin/grep -Fq -- 'TeamIdentifier=4X4RJA7GMD' <<< "${signature_details}" || {
    echo "error: update archive is not signed by the SparkTales Developer ID team" >&2
    exit 1
}
app_architectures="$(/usr/bin/lipo -archs "${app}/Contents/MacOS/Locus")"
[[ "${app_architectures}" == "arm64" ]] || {
    echo "error: public updates must contain only arm64, found ${app_architectures}" >&2
    exit 1
}
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    /usr/sbin/spctl --assess --type execute -vv "${app}" >/dev/null || {
        echo "error: Gatekeeper rejected the update archive" >&2
        exit 1
    }
    /usr/bin/xcrun stapler validate "${app}" >/dev/null || {
        echo "error: update archive does not contain a valid notarization ticket" >&2
        exit 1
    }
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info}")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info}")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info}")"
embedded_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${info}")"
[[ "${version}" == <->.<->.<-> && "${build}" == <-> ]] || {
    echo "error: update versions must be numeric (version ${version}, build ${build})" >&2
    exit 1
}
[[ "${embedded_public_key}" == "${sparkle_public_key}" ]] || {
    echo "error: archived app does not contain the expected Sparkle public key" >&2
    exit 1
}
[[ "${bundle_identifier}" == "io.sparktales.locus" ]] || {
    echo "error: archived app has unexpected bundle identifier ${bundle_identifier}" >&2
    exit 1
}
[[ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "${info}")" == "${feed_url}" ]] || {
    echo "error: archived app does not use the stable Locus appcast URL" >&2
    exit 1
}
for boolean_key in \
    SUAllowsAutomaticUpdates \
    SUAutomaticallyUpdate \
    SUEnableAutomaticChecks \
    SURequireSignedFeed \
    SUVerifyUpdateBeforeExtraction
do
    [[ "$(/usr/bin/plutil -extract "${boolean_key}" raw -o - "${info}")" == "true" ]] || {
        echo "error: archived app requires ${boolean_key}=true" >&2
        exit 1
    }
done
[[ "$(/usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "${info}")" == "false" ]] || {
    echo "error: archived app must disable anonymous system profiling" >&2
    exit 1
}
[[ "$(/usr/bin/plutil -extract SUScheduledCheckInterval raw -o - "${info}")" == "86400" ]] || {
    echo "error: archived app must use the 24-hour update interval" >&2
    exit 1
}
sparkle_info="${app}/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
[[ -f "${sparkle_info}" \
    && "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${sparkle_info}")" == "${sparkle_version}" ]] || {
    echo "error: archived app does not contain Sparkle ${sparkle_version}" >&2
    exit 1
}
[[ ! -e "${app}/Contents/PlugIns/LocusTests.xctest" ]] || {
    echo "error: update archive contains an embedded test bundle" >&2
    exit 1
}

archive_dir="${stage}/archives"
/bin/mkdir -p "${archive_dir}"
/bin/cp "${zip_path}" "${archive_dir}/Locus-macOS.zip"

notes="${archive_dir}/Locus-macOS.md"
/usr/bin/awk -v version="${version}" '
    BEGIN { wanted = "## " version }
    /^## / {
        if (found) exit
        suffix = substr($0, length(wanted) + 1, 1)
        if (substr($0, 1, length(wanted)) == wanted && (suffix == "" || suffix == " " || suffix == "—")) {
            found = 1
        }
    }
    found { print }
    END { if (!found) exit 2 }
' "${repo_root}/CHANGELOG.md" > "${notes}" || {
    echo "error: CHANGELOG.md has no release section for ${version}" >&2
    exit 1
}
[[ -s "${notes}" ]] || {
    echo "error: release notes for ${version} are empty" >&2
    exit 1
}

if (( build > first_updater_build )); then
    echo "Fetching the current signed feed so release history is preserved…"
    /usr/bin/curl --fail --location --show-error "${feed_url}" \
        --output "${archive_dir}/appcast.xml"
    previous_build="$(/usr/bin/xmllint --xpath \
        'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="version"])' \
        "${archive_dir}/appcast.xml")"
    [[ "${previous_build}" == <-> && "${build}" -gt "${previous_build}" ]] || {
        echo "error: build ${build} must be greater than published build ${previous_build:-unknown}" >&2
        exit 1
    }
fi

download_prefix="${release_root}/v${version}/"
"${generate_appcast}" \
    --account "${sparkle_key_account}" \
    --download-url-prefix "${download_prefix}" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --maximum-versions 4 \
    --link "https://locushost.co" \
    "${archive_dir}"

generated="${archive_dir}/appcast.xml"
/usr/bin/xmllint --noout "${generated}"
latest_build="$(/usr/bin/xmllint --xpath \
    'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="version"])' \
    "${generated}")"
latest_version="$(/usr/bin/xmllint --xpath \
    'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="shortVersionString"])' \
    "${generated}")"
enclosure_url="$(/usr/bin/xmllint --xpath \
    'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' \
    "${generated}")"
archive_signature="$(/usr/bin/xmllint --xpath \
    'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    "${generated}")"

[[ "${latest_build}" == "${build}" && "${latest_version}" == "${version}" ]] || {
    echo "error: generated feed latest version does not match ${version} (${build})" >&2
    exit 1
}
[[ "${enclosure_url}" == "${download_prefix}Locus-macOS.zip" ]] || {
    echo "error: generated enclosure URL is unexpected: ${enclosure_url}" >&2
    exit 1
}
[[ -n "${archive_signature}" ]] || {
    echo "error: generated update archive has no Ed25519 signature" >&2
    exit 1
}
/usr/bin/grep -Fq -- '<!-- sparkle-signatures:' "${generated}" \
    && /usr/bin/grep -Fq -- 'edSignature:' "${generated}" || {
    echo "error: generated appcast does not carry a signed-feed signature" >&2
    exit 1
}
"${sign_update}" --account "${sparkle_key_account}" --verify \
    "${archive_dir}/Locus-macOS.zip" "${archive_signature}" >/dev/null || {
    echo "error: generated archive signature does not verify" >&2
    exit 1
}
"${sign_update}" --account "${sparkle_key_account}" --verify "${generated}" \
    >/dev/null || {
    echo "error: generated feed signature does not verify" >&2
    exit 1
}

/bin/mkdir -p "${appcast_out:h}"
/bin/cp "${generated}" "${appcast_out}"
echo "Signed appcast: ${appcast_out}"
/usr/bin/shasum -a 256 "${appcast_out}"
