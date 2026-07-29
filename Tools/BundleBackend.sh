#!/bin/zsh
# Embeds the agent service and a self-contained Python into Locus.app, so the
# app is a single download with no Python install required — the same
# experience as Claude Code or Codex. Layout consumed by BackendProcess.swift:
#   Resources/AgentRuntime/python/bin/python3.x   relocatable interpreter
#   Resources/AgentRuntime/site-packages          agent dependencies
#   Resources/AgentRuntime/source/ollama_code     agent source
#
# LOCUS_BUNDLE_MODE=standalone (default) uses the relocatable runtime cached
# by PrepareAgentRuntime.sh (downloads on first build). `venv` copies the
# developer venv's interpreter instead — such a build only runs on Macs that
# already have that Python. `skip` bundles nothing.
set -euo pipefail
setopt null_glob

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
backend_root="${LOCUS_BACKEND_ROOT:-${repo_root}/agent}"
cache="${LOCUS_RUNTIME_CACHE:-${repo_root}/.agent-runtime}"
mode="${LOCUS_BUNDLE_MODE:-standalone}"

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
runtime="${resources}/AgentRuntime"
source_package="${backend_root}/ollama_code"

if [[ "${mode}" == "skip" ]]; then
    echo "note: LOCUS_BUNDLE_MODE=skip — agent runtime not bundled."
    exit 0
fi

if [[ ! -d "${source_package}" ]]; then
    echo "warning: No agent source at ${source_package}; runtime not bundled."
    exit 0
fi

if [[ -z "${resources}" || "${resources}" != *".app/Contents/Resources" ]]; then
    echo "error: Refusing to bundle runtime outside an app Resources directory." >&2
    exit 1
fi

bundle_source() {
    /bin/rm -rf "${runtime}"
    /bin/mkdir -p "${runtime}/source"
    /usr/bin/ditto "${source_package}" "${runtime}/source/ollama_code"
    for junk in "${runtime}/source/ollama_code"/**/__pycache__(N/); do
        /bin/rm -rf "${junk}"
    done
}

bundle_standalone() {
    "${script_dir}/PrepareAgentRuntime.sh" || return 1
    [[ -x "${cache}/cpython/bin/python3" && -d "${cache}/site-packages" ]] || return 1

    bundle_source
    /usr/bin/ditto "${cache}/cpython" "${runtime}/python"
    /usr/bin/ditto "${cache}/site-packages" "${runtime}/site-packages"

    # Trim what the agent never uses. The cache stays complete (pip lives
    # there); only the app copy is slimmed.
    local bin_entry lib_dir prune
    for bin_entry in "${runtime}/python/bin"/*(N); do
        case "${bin_entry:t}" in
            python3|python3.<->) ;;
            *) /bin/rm -f "${bin_entry}" ;;
        esac
    done
    for lib_dir in "${runtime}/python/lib"/python3.*(N/); do
        for prune in test idlelib turtledemo tkinter ensurepip pydoc_data turtle.py; do
            /bin/rm -rf "${lib_dir}/${prune}"
        done
        /bin/rm -rf "${lib_dir}/site-packages"
        /bin/mkdir -p "${lib_dir}/site-packages"
    done
    for prune in "${runtime}/python/lib"/tcl*(N) "${runtime}/python/lib"/tk*(N) \
        "${runtime}/python/lib"/itcl*(N) "${runtime}/python/lib"/libtcl*(N) \
        "${runtime}/python/lib"/libtk*(N) "${runtime}/python/lib"/Tix*(N) \
        "${runtime}/python/lib"/thread*(N) "${runtime}/python/include" \
        "${runtime}/python/share"; do
        /bin/rm -rf "${prune}"
    done

    # Pre-compile so imports from the read-only bundle skip source compiling.
    "${runtime}/python/bin/python3" -m compileall -q "${runtime}/source" || true
    echo "Bundled self-contained agent runtime ($("${runtime}/python/bin/python3" -V))."
}

bundle_venv() {
    local venv_config="${backend_root}/.venv/pyvenv.cfg"
    [[ -f "${venv_config}" ]] || return 1

    local site_packages="" candidate
    for candidate in "${backend_root}"/.venv/lib/python*/site-packages(N/); do
        site_packages="${candidate}"
        break
    done
    [[ -n "${site_packages}" ]] || return 1

    local python_home python_bin=""
    python_home="$(/usr/bin/awk -F ' = ' '$1 == "home" { print $2; exit }' "${venv_config}")"
    for candidate in "${python_home}"/python3.*(N) "${python_home}/python3"; do
        if [[ -x "${candidate}" ]]; then
            python_bin="${candidate}"
            break
        fi
    done
    [[ -n "${python_home}" && -n "${python_bin}" ]] || return 1

    bundle_source
    /usr/bin/ditto "${site_packages}" "${runtime}/site-packages"
    /usr/bin/ditto "${python_home%/bin}" "${runtime}/python"
    echo "warning: Bundled the developer venv's Python ($(basename "${python_bin}"))." \
        "This build runs only on Macs where that Python is installed;" \
        "use LOCUS_BUNDLE_MODE=standalone for a self-contained app."
}

if [[ "${mode}" == "venv" ]]; then
    if ! bundle_venv; then
        echo "warning: venv bundling failed; runtime not bundled."
    fi
    exit 0
fi

if ! bundle_standalone; then
    echo "warning: Standalone runtime unavailable (offline?); falling back to the developer venv."
    if ! bundle_venv; then
        echo "warning: venv fallback also failed; runtime not bundled."
    fi
fi
