#!/bin/zsh
# Reproducibly builds the OpenAI Codex helper used for ChatGPT-plan accounts.
# The source archive, lockfile, and resulting cache provenance are pinned; an
# upgrade is an intentional edit to all three constants below.
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
tag="rust-v0.147.0"
version="0.147.0"
source_sha256="355bde4b40d5ba6deea2e469d36f91708315729f3e84c9c69cce6b041a5ba593"
upstream_lock_sha256="eeab4e9d3466da54037032251e2f13ad1ed11eae18bb8ee7dd2c89dbb86f645d"
normalized_lock_sha256="bc4fe450de929afe82928734f860ca83e5f9dc5f9f1211b0974ea47b57af77ca"
v8_version="150.4.0"
v8_aarch64_archive_sha256="00adbb48798848c77550441c68673a5e8529b8e1b73eabcdee232cb39b40f4a1"
v8_aarch64_binding_sha256="ca5adf0cf89c9a70ad460ae73648b2fe89b74aa113b3cb7f757b6a02b758394f"
v8_x86_64_archive_sha256="e0d9bb64e8b3a034c2930c83972f3f35760211148342fa0407b38250ef330856"
v8_x86_64_binding_sha256="ca5adf0cf89c9a70ad460ae73648b2fe89b74aa113b3cb7f757b6a02b758394f"
cache="${LOCUS_CODEX_CACHE:-${repo_root}/.codex-app-server}"
archive="${cache}/codex-${tag}.tar.gz"
source="${cache}/source-${tag}"
source_marker="${source}/.locus-source-sha256"
binary="${cache}/bin/codex"
code_mode_host_binary="${cache}/bin/codex-code-mode-host"
provenance="${cache}/PROVENANCE"
requested_archs="${LOCUS_CODEX_ARCHS:-$(/usr/bin/uname -m)}"
normalized_archs="$(
    for architecture in ${=requested_archs}; do
        print -r -- "${architecture}"
    done | /usr/bin/sort -u | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//'
)"

if [[ -x "${binary}" && -x "${code_mode_host_binary}" && -f "${provenance}" ]] \
    && /usr/bin/grep -Fq "source_sha256=${source_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "cargo_lock_sha256=${normalized_lock_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "code_mode_host_sha256=" "${provenance}" \
    && /usr/bin/grep -Fq "v8_version=${v8_version}" "${provenance}" \
    && /usr/bin/grep -Fq "v8_aarch64_archive_sha256=${v8_aarch64_archive_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "v8_aarch64_binding_sha256=${v8_aarch64_binding_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "v8_x86_64_archive_sha256=${v8_x86_64_archive_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "v8_x86_64_binding_sha256=${v8_x86_64_binding_sha256}" "${provenance}" \
    && /usr/bin/grep -Fq "architectures=${normalized_archs}" "${provenance}"; then
    exit 0
fi

/bin/mkdir -p "${cache}" "${cache}/bin"
if [[ ! -f "${archive}" ]]; then
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/openai/codex/archive/refs/tags/${tag}.tar.gz" \
        --output "${archive}.partial"
    /bin/mv "${archive}.partial" "${archive}"
fi

actual="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{print $1}')"
[[ "${actual}" == "${source_sha256}" ]] || {
    echo "error: Codex source checksum mismatch (${actual})" >&2
    exit 1
}

cached_source_sha="$(/bin/cat "${source_marker}" 2>/dev/null || true)"
if [[ "${cached_source_sha}" != "${source_sha256}" ]]; then
    /bin/rm -rf "${source}"
    /bin/mkdir -p "${source}"
    /usr/bin/tar -xzf "${archive}" --strip-components=1 -C "${source}"
    print -r -- "${source_sha256}" > "${source_marker}"
fi

lockfile="${source}/codex-rs/Cargo.lock"
actual_lock_sha="$(/usr/bin/shasum -a 256 "${lockfile}" | /usr/bin/awk '{print $1}')"
if [[ "${actual_lock_sha}" == "${upstream_lock_sha256}" ]]; then
    # OpenAI's release automation changes every workspace manifest from the
    # development version 0.0.0 to the release version, but the GitHub source
    # archive retains those 0.0.0 entries in Cargo.lock. Cargo 1.95 therefore
    # refuses a --locked build until the same deterministic version rewrite is
    # reflected in the lockfile. No dependencies or checksums are changed.
    /usr/bin/sed -i '' \
        "s/^version = \"0.0.0\"$/version = \"${version}\"/" "${lockfile}"
    actual_lock_sha="$(/usr/bin/shasum -a 256 "${lockfile}" | /usr/bin/awk '{print $1}')"
fi
[[ "${actual_lock_sha}" == "${normalized_lock_sha256}" ]] || {
    echo "error: normalized Codex Cargo.lock checksum mismatch (${actual_lock_sha})" >&2
    exit 1
}

command -v cargo >/dev/null || {
    echo "error: Rust cargo is required to build the pinned Codex App Server" >&2
    exit 1
}

export CARGO_HOME="${LOCUS_CODEX_CARGO_HOME:-${cache}/cargo-home}"
export CARGO_TARGET_DIR="${cache}/target-${version}"
export SOURCE_DATE_EPOCH="0"
outputs=()
code_mode_host_outputs=()
for architecture in ${=normalized_archs}; do
    case "${architecture}" in
        arm64)
            rust_target="aarch64-apple-darwin"
            expected_v8_archive_sha="${v8_aarch64_archive_sha256}"
            expected_v8_binding_sha="${v8_aarch64_binding_sha256}"
            ;;
        x86_64)
            rust_target="x86_64-apple-darwin"
            expected_v8_archive_sha="${v8_x86_64_archive_sha256}"
            expected_v8_binding_sha="${v8_x86_64_binding_sha256}"
            ;;
        *) echo "error: unsupported Codex helper architecture ${architecture}" >&2; exit 1 ;;
    esac
    # The code-mode host links V8. OpenAI publishes its own verified V8 pair
    # because Deno's upstream crate release does not carry these macOS
    # ptr-compression+sandbox archives. These are the same URLs used by the
    # pinned source's scripts/codex_package/v8.py release builder.
    v8_release_url="https://github.com/openai/codex/releases/download/rusty-v8-v${v8_version}"
    v8_cache="${cache}/v8/rusty-v8-${v8_version}-${rust_target}"
    v8_archive="${v8_cache}/librusty_v8_ptrcomp_sandbox_release_${rust_target}.a.gz"
    v8_binding="${v8_cache}/src_binding_ptrcomp_sandbox_release_${rust_target}.rs"
    /bin/mkdir -p "${v8_cache}"
    actual_v8_archive_sha=""
    if [[ -f "${v8_archive}" ]]; then
        actual_v8_archive_sha="$(/usr/bin/shasum -a 256 "${v8_archive}" \
            | /usr/bin/awk '{print $1}')"
    fi
    if [[ "${actual_v8_archive_sha}" != "${expected_v8_archive_sha}" ]]; then
        /bin/rm -f "${v8_archive}" "${v8_archive}.partial"
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
            "${v8_release_url}/${v8_archive:t}" --output "${v8_archive}.partial"
        /bin/mv "${v8_archive}.partial" "${v8_archive}"
    fi
    actual_v8_binding_sha=""
    if [[ -f "${v8_binding}" ]]; then
        actual_v8_binding_sha="$(/usr/bin/shasum -a 256 "${v8_binding}" \
            | /usr/bin/awk '{print $1}')"
    fi
    if [[ "${actual_v8_binding_sha}" != "${expected_v8_binding_sha}" ]]; then
        /bin/rm -f "${v8_binding}" "${v8_binding}.partial"
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
            "${v8_release_url}/${v8_binding:t}" --output "${v8_binding}.partial"
        /bin/mv "${v8_binding}.partial" "${v8_binding}"
    fi
    actual_v8_archive_sha="$(/usr/bin/shasum -a 256 "${v8_archive}" | /usr/bin/awk '{print $1}')"
    actual_v8_binding_sha="$(/usr/bin/shasum -a 256 "${v8_binding}" | /usr/bin/awk '{print $1}')"
    [[ "${actual_v8_archive_sha}" == "${expected_v8_archive_sha}" ]] || {
        echo "error: OpenAI V8 archive checksum mismatch (${actual_v8_archive_sha})" >&2
        exit 1
    }
    [[ "${actual_v8_binding_sha}" == "${expected_v8_binding_sha}" ]] || {
        echo "error: OpenAI V8 binding checksum mismatch (${actual_v8_binding_sha})" >&2
        exit 1
    }
    (cd "${source}/codex-rs" && \
        RUSTY_V8_ARCHIVE="${v8_archive}" \
        RUSTY_V8_SRC_BINDING_PATH="${v8_binding}" \
        cargo build --locked --release \
        --bin codex --bin codex-code-mode-host --target "${rust_target}")
    outputs+=("${CARGO_TARGET_DIR}/${rust_target}/release/codex")
    code_mode_host_outputs+=(
        "${CARGO_TARGET_DIR}/${rust_target}/release/codex-code-mode-host"
    )
done
if (( ${#outputs} == 1 )); then
    /usr/bin/ditto "${outputs[1]}" "${binary}"
    /usr/bin/ditto "${code_mode_host_outputs[1]}" "${code_mode_host_binary}"
else
    /usr/bin/lipo -create "${outputs[@]}" -output "${binary}"
    /usr/bin/lipo -create "${code_mode_host_outputs[@]}" -output "${code_mode_host_binary}"
fi
/bin/chmod 755 "${binary}" "${code_mode_host_binary}"
{
    echo "tag=${tag}"
    echo "version=${version}"
    echo "architectures=${normalized_archs}"
    echo "source_sha256=${source_sha256}"
    echo "binary_sha256=$(/usr/bin/shasum -a 256 "${binary}" | /usr/bin/awk '{print $1}')"
    echo "code_mode_host_sha256=$(/usr/bin/shasum -a 256 "${code_mode_host_binary}" | /usr/bin/awk '{print $1}')"
    echo "v8_version=${v8_version}"
    echo "v8_aarch64_archive_sha256=${v8_aarch64_archive_sha256}"
    echo "v8_aarch64_binding_sha256=${v8_aarch64_binding_sha256}"
    echo "v8_x86_64_archive_sha256=${v8_x86_64_archive_sha256}"
    echo "v8_x86_64_binding_sha256=${v8_x86_64_binding_sha256}"
    echo "upstream_cargo_lock_sha256=${upstream_lock_sha256}"
    echo "cargo_lock_normalization=workspace_versions_0.0.0_to_${version}"
    echo "cargo_lock_sha256=${normalized_lock_sha256}"
} > "${provenance}"
