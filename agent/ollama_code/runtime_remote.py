"""Owned-host deployment over OpenSSH. No listener is exposed to the network."""
from __future__ import annotations

import base64
import contextlib
import json
import re
import shlex
import socket
import subprocess
import threading
import time
import uuid
from pathlib import Path

import requests

from . import runtime_install, runtime_snapshots


def ssh_arguments(host: str) -> list[str]:
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:\[\]-]{0,240}", host):
        raise ValueError("Use an existing SSH host name or user@host")
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", host]


class RemoteRuntimes:
    def __init__(self, runtime):
        self.runtime = runtime
        self.tunnels = {}
        self.login_tunnels = {}
        self.lock = threading.RLock()

    def records(self):
        with self.runtime.store.runs._connect(readonly=True) as db:
            return [json.loads(row[0]) for row in db.execute("SELECT payload FROM runtime_deployments ORDER BY created_at DESC")]

    def record(self, key):
        found = next((row for row in self.records() if row["id"] == key), None)
        if not found:
            raise ValueError("Unknown runtime connection")
        return found

    def save(self, value):
        with self.runtime.store.runs._connect() as db:
            db.execute("INSERT INTO runtime_deployments VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                       (value["id"], json.dumps(value), time.time()))
        return value

    def installer(self, host, header, payload=b""):
        source = Path(runtime_install.__file__).read_text()
        command = "python3 -c " + shlex.quote(source)
        try:
            result = subprocess.run(ssh_arguments(host) + [command], input=json.dumps(header).encode() + b"\n" + payload,
                                    capture_output=True, timeout=300)
        except (subprocess.TimeoutExpired, OSError):
            raise ValueError("SSH could not reach this host using your existing authentication") from None
        try:
            response = json.loads(result.stdout)
        except (ValueError, UnicodeError):
            raise ValueError("SSH setup failed. Verify this host's key and authentication using OpenSSH, then retry.") from None
        if result.returncode or response.get("error"):
            raise ValueError(response.get("error", "The remote installer failed"))
        return response

    def validate(self, host):
        return self.installer(host, {"action": "validate"})

    def install(self, host, package_path, expected):
        package = Path(package_path).expanduser().resolve(strict=True)
        if package.stat().st_size > runtime_install.MAX_PACKAGE or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError("Provide a supported release package and its SHA-256")
        data = package.read_bytes()
        if runtime_snapshots.digest(data) != expected:
            raise ValueError("Local package integrity check failed")
        with self.lock:
            result = self.installer(host, {"action": "install", "sha256": expected, "size": len(data)}, data)
            key = next((row["id"] for row in self.records() if row["host"] == host), uuid.uuid4().hex)
            token = result.pop("token")
            self.runtime.private.set(f"remote:{key}", {"token": token})
            old = next((row for row in self.records() if row["id"] == key), {})
            record = self.save({**old, **result, "id": key, "host": host, "last_connection_at": None,
                                "deployments": old.get("deployments", [])})
            self.disconnect(key)
            self.status(key)
            return self.record(record["id"])

    def connect(self, key):
        with self.lock:
            existing = self.tunnels.get(key)
            if existing and existing[0].poll() is None:
                return existing[1]
            record = self.record(key)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            base = ssh_arguments(record["host"])
            args = base[:-2] + ["-N", "-o", "ExitOnForwardFailure=yes", "-L", f"127.0.0.1:{port}:127.0.0.1:{record['port']}"] + base[-2:]
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.tunnels[key] = (process, port)
            for _ in range(100):
                if process.poll() is not None:
                    raise ValueError("SSH tunnel failed; check the host key, authentication and runtime service")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        return port
                except OSError:
                    time.sleep(.1)
            self.disconnect(key)
            raise ValueError("The SSH tunnel did not become ready")

    def request(self, key, method, path, body=None, timeout=60):
        if not path.startswith("/api/") or ".." in path or "#" in path:
            raise ValueError("Invalid runtime API path")
        port = self.connect(key)
        secret = self.runtime.private.read().get(f"remote:{key}") or {}
        with requests.Session() as client:
            client.trust_env = False
            try:
                response = client.request(method, f"http://127.0.0.1:{port}{path}", json=body,
                                          headers={"X-Locus-Token": secret.get("token", "")}, timeout=timeout, allow_redirects=False)
                result = response.json()
            except (requests.RequestException, ValueError):
                raise ValueError("The remote runtime did not respond; its work may still be running") from None
            if not response.ok:
                raise ValueError(str(result.get("detail", "Remote request failed")))
            return result

    def status(self, key):
        with self.lock:
            result = self.request(key, "GET", "/api/runtime")
            if result.get("protocol_version") != 1:
                raise ValueError("This runtime version is incompatible with this controller")
            record = self.record(key)
            record.update(last_connection_at=time.time(), runtime_id=result["id"])
            self.save(record)
            return {**result, "connection": record}

    def control(self, key, action):
        if action == "pause":
            return self.request(key, "POST", "/api/runtime/pause", {})
        if action == "stop":
            self.request(key, "POST", "/api/runtime/pause", {})
            for _ in range(60):
                status = self.status(key)
                if not status.get("active_work", 0):
                    break
                time.sleep(.5)
            else:
                raise ValueError("Work is still checkpointing; retry Stop after it drains")
        result = self.installer(self.record(key)["host"], {"action": "control", "control": action})
        self.disconnect(key)
        return result

    def login(self, key, account_id, method):
        if method == "browser":
            existing = self.login_tunnels.pop(key, None)
            if existing:
                existing.terminate()
            base = ssh_arguments(self.record(key)["host"])
            args = base[:-2] + ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:1455:127.0.0.1:1455"] + base[-2:]
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.login_tunnels[key] = process
            time.sleep(.3)
            if process.poll() is not None:
                raise ValueError("Browser login needs local port 1455 available for its SSH tunnel")
        elif method != "device_code":
            raise ValueError("Choose device_code or browser login")
        return self.request(key, "POST", "/api/chatgpt/login/start", {"account_id": account_id, "method": method})

    def disconnect(self, key):
        tunnel = self.tunnels.pop(key, None)
        if tunnel:
            tunnel[0].terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                tunnel[0].wait(timeout=3)
            if tunnel[0].poll() is None:
                tunnel[0].kill()
                tunnel[0].wait()

    def remove(self, key):
        with self.lock:
            # Removing a controller connection never deletes a remote workspace.
            self.disconnect(key)
            with self.runtime.store.runs._connect() as db:
                db.execute("DELETE FROM runtime_deployments WHERE id=?", (key,))
            self.runtime.private.set(f"remote:{key}", None)
            return {"ok": True}

    def deploy(self, key, review, configuration):
        with self.lock:
            deployment_id = uuid.uuid4().hex
            payload = {"deployment_id": deployment_id, "snapshot": review, "archive": base64.b64encode(runtime_snapshots.archive(review)).decode(),
                       "configuration": configuration}
            record = self.record(key)
            pending = {"id": deployment_id, "session_id": "", "workspace": "", "baseline": review, "state": "uploading", "created_at": time.time()}
            record["deployments"].append(pending)
            self.save(record)
            self.runtime.private.set(f"deployment:{deployment_id}", configuration)
            try:
                result = self.request(key, "POST", "/api/runtime/snapshots/import", payload, timeout=120)
            except ValueError:
                pending["state"] = "uncertain"
                self.save(record)
                raise ValueError("Deployment response was interrupted. Retry this saved deployment to reconcile its existing remote workspace.") from None
            pending.update(result)
            self.save(record)
            return result

    def retry_deployment(self, key, deployment_id):
        with self.lock:
            record = self.record(key)
            deployment = next((row for row in record["deployments"] if row["id"] == deployment_id), None)
            if not deployment:
                raise ValueError("Unknown deployment")
            review = deployment["baseline"]
            configuration = self.runtime.private.read().get(f"deployment:{deployment_id}")
            if configuration is None:
                raise ValueError("Reconfigure the selected accounts before retrying")
            payload = {"deployment_id": deployment_id, "snapshot": review, "configuration": configuration,
                       "archive": base64.b64encode(runtime_snapshots.archive(review)).decode()}
            result = self.request(key, "POST", "/api/runtime/snapshots/import", payload, timeout=120)
            deployment.update(result)
            self.save(record)
            return result

    def retrieve(self, key, deployment_id):
        with self.lock:
            record = self.record(key)
            deployment = next((row for row in record["deployments"] if row["id"] == deployment_id), None)
            if not deployment:
                raise ValueError("Unknown deployment")
            result = self.request(key, "GET", f"/api/runtime/snapshots/{deployment_id}", timeout=120)
            destination = self.runtime.root / "returns" / uuid.uuid4().hex
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            runtime_snapshots.unpack(base64.b64decode(result.pop("archive"), validate=True), destination, result["snapshot"]["files"])
            deployment["return"] = {**result, "directory": str(destination), "changes": runtime_snapshots.changes(deployment["baseline"], result["snapshot"])}
            self.save(record)
            return deployment["return"]
