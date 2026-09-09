"""Remote deployment safety and snapshot round-trip fixtures (no live hosts)."""
import hashlib
import io
import json
import tarfile

import pytest

from ollama_code import runtime_snapshots as snapshots
from ollama_code.runtime_install import extract_package
from ollama_code.runtime_remote import ssh_arguments


def test_snapshot_excludes_secrets_and_rejects_edits_after_review(tmp_path):
    tmp_path = tmp_path / "project"
    tmp_path.mkdir()
    (tmp_path / 'app.py').write_text('print("hello")')
    (tmp_path / '.env').write_text('TOKEN=private')
    (tmp_path / 'credential.txt').write_text('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----')
    (tmp_path / 'link').symlink_to('/etc/passwd')
    review = snapshots.preview(tmp_path)
    assert [row['path'] for row in review['files']] == ['app.py']
    assert len(review['exclusions']) == 3
    (tmp_path / 'app.py').write_text('changed')
    with pytest.raises(ValueError, match='changed'):
        snapshots.archive(review)


def test_snapshot_return_requires_explicit_selection_and_unchanged_local_file(tmp_path):
    local, remote = tmp_path / 'local', tmp_path / 'remote'
    local.mkdir()
    (local / 'file.txt').write_text('baseline')
    baseline = snapshots.preview(local)
    snapshots.unpack(snapshots.archive(baseline), remote, baseline['files'])
    (remote / 'file.txt').write_text('remote result')
    returned = snapshots.preview(remote)
    assert snapshots.apply_changes(baseline, returned, remote, []) == []
    assert (local / 'file.txt').read_text() == 'baseline'
    (local / 'file.txt').write_text('local edit')
    with pytest.raises(ValueError, match='conflict'):
        snapshots.apply_changes(baseline, returned, remote, ['file.txt'])
    (local / 'file.txt').write_text('baseline')
    assert snapshots.apply_changes(baseline, returned, remote, ['file.txt']) == ['file.txt']
    assert (local / 'file.txt').read_text() == 'remote result'


def test_snapshot_rejects_archive_path_escape(tmp_path):
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode='w:gz') as archive:
        info = tarfile.TarInfo('../escape')
        info.size = 1
        archive.addfile(info, io.BytesIO(b'x'))
    with pytest.raises(ValueError):
        snapshots.unpack(payload.getvalue(), tmp_path / 'import', [])
    assert not (tmp_path / 'escape').exists()


def test_ssh_uses_existing_auth_and_strict_host_keys():
    command = ssh_arguments('worker@my-server')
    assert 'StrictHostKeyChecking=yes' in command
    assert 'BatchMode=yes' in command
    assert command[-2:] == ['--', 'worker@my-server']
    for host in ('-oProxyCommand=bad', 'host; touch x', 'host\ncommand'):
        with pytest.raises(ValueError):
            ssh_arguments(host)


def package(target='linux-arm64', protocol=1):
    payload = io.BytesIO()
    files = {'python/bin/python3': b'python', 'source/ollama_code/runtime.py': b'runtime', 'codex-app-server': b'helper', 'codex-code-mode-host': b'code host'}
    manifest = {'target': target, 'protocol_version': protocol, 'codex_version': '0.147.0',
                'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    files['manifest.json'] = json.dumps(manifest).encode()
    with tarfile.open(fileobj=payload, mode='w:gz') as archive:
        for name, data in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
    return payload.getvalue()


def test_package_integrity_architecture_and_atomic_install(tmp_path):
    data = package()
    checksum = hashlib.sha256(data).hexdigest()
    with pytest.raises(ValueError, match='integrity'):
        extract_package(data, '0' * 64, tmp_path, 'linux-arm64')
    with pytest.raises(ValueError, match='incompatible'):
        extract_package(data, checksum, tmp_path, 'linux-x86_64')
    installed = extract_package(data, checksum, tmp_path, 'linux-arm64')
    assert installed == tmp_path / 'versions' / checksum
    assert (installed / 'codex-app-server').read_bytes() == b'helper'
    assert extract_package(data, checksum, tmp_path, 'linux-arm64') == installed
    assert not list((tmp_path / 'versions').glob('.install-*'))


def test_reusing_modified_installed_package_is_rejected(tmp_path):
    data = package()
    checksum = hashlib.sha256(data).hexdigest()
    installed = extract_package(data, checksum, tmp_path, 'linux-arm64')
    (installed / 'codex-app-server').write_bytes(b'tampered')
    with pytest.raises(ValueError, match='integrity'):
        extract_package(data, checksum, tmp_path, 'linux-arm64')


def test_chatgpt_device_login_uses_pinned_protocol_and_separate_homes(tmp_path, monkeypatch):
    from ollama_code.codex_app_server import CodexAppServerManager, codex_home_for_account
    manager = CodexAppServerManager(helper_path='/fixture/codex')
    calls = []
    def request(method, parameters, **kwargs):
        calls.append((method, parameters))
        return {'loginId': 'login', 'verificationUrl': 'https://auth.openai.com/device', 'userCode': 'test'}
    monkeypatch.setattr(manager, 'request', request)
    assert manager.start_login(device_code=True)['userCode'] == 'test'
    assert calls == [('account/login/start', {'type': 'chatgptDeviceCode'})]
    assert codex_home_for_account('one') != codex_home_for_account('two')


def test_ssh_host_key_failure_is_not_bypassed(tmp_path, monkeypatch):
    import subprocess
    from types import SimpleNamespace

    from ollama_code.runtime_remote import RemoteRuntimes
    def fail(args, **kwargs):
        assert 'StrictHostKeyChecking=yes' in args
        return subprocess.CompletedProcess(args, 255, b'', b'REMOTE HOST IDENTIFICATION HAS CHANGED')
    monkeypatch.setattr(subprocess, 'run', fail)
    manager = RemoteRuntimes(SimpleNamespace())
    with pytest.raises(ValueError, match="host's key"):
        manager.validate('owned-host')


def test_secret_excluded_from_return_is_not_reported_as_deleted(tmp_path):
    root = tmp_path / 'project'
    root.mkdir()
    (root / 'data.txt').write_text('ordinary content')
    baseline = snapshots.preview(root)
    (root / 'data.txt').write_text('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----')
    returned = snapshots.preview(root)
    assert snapshots.changes(baseline, returned) == []
    assert returned['exclusions'][0]['reason'] == 'detected secret'
