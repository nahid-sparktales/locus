#!/bin/zsh
# Builds/refreshes the cached self-contained agent runtime consumed by
# BundleBackend.sh:
#   .agent-runtime/cpython        relocatable CPython (python-build-standalone)
#   .agent-runtime/site-packages  agent dependencies (pip --target)
# Unlike a Homebrew/system Python, these builds resolve their dylib and
# stdlib relative to the executable, so the copy inside Locus.app works on
# Macs with no Python installed.
# Safe to run manually; does no work (and no network) while the stamp is
# current. The stamp covers the interpreter build, package metadata, and the
# fully hashed runtime dependency lock.
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
backend_root="${LOCUS_BACKEND_ROOT:-${repo_root}/agent}"
cache="${LOCUS_RUNTIME_CACHE:-${repo_root}/.agent-runtime}"
requirements_lock="${backend_root}/requirements-runtime.lock"

if [[ ! -f "${requirements_lock}" ]]; then
    echo "error: missing hashed runtime lock ${requirements_lock}" >&2
    exit 1
fi

# Bump these together when moving to a newer interpreter:
# https://github.com/astral-sh/python-build-standalone/releases
pbs_tag="${LOCUS_PBS_TAG:-20260728}"
py_version="${LOCUS_PBS_PYTHON:-3.14.6}"

case "$(/usr/bin/uname -m)" in
    arm64)
        pbs_arch="aarch64"
        pbs_sha256="f4b47659e2da4b97f38cefdf5ad19f0042946099d843cde60de308708e5b1ac5"
        ;;
    x86_64)
        pbs_arch="x86_64"
        pbs_sha256="00a22363402a1a15d4fb1327c8259a91118258d5463d10a97d3e56c1f18195f6"
        ;;
    *) echo "error: unsupported architecture $(/usr/bin/uname -m)" >&2; exit 1 ;;
esac

asset="cpython-${py_version}+${pbs_tag}-${pbs_arch}-apple-darwin-install_only_stripped.tar.gz"
url="https://github.com/astral-sh/python-build-standalone/releases/download/${pbs_tag}/${asset}"

manifest_hash="$(
    /usr/bin/shasum -a 256 \
        "${backend_root}/pyproject.toml" \
        "${requirements_lock}" \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/cut -d' ' -f1
)"
stamp_value="v4 ${asset} ${pbs_sha256} ${manifest_hash}"
stamp_file="${cache}/.stamp"

if [[ -f "${stamp_file}" && -x "${cache}/cpython/bin/python3" && -d "${cache}/site-packages" ]] \
    && [[ "$(<"${stamp_file}")" == "${stamp_value}" ]]; then
    echo "Agent runtime cache is current (${asset})."
    exit 0
fi

echo "Preparing agent runtime: ${asset}"
workdir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-runtime.XXXXXX")"
trap '/bin/rm -rf "${workdir}"' EXIT

/usr/bin/curl -fsSL --retry 3 -o "${workdir}/${asset}" "${url}"
actual="$(/usr/bin/shasum -a 256 "${workdir}/${asset}" | /usr/bin/cut -d' ' -f1)"
if [[ "${pbs_sha256}" != "${actual}" ]]; then
    echo "error: pinned checksum mismatch for ${asset}" >&2
    exit 1
fi

/usr/bin/tar -xzf "${workdir}/${asset}" -C "${workdir}"
if [[ ! -x "${workdir}/python/bin/python3" ]]; then
    echo "error: unexpected archive layout in ${asset}" >&2
    exit 1
fi

# Install only the agent's locked third-party dependencies. The app bundles
# the live first-party source tree separately.
/bin/mkdir -p "${workdir}/site-packages"
"${workdir}/python/bin/python3" -m pip install --quiet \
    --require-hashes \
    --only-binary=:all: \
    --target "${workdir}/site-packages" \
    --requirement "${requirements_lock}"
/bin/rm -rf \
    "${workdir}/site-packages/bin"

# Pre-compile EVERYTHING — stdlib included. The bundle is sealed by the app's
# code signature after this; a .pyc written at first launch would break the
# seal and make Gatekeeper report the download as damaged.
"${workdir}/python/bin/python3" -m compileall -q -j 0 \
    "${workdir}/python/lib" "${workdir}/site-packages"

/bin/rm -rf "${cache}"
/bin/mkdir -p "${cache}"
/usr/bin/ditto "${workdir}/python" "${cache}/cpython"
/usr/bin/ditto "${workdir}/site-packages" "${cache}/site-packages"
print -r -- "${stamp_value}" > "${stamp_file}"
echo "Agent runtime cache ready at ${cache}"
