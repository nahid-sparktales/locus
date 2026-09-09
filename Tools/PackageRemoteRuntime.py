#!/usr/bin/env python3
"""Package a portable, dependency-pinned AgentRuntime and pinned ChatGPT helper.

Build on each supported host/architecture using Tools/PrepareAgentRuntime.sh and
Tools/PrepareCodexAppServer.sh (or the same pinned helper built for Linux). This
command never downloads unverified executables. Ship its SHA-256 with the release.
"""
import argparse
import hashlib
import io
import json
import tarfile
import subprocess
import platform
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--codex-helper', type=Path, required=True)
parser.add_argument('--codex-code-mode-host', type=Path, required=True)
parser.add_argument('--target', choices=['linux-x86_64', 'linux-arm64', 'macos-arm64'], required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
system = platform.system()
architecture = 'arm64' if platform.machine() in {'arm64', 'aarch64'} else 'x86_64'
actual_target = ('macos-' if system == 'Darwin' else 'linux-' if system == 'Linux' else 'unsupported-') + architecture
if actual_target != args.target:
    parser.error('Build and validate this package on its target operating system and architecture.')
version = subprocess.run([str(args.codex_helper.resolve()), '--version'], capture_output=True, text=True, timeout=20)
if version.returncode or not version.stdout.strip().endswith(' 0.147.0'):
    parser.error('The ChatGPT helper must be pinned to version 0.147.0.')
for required in ['python/bin/python3', 'source/ollama_code/runtime.py']:
    if not (args.runtime / required).is_file():
        parser.error('The portable runtime layout is incomplete: ' + required)
files = {}
for path in sorted(args.runtime.rglob('*')):
    if path.is_file() and '__pycache__' not in path.parts and path.suffix != '.pyc':
        files[path.relative_to(args.runtime).as_posix()] = path
files['codex-app-server'] = args.codex_helper
files['codex-code-mode-host'] = args.codex_code_mode_host
manifest = {'version': 1, 'protocol_version': 1, 'target': args.target, 'codex_version': '0.147.0',
            'files': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}}
with tarfile.open(args.output, 'w:gz') as archive:
    for name, path in files.items():
        data = path.read_bytes()
        item = tarfile.TarInfo(name)
        item.mode, item.size = (0o700 if path.stat().st_mode & 0o111 else 0o600), len(data)
        archive.addfile(item, io.BytesIO(data))
    data = json.dumps(manifest, sort_keys=True).encode()
    item = tarfile.TarInfo('manifest.json')
    item.size, item.mode = len(data), 0o600
    archive.addfile(item, io.BytesIO(data))
checksum = hashlib.sha256(args.output.read_bytes()).hexdigest()
args.output.with_suffix(args.output.suffix + '.sha256').write_text(checksum + '\n')
print(f'{args.target}: {args.output} (SHA-256 {checksum})')
