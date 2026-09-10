"""Account-scoped workers must never borrow the primary's selected plan."""
from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace

import pytest

from ollama_code import orchestration
from ollama_code.api.chat_transport import ws_codex_broker
from ollama_code.chat_service import ChatService
from ollama_code.codex_app_server import CodexBrokerClient, CodexThreadOptions
from ollama_code.core import AgentCore


@pytest.fixture(autouse=True)
def isolated_team_broker(monkeypatch):
    monkeypatch.setattr(orchestration, "_TEAM_CODEX_BROKER", None)
    monkeypatch.setattr(orchestration, "_TEAM_CODEX_ACCOUNT_RESOLVER", None)


def profile(home_id="work", **route_overrides):
    return orchestration.AgentProfile.parse({
        "id": "writer", "name": "Writer", "model": "exact-model",
        "role": "implementer", "access_ceiling": "workspace_write",
        "timeout_seconds": 60, "token_limit": 8_000,
        "metering": "metered", "input_cost_per_million": 10,
        "output_cost_per_million": 20,
        "route": {
            "provider": "chatgpt", "account_id": "selected-account",
            "codex_home_id": home_id, **route_overrides,
        },
    })


class Helper:
    def __init__(self, home_id):
        self.home_id = home_id
        self.calls = []

    def account(self, **kwargs):
        self.calls.append(("account", kwargs))
        return {"home": self.home_id}

    def models(self):
        return [{"model": self.home_id}]

    def usage(self):
        return {"home": self.home_id}

    def start_thread(self, **kwargs):
        self.calls.append(("thread_start", kwargs))
        return self.home_id

    def resume_thread(self, thread_id, **kwargs):
        self.calls.append(("thread_resume", {"thread_id": thread_id, **kwargs}))
        return self.home_id

    def complete(self, **kwargs):
        self.calls.append(("complete", kwargs))
        return {"text": self.home_id}

    def run_turn(self, **kwargs):
        self.calls.append(("turn_run", kwargs))
        kwargs["event_handler"]({"home": self.home_id})
        return {"home": self.home_id}


def service_with_helpers():
    helpers = {key: Helper(key) for key in ("active", "work", "personal", "")}
    service = ChatService.__new__(ChatService)
    service._codex_home_id = "active"
    service._codex_pinned = None
    service._codex_registry = SimpleNamespace(manager=lambda key: helpers[key])
    service.core = SimpleNamespace(cwd="/workspace", codex_manager=helpers["active"])
    return service, helpers


class BrokerSocket:
    def __init__(self, service, request):
        self.app = SimpleNamespace(state=SimpleNamespace(service=service, auth_token="internal"))
        self.headers = {"x-locus-token": "internal"}
        self.request = request
        self.messages = []

    async def accept(self):
        pass

    async def receive_json(self):
        if self.request is not None:
            request, self.request = self.request, None
            return request
        await asyncio.Event().wait()

    async def send_json(self, message):
        self.messages.append(message)

    async def close(self, **_kwargs):
        pass


@pytest.mark.parametrize("operation", [
    "account", "models", "usage", "thread_start", "thread_resume", "complete", "turn_run",
])
def test_every_broker_operation_uses_requested_home_without_switching_primary(operation):
    service, helpers = service_with_helpers()
    socket = BrokerSocket(service, {
        "op": operation, "codex_home_id": "work", "model": "exact-model", "thread_id": "thread",
    })
    asyncio.run(ws_codex_broker(socket))
    assert "work" in json.dumps(socket.messages)
    assert "active" not in json.dumps(socket.messages)
    assert service._codex_home_id == "active"
    assert service.core.codex_manager is helpers["active"]


def test_concurrent_bound_requests_and_legacy_default_stay_separate():
    service, helpers = service_with_helpers()

    async def run():
        sockets = [BrokerSocket(service, {"op": "account", **identity}) for identity in (
            {"codex_home_id": "work"}, {"codex_home_id": "personal"},
            {"codex_home_id": ""}, {},
        )]
        await asyncio.gather(*(ws_codex_broker(socket) for socket in sockets))
        return [socket.messages[-1]["result"]["home"] for socket in sockets]

    assert asyncio.run(run()) == ["work", "personal", "", "active"]
    assert service.codex is helpers["active"]


@pytest.mark.parametrize("home_id", ["../work", "work/other", None, 42, {}])
def test_invalid_broker_identity_never_falls_back(home_id):
    service, helpers = service_with_helpers()
    socket = BrokerSocket(service, {"op": "account", "codex_home_id": home_id})
    asyncio.run(ws_codex_broker(socket))
    assert socket.messages[-1]["type"] == "error"
    assert all(not helper.calls for helper in helpers.values())
    assert service._codex_home_id == "active"


def test_worker_clones_put_identity_on_every_wire_request(monkeypatch):
    requests = []

    class Socket:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            pass

        def send(self, request):
            self.request = json.loads(request)
            requests.append(self.request)

        def recv(self, **_kwargs):
            if self.request["op"] == "turn_run":
                return json.dumps({"type": "completed", "turn": {}})
            return json.dumps({"type": "result", "result": "thread"})

    monkeypatch.setattr(CodexBrokerClient, "_connect", lambda _self: Socket())
    legacy = CodexBrokerClient("ws://localhost/broker", "internal")
    work = legacy.for_account("work")
    personal = work.for_account("personal")
    work.account()
    work.models()
    work.usage()
    work.start_thread(model="exact-model", cwd="/workspace", tools=[],
                      options=CodexThreadOptions(image_generation=True))
    work.resume_thread("thread", model="exact-model", cwd="/workspace")
    work.complete(model="exact-model", cwd="/workspace", base_instructions="", prompt="plan")
    work.run_turn(thread_id="thread", text="implement", model="exact-model")
    personal.account()
    legacy.account()
    legacy.for_account("").account()
    assert [item["codex_home_id"] for item in requests[:7]] == ["work"] * 7
    assert requests[3]["image_generation"] is True
    assert requests[7]["codex_home_id"] == "personal"
    assert "codex_home_id" not in requests[8]
    assert requests[9]["codex_home_id"] == ""
    assert all("token" not in item and "api_key" not in item for item in requests)


def test_worker_binding_changes_only_its_proxy_and_invalid_binding_is_atomic():
    service = ChatService.__new__(ChatService)
    original = CodexBrokerClient("ws://localhost/broker", "internal")
    service._codex_pinned = original
    service._codex_registry = None
    service._codex_home_id = ""
    service.core = SimpleNamespace(codex_manager=original)
    selected = service.use_chatgpt_home("work")
    assert selected is not original
    assert selected._request("account")["codex_home_id"] == "work"
    assert "codex_home_id" not in original._request("account")
    assert service.core.codex_manager is selected
    assert service.codex_for("personal")._request("account")["codex_home_id"] == "personal"
    assert service.codex is selected
    with pytest.raises(ValueError):
        service.use_chatgpt_home("../escape")
    assert service.codex is selected
    assert service._codex_home_id == "work"


@pytest.mark.parametrize("worker", [False, True])
def test_team_profiles_bind_independent_account_clients(worker):
    service, helpers = service_with_helpers()
    broker = CodexBrokerClient("ws://localhost/broker", "internal") if worker else service.codex
    orchestration.set_chatgpt_manager(broker, account_resolver=service.codex_for)
    first = orchestration.client_for_profile(profile("work"))
    second = orchestration.client_for_profile(profile("personal"))
    if worker:
        assert first.broker._request("account")["codex_home_id"] == "work"
        assert second.broker._request("account")["codex_home_id"] == "personal"
    else:
        assert first.broker is helpers["work"]
        assert second.broker is helpers["personal"]
    assert service.codex is helpers["active"]


def test_writer_installs_and_restores_exact_manager_and_options(tmp_path, monkeypatch):
    from ollama_code.server import _install_writer_route, _restore_writer_route

    service, helpers = service_with_helpers()
    orchestration.set_chatgpt_manager(service.codex, account_resolver=service.codex_for)
    core = AgentCore(cwd=str(tmp_path), config={"model": "initial-model"})
    monkeypatch.setattr(core, "_emit_info", lambda: None)
    core.codex_manager = helpers["active"]
    original_config = dict(core.config)
    writer = profile("work", native_mode=False, web_search=True, reasoning_effort="high")
    snapshot = _install_writer_route(core, writer)
    assert core.codex_manager is helpers["work"]
    assert core.model == "exact-model"
    assert core.config["chatgpt_reasoning_effort"] == "high"
    assert core.config["chatgpt_web_search"] is True
    _restore_writer_route(core, snapshot)
    assert core.codex_manager is helpers["active"]
    assert core.config == original_config
    assert service.codex is helpers["active"]
    with pytest.raises(ValueError):
        _install_writer_route(core, profile("../escape"))
    assert core.codex_manager is helpers["active"]
    assert core.config == original_config


@pytest.mark.parametrize("kind", ["kimiCode", "kimi_code"])
def test_kimi_membership_does_not_consume_api_dollar_budget(kind):
    member = profile(
        provider="remote", account_kind=kind,
        base_url="https://api.kimi.com/coding/v1", api_key="test-key",
    )
    assert member.metering == "self_hosted"
    assert orchestration._estimated_call_cost(member, 1_000_000, 1_000_000) == 0
    api = profile(
        provider="remote", account_kind="kimi",
        base_url="https://api.moonshot.ai/v1", api_key="different-test-key",
    )
    assert api.metering == "metered"
    assert orchestration._estimated_call_cost(api, 1_000_000, 1_000_000) == 30
