#!/usr/bin/env python3
"""Exercise an installed package with a local model fixture and an isolated profile.

--service-manager installs a disposable, uniquely named user service, then removes
only that service/profile. No provider accounts, SSH hosts, or desktop data are used.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import platform
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PackageRemoteRuntime import digest, host_target

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))
from ollama_code import runtime_install as installer


class FixtureProvider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body.get("messages", [])
        if any("Turn the explicitly selected correction" in str(m.get("content", "")) for m in messages):
            delta = {"content": json.dumps({"check": {"id": "ready", "kind": "file_contains", "path": "result.txt",
                                                     "value": "ready", "requirement": "The result contains ready"},
                                           "verification_limits": "Exact text only."})}
            finish = "stop"
        elif messages and messages[-1].get("role") == "tool":
            delta, finish = {"content": "Created result.txt containing ready."}, "stop"
        else:
            delta = {"tool_calls": [{"index": 0, "id": "fixture-write", "type": "function",
                                     "function": {"name": "write_file", "arguments": json.dumps({"path": "result.txt", "content": "ready\n"})}}]}
            finish = "tool_calls"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for item in [{"choices": [{"delta": delta, "finish_reason": None}]},
                     {"choices": [{"delta": {}, "finish_reason": finish}], "usage": {"prompt_tokens": 10, "completion_tokens": 2}}]:
            self.wfile.write(("data: " + json.dumps(item) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")


def failed_startup_package(package: Path, output: Path) -> str:
    """A valid fixture package that imports normally but fails service startup."""
    with tarfile.open(package, "r:gz") as source:
        manifest = json.load(source.extractfile("manifest.json"))
        with tarfile.open(output, "w:gz") as target:
            for member in source:
                if member.name == "manifest.json":
                    continue
                stream = source.extractfile(member)
                if member.name == "source/ollama_code/runtime.py":
                    data = stream.read()
                    # Future imports must remain first. Appending this before the
                    # existing main guard triggers failure only during startup.
                    needle = b'if __name__ == "__main__":'
                    if needle not in data:
                        raise ValueError("Cannot locate the runtime entry point for the rollback fixture")
                    data = data.replace(needle, b'if __name__ == "__main__":\n    raise SystemExit("fixture startup failure")\n\n' + needle)
                    manifest["files"][member.name] = hashlib.sha256(data).hexdigest()
                    member.size = len(data)
                    stream = io.BytesIO(data)
                target.addfile(member, stream)
            data = json.dumps(manifest, sort_keys=True).encode()
            member = tarfile.TarInfo("manifest.json")
            member.size, member.mode = len(data), 0o600
            target.addfile(member, io.BytesIO(data))
    return digest(output)


def scenario(base: str, token: str, provider_port: int, workspace: Path) -> dict:
    from ollama_code.runtime_snapshots import archive, preview
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(method, path, body=None):
        request = urllib.request.Request(base + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"X-Locus-Token": token, "Content-Type": "application/json"})
        with opener.open(request, timeout=90) as response:
            return json.load(response)

    try:
        opener.open(base + "/api/runtime", timeout=5)
        raise AssertionError("The runtime accepted an unauthenticated request")
    except urllib.error.HTTPError as error:
        assert error.code in {401, 403}
    for account in ("smoke-one", "smoke-two"):
        state = call("GET", "/api/chatgpt/account?account_id=" + account)
        assert state["runtime_available"] and state["status"] == "signed_out", "Pinned helper handshake failed: " + str(state.get("message", state["status"]))
    (workspace / "README.md").write_text("Disposable runtime release validation")
    review = preview(workspace)
    approved = {"id": "initial", "version": 1, "revision": 2, "state": "approved", "workspace_root": str(workspace),
                "correction": "Always create result.txt.", "source": {"session_id": "source"},
                "scope": {"agent_id": "", "files": []}, "verification_limits": "Presence only.",
                "approved_at": time.time(), "created_at": time.time(),
                "check": {"id": "exists", "kind": "file_exists", "path": "result.txt", "requirement": "The result exists"}}
    configuration = {"keep_running": True, "permissions": {"mode": "bypass"}, "reusable_checks": [approved],
                     "provider": {"provider": "remote", "model": "fixture", "account_id": "fixture",
                                  "base_url": f"http://127.0.0.1:{provider_port}/v1", "api_key": "fixture"},
                     "schedule": {"name": "Package validation", "prompt": "Create result.txt containing ready.",
                                  "mode": "work", "runner": "solo", "provider": "remote", "provider_account_id": "fixture",
                                  "model": "fixture", "timezone": "UTC",
                                  "rule": {"kind": "interval", "every": 1, "unit": "hours", "anchor": time.time() + 15}}}
    deployed = call("POST", "/api/runtime/snapshots/import", {"deployment_id": "package-smoke", "snapshot": review,
                                                            "archive": base64.b64encode(archive(review)).decode(), "configuration": configuration})
    call("POST", "/api/runtime/detach", {})

    def result(count):
        returned = {"runs": []}
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                returned = call("GET", "/api/runtime/snapshots/" + deployed["id"])
            except urllib.error.HTTPError as error:
                if error.code != 409:
                    raise
                error.close()
                time.sleep(.2)
                continue
            if len(returned["runs"]) >= count and all(run["state"] == "completed" for run in returned["runs"]):
                return returned
            time.sleep(.2)
        health = call("GET", "/api/runtime")
        diagnostic = {"expected_runs": count, "run_states": [run["state"] for run in returned["runs"]],
                      "paused": health["paused"], "worker_states": [worker["state"] for worker in health["workers"]]}
        raise AssertionError("Package work did not complete: " + json.dumps(diagnostic))

    returned = result(1)
    assert returned["task_contracts"] and all(task["verification_status"] == "passed" for task in returned["task_contracts"])
    assert returned["accounting"]["total_tokens"] > 0 and returned["accounting"]["estimated_api_cost"] is None
    assert not (workspace / "result.txt").exists()
    session = returned["runs"][0]["session_id"]
    worker = "/api/runtime/workers/" + session
    correction = "Keep result.txt ready."
    call("POST", worker + "/commands", {"type": "user_message", "text": correction, "request_id": "correction"})
    result(2)
    proposal = call("POST", worker + "/api/reusable-checks/propose", {"session_id": session, "correction": correction})
    assert proposal["state"] == "proposed"
    saved = call("PATCH", worker + "/api/reusable-checks/" + proposal["id"], {"action": "approve", "expected_revision": proposal["revision"]})
    call("POST", worker + "/commands", {"type": "user_message", "text": "Create the next result.", "request_id": "next-task"})
    returned = result(3)
    latest = max(returned["runs"], key=lambda run: run["created_at"])
    task = next(task for task in returned["task_contracts"] if task["id"] == "run:" + latest["id"])
    assert task["verification_status"] == "passed"
    assert any(check["id"] == saved["id"] and check["version"] == saved["version"] for check in task["reusable_checks"])
    assert "check_generation" in returned["accounting"]["by_purpose"]
    call("POST", "/api/runtime/pause", {})
    assert call("GET", "/api/runtime")["active_work"] == 0
    return {"run_ids": sorted(run["id"] for run in returned["runs"]), "total_tokens": returned["accounting"]["total_tokens"],
            "checks": {"authenticated_loopback": True, "helper_handshake_without_accounts": True, "detached_schedule": True,
                       "verified_result": True, "usage_coverage": True, "approved_correction_enforced": True}}


def run(package: Path, checksum: str, output: Path, *, service_manager: bool, exercise_rollback: bool) -> dict:
    if digest(package) != checksum:
        raise ValueError("The smoke-test package checksum does not match")
    validation_id = uuid.uuid4().hex
    report = {"version": 1, "target": host_target(), "package_sha256": checksum, "provider": "deterministic-fixture",
              "mode": "user-service" if service_manager else "process", "passed": False, "checks": {}}
    provider = ThreadingHTTPServer(("127.0.0.1", 0), FixtureProvider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    process = None
    with tempfile.TemporaryDirectory(prefix="locus-package-smoke-") as temporary:
        work = Path(temporary)
        log = (work / "process.log").open("w")
        os.environ["OLLAMA_CODE_HOME"] = str(work / "controller-profile")
        os.environ["LOCUS_CODEX_HOME"] = str(work / "controller-accounts")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        header = {"action": "install", "sha256": checksum, "port": port, "validation_id": validation_id}
        info = {"system": platform.system(), "target": host_target()}
        root = installer.deployment_paths(info, validation_id)[0] if service_manager else work / "runtime"
        try:
            if service_manager:
                installed = installer.install(header, package.read_bytes())
                token = installed["token"]
            else:
                root.mkdir(mode=0o700)
                (root / "workspaces").mkdir()
                extracted = installer.extract_package(package.read_bytes(), checksum, root, host_target())
                _, environment = installer.service_definition(info, root, extracted, port, "fixture")
                process = subprocess.Popen([str(extracted / "python/bin/python3"), "-m", "ollama_code.runtime", "--home", str(root),
                                            "--port", str(port), "--cwd", str(root / "workspaces")],
                                           env={**os.environ, **environment}, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                installer.wait_ready(root, port, checksum)
                token = installer.private_read(root)["controller_token"]
            source = work / "project"
            source.mkdir()
            report.update(scenario(f"http://127.0.0.1:{port}", token, provider.server_port, source))
            if service_manager:
                control = {"action": "control", "validation_id": validation_id}
                installer.control({**control, "control": "stop"})
                installer.control({**control, "control": "start"})
                installer.wait_ready(root, port, checksum)
                returned = installer.api_request(root, port, path="/api/runtime/snapshots/package-smoke")
                assert sorted(run["id"] for run in returned["runs"]) == report["run_ids"]
                assert returned["accounting"]["total_tokens"] == report["total_tokens"]
                report["checks"]["service_restart_preserves_results_and_usage"] = True
                if exercise_rollback:
                    candidate = work / "failed-startup.tar.gz"
                    candidate_sha = failed_startup_package(package, candidate)
                    try:
                        installer.install({**header, "sha256": candidate_sha}, candidate.read_bytes())
                    except ValueError as error:
                        assert "were restored" in str(error), str(error)
                    else:
                        raise AssertionError("The startup failure fixture unexpectedly installed")
                    installer.wait_ready(root, port, checksum)
                    returned = installer.api_request(root, port, path="/api/runtime/snapshots/package-smoke")
                    assert sorted(run["id"] for run in returned["runs"]) == report["run_ids"]
                    assert returned["accounting"]["total_tokens"] == report["total_tokens"]
                    report["checks"]["failed_update_restores_service_and_usage"] = True
            elif exercise_rollback:
                raise ValueError("Rollback validation requires --service-manager")
            report["passed"] = True
        finally:
            try:
                if service_manager and root.exists():
                    installer.control({"action": "control", "control": "remove-validation", "validation_id": validation_id})
                elif process is not None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                report["checks"]["isolated_cleanup"] = True
            except Exception:
                report["passed"] = False
                report["checks"]["isolated_cleanup"] = False
                raise
            finally:
                provider.shutdown()
                provider.server_close()
                log.close()
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--service-manager", action="store_true")
    parser.add_argument("--exercise-rollback", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.package, args.sha256, args.output, service_manager=args.service_manager, exercise_rollback=args.exercise_rollback)))


if __name__ == "__main__":
    main()
