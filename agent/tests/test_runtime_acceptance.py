"""Owned-host API fixture: schedule, disconnect, verified return, new correction."""

import base64
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
import requests

from ollama_code.runtime_snapshots import archive, preview
from ollama_code.runtime_store import PrivateStore


def test_closed_controller_schedule_and_correction_check(tmp_path):
    check = {
        "id": "ready",
        "kind": "file_contains",
        "path": "result.txt",
        "value": "ready",
        "requirement": "The result contains ready",
    }

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"data":[]}')

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = body.get("messages", [])
            if any(
                "Turn the explicitly selected correction" in str(message.get("content", ""))
                for message in messages
            ):
                delta, finish = (
                    {
                        "content": json.dumps(
                            {"check": check, "verification_limits": "Exact text only."}
                        )
                    },
                    "stop",
                )
            elif messages and messages[-1].get("role") == "tool":
                delta, finish = {"content": "Created result.txt containing ready."}, "stop"
            else:
                delta = {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "write-result",
                            "type": "function",
                            "function": {
                                "name": "write_file",
                                "arguments": json.dumps(
                                    {"path": "result.txt", "content": "ready\n"}
                                ),
                            },
                        }
                    ]
                }
                finish = "tool_calls"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for item in [
                {"choices": [{"delta": delta, "finish_reason": None}]},
                {
                    "choices": [{"delta": {}, "finish_reason": finish}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 2},
                },
            ]:
                self.wfile.write(("data: " + json.dumps(item) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    source = tmp_path / "source"
    source.mkdir()
    (source / "README.md").write_text("Fixture project")
    snapshot = preview(source)
    root = tmp_path / "runtime"
    token = PrivateStore(root).token()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    environment = {
        **os.environ,
        "OLLAMA_CODE_HOME": str(tmp_path / "profile"),
        "PYTHONPATH": str(Path(__file__).resolve().parents[1]),
        "LOCUS_CODEX_HOME": str(tmp_path / "codex"),
    }
    log = (tmp_path / "service.log").open("w+")
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "ollama_code.runtime",
            "--home",
            str(root),
            "--port",
            str(port),
            "--cwd",
            str(tmp_path),
        ],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
    )
    base = f"http://127.0.0.1:{port}"

    def connect():
        client = requests.Session()
        client.trust_env = False
        client.headers["X-Locus-Token"] = token
        return client

    client = connect()

    def call(method, path, **kwargs):
        response = client.request(method, base + path, timeout=45, **kwargs)
        assert response.ok, response.text
        return response.json()

    def wait_result(deployment, count):
        last = {}
        for _ in range(250):
            response = client.get(base + "/api/runtime/snapshots/" + deployment, timeout=5)
            if response.ok:
                last = response.json()
                if len(last["runs"]) >= count and all(
                    run["state"] == "completed" for run in last["runs"]
                ):
                    return last
            time.sleep(0.1)
        pytest.fail("Scheduled work did not complete: " + str(last))

    try:
        for _ in range(150):
            try:
                if client.get(base + "/api/runtime", timeout=0.3).ok:
                    break
            except requests.RequestException:
                pass
            time.sleep(0.1)
        initial = {
            "id": "initial",
            "version": 1,
            "revision": 2,
            "state": "approved",
            "workspace_root": str(source),
            "correction": "Always create result.txt.",
            "source": {"session_id": "source"},
            "scope": {"agent_id": "", "files": []},
            "check": {
                "id": "exists",
                "kind": "file_exists",
                "path": "result.txt",
                "requirement": "The result exists",
            },
            "verification_limits": "Presence only.",
            "approved_at": time.time(),
            "created_at": time.time(),
        }
        configuration = {
            "keep_running": True,
            "permissions": {"mode": "bypass"},
            "reusable_checks": [initial],
            "provider": {
                "provider": "remote",
                "model": "fixture",
                "account_id": "fixture",
                "base_url": f"http://127.0.0.1:{provider.server_port}/v1",
                "api_key": "fixture",
            },
            "schedule": {
                "name": "Remote fixture",
                "prompt": "Create result.txt containing ready.",
                "mode": "work",
                "runner": "solo",
                "provider": "remote",
                "provider_account_id": "fixture",
                "model": "fixture",
                "timezone": "UTC",
                "rule": {
                    "kind": "interval",
                    "every": 1,
                    "unit": "hours",
                    "anchor": time.time() + 2,
                },
            },
        }
        deployed = call(
            "POST",
            "/api/runtime/snapshots/import",
            json={
                "deployment_id": "fixture-deployment",
                "snapshot": snapshot,
                "archive": base64.b64encode(archive(snapshot)).decode(),
                "configuration": configuration,
            },
        )
        call("POST", "/api/runtime/detach", json={})
        client.close()
        time.sleep(6)
        assert process.poll() is None
        client = connect()
        returned = wait_result(deployed["id"], 1)
        assert returned["accounting"]["total_tokens"] > 0
        assert returned["accounting"]["estimated_api_cost"] is None
        assert all(task["verification_status"] == "passed" for task in returned["task_contracts"])
        assert returned["task_contracts"]
        assert not (source / "result.txt").exists()
        session = returned["runs"][0]["session_id"]
        worker = "/api/runtime/workers/" + session
        correction = "Keep result.txt ready."
        call(
            "POST",
            worker + "/commands",
            json={"type": "user_message", "text": correction, "request_id": "correction-message"},
        )
        wait_result(deployed["id"], 2)
        proposal = call(
            "POST",
            worker + "/api/reusable-checks/propose",
            json={"session_id": session, "correction": correction},
        )
        assert proposal["state"] == "proposed"
        approved = call(
            "PATCH",
            worker + "/api/reusable-checks/" + proposal["id"],
            json={"action": "approve", "expected_revision": proposal["revision"]},
        )
        call(
            "POST",
            worker + "/commands",
            json={
                "type": "user_message",
                "text": "Create the next result.",
                "request_id": "next-task",
            },
        )
        returned = wait_result(deployed["id"], 3)
        latest = max(returned["runs"], key=lambda run: run["created_at"])
        task = next(
            task for task in returned["task_contracts"] if task["id"] == "run:" + latest["id"]
        )
        assert task["verification_status"] == "passed"
        assert any(
            item["id"] == approved["id"] and item["version"] == approved["version"]
            for item in task["reusable_checks"]
        )
        assert "check_generation" in returned["accounting"]["by_purpose"]
    finally:
        process.terminate()
        try:
            process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        provider.shutdown()
        provider.server_close()
        client.close()
        log.close()
