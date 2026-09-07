"""Smoke-test the actual bundled backend and native capability protocol.

This starts the app's embedded Python/server on a private authenticated port,
with a disposable home and checkout. It does not run a model or install the app.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import websockets


async def check_transport(url: str, token: str) -> dict:
    events = []
    pending: dict[str, list[dict]] = {}

    async def receive(ws, kind):
        if pending.get(kind):
            return pending[kind].pop(0)
        async with asyncio.timeout(15):
            while True:
                event = json.loads(await ws.recv())
                events.append(event["type"])
                if event["type"] == kind:
                    return event
                pending.setdefault(event["type"], []).append(event)

    headers = {"X-Locus-Token": token}
    async with websockets.connect(url, additional_headers=headers) as ws:
        session = await receive(ws, "session_info")
        await ws.send(json.dumps({
            "type": "set_question_capability", "version": 1,
            "async_questions_v1": True, "collaboration_v1": True,
        }))
        capability = await receive(ws, "question_capability")
        assert capability["enabled"] and capability["version"] == 1
        questions = await receive(ws, "question_async_snapshot")
        assert questions["requests"] == []
        helpers = await receive(ws, "solo_collaboration_snapshot")
        assert helpers["agents"] == []
        await ws.send(json.dumps({
            "type": "solo_agent_action", "action": "resume",
            "agent_id": "missing", "request_id": "smoke-helper-action",
        }))
        action = await receive(ws, "solo_agent_action_result")
        assert action["request_id"] == "smoke-helper-action"
        assert action["result"]["ok"] is False
        await ws.send(json.dumps({
            "type": "question_async_response", "request_id": "missing",
            "response_id": "smoke-question-response", "action": "skip", "answers": [],
        }))
        response = await receive(ws, "question_async_response_ack")
        assert response["accepted"] is False
    pending.clear()
    async with websockets.connect(url, additional_headers=headers) as ws:
        resumed = await receive(ws, "session_info")
        assert resumed["session_id"] == session["session_id"]
        await ws.send(json.dumps({
            "type": "set_question_capability", "version": 1,
            "async_questions_v1": True, "collaboration_v1": True,
        }))
        assert (await receive(ws, "question_capability"))["enabled"]
        replay = await receive(ws, "question_async_snapshot")
        assert replay["requests"] == []
    return {"capability_negotiated": True, "reconnect_passed": True, "events": events}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runtime = args.app.resolve() / "Contents/Resources/AgentRuntime"
    python = next(path for path in sorted((runtime / "python/bin").glob("python3.*"))
                  if path.is_file() and os.access(path, os.X_OK))
    home = Path(tempfile.mkdtemp(prefix="locus-packaged-smoke-"))
    checkout = home / "workspace"
    checkout.mkdir()
    token = secrets.token_urlsafe(32)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {**os.environ, "OLLAMA_CODE_HOME": str(home / "agent-home"),
           "PYTHONPATH": os.pathsep.join(str(runtime / name) for name in ("source", "site-packages")),
           "LOCUS_AGENT_TOKEN": token}
    # A smoke process must not attach to a desktop worker's broker or proxy pipe.
    for key in list(env):
        if key.startswith("LOCUS_CODEX_BROKER") or key.startswith("LOCUS_PROXY_"):
            env.pop(key)
    base = f"http://127.0.0.1:{port}"
    started = time.monotonic()
    with (home / "server.log").open("w") as log:
        process = subprocess.Popen(
            [str(python), "-m", "ollama_code.server", "--host", "127.0.0.1",
             "--port", str(port), "--cwd", str(checkout)],
            cwd=checkout, env=env, stdout=log, stderr=log,
        )
        try:
            request = urllib.request.Request(base + "/api/health", headers={"X-Locus-Token": token})
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"Bundled server exited; inspect {home / 'server.log'}")
                try:
                    with urllib.request.urlopen(request, timeout=2) as response:
                        health = json.load(response)
                    break
                except (urllib.error.URLError, OSError):
                    if time.monotonic() - started > 45:
                        raise
                    time.sleep(0.1)
            assert health["ok"] is True
            try:
                urllib.request.urlopen(base + "/api/health", timeout=2)
                raise AssertionError("Unauthenticated health request was accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 401
            report = asyncio.run(check_transport(f"ws://127.0.0.1:{port}/ws/chat", token))
            report.update({"passed": True, "app": str(args.app.resolve()),
                           "packaged_python": str(python), "health_ok": True,
                           "authentication_enforced": True,
                           "seconds": round(time.monotonic() - started, 2)})
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
