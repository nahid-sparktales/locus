"""Two authenticated controllers use one host vault through existing runtime transport.

Only HTTP sockets/SSH tunnels are replaced. The controller route, remote request,
worker proxy, worker request and memory HTTP endpoints are the production code.
"""
from contextlib import ExitStack
from types import SimpleNamespace
from urllib.parse import urlsplit

import pytest
from fastapi import APIRouter, FastAPI
from fastapi.testclient import TestClient

from ollama_code import paths
from ollama_code.api import continuity, runtime, runtime_deploy
from ollama_code.runtime import RuntimeSupervisor
from ollama_code.runtime_remote import RemoteRuntimes
from ollama_code.server import block_browser_origins


def _app(token):
    app = FastAPI()
    app.state.auth_token = token
    app.state.allowed_origins = set()
    app.middleware("http")(block_browser_origins)
    return app


@pytest.fixture
def shared_host(tmp_path, monkeypatch):
    calls, connect_calls, clients_by_port = [], [], {}
    host_token = "shared-host-token"
    worker_tokens = {"worker-a": "worker-a-token", "worker-b": "worker-b-token"}
    workspaces = {name: tmp_path / name for name in worker_tokens}
    for workspace in workspaces.values():
        workspace.mkdir()

    class TransportSession:
        trust_env = True

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return None

        def request(self, method, url, **kwargs):
            address = urlsplit(url)
            assert address.scheme == "http" and address.hostname == "127.0.0.1"
            assert not self.trust_env and kwargs["allow_redirects"] is False
            calls.append({"method": method, "port": address.port,
                          "path": address.path + ("?" + address.query if address.query else ""),
                          "body": kwargs.get("json"), "headers": kwargs["headers"],
                          "timeout": kwargs["timeout"]})
            response = clients_by_port[address.port].request(method, calls[-1]["path"],
                json=kwargs.get("json"), headers=kwargs["headers"])
            return SimpleNamespace(status_code=response.status_code, ok=response.is_success,
                content=response.content, text=response.text, json=response.json)

    monkeypatch.setattr("requests.Session", TransportSession)
    with ExitStack() as stack:
        workers = {}
        for index, (worker_id, worker_token) in enumerate(worker_tokens.items()):
            app = _app(worker_token)
            app.state.service = SimpleNamespace(core=SimpleNamespace(
                workspace_root=str(workspaces[worker_id]), cwd=str(workspaces[worker_id])))
            router = APIRouter()
            continuity.register_routes(router)
            app.include_router(router)
            port = 31011 + index
            clients_by_port[port] = stack.enter_context(TestClient(app))
            workers[worker_id] = SimpleNamespace(session_id=worker_id, port=port,
                token=worker_token, active_command="", session_info={},
                headers={"X-Locus-Token": worker_token}, configuration_paths=frozenset())

        host = _app(host_token)
        supervisor = SimpleNamespace(workers=workers, paused=False, maintenance=False)
        # Keep the established worker transport, including its own token.
        supervisor.request = RuntimeSupervisor.request.__get__(supervisor)
        host.state.runtime = supervisor
        router = APIRouter()
        runtime.register_routes(router)
        host.include_router(router)
        clients_by_port[31001] = stack.enter_context(TestClient(host))

        controllers, local_roots = [], []
        for name in ("first", "second"):
            local_root = tmp_path / (name + "-controller")
            local_root.mkdir()
            local_roots.append(local_root)
            private = SimpleNamespace(read=lambda: {"remote:owned-host": {"token": host_token}})
            control_runtime = SimpleNamespace(root=local_root, private=private, maintenance=False)
            control_runtime.remotes = RemoteRuntimes(control_runtime)

            def connect(key, controller=name):
                connect_calls.append((controller, key))
                assert key == "owned-host"
                return 31001

            monkeypatch.setattr(control_runtime.remotes, "connect", connect)
            app = _app(name + "-controller-token")
            app.state.runtime = control_runtime
            router = APIRouter()
            runtime_deploy.register_routes(router)
            app.include_router(router)
            client = stack.enter_context(TestClient(app))
            client.headers["X-Locus-Token"] = name + "-controller-token"
            controllers.append(client)

        yield SimpleNamespace(controllers=controllers, calls=calls, connects=connect_calls,
            host_dir=paths.APP_DIR, local_roots=local_roots, workspaces=workspaces,
            worker_tokens=worker_tokens, host_token=host_token)


def _request(client, method, path="/api/memory", body=None, worker="worker-a"):
    response = client.post("/api/runtime/remotes/owned-host/request", json={
        "method": method, "path": f"/api/runtime/workers/{worker}{path}", "body": body})
    assert response.status_code == 200, response.text
    return response.json()


def test_two_controllers_create_read_edit_delete_one_host_memory(shared_host):
    first, second = shared_host.controllers
    create_body = {"title": "Deployment", "content": "Deploy using cerulean release.",
                   "scope": "workspace", "kind": "fact"}
    saved = _request(first, "POST", body=create_body)["memory"]
    identifier = saved["id"]
    assert [item["id"] for item in _request(second, "GET")["memories"]] == [identifier]

    changed = "Deploy using emerald release."
    edited = _request(second, "PUT", f"/api/memory/{identifier}", {"content": changed})["memory"]
    assert edited["revision"] > saved["revision"]
    assert _request(first, "GET")["memories"][0]["content"] == changed

    documents = list((shared_host.host_dir / "memories").rglob("*.md"))
    assert sum(changed in path.read_text() for path in documents) == 1
    assert len(list((shared_host.host_dir / "memory-engine").glob("p*/memory.sqlite3"))) == 1
    assert _request(first, "DELETE", f"/api/memory/{identifier}") == {"ok": True, "id": identifier}
    assert _request(second, "GET")["memories"] == []
    assert all(changed not in path.read_text() for path in documents)

    # Both remote calls and worker calls use the production authenticated transport.
    for call in shared_host.calls:
        expected_token = shared_host.host_token if call["port"] == 31001 else shared_host.worker_tokens["worker-a"]
        assert call["headers"] == {"X-Locus-Token": expected_token}
    assert [call["body"] for call in shared_host.calls[:2]] == [create_body, create_body]
    assert any(call["method"] == "PUT" and call["path"].endswith(identifier) for call in shared_host.calls)
    assert {name for name, _ in shared_host.connects} == {"first", "second"}
    assert all(not list(root.iterdir()) for root in shared_host.local_roots)


def test_worker_workspace_isolation_and_personal_memory_shared_on_host(shared_host):
    first, second = shared_host.controllers
    workspace_memory = _request(first, "POST", body={"title": "Project A", "content": "Project A uses cyan checks.",
        "scope": "workspace"})["memory"]
    personal_memory = _request(first, "POST", body={"title": "Writing style", "content": "I prefer concise replies.",
        "scope": "personal", "kind": "preference"})["memory"]
    first_ids = {item["id"] for item in _request(second, "GET", worker="worker-a")["memories"]}
    second_ids = {item["id"] for item in _request(second, "GET", worker="worker-b")["memories"]}
    assert first_ids == {workspace_memory["id"], personal_memory["id"]}
    assert second_ids == {personal_memory["id"]}
    assert any(call["headers"] == {"X-Locus-Token": shared_host.worker_tokens["worker-b"]}
               and call["path"] == "/api/memory" for call in shared_host.calls)
    user_file = shared_host.host_dir / "memories" / "USER.md"
    assert personal_memory["content"] in user_file.read_text()
    assert workspace_memory["content"] not in user_file.read_text()
    assert all(not list(root.iterdir()) for root in shared_host.local_roots)


def test_controller_authentication_blocks_forwarding_without_local_token(shared_host):
    first = shared_host.controllers[0]
    response = first.post("/api/runtime/remotes/owned-host/request", headers={"X-Locus-Token": "wrong"},
        json={"method": "POST", "path": "/api/runtime/workers/worker-a/api/memory",
              "body": {"content": "This request must never be saved.", "scope": "workspace"}})
    assert response.status_code == 401
    assert shared_host.calls == [] and shared_host.connects == []
    assert not (shared_host.host_dir / "memory-engine").exists()
