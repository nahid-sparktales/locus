"""Dependency-free installer sent over authenticated SSH; secrets use stdin only."""
from __future__ import annotations

import hashlib
import io
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

PROTOCOL = 1
MAX_PACKAGE = 2 * 1024 * 1024 * 1024


def host_info():
    system, architecture = platform.system(), platform.machine()
    if system == "Linux" and architecture in {"x86_64", "aarch64", "arm64"}:
        target = "linux-" + ("arm64" if architecture != "x86_64" else "x86_64")
        command = subprocess.run(["systemctl", "--user", "show-environment"], capture_output=True)
        if command.returncode:
            raise ValueError("A working systemd user session is required")
        linger = subprocess.run(["loginctl", "show-user", str(os.getuid()), "--property=Linger", "--value"], capture_output=True, text=True)
        requirement = "User lingering is enabled" if linger.stdout.strip() == "yes" else "Enable lingering for this user to run after SSH logout (loginctl enable-linger USER)"
    elif system == "Darwin" and architecture == "arm64" and int(platform.mac_ver()[0].split(".")[0]) >= 14:
        target = "macos-arm64"
        result = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}"], capture_output=True)
        if result.returncode:
            raise ValueError("macOS needs an active graphical login for this user's launch agent")
        requirement = "Runs while this macOS user is logged in and the Mac is awake"
    else:
        raise ValueError("Supported hosts: Linux x86-64/ARM64 with systemd, or macOS 14+ Apple Silicon")
    return {"target": target, "system": system, "architecture": architecture, "requirements": requirement,
            "home": str(Path.home()), "protocol_version": PROTOCOL}


def extract_package(data, expected, root, target):
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise ValueError("Runtime package integrity check failed")
    destination = root / "versions" / actual
    if destination.exists():
        manifest = json.loads((destination / "manifest.json").read_text())
        if manifest["target"] != target or manifest["protocol_version"] != PROTOCOL:
            raise ValueError("Runtime package is incompatible with this host")
        for name, checksum in manifest["files"].items():
            path = destination / name
            if path.is_symlink() or destination not in path.resolve().parents or hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
                raise ValueError("Installed runtime integrity check failed")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".install-", dir=destination.parent))
    try:
        seen, total = set(), 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for member in archive:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not member.isfile() or member.name in seen:
                    raise ValueError("Unsafe runtime package member")
                total += member.size
                if total > MAX_PACKAGE or member.size > MAX_PACKAGE:
                    raise ValueError("Runtime package exceeds size limit")
                destination_file = staging / str(path)
                destination_file.parent.mkdir(parents=True, exist_ok=True)
                with destination_file.open("xb") as stream:
                    shutil.copyfileobj(archive.extractfile(member), stream)
                destination_file.chmod(0o700 if member.mode & 0o111 else 0o600)
                seen.add(member.name)
        manifest = json.loads((staging / "manifest.json").read_text())
        if manifest["target"] != target or manifest["protocol_version"] != PROTOCOL or manifest["codex_version"] != "0.147.0":
            raise ValueError("Runtime package is incompatible with this host or controller")
        for name, checksum in manifest["files"].items():
            if name not in seen or hashlib.sha256((staging / name).read_bytes()).hexdigest() != checksum:
                raise ValueError("Runtime package file integrity check failed")
        if seen != set(manifest["files"]) | {"manifest.json"}:
            raise ValueError("Runtime package contains unverified files")
        for required in ("python/bin/python3", "source/ollama_code/runtime.py", "codex-app-server"):
            if required not in seen:
                raise ValueError("Runtime package is incomplete")
        os.replace(staging, destination)
        return destination
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def install(header, data):
    info = host_info()
    root = Path.home() / ".local/share/locus-runtime"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    current = root / "current"
    # An update cannot replace a runtime while billable or external work is active.
    if (root / "endpoint.json").exists():
        import urllib.error
        import urllib.request
        endpoint = json.loads((root / "endpoint.json").read_text())
        secret_path = root / "runtime-secrets.json"
        if secret_path.exists():
            token = json.loads(secret_path.read_text()).get("controller_token", "")
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                request = urllib.request.Request(endpoint["url"] + "/api/runtime", headers={"X-Locus-Token": token})
                with opener.open(request, timeout=3) as response:
                    status = json.load(response)
                if any(worker["state"] not in {"idle", "paused", "completed", "interrupted"} for worker in status["workers"]):
                    raise ValueError("Pause and drain active agents before updating this runtime")
            except (urllib.error.URLError, TimeoutError):
                pass
    package = extract_package(data, header["sha256"], root, info["target"])
    python = str(package / "python/bin/python3")
    environment = {"PYTHONPATH": str(package / "source") + ":" + str(package / "site-packages"),
                   "OLLAMA_CODE_HOME": str(root / "profile"), "LOCUS_CODEX_HOME": str(root / "accounts"),
                   "LOCUS_CODEX_APP_SERVER_PATH": str(package / "codex-app-server"),
                   "LOCUS_DOCUMENT_COORDINATOR": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1"}
    workspaces = root / "workspaces"
    workspaces.mkdir(exist_ok=True, mode=0o700)
    port = int(header.get("port", 8793))
    if not 1024 <= port <= 65535:
        raise ValueError("Invalid runtime port")
    arguments = [python, "-m", "ollama_code.runtime", "--home", str(root), "--port", str(port), "--cwd", str(workspaces)]
    if info["system"] == "Linux":
        unit = Path.home() / ".config/systemd/user/locus-runtime.service"
        unit.parent.mkdir(parents=True, exist_ok=True)
        def quoted(value):
            return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n') + '"'
        text = "[Unit]\nDescription=Locus independent agents\nAfter=network-online.target\n[Service]\nType=simple\n"
        text += "ExecStart=" + " ".join(quoted(value) for value in arguments) + "\n"
        text += "\n".join("Environment=" + quoted(key + "=" + value) for key, value in environment.items())
        text += "\nRestart=on-failure\nRestartSec=5\nKillMode=control-group\nTimeoutStopSec=30\nUMask=0077\n[Install]\nWantedBy=default.target\n"
        unit.write_text(text)
        unit.chmod(0o600)
        commands = [["systemctl", "--user", "daemon-reload"], ["systemctl", "--user", "enable", "locus-runtime"], ["systemctl", "--user", "restart", "locus-runtime"]]
    else:
        unit = Path.home() / "Library/LaunchAgents/io.sparktales.locus.runtime.remote.plist"
        unit.parent.mkdir(parents=True, exist_ok=True)
        unit.write_bytes(plistlib.dumps({"Label": "io.sparktales.locus.runtime.remote", "ProgramArguments": arguments,
                                        "EnvironmentVariables": environment, "RunAtLoad": True, "KeepAlive": True,
                                        "ThrottleInterval": 10, "ProcessType": "Background"}))
        unit.chmod(0o600)
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(unit)], capture_output=True)
        commands = [["launchctl", "bootstrap", f"gui/{os.getuid()}", str(unit)]]
    for command in commands:
        result = subprocess.run(command, capture_output=True)
        if result.returncode:
            raise ValueError("The host's service manager could not start Locus")
    if current.is_symlink():
        previous = root / "previous"
        previous.unlink(missing_ok=True)
        previous.symlink_to(current.resolve())
        current.unlink()
    current.symlink_to(package)
    import time
    for _ in range(100):
        if (root / "runtime-secrets.json").exists():
            secrets = json.loads((root / "runtime-secrets.json").read_text())
            if secrets.get("controller_token"):
                return {**info, "root": str(root), "port": port, "package": header["sha256"], "token": secrets["controller_token"]}
        time.sleep(.2)
    raise ValueError("The runtime did not become ready")


def main():
    header = json.loads(sys.stdin.buffer.readline(16384))
    if header.get("action") == "control":
        info = host_info()
        action = header.get("control")
        if action not in {"stop", "start"}:
            raise ValueError("Unknown runtime control")
        if info["system"] == "Linux":
            command = ["systemctl", "--user", action, "locus-runtime"]
        else:
            path = str(Path.home() / "Library/LaunchAgents/io.sparktales.locus.runtime.remote.plist")
            command = ["launchctl", "bootout" if action == "stop" else "bootstrap", f"gui/{os.getuid()}", path]
        completed = subprocess.run(command, capture_output=True)
        if completed.returncode:
            raise ValueError("The host's service manager could not change runtime state")
        result = {"ok": True}
    elif header.get("action") == "validate":
        result = host_info()
    else:
        size = int(header.get("size", 0))
        if not 0 < size <= MAX_PACKAGE:
            raise ValueError("Invalid package size")
        result = install(header, sys.stdin.buffer.read(size + 1))
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"error": str(error)}))
        raise SystemExit(1) from None
