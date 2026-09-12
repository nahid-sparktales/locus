#!/usr/bin/env python3
"""Extract Anthropic's runtime from a checksum-pinned official SDK wheel."""
import argparse
import hashlib
import io
import json
import os
import platform
import subprocess
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare(target: str, output: Path) -> Path:
    manifest = json.loads((ROOT / 'Config/ClaudeRuntime.json').read_text())
    tags = {'macos-arm64': 'macosx_11_0_arm64', 'macos-x86_64': 'macosx_11_0_x86_64',
            'linux-arm64': 'manylinux_2_17_aarch64', 'linux-x86_64': 'manylinux_2_17_x86_64'}
    entry = next(row for row in manifest['wheels'] if tags[target] in row['filename'])
    output.mkdir(parents=True, exist_ok=True)
    helper = output / 'claude'
    provenance = output / 'PROVENANCE'
    if helper.exists() and provenance.exists():
        previous = json.loads(provenance.read_text())
        if previous.get('wheel_sha256') == entry['sha256'] and previous.get('binary_sha256') == hashlib.sha256(helper.read_bytes()).hexdigest():
            return helper
    with urllib.request.urlopen(entry['url'], timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise ValueError('Claude runtime wheel checksum did not match the pinned manifest')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        binary = archive.read('claude_agent_sdk/_bundled/claude')
        license_path = next(name for name in archive.namelist() if name.endswith('/licenses/LICENSE'))
        license_text = archive.read(license_path)
    temporary = output / 'claude.pending'
    temporary.write_bytes(binary)
    temporary.chmod(0o755)
    # Verify before publishing. This runs only on the build target itself.
    version = subprocess.run([str(temporary.resolve()), '--version'], capture_output=True, text=True, timeout=20, check=True).stdout
    if not version.startswith(manifest['runtime_version'] + ' '):
        raise ValueError('Claude runtime version did not match the pinned manifest')
    os.replace(temporary, helper)
    (output / 'LICENSE').write_bytes(license_text)
    (output / 'NOTICE').write_text('Claude Agent SDK by Anthropic. The bundled Claude Code runtime is governed by Anthropic terms.\nhttps://code.claude.com/docs/en/legal-and-compliance\n')
    provenance.write_text(json.dumps({'sdk_version': manifest['sdk_version'], 'runtime_version': manifest['runtime_version'],
        'wheel_url': entry['url'], 'wheel_sha256': entry['sha256'], 'binary_sha256': hashlib.sha256(binary).hexdigest()}, indent=2) + '\n')
    return helper


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', default=('macos' if platform.system() == 'Darwin' else 'linux') + '-' + ('arm64' if platform.machine() in {'arm64', 'aarch64'} else 'x86_64'))
    parser.add_argument('--output', type=Path, default=ROOT / '.claude-runtime')
    args = parser.parse_args()
    print(prepare(args.target, args.output))
