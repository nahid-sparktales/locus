"""Package provenance, archive boundaries, maintenance admission and update recovery."""
import asyncio
import base64
import hashlib
import importlib.util
import io
import json
import sqlite3
import sys
import tarfile
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from ollama_code import runtime_install as installer
from ollama_code import server
from ollama_code.api.runtime import resume_runtime
from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor


def tool(name):
    path = Path(__file__).resolve().parents[2] / "Tools" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


packager = tool("PackageRemoteRuntime")
builder = tool("PrepareRemoteRuntime")


@pytest.fixture
def layout(tmp_path, monkeypatch):
    root = tmp_path / "runtime"
    for name, data in {"python/bin/python3.14": b"python", "source/ollama_code/runtime.py": b"source", "site-packages/example.py": b"dependency"}.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (root / "python/bin/python3").symlink_to("python3.14")
    helper, code_host = tmp_path / "helper", tmp_path / "code-host"
    for path in (helper, code_host):
        path.write_bytes(b"fixture executable")
        path.chmod(0o700)
    monkeypatch.setattr(packager, "host_target", lambda: "linux-arm64")
    monkeypatch.setattr(packager, "check_runtime", lambda *_: None)
    return root, helper, code_host


def test_packages_are_reproducible_and_relocatable(layout, tmp_path):
    root, helper, code_host = layout
    first, second = tmp_path / "one.tar.gz", tmp_path / "another-name.tar.gz"
    checksum = packager.package_runtime(root, helper, code_host, "linux-arm64", first)
    for path in root.rglob("*"):
        if path.is_file():
            import os
            os.utime(path, (1234, 1234))
    (root / "python/.DS_Store").write_bytes(b"irrelevant metadata")
    assert packager.package_runtime(root, helper, code_host, "linux-arm64", second) == checksum
    relocated = installer.extract_package(first.read_bytes(), checksum, tmp_path / "elsewhere", "linux-arm64")
    assert (relocated / "python/bin/python3").read_bytes() == b"python"
    assert not (relocated / "python/bin/python3").is_symlink()
    assert str(tmp_path) not in (relocated / "manifest.json").read_text()


def test_package_rejects_external_links_wrong_target_and_private_files(layout, tmp_path):
    root, helper, code_host = layout
    output = tmp_path / "package.tar.gz"
    with pytest.raises(ValueError, match="target"):
        packager.package_runtime(root, helper, code_host, "linux-x86_64", output)
    secret = root / "runtime-secrets.json"
    secret.write_text('{}')
    with pytest.raises(ValueError, match="Unexpected file"):
        packager.package_runtime(root, helper, code_host, "linux-arm64", output)
    secret.unlink()
    (root / "source/escape").symlink_to(helper)
    with pytest.raises(ValueError, match="inside"):
        packager.package_runtime(root, helper, code_host, "linux-arm64", output)
    assert not output.exists()


def test_reused_package_cannot_rewrite_its_own_trust_manifest(layout, tmp_path):
    output = tmp_path / "package.tar.gz"
    checksum = packager.package_runtime(*layout, "linux-arm64", output)
    installed = installer.extract_package(output.read_bytes(), checksum, tmp_path / "install", "linux-arm64")
    path = installed / "manifest.json"
    manifest = json.loads(path.read_text())
    (installed / "codex-app-server").write_bytes(b"changed helper")
    manifest["files"]["codex-app-server"] = packager.digest(installed / "codex-app-server")
    path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="integrity"):
        installer.extract_package(output.read_bytes(), checksum, tmp_path / "install", "linux-arm64")


@pytest.mark.parametrize("name,link", [("../escape", None), ("/absolute", None), ("inside/link", "../../escape"), ("inside/link", "/absolute")])
def test_build_inputs_cannot_escape_extraction(tmp_path, name, link):
    archive = tmp_path / "input.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        member = tarfile.TarInfo(name)
        if link is not None:
            member.type, member.linkname = tarfile.SYMTYPE, link
            stream.addfile(member)
        else:
            member.size = 1
            stream.addfile(member, io.BytesIO(b"x"))
    with pytest.raises(ValueError):
        builder.extract(archive, tmp_path / "staging")
    assert not (tmp_path / "escape").exists()


def test_pins_cover_every_supported_target_without_floating_versions():
    pins = json.loads(builder.PINS.read_text())
    assert set(pins["targets"]) == set(packager.TARGETS)
    assert pins["codex_version"] == packager.CODEX_VERSION
    for target in pins["targets"].values():
        for name, component in target.items():
            assert len(component["sha256"]) == 64
            assert component["url"].startswith("https://github.com/")
            assert "/latest/" not in component["url"]
            assert (pins["python_release"] if name == "python" else "rust-v" + pins["codex_version"]) in component["url"]


def test_download_does_not_trust_a_corrupted_cache(tmp_path, monkeypatch):
    good = b"reviewed release"
    checksum = hashlib.sha256(good).hexdigest()
    cached = tmp_path / (checksum + ".tar.gz")
    cached.write_bytes(b"changed cache")
    component = {"sha256": checksum, "url": "https://github.com/example/releases/download/v1/asset.tar.gz"}
    response = io.BytesIO(b"changed remote release")
    response.geturl = lambda: "https://github.com/example/releases/download/v1/asset.tar.gz"
    monkeypatch.setattr(builder.urllib.request, "urlopen", lambda *_args, **_kwargs: response)
    with pytest.raises(ValueError, match="integrity"):
        builder.download(component, tmp_path)
    assert cached.read_bytes() == b"changed cache"
    assert not list(tmp_path.glob(".download-*"))
    cached.write_bytes(good)
    assert builder.download(component, tmp_path) == cached


@pytest.mark.parametrize("libc,version", [("glibc", "2.17"), ("musl", "1.2")])
def test_linux_setup_rejects_incompatible_c_libraries(monkeypatch, libc, version):
    monkeypatch.setattr(installer.platform, "system", lambda: "Linux")
    monkeypatch.setattr(installer.platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(installer.platform, "libc_ver", lambda: (libc, version))
    with pytest.raises(ValueError, match="glibc 2.28"):
        installer.host_info()


def test_remote_cli_helper_uses_its_declared_entry_point(monkeypatch):
    from ollama_code.codex_app_server import CodexAppServerManager
    manager = CodexAppServerManager(helper_path="/fixture/codex-app-server")
    monkeypatch.setenv("LOCUS_CODEX_HELPER_KIND", "cli")
    assert manager._command() == ["/fixture/codex-app-server", "app-server", "--listen", "stdio://"]
    monkeypatch.setenv("LOCUS_CODEX_HELPER_KIND", "app-server")
    assert manager._command() == ["/fixture/codex-app-server", "--listen", "stdio://"]


def test_maintenance_rejects_commands_and_http_mutations(tmp_path):
    app = server.create_app(auth_token="fixture-token")
    app.state.service = SimpleNamespace(run_store=RunStore(tmp_path / "runs.sqlite3"))
    root = tmp_path / "runtime"
    root.mkdir()
    (root / "installation.json").write_text('{}')
    runtime = app.state.runtime = RuntimeSupervisor(app, root, port=1)
    assert runtime.paused and runtime.status()["maintenance"]
    with pytest.raises(RuntimeError, match="installation"):
        asyncio.run(runtime.command("session", {"type": "user_message", "text": "do work"}))
    with pytest.raises(RuntimeError, match="installation"):
        asyncio.run(runtime.ensure_worker("session", str(tmp_path)))
    with pytest.raises(HTTPException) as error:
        resume_runtime(SimpleNamespace(app=app))
    assert error.value.status_code == 409
    client = TestClient(app)
    try:
        assert client.post("/api/config", json={}).status_code in {401, 403}
        response = client.post("/api/config", json={}, headers={"X-Locus-Token": "fixture-token"})
        assert response.status_code == 409
    finally:
        client.close()
    (root / "installation.json").unlink()
    resume_runtime(SimpleNamespace(app=app))
    assert not runtime.paused and not runtime.maintenance


@pytest.fixture
def installation(tmp_path, monkeypatch):
    info = {"system": "Linux", "target": "linux-arm64", "protocol_version": 1}
    monkeypatch.setattr(installer, "host_info", lambda: info)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    root, unit, label = installer.deployment_paths(info)
    root.mkdir(parents=True)
    previous = root / "versions" / ("a" * 64)
    candidate = root / "versions" / ("b" * 64)
    previous.mkdir(parents=True)
    candidate.mkdir()
    (root / "current").symlink_to(previous)
    installer.atomic_write(unit, b"old-unit")
    installer.atomic_write(root / "runtime-secrets.json", b'{"controller_token":"fixture-token","paused":true}')
    installer.atomic_write(root / "endpoint.json", b'{"url":"http://127.0.0.1:8793"}')
    profile = root / "profile"
    profile.mkdir()
    database = profile / "agent-runs.sqlite3"
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE evidence(value TEXT)")
        db.execute("INSERT INTO evidence VALUES('consumed allowance')")
    state = {"running": True, "package_id": previous.name, "starts": [], "fail": True}
    monkeypatch.setattr(installer, "extract_package", lambda *_: candidate)
    monkeypatch.setattr(installer.subprocess, "run", lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout="codex-cli 0.147.0\n"))
    monkeypatch.setattr(installer, "service_running", lambda *_: state["running"])

    def status(*_args, **_kwargs):
        return {"package_id": state["package_id"], "paused": True, "workers": [], "active_work": 0} if state["running"] else None

    def service(_info, _unit, _label, action):
        state["running"] = action == "start"
        if action == "start":
            state["package_id"] = previous.name if unit.read_bytes() == b"old-unit" else candidate.name
            state["starts"].append(state["package_id"])
            if state["package_id"] == candidate.name:
                with sqlite3.connect(database) as db:
                    db.execute("UPDATE evidence SET value='startup migration'")
                with sqlite3.connect(profile / "new-feature.sqlite3") as db:
                    db.execute("CREATE TABLE IF NOT EXISTS newer_schema(value TEXT)")

    def ready(_root, _port, expected):
        if expected == candidate.name and state["fail"]:
            raise ValueError("Fixture startup failure")
        assert state["running"] and state["package_id"] == expected
        return status()

    monkeypatch.setattr(installer, "api_request", status)
    monkeypatch.setattr(installer, "service_control", service)
    monkeypatch.setattr(installer, "wait_ready", ready)
    return SimpleNamespace(root=root, unit=unit, label=label, info=info, previous=previous, candidate=candidate,
                           database=database, state=state, header={"sha256": candidate.name, "port": 8793})


def test_failed_update_restores_unit_package_and_consumed_allowances(installation):
    value = installation
    with pytest.raises(ValueError, match="were restored"):
        installer.install(value.header, b"fixture")
    assert value.unit.read_bytes() == b"old-unit"
    assert (value.root / "current").resolve() == value.previous
    assert value.state["starts"] == [value.candidate.name, value.previous.name]
    assert not (value.root / "installation.json").exists()
    with sqlite3.connect(value.database) as db:
        assert db.execute("SELECT value FROM evidence").fetchone()[0] == "consumed allowance"
    assert list((value.root / "install-backups").rglob("*.sqlite3"))
    assert not (value.database.parent / "new-feature.sqlite3").exists()


def test_failed_recovery_retains_journal_and_blocks_service_start(installation, monkeypatch):
    def fail(*_args):
        raise ValueError("Fixture readiness failure")
    monkeypatch.setattr(installer, "wait_ready", fail)
    value = installation
    with pytest.raises(ValueError, match="recovery needs attention"):
        installer.install(value.header, b"fixture")
    assert (value.root / "installation.json").exists()
    assert list((value.root / "install-backups").rglob("*.sqlite3"))
    with pytest.raises(ValueError, match="interrupted installation"):
        installer.control({"control": "start"})


def test_install_and_control_share_an_exclusive_lock(installation):
    import fcntl
    with (installation.root / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(ValueError, match="in progress"):
            installer.install(installation.header, b"fixture")
        with pytest.raises(ValueError, match="in progress"):
            installer.control({"control": "stop"})


def test_successful_update_retains_previous_package_and_stays_paused(installation):
    value = installation
    value.state["fail"] = False
    result = installer.install(value.header, b"fixture")
    assert result["package"] == value.candidate.name
    assert (value.root / "current").resolve() == value.candidate
    assert (value.root / "previous").resolve() == value.previous
    assert installer.private_read(value.root)["paused"]
    assert not (value.root / "installation.json").exists()


def test_interrupted_install_is_recovered_before_retry(installation):
    value = installation
    journal = {"id": "c" * 32, "port": 8793, "previous_port": 8793, "previous_package": str(value.previous),
               "unit": base64.b64encode(b"old-unit").decode(), "was_running": True, "was_paused": True}
    installer.backup_databases(value.root, journal)
    value.unit.write_bytes(b"partially-installed-unit")
    value.state.update(package_id=value.candidate.name, running=False, fail=False)
    result = installer.install(value.header, b"fixture")
    assert value.state["starts"] == [value.previous.name, value.candidate.name]
    assert result["package"] == value.candidate.name


def test_validation_cleanup_cannot_target_production_or_escape_home():
    info = {"system": "Linux"}
    for value in ("", "../production", "g" * 32, "a" * 31, "/tmp/host"):
        with pytest.raises(ValueError):
            installer.deployment_paths(info, value)
    root, unit, label = installer.deployment_paths(info, "a" * 32)
    assert "locus-runtime-validation" in str(root)
    assert label.startswith("locus-runtime-validation-") and unit.name == label + ".service"
