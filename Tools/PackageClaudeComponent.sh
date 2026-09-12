#!/bin/zsh
# Package the pinned official Claude runtime for the existing component feed.
set -euo pipefail
out_dir="${1:?usage: PackageClaudeComponent.sh <output-directory>}"
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
arch="${LOCUS_COMPONENT_ARCH:-$(uname -m)}"
identity="${LOCUS_SIGN_IDENTITY:?set LOCUS_SIGN_IDENTITY to a Developer ID Application identity}"
cache="${repo_root}/.claude-runtime/${arch}"
python3 "${script_dir}/PrepareClaudeRuntime.py" --target "macos-${arch}" --output "${cache}"
mkdir -p "${out_dir}"
staging="$(mktemp -d "${TMPDIR:-/tmp}/locus-claude-component.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT
for name in claude LICENSE NOTICE PROVENANCE; do
    ditto --norsrc --noextattr --noqtn "${cache}/${name}" "${staging}/${name}"
done
codesign --force --timestamp --options runtime --entitlements "${repo_root}/Config/CodexCodeModeHost.entitlements" --identifier io.sparktales.locus.claude --sign "${identity}" "${staging}/claude"
codesign --verify --strict -R='=identifier "io.sparktales.locus.claude" and anchor apple generic and certificate leaf[subject.OU] = "4X4RJA7GMD"' "${staging}/claude"
python3 - "${staging}" "${out_dir}" "${arch}" "${repo_root}" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
staging, output, arch, root = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
manifest = json.loads((root / 'Config/ClaudeRuntime.json').read_text())
version = manifest['runtime_version']
provenance = json.loads((staging / 'PROVENANCE').read_text())
provenance.update(delivery='component', binary_sha256=hashlib.sha256((staging / 'claude').read_bytes()).hexdigest())
(staging / 'PROVENANCE').write_text(json.dumps(provenance, indent=2) + '\n')
archive = output / f'claude-plan-{version}-{arch}.zip'
subprocess.run(['/usr/bin/ditto', '-c', '-k', str(staging), str(archive)], check=True)
feed_path = output / 'components.json'
feed = json.loads(feed_path.read_text()) if feed_path.exists() else {'schemaVersion': 1, 'components': []}
feed['components'] = [r for r in feed['components'] if (r['id'], r['arch']) != ('claude-plan', arch)]
feed['components'].append({'id': 'claude-plan', 'version': version, 'arch': arch,
    'minAppVersion': os.environ.get('LOCUS_COMPONENT_MIN_APP_VERSION', '2.0.0'),
    'url': os.environ.get('LOCUS_COMPONENT_BASE_URL', 'https://github.com/nahid-sparktales/locus/releases/latest/download') + '/' + archive.name,
    'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'downloadBytes': archive.stat().st_size,
    'installedBytes': sum(p.stat().st_size for p in staging.iterdir())})
feed_path.write_text(json.dumps(feed, indent=2) + '\n')
PY
if [[ "${LOCUS_NOTARIZE:-0}" == "1" ]]; then
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime_version"])' "${repo_root}/Config/ClaudeRuntime.json")"
    xcrun notarytool submit "${out_dir}/claude-plan-${version}-${arch}.zip" \
        --key "${LOCUS_ASC_KEY_PATH:?set LOCUS_ASC_KEY_PATH}" \
        --key-id "${LOCUS_ASC_KEY_ID:?set LOCUS_ASC_KEY_ID}" \
        --issuer "${LOCUS_ASC_ISSUER_ID:?set LOCUS_ASC_ISSUER_ID}" --wait --timeout 30m
fi
