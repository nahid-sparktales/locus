"""Durability and controller independence, including an actual worker process."""
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest
import requests

from ollama_code.runstore import RunStore
from ollama_code.runtime_store import PrivateStore, RuntimeStore


@pytest.fixture
def store(tmp_path):
    return RuntimeStore(RunStore(tmp_path / "runs.sqlite3"))


def test_commands_are_durable_idempotent_and_not_replayed_after_crash(store, tmp_path):
    store.save_worker("session", str(tmp_path), keep_running=True)
    command = {"type": "user_message", "text": "Work", "request_id": "request"}
    assert store.enqueue("session", command) == store.enqueue("session", command)
    assert len(store.commands("session")) == 1
    with pytest.raises(ValueError, match="different work"):
        store.enqueue("session", {**command, "text": "Different work"})
    store.command_state("request", "sent")
    store.interrupted("session")
    reconstructed = RuntimeStore(RunStore(store.runs.path))
    assert not reconstructed.commands("session")
    assert reconstructed.commands("session", "uncertain")[0]["id"] == "request"
    assert reconstructed.worker("session")["keep_running"]


def test_approval_requires_current_fingerprint_and_is_single_use(store, tmp_path):
    store.save_worker("session", str(tmp_path))
    event = {"type": "permission_request", "request_id": "action", "tool": "write_file"}
    decision = store.decision("session", event)
    with pytest.raises(ValueError, match="current"):
        store.resolve(decision["id"], "stale", {"decision": "allow"})
    assert store.resolve(decision["id"], decision["fingerprint"], {"decision": "allow"}) == "session"
    with pytest.raises(ValueError, match="current"):
        store.resolve(decision["id"], decision["fingerprint"], {"decision": "allow"})
    store.interrupted("session")
    assert store.decisions() == []


def test_event_cursor_is_ordered_and_scoped(store):
    first = store.append("one", {"type": "message", "text": "first"})
    store.append("two", {"type": "message", "text": "other"})
    last = store.append("one", {"type": "message", "text": "last"})
    assert store.events("one", first["runtime_seq"]) == [last]


def test_private_configuration_is_atomic_and_not_in_database(tmp_path, store):
    private = PrivateStore(tmp_path / "private")
    token = private.token()
    private.set("account:one", {"api_key": "test-secret"})
    assert PrivateStore(private.root).token() == token
    assert private.path.stat().st_mode & 0o077 == 0
    assert b"test-secret" not in store.runs.path.read_bytes()


def test_automation_continuation_defaults_to_off(store):
    assert not store.automation_enabled("schedule", "one")
    store.set_automation("schedule", "one", True)
    assert store.automation_enabled("schedule", "one")
    assert not store.automation_enabled("event", "one")


def test_runtime_process_survives_client_disconnect_and_reuses_worker(tmp_path, monkeypatch):
    # This starts real Python services, with all state in a disposable profile.
    root = tmp_path / "runtime"
    private = PrivateStore(root)
    token = private.token()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    environment = {**os.environ, "OLLAMA_CODE_HOME": str(tmp_path / "profile"),
                   "PYTHONPATH": str(Path(__file__).resolve().parents[1]),
                   "LOCUS_CODEX_HOME": str(tmp_path / "codex")}
    process = subprocess.Popen([sys.executable, "-m", "ollama_code.runtime", "--home", str(root),
                                "--port", str(port), "--cwd", str(tmp_path)], env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    client = requests.Session()
    client.trust_env = False
    client.headers["X-Locus-Token"] = token
    try:
        for _ in range(100):
            if process.poll() is not None:
                pytest.fail("Runtime exited during startup")
            try:
                if client.get(base + "/api/runtime", timeout=.3).ok:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            pytest.fail("Runtime did not start")
        assert requests.get(base + "/api/runtime", timeout=2).status_code == 401
        created = client.post(base + "/api/sessions/new", json={}, timeout=5)
        assert created.ok, created.text
        body = created.json()
        session_id = body.get("session_info", body).get("session_id")
        assert session_id, body
        created = client.post(base + "/api/runtime/workers", json={"session_id": session_id,
                              "workspace": str(tmp_path), "keep_running": True}, timeout=35)
        assert created.ok, created.text
        assert client.post(base + "/api/runtime/detach", json={}, timeout=5).ok
        client.close()
        time.sleep(.2)
        assert process.poll() is None
        with requests.Session() as reconnect:
            reconnect.trust_env = False
            reconnect.headers["X-Locus-Token"] = token
            status = reconnect.get(base + "/api/runtime", timeout=5).json()
            assert status["workers"][0]["keep_running"] is True
            assert status["workers"][0]["state"] == "idle"
            again = reconnect.post(base + "/api/runtime/workers", json={"session_id": session_id,
                                   "workspace": str(tmp_path)}, timeout=5)
            assert again.ok, again.text
    finally:
        process.terminate()
        try:
            process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def test_disconnect_pauses_only_ordinary_work_and_keeps_approval(tmp_path, store):
    import asyncio
    from types import SimpleNamespace

    from ollama_code.runtime import RuntimeSupervisor

    async def scenario():
        app = SimpleNamespace(state=SimpleNamespace(service=SimpleNamespace(run_store=store.runs)))
        runtime = RuntimeSupervisor(app, tmp_path / "private", port=1)
        sent = []
        async def send(worker, message):
            sent.append((worker.session_id, message))
        runtime.send = send
        for key, keep in (("ordinary", False), ("background", True)):
            runtime.store.save_worker(key, str(tmp_path), keep_running=keep)
            runtime.workers[key] = SimpleNamespace(session_id=key, active_command=key, subscribers=set())
            runtime.store.decision(key, {"type": "permission_request", "request_id": key})
        await runtime.detach()
        assert [key for key, _ in sent] == ["ordinary"]
        assert runtime.store.worker("ordinary")["state"] == "paused"
        assert len(runtime.store.decisions("background")) == 1
    asyncio.run(scenario())


def test_runtime_refuses_mismatched_decision_without_consuming_it(tmp_path, store):
    import asyncio
    from types import SimpleNamespace

    from ollama_code.runtime import RuntimeSupervisor

    async def scenario():
        runtime = RuntimeSupervisor(SimpleNamespace(state=SimpleNamespace(service=SimpleNamespace(run_store=store.runs))), tmp_path / "private", port=1)
        decision = store.decision("session", {"type": "permission_request", "request_id": "pending"})
        with pytest.raises(ValueError, match="does not match"):
            await runtime.resolve(decision["id"], decision["fingerprint"], {"type": "user_message", "text": "wrong"})
        assert len(store.decisions()) == 1
    asyncio.run(scenario())


def test_connector_receipt_prevents_repeating_external_action(tmp_path, store, monkeypatch):
    import asyncio
    from types import SimpleNamespace

    from ollama_code.runtime import RuntimeSupervisor
    from ollama_code.runtime_connectors import RuntimeConnectors

    async def scenario():
        runtime = RuntimeSupervisor(SimpleNamespace(state=SimpleNamespace(service=SimpleNamespace(run_store=store.runs))), tmp_path / "private", port=1)
        calls, replies = [], []
        async def action(self, event):
            calls.append(event)
            return {"text": "Sent"}
        async def send(worker, reply):
            replies.append(reply)
        monkeypatch.setattr(RuntimeConnectors, "action", action)
        runtime.send = send
        worker = SimpleNamespace(session_id="session")
        event = {"request_id": "one", "idempotency_key": "stable", "tool": "telegram_send"}
        await runtime._connector_action(worker, event)
        await runtime._connector_action(worker, event)
        assert len(calls) == 1
        assert replies[0]["result"] == replies[1]["result"]
    asyncio.run(scenario())
