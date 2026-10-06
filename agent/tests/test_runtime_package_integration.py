"""The composed product must discover its trusted host without a sibling repo."""
import ast
import hashlib
import importlib.metadata
import importlib.util
import json
import shlex
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "RuntimePackage", Path(__file__).resolve().parents[2] / "Tools/RuntimePackage.py"
)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


@pytest.fixture
def candidate(tmp_path):
    agent = tmp_path / "agent"
    wheels = agent / "vendor/wheels"
    wheels.mkdir(parents=True)
    (agent / "pyproject.toml").write_text('''
[project]
name = "ollama-code"
version = "0.3.0"
requires-python = ">=3.10"
dependencies = ["locus-runtime==0.1.0", "fastapi>=0.110"]
[project.scripts]
ollama-code-server = "ollama_code.server:main"
[project.entry-points."locus_runtime.host"]
locus = "ollama_code.runtime_host:main"
''')
    wheel = wheels / "locus_runtime-0.1.0-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("locus_runtime-0.1.0.dist-info/METADATA", "Name: locus-runtime\nVersion: 0.1.0\n")
        archive.writestr("locus_runtime-0.1.0.dist-info/entry_points.txt", "[console_scripts]\nlocus-runtime = locus_runtime.cli:main\n")
    manifest = {"distribution": "locus-runtime", "version": "0.1.0", "artifact": wheel.name,
                "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
                "source_repository": "locus-runtime", "source_revision": "a" * 40}
    (wheels / "runtime-release.json").write_text(json.dumps(manifest))
    return agent, wheel, manifest


def test_vendored_wheel_is_bound_to_product_version_and_source(candidate):
    agent, _wheel, manifest = candidate
    assert package.runtime_release(agent) == manifest
    path = agent / "pyproject.toml"
    path.write_text(path.read_text().replace("locus-runtime==0.1.0", "locus-runtime==0.2.0"))
    with pytest.raises(ValueError, match="compatible pair"):
        package.runtime_release(agent)


def test_changed_wheel_is_rejected_before_install(candidate):
    agent, wheel, _manifest = candidate
    wheel.write_bytes(wheel.read_bytes() + b"changed after review")
    with pytest.raises(ValueError, match="integrity"):
        package.runtime_release(agent)


def test_composition_rejects_installed_runtime_with_changed_metadata(candidate, tmp_path):
    agent, wheel, manifest = candidate
    installed = tmp_path / "installed"
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(installed)
    assert package.verify_installed_runtime(agent, installed) == manifest
    (installed / "locus_runtime-0.1.0.dist-info/entry_points.txt").write_text("[console_scripts]\nlocus-runtime = other:main\n")
    with pytest.raises(ValueError, match="differs from the reviewed wheel"):
        package.verify_installed_runtime(agent, installed)


@pytest.mark.skipif(shutil.which("zsh") is None, reason="Native bundling uses zsh")
def test_venv_bundle_rejects_missing_runtime_before_staging_provenance(candidate, tmp_path):
    agent, _wheel, _manifest = candidate
    root = Path(__file__).resolve().parents[2]
    venv = agent / ".venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "lib/python3.14/site-packages").mkdir(parents=True)
    (venv / "bin/python").symlink_to(sys.executable)
    (venv / "pyvenv.cfg").write_text(f"home = {Path(sys.executable).parent}\n")
    builder = (root / "Tools/BundleBackend.sh").read_text()
    function = "bundle_venv() {" + builder.split("bundle_venv() {", 1)[1].split('\nif [[ "${mode}"', 1)[0]
    staged = tmp_path / "source-was-staged"
    script = ("set -euo pipefail\nsetopt null_glob\n"
              f"backend_root={shlex.quote(str(agent))}\nscript_dir={shlex.quote(str(root / 'Tools'))}\n"
              f"bundle_source() {{ touch {shlex.quote(str(staged))}; }}\n"
              + function + "\nbundle_venv\n")
    result = subprocess.run(["zsh", "-c", script], capture_output=True, text=True)
    assert result.returncode != 0
    assert "differs from the reviewed wheel" in result.stderr
    assert not staged.exists()


@pytest.mark.skipif(shutil.which("zsh") is None, reason="Native bundling uses zsh")
def test_host_staging_failure_propagates_even_inside_shell_condition(candidate, tmp_path):
    agent, _wheel, _manifest = candidate
    root = Path(__file__).resolve().parents[2]
    source = agent / "ollama_code"
    source.mkdir()
    (source / "product_build.py").write_text("# product edition\n")
    (source / "runtime_host.py").write_text("# host adapter\n")
    fail_python = tmp_path / "fail-python"
    fail_python.write_text('#!/bin/zsh\n[[ "$2" != "stage-host" ]] || exit 9\nexit 0\n')
    fail_python.chmod(0o755)
    runtime = tmp_path / "runtime"
    builder = (root / "Tools/BundleBackend.sh").read_text()
    function = "bundle_source() {" + builder.split("bundle_source() {", 1)[1].split("\nprune_disallowed_runtime_components()", 1)[0]
    script = ("set -euo pipefail\nsetopt null_glob\nTARGET_NAME=Locus\nLOCUS_EDITION=locus\n"
              f"backend_root={shlex.quote(str(agent))}\nscript_dir={shlex.quote(str(root / 'Tools'))}\n"
              f"runtime={shlex.quote(str(runtime))}\nsource_package={shlex.quote(str(source))}\n"
              + function + f"\nif ! bundle_source {shlex.quote(str(fail_python))}; then exit 23; fi\n")
    result = subprocess.run(["zsh", "-c", script], capture_output=True, text=True)
    assert result.returncode == 23, result.stderr
    assert not (runtime / "provenance.json").exists()


def test_wheel_paths_cannot_escape_vendor(candidate):
    agent, _wheel, manifest = candidate
    manifest["artifact"] = "../../some-other-wheel.whl"
    (agent / "vendor/wheels/runtime-release.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="filename"):
        package.runtime_release(agent)


def test_staged_source_has_exact_trusted_host_and_no_duplicate_console(candidate, tmp_path, monkeypatch):
    agent, _wheel, _manifest = candidate
    source = tmp_path / "source"
    (source / "ollama_code").mkdir(parents=True)
    (source / "ollama_code/runtime_host.py").write_text("def main(): pass\n")
    package.stage_host_metadata(agent, source)
    monkeypatch.setattr(sys, "path", [str(source)])
    host = importlib.metadata.distribution("ollama-code")
    assert host.version == "0.3.0"
    assert host.requires == ["locus-runtime==0.1.0", "fastapi>=0.110"]
    assert [(entry.name, entry.value) for entry in host.entry_points if entry.group == package.HOST_GROUP] == [
        ("locus", "ollama_code.runtime_host:main")
    ]
    assert [entry.name for entry in host.entry_points if entry.group == "console_scripts"] == ["ollama-code-server"]
    before = {path.name: path.read_bytes() for path in (source / "ollama_code-0.3.0.dist-info").iterdir()}
    package.stage_host_metadata(agent, source)
    assert before == {path.name: path.read_bytes() for path in (source / "ollama_code-0.3.0.dist-info").iterdir()}


@pytest.mark.parametrize("before,after,error", [
    ('locus = "ollama_code.runtime_host:main"', 'locus = "untrusted.module:run"', "canonical"),
    ('ollama-code-server = "ollama_code.server:main"', 'locus-runtime = "ollama_code.runtime:main"', "sole"),
])
def test_staging_rejects_changed_host_authority_or_console_owner(candidate, tmp_path, before, after, error):
    agent, _wheel, _manifest = candidate
    path = agent / "pyproject.toml"
    path.write_text(path.read_text().replace(before, after))
    with pytest.raises(ValueError, match=error):
        package.stage_host_metadata(agent, tmp_path / "source")


def test_staging_requires_host_adapter_in_product_source(candidate, tmp_path):
    with pytest.raises(ValueError, match="adapter is missing"):
        package.stage_host_metadata(candidate[0], tmp_path / "source")


def test_product_dependency_and_ci_use_committed_wheel():
    root = Path(__file__).resolve().parents[2]
    release = package.runtime_release(root / "agent")
    lock = (root / "agent/requirements-runtime.lock").read_text().replace("\\\n", " ")
    pinned = next(line for line in lock.splitlines() if line.startswith("locus-runtime=="))
    assert f"locus-runtime=={release['version']} " in pinned
    assert f"--hash=sha256:{release['sha256']}" in pinned
    assert "--find-links agent/vendor/wheels" in (root / ".github/workflows/ci.yml").read_text()


def test_smoke_runner_requires_only_the_installed_runtime_package():
    path = Path(__file__).resolve().parents[2] / "Tools/SmokeRemoteRuntime.py"
    imports = []
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.ImportFrom):
            imports.append(node.module or "")
        elif isinstance(node, ast.Import):
            imports.extend(alias.name for alias in node.names)
    assert not any(name == "ollama_code" or name.startswith("ollama_code.") for name in imports)
