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
    if sys.version_info < (3, 10):  # noqa: UP036 - bootstrap runs on the host Python
        raise ValueError("Install Python 3.10 or newer for runtime setup on this host")
    system, architecture = platform.system(), platform.machine()
    if system == "Linux" and architecture in {"x86_64", "aarch64", "arm64"}:
        libc, version = platform.libc_ver()
        if libc != "glibc" or tuple(int(part) for part in version.split(".")[:2]) < (2, 28):
            raise ValueError("Linux runtime packages require glibc 2.28 or newer")
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
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".install-", dir=destination.parent))
    try:
        seen, total = set(), 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for member in archive:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or str(path) != member.name or not member.isfile() or member.name in seen:
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
        if not isinstance(manifest.get("files"), dict) or not manifest["files"]:
            raise ValueError("Runtime package manifest is invalid")
        for name, checksum in manifest["files"].items():
            if not isinstance(name, str) or str(PurePosixPath(name)) != name or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
                raise ValueError("Unsafe runtime manifest path")
            if name not in seen or hashlib.sha256((staging / name).read_bytes()).hexdigest() != checksum:
                raise ValueError("Runtime package file integrity check failed")
        if seen != set(manifest["files"]) | {"manifest.json"}:
            raise ValueError("Runtime package contains unverified files")
        for required in ("python/bin/python3", "source/ollama_code/runtime.py", "codex-app-server", "codex-code-mode-host"):
            if required not in seen:
                raise ValueError("Runtime package is incomplete")
        if destination.exists():
            if destination.is_symlink():
                raise ValueError("Installed runtime integrity check failed")
            actual_files = set()
            for path in destination.rglob("*"):
                if path.is_symlink():
                    raise ValueError("Installed runtime integrity check failed")
                if path.is_file():
                    actual_files.add(path.relative_to(destination).as_posix())
            if actual_files != seen or (destination / "manifest.json").read_bytes() != (staging / "manifest.json").read_bytes():
                raise ValueError("Installed runtime integrity check failed")
            for name, checksum in manifest["files"].items():
                if hashlib.sha256((destination / name).read_bytes()).hexdigest() != checksum:
                    raise ValueError("Installed runtime integrity check failed")
        else:
            os.replace(staging, destination)
        return destination
    finally:
        if staging.exists():
            shutil.rmtree(staging)



def deployment_paths(info, validation_id=None):
    import re
    if validation_id is not None and not re.fullmatch(r"[a-f0-9]{32}", validation_id):
        raise ValueError("Invalid isolated runtime validation identifier")
    root = Path.home() / ".local/share/locus-runtime"
    label = "locus-runtime" if info["system"] == "Linux" else "io.sparktales.locus.runtime.remote"
    if validation_id:
        root = Path.home() / ".local/share/locus-runtime-validation" / validation_id
        label = "locus-runtime-validation-" + validation_id if info["system"] == "Linux" else "io.sparktales.locus.runtime.validation." + validation_id
    unit = (Path.home() / ".config/systemd/user" / (label + ".service") if info["system"] == "Linux"
            else Path.home() / "Library/LaunchAgents" / (label + ".plist"))
    return root, unit, label


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".runtime-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def private_read(root):
    path = root / "runtime-secrets.json"
    if not path.exists():
        return {}
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError("Runtime credentials must be a user-only regular file")
    return json.loads(path.read_text())


def set_paused(root, value):
    private = private_read(root)
    private["paused"] = value
    atomic_write(root / "runtime-secrets.json", json.dumps(private).encode())


def api_request(root, port, method="GET", path="/api/runtime"):
    import urllib.error
    import urllib.request
    token = private_read(root).get("controller_token")
    if not token:
        return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(f"http://127.0.0.1:{port}" + path,
                                     headers={"X-Locus-Token": token, "Content-Type": "application/json"},
                                     method=method, data=b"{}" if method == "POST" else None)
    try:
        with opener.open(request, timeout=2) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None


def service_running(info, label):
    command = (["systemctl", "--user", "is-active", "--quiet", label] if info["system"] == "Linux"
               else ["launchctl", "print", f"gui/{os.getuid()}/{label}"])
    return subprocess.run(command, capture_output=True, timeout=15).returncode == 0


def service_control(info, unit, label, action):
    if action == "stop" and not service_running(info, label):
        return
    if info["system"] == "Linux":
        commands = [["systemctl", "--user", "daemon-reload"], ["systemctl", "--user", action, label]]
        if action == "start":
            commands.insert(1, ["systemctl", "--user", "enable", label])
    else:
        commands = [["launchctl", "bootout" if action == "stop" else "bootstrap", f"gui/{os.getuid()}", str(unit)]]
    for command in commands:
        if subprocess.run(command, capture_output=True, timeout=35).returncode:
            raise ValueError("The host's service manager could not " + action + " Locus")


def service_definition(info, root, package, port, label):
    python = str(package / "python/bin/python3")
    environment = {"PYTHONPATH": str(package / "source") + ":" + str(package / "site-packages"),
                   "OLLAMA_CODE_HOME": str(root / "profile"), "LOCUS_CODEX_HOME": str(root / "accounts"),
                   "LOCUS_CODEX_APP_SERVER_PATH": str(package / "codex-app-server"),
                   "LOCUS_CODEX_HELPER_KIND": "cli",
                   "LOCUS_RUNTIME_PACKAGE_ID": package.name, "LOCUS_DOCUMENT_COORDINATOR": "1",
                   "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1"}
    arguments = [python, "-m", "ollama_code.runtime", "--home", str(root), "--port", str(port), "--cwd", str(root / "workspaces")]
    if info["system"] == "Linux":
        def quoted(value):
            return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n') + '"'
        text = "[Unit]\nDescription=Locus independent agents\nAfter=network-online.target\n[Service]\nType=simple\n"
        text += "ExecStart=" + " ".join(quoted(value) for value in arguments) + "\n"
        text += "\n".join("Environment=" + quoted(key + "=" + value) for key, value in environment.items())
        text += "\nRestart=on-failure\nRestartSec=5\nKillMode=control-group\nTimeoutStopSec=30\nUMask=0077\n[Install]\nWantedBy=default.target\n"
        return text.encode(), environment
    return plistlib.dumps({"Label": label, "ProgramArguments": arguments, "EnvironmentVariables": environment,
                           "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10, "ProcessType": "Standard",
                           "WorkingDirectory": str(root / "workspaces"), "Umask": 0o077, "ExitTimeOut": 30,
                           "StandardOutPath": str(root / "service.log"), "StandardErrorPath": str(root / "service.log")}), environment


def assert_idle(status):
    if status and (status.get("active_work") or any(worker["state"] not in {"idle", "paused", "completed", "interrupted"} for worker in status.get("workers", []))):
        raise ValueError("Pause and drain active agents before updating this runtime")


def wait_ready(root, port, expected):
    import time
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        ready = api_request(root, port)
        if ready and ready.get("protocol_version") == PROTOCOL and ready.get("package_id") == expected:
            return ready
        time.sleep(.2)
    raise ValueError("The runtime did not become ready")


def set_current(root, name, package):
    path = root / name
    if path.exists() and not path.is_symlink():
        raise ValueError("Runtime version references must be symlinks")
    if package is None:
        path.unlink(missing_ok=True)
        return
    import secrets
    temporary = root / (".link-" + secrets.token_hex(8))
    try:
        temporary.symlink_to(package)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def backup_databases(root, journal):
    import sqlite3
    from contextlib import closing
    folder = root / "install-backups" / journal["id"]
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    backups = []
    for path in (root / "profile").rglob("*.sqlite3"):
        if path.is_symlink():
            raise ValueError("Runtime databases cannot be symlinks")
        relative = path.relative_to(root)
        output = folder / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as source, closing(sqlite3.connect(output)) as target:
            source.backup(target)
        output.chmod(0o600)
        backups.append(str(relative))
    journal["databases"] = backups
    atomic_write(root / "installation.json", json.dumps(journal).encode())


def rollback(info, root, unit, label, journal):
    import base64
    # No new work is admitted while installation.json exists. Restore only the
    # databases captured after the prior service stopped, retaining their backups.
    service_control(info, unit, label, "stop")
    if "databases" in journal:
        # Candidate startup may create a new database. It contains no admitted
        # work and must not leave a newer schema behind for the previous package.
        baseline = set(journal["databases"])
        for path in (root / "profile").rglob("*.sqlite3"):
            if str(path.relative_to(root)) not in baseline:
                for suffix in ("", "-wal", "-shm"):
                    Path(str(path) + suffix).unlink(missing_ok=True)
    for relative in journal.get("databases", []):
        path = root / relative
        backup = root / "install-backups" / journal["id"] / relative
        if not relative.startswith("profile/") or ".." in PurePosixPath(relative).parts:
            raise ValueError("Invalid runtime database backup path")
        for suffix in ("-wal", "-shm"):
            Path(str(path) + suffix).unlink(missing_ok=True)
        atomic_write(path, backup.read_bytes())
    if journal["unit"] is None:
        if info["system"] == "Linux":
            subprocess.run(["systemctl", "--user", "disable", label], capture_output=True, timeout=15)
        unit.unlink(missing_ok=True)
    else:
        atomic_write(unit, base64.b64decode(journal["unit"], validate=True))
    set_current(root, "current", journal["previous_package"])
    set_current(root, "previous", journal.get("previous_link"))
    set_paused(root, journal["was_paused"])
    if journal["was_running"] and journal["unit"] is not None:
        service_control(info, unit, label, "start")
        wait_ready(root, journal["previous_port"], Path(journal["previous_package"]).name)
    (root / "installation.json").unlink()
    if journal["was_running"] and not journal["was_paused"]:
        api_request(root, journal["previous_port"], "POST", "/api/runtime/resume")


def install(header, data):
    import base64
    import fcntl
    import secrets
    info = host_info()
    root, unit, label = deployment_paths(info, header.get("validation_id"))
    if root.is_symlink() or unit.is_symlink():
        raise ValueError("Runtime installation paths cannot be symlinks")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / ".install.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another runtime installation or control operation is in progress") from None
        pending = root / "installation.json"
        if pending.exists():
            journal = json.loads(pending.read_text())
            assert_idle(api_request(root, journal["port"]))
            rollback(info, root, unit, label, journal)
        port = int(header.get("port", 8793))
        if not 1024 <= port <= 65535:
            raise ValueError("Invalid runtime port")
        endpoint = root / "endpoint.json"
        previous_port = int(json.loads(endpoint.read_text())["url"].rsplit(":", 1)[1]) if endpoint.exists() else port
        status = api_request(root, previous_port)
        assert_idle(status)
        was_running = service_running(info, label)
        if was_running and status is None:
            raise ValueError("Stop the unresponsive runtime explicitly before updating it")
        if status and not status.get("paused"):
            raise ValueError("Pause this runtime before installing an update")
        package = extract_package(data, header["sha256"], root, info["target"])
        helper = subprocess.run([str(package / "codex-app-server"), "--version"], capture_output=True, text=True, timeout=20)
        if helper.returncode or helper.stdout.strip() != "codex-cli 0.147.0":
            raise ValueError("The packaged ChatGPT helper does not match pinned version 0.147.0")
        definition, environment = service_definition(info, root, package, port, label)
        with tempfile.TemporaryDirectory(prefix=".preflight-", dir=root) as temporary:
            check_environment = {**os.environ, **environment, "OLLAMA_CODE_HOME": str(Path(temporary) / "profile"),
                                 "LOCUS_CODEX_HOME": str(Path(temporary) / "accounts")}
            check = subprocess.run([str(package / "python/bin/python3"), "-s", "-c", 'import sys; assert sys.version_info >= (3,10); import ollama_code.runtime'],
                                   env=check_environment, cwd=temporary, capture_output=True, timeout=40)
            if check.returncode:
                raise ValueError("The packaged Python runtime cannot import its required dependencies")
        current = root / "current"
        previous_package = str(current.resolve()) if current.is_symlink() else None
        if previous_package is not None and Path(previous_package).parent != root / "versions":
            raise ValueError("The current package is outside the runtime version directory")
        journal = {"version": 1, "id": secrets.token_hex(16), "package": package.name, "port": port,
                   "previous_package": previous_package, "previous_port": previous_port,
                   "previous_link": str((root / "previous").resolve()) if (root / "previous").is_symlink() else None,
                   "unit": base64.b64encode(unit.read_bytes()).decode() if unit.exists() else None,
                   "was_running": was_running, "was_paused": bool(private_read(root).get("paused", False))}
        if journal["unit"] is not None and previous_package is None:
            raise ValueError("The existing service has no verified current package; inspect it before installing")
        atomic_write(pending, json.dumps(journal).encode())
        try:
            service_control(info, unit, label, "stop")
            backup_databases(root, journal)
            set_paused(root, True)
            (root / "workspaces").mkdir(exist_ok=True, mode=0o700)
            atomic_write(unit, definition)
            service_control(info, unit, label, "start")
            wait_ready(root, port, package.name)
            if previous_package and previous_package != str(package):
                set_current(root, "previous", previous_package)
            set_current(root, "current", str(package))
            pending.unlink()
        except BaseException as error:
            try:
                rollback(info, root, unit, label, journal)
            except Exception:
                raise ValueError("Runtime update failed and recovery needs attention; the installation journal and database backups were retained") from None
            raise ValueError("Runtime update failed; the previous service and database state were restored") from error
        # Existing installations deliberately stay paused. First installs have
        # no saved work, so enable scheduling only after the transaction commits.
        if journal["unit"] is None:
            api_request(root, port, "POST", "/api/runtime/resume")
        return {**info, "root": str(root), "port": port, "package": package.name,
                "token": private_read(root)["controller_token"]}


def control(header):
    import fcntl
    info = host_info()
    root, unit, label = deployment_paths(info, header.get("validation_id"))
    action = header.get("control")
    if action not in {"stop", "start", "remove-validation"} or (action == "remove-validation" and not header.get("validation_id")):
        raise ValueError("Unknown runtime control")
    if not root.is_dir() or root.is_symlink() or unit.is_symlink():
        raise ValueError("Runtime installation was not found")
    with (root / ".install.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another runtime installation or control operation is in progress") from None
        if (root / "installation.json").exists() and action == "start":
            raise ValueError("Retry the interrupted installation before starting work")
        service_control(info, unit, label, "stop" if action == "remove-validation" else action)
        if action == "remove-validation":
            if info["system"] == "Linux":
                subprocess.run(["systemctl", "--user", "disable", label], capture_output=True, timeout=15)
            unit.unlink(missing_ok=True)
            shutil.rmtree(root)
    return {"ok": True}


def main():
    header = json.loads(sys.stdin.buffer.readline(16384))
    if header.get("action") == "control":
        result = control(header)
    elif header.get("action") == "validate":
        result = host_info()
    elif header.get("action") == "install":
        size = int(header.get("size", 0))
        if not 0 < size <= MAX_PACKAGE:
            raise ValueError("Invalid package size")
        data = sys.stdin.buffer.read(size + 1)
        if len(data) != size:
            raise ValueError("The runtime upload was interrupted or exceeded its declared size")
        result = install(header, data)
    else:
        raise ValueError("Unknown installer action")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"error": str(error)}))
        raise SystemExit(1) from None
