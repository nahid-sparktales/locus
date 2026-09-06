"""Exercise the exact Python packages shipped by the two app products."""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import ExitStack
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "stage_backend_edition", ROOT / "Tools/StageBackendEdition.py"
)
assert SPEC and SPEC.loader
staging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(staging)

# A developer venv may contain setuptools' editable-import fallback. The app
# runtime has no editable install; remove that fallback so a missing packaged
# module cannot be supplied from the checkout during these artifact tests.
PACKAGED_IMPORTS = (
    "import sys\n"
    "sys.meta_path = [finder for finder in sys.meta_path "
    "if not getattr(finder, '__module__', '').startswith('__editable__')]\n"
)


@pytest.fixture(scope="module")
def staged_backends(tmp_path_factory):
    directory = tmp_path_factory.mktemp("product-backends")
    packages = {}
    for edition in ("locus", "locusx"):
        destination = directory / edition / "ollama_code"
        staging.stage_backend(ROOT / "agent/ollama_code", destination, edition)
        packages[edition] = destination
    return packages


def _environment(package: Path, profile: Path) -> dict[str, str]:
    return {
        **os.environ,
        "PYTHONPATH": str(package.parent),
        "PYTHONDONTWRITEBYTECODE": "1",
        "OLLAMA_CODE_HOME": str(profile / "Agent"),
        "LOCUS_CODEX_HOME": str(profile / "Codex"),
        "LOCUS_PARENT_PID": "0",
        "LOCUS_DOCUMENT_COORDINATOR": "0",
        # These must never select a different product implementation.
        "LOCUS_EDITION": "locusx",
        "LOCUS_PRODUCT_EDITION": "locusx",
        "LOCUS_WALLET_ENABLED": "1",
        "LOCUS_CAPABILITY_WALLET": "1",
    }


def _run(package: Path, profile: Path, script: str) -> dict:
    result = subprocess.run(
        [sys.executable, "-c", PACKAGED_IMPORTS + script],
        cwd=package.parent,
        env=_environment(package, profile),
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_standard_package_contains_no_private_implementation_or_protocol(staged_backends):
    package = staged_backends["locus"]
    assert not (package / "_locusx").exists()
    assert not list(package.rglob("*.pyc"))
    forbidden = (
        "WALLET_TOOL_SCHEMAS", "set_wallet_control", "wallet_control_status",
        "wallet_action_request", "wallet_action_result", "wallet_execute_transaction",
        "WalletFeature", "pending_wallet_actions",
    )
    for path in package.rglob("*.py"):
        content = path.read_text()
        assert not any(marker in content for marker in forbidden), path
    assert (package / "memory.py").is_file()
    assert "AESGCM" in (package / "memory.py").read_text()


def test_packaged_locus_rejects_wallet_control_and_guessed_tools(staged_backends, tmp_path):
    result = _run(staged_backends["locus"], tmp_path, r'''
import importlib.util
import json
import os
from fastapi.testclient import TestClient
from ollama_code import PRODUCT_NAME, USER_AGENT
from ollama_code.core import AgentCore
from ollama_code.ollama import ToolCall
from ollama_code.server import ChatService, create_app

ChatService.background_probes = False
core = AgentCore(cwd=os.environ["OLLAMA_CODE_HOME"], config={"model": "test", "permission_mode": "bypass"})
core.messages = [core.system_message()]
service = ChatService(core)
assert importlib.util.find_spec("ollama_code._locusx") is None
assert PRODUCT_NAME == "Locus" and "io.sparktales.locus)" in USER_AGENT
with TestClient(create_app(chat_service=service)) as client:
    with client.websocket_connect("/ws/chat") as ws:
        assert ws.receive_json()["type"] == "session_info"
        ws.send_json({"type": "set_wallet_control", "capability": {
            "protocol_version": 1, "signer_state": "unlocked", "session_id": "native-1",
            "supported_chains": ["eip155:11155111"],
            "allowed_operations": ["wallet_list_accounts", "wallet_execute_transaction"],
        }})
        assert ws.receive_json()["type"] == "command_error"
        ws.send_json({"type": "wallet_action_result", "request_id": "fake", "result": {"text": "ok"}})
        assert ws.receive_json()["type"] == "command_error"
        ws.send_json({"type": "set_notes_control", "enabled": True})
        assert ws.receive_json() == {"type": "notes_control_status", "enabled": True}
        ws.send_json({"type": "ping"})
        assert ws.receive_json()["type"] == "pong"
assert not any(s["function"]["name"].startswith("wallet_") for s in core.tool_registry.schemas())
assert not any(s["name"].startswith("wallet_") for s in core.tool_registry.metadata())
assert core.tool_registry.tool_info("wallet_execute_transaction") is None
result = core._run_tool_call(ToolCall("wallet_execute_transaction", {"intent_id": "fake"}), None)
assert result.startswith("Error"), result
assert not core.tool_registry.product_features.owns("wallet_execute_transaction")
print(json.dumps({"product": PRODUCT_NAME, "rejected": True}))
''')
    assert result == {"product": "Locus", "rejected": True}


def test_packaged_locusx_keeps_native_capability_bridge_and_route_checks(staged_backends, tmp_path):
    result = _run(staged_backends["locusx"], tmp_path, r'''
import json
import os
import threading
from fastapi.testclient import TestClient
from ollama_code import PRODUCT_NAME, USER_AGENT
from ollama_code.core import AgentCore
from ollama_code.server import ChatService, create_app

ChatService.background_probes = False
core = AgentCore(cwd=os.environ["OLLAMA_CODE_HOME"], config={"model": "test"})
core.messages = [core.system_message()]
service = ChatService(core)
feature = core.tool_registry.product_features
assert PRODUCT_NAME == "LocusX" and "io.sparktales.locusx)" in USER_AGENT
assert not feature.enabled
with TestClient(create_app(chat_service=service)) as client:
    with client.websocket_connect("/ws/chat") as ws:
        assert ws.receive_json()["type"] == "session_info"
        ws.send_json({"type": "set_wallet_control", "capability": {
            "protocol_version": 1, "signer_state": "unlocked", "session_id": "native-1",
            "supported_chains": ["eip155:11155111"],
            "allowed_operations": ["wallet_list_accounts", "wallet_execute_transaction"],
        }})
        status = ws.receive_json()
        assert status["type"] == "wallet_control_status" and status["enabled"]
        assert core.tool_registry.tool_info("wallet_list_accounts")["origin"] == "wallet"
        completed = []
        worker = threading.Thread(target=lambda: completed.append(feature.execute("wallet_list_accounts", {}, "read-1")))
        worker.start()
        request = ws.receive_json()
        assert request["type"] == "wallet_action_request" and request["request_id"] == "read-1"
        ws.send_json({"type": "wallet_action_result", "request_id": "read-1", "result": {"text": "account-1"}})
        worker.join(timeout=3)
        assert completed == ["account-1"] and not feature.pending_actions
        core.tool_registry.set_mcp_agent_policy({}, access_ceiling="read_only", role="reviewer")
        assert "wallet_execute_transaction" not in {s["function"]["name"] for s in core.tool_registry.schemas()}
        assert feature.execute("wallet_execute_transaction", {"intent_id": "fake"}, "write-1").startswith("Error")
        ws.send_json({"type": "set_wallet_control", "capability": None})
        assert ws.receive_json()["enabled"] is False
        assert not feature.schemas() and feature.execute("wallet_list_accounts", {}, "read-2").startswith("Error")
print(json.dumps({"product": PRODUCT_NAME, "bridge": True}))
''')
    assert result == {"product": "LocusX", "bridge": True}


@pytest.mark.parametrize("edition", ["locus", "locusx"])
def test_packaged_oauth_callback_uses_fixed_product(staged_backends, tmp_path, edition):
    result = _run(staged_backends[edition], tmp_path, r'''
import json
from ollama_code.extensions import ExtensionError, _normalize_mcp_config
from ollama_code.product_build import PRODUCT_URL_SCHEME

config = {"url": "https://example.com/mcp", "auth": "oauth", "oauth": {
    "authorization_endpoint": "https://example.com/authorize",
    "token_endpoint": "https://example.com/token", "client_id": "example",
}}
actual = _normalize_mcp_config(config)["oauth"]["redirect_uri"]
assert actual == f"{PRODUCT_URL_SCHEME}://mcp/oauth"
other = "locusx" if PRODUCT_URL_SCHEME == "locus" else "locus"
config["oauth"]["redirect_uri"] = f"{other}://mcp/oauth"
try:
    _normalize_mcp_config(config)
except ExtensionError:
    pass
else:
    raise AssertionError("cross-product callback accepted")
print(json.dumps({"callback": actual}))
''')
    assert result == {"callback": f"{edition}://mcp/oauth"}


def test_two_products_keep_parallel_profiles_separate(staged_backends, tmp_path):
    script = r'''
import json
import os
import sys
from pathlib import Path
from ollama_code import PRODUCT_NAME
from ollama_code.codex_app_server import codex_home_from_environment
from ollama_code.config import CONFIG_PATH, load_config, save_config
from ollama_code.extensions import ExtensionManager
from ollama_code.memory import MemoryVault
from ollama_code.paths import APP_DIR
from ollama_code.sessions import SessionStore

root = Path(os.environ["OLLAMA_CODE_HOME"])
assert APP_DIR == root and CONFIG_PATH == root / "config.json"
save_config({"model": PRODUCT_NAME})
session = SessionStore(cwd=str(root), model=PRODUCT_NAME)
session.append({"type": "message", "role": "user", "content": PRODUCT_NAME})
memory = MemoryVault()
memory.save({"content": PRODUCT_NAME, "scope": "personal"})
extensions = ExtensionManager(str(root))
extensions.set_skill_enabled("brainstorming", False)
codex = codex_home_from_environment()
codex.mkdir(parents=True, exist_ok=True)
(codex / "profile-marker").write_text(PRODUCT_NAME)
print("ready", flush=True)
assert sys.stdin.readline().strip() == "inspect"
assert load_config()["model"] == PRODUCT_NAME
assert len(SessionStore.list_sessions()) == 1
assert memory.list(scopes=["personal"])[0]["content"] == PRODUCT_NAME
assert (codex / "profile-marker").read_text() == PRODUCT_NAME
print(json.dumps({"product": PRODUCT_NAME, "agent": str(APP_DIR), "codex": str(codex), "extensions": str(extensions.root)}), flush=True)
'''
    processes = []
    try:
        for edition, package in staged_backends.items():
            profile = tmp_path / edition
            process = subprocess.Popen(
                [sys.executable, "-c", PACKAGED_IMPORTS + script], cwd=package.parent,
                env=_environment(package, profile), text=True,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            processes.append((edition, profile, process))
        # Both children write while alive, then read their own saved state.
        for _, _, process in processes:
            assert process.stdout.readline().strip() == "ready", process.stderr.read()
        for edition, profile, process in processes:
            stdout, stderr = process.communicate("inspect\n", timeout=20)
            assert process.returncode == 0, stderr
            result = json.loads(stdout)
            assert result["agent"] == str(profile / "Agent")
            assert result["codex"] == str(profile / "Codex")
            assert result["extensions"] == str(profile / "Agent/extensions")
            assert result["product"] == ("Locus" if edition == "locus" else "LocusX")
        assert (tmp_path / "locus/Agent/memory/master.key").read_bytes() != (
            tmp_path / "locusx/Agent/memory/master.key"
        ).read_bytes()
    finally:
        for _, _, process in processes:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)


def test_staged_servers_run_together_with_isolated_http_and_websocket_state(staged_backends, tmp_path):
    from websockets.sync.client import connect

    servers = {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(edition, path, *, method="GET", body=None, token=None):
        server = servers[edition]
        payload = json.dumps(body).encode() if body is not None else None
        query = urllib.request.Request(
            f"http://127.0.0.1:{server['port']}{path}", data=payload, method=method,
            headers={"x-locus-token": token or server["token"], "Content-Type": "application/json"},
        )
        with opener.open(query, timeout=2) as response:
            return json.load(response)

    def receive_kind(connection, kind):
        for _ in range(12):
            event = json.loads(connection.recv(timeout=5))
            if event["type"] == kind:
                return event
        raise AssertionError(f"did not receive {kind}")

    with ExitStack() as resources:
        try:
            for edition, package in staged_backends.items():
                profile = tmp_path / edition
                agent_home = profile / "Agent"
                agent_home.mkdir(parents=True)
                (agent_home / "config.json").write_text(json.dumps({
                    "host": "http://127.0.0.1:1", "model": edition,
                }))
                with socket.socket() as reserved:
                    reserved.bind(("127.0.0.1", 0))
                    port = reserved.getsockname()[1]
                token = f"{edition}-test-authentication"
                log = resources.enter_context((profile / "server.log").open("w+"))
                process = subprocess.Popen(
                    [sys.executable, "-c", PACKAGED_IMPORTS + "from ollama_code.server import main\nmain()\n",
                     "--port", str(port), "--cwd", str(profile), "--model", edition],
                    cwd=package.parent,
                    env={**_environment(package, profile), "LOCUS_AGENT_TOKEN": token},
                    text=True, stdout=log, stderr=subprocess.STDOUT,
                )
                servers[edition] = {"process": process, "port": port, "token": token, "log": log}

            for edition, server in servers.items():
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline and server["process"].poll() is None:
                    try:
                        request(edition, "/api/config")
                        break
                    except (urllib.error.URLError, TimeoutError):
                        time.sleep(0.05)
                else:
                    server["log"].seek(0)
                    raise AssertionError(server["log"].read())
                assert request(edition, "/api/health")["ok"] is True

            for edition, limit in (("locus", 7), ("locusx", 11)):
                other = "locusx" if edition == "locus" else "locus"
                request(edition, "/api/config", method="POST", body={"max_iterations": limit})
                request(edition, "/api/sessions/new", method="POST", body={})
                session_id = request(edition, "/api/sessions")["current"]
                servers[edition]["session_id"] = session_id
                request(edition, f"/api/sessions/{session_id}", method="PATCH", body={"title": edition})
                request(edition, "/api/memory", method="POST", body={"content": edition, "scope": "personal"})
                with pytest.raises(urllib.error.HTTPError) as denied:
                    request(edition, "/api/config", token=servers[other]["token"])
                assert denied.value.code == 401
                with pytest.raises(urllib.error.HTTPError) as missing:
                    request(other, f"/api/sessions/{session_id}")
                assert missing.value.code == 404

            connections = {}
            for edition, server in servers.items():
                connection = resources.enter_context(connect(
                    f"ws://127.0.0.1:{server['port']}/ws/chat",
                    additional_headers={"x-locus-token": server["token"]}, proxy=None,
                ))
                connections[edition] = connection
                receive_kind(connection, "session_info")
                connection.send(json.dumps({"type": "set_wallet_control", "capability": {
                    "protocol_version": 1, "signer_state": "unlocked", "session_id": "smoke-native",
                    "supported_chains": ["eip155:11155111"],
                    "allowed_operations": ["wallet_list_accounts"],
                }}))
            receive_kind(connections["locus"], "command_error")
            assert receive_kind(connections["locusx"], "wallet_control_status")["enabled"] is True

            for edition, limit in (("locus", 7), ("locusx", 11)):
                assert request(edition, "/api/config")["max_iterations"] == limit
                session_id = servers[edition]["session_id"]
                assert request(edition, f"/api/sessions/{session_id}")["title"] == edition
                assert {item["content"] for item in request(edition, "/api/memory")["memories"]} == {edition}
                names = {item["name"] for item in request(edition, "/api/tools")["tools"]}
                assert ("wallet_list_accounts" in names) == (edition == "locusx")
                assert servers[edition]["process"].poll() is None
        finally:
            for server in servers.values():
                server["process"].terminate()
            for server in servers.values():
                try:
                    server["process"].wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server["process"].kill()
                    server["process"].wait(timeout=5)
