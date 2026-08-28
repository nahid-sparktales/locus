from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient

from ollama_code import server


def _service(name: str):
    core = SimpleNamespace(
        provider_state=lambda: {"provider": name},
        provider="ollama",
        client=SimpleNamespace(check=lambda: None),
        host=f"https://{name}.invalid",
        model=name,
        cwd=name,
        workspace_root=name,
        session=SimpleNamespace(session_id=f"{name}-session"),
    )
    run_store = SimpleNamespace(
        schedules=lambda: [{"service": name}],
        usage_summary=lambda **_options: {"service": name},
        read_only=False,
    )
    codex = SimpleNamespace(account=lambda **_options: {"service": name})
    return SimpleNamespace(core=core, run_store=run_store, codex=codex)


def _route_contract() -> list[str]:
    contract = []
    for route in server.api.routes:
        methods = getattr(route, "methods", None)
        method = ",".join(sorted(methods)) if methods else "WEBSOCKET"
        contract.append(f"{method} {route.path}")
    return contract


def test_create_app_keeps_service_state_isolated():
    first = TestClient(server.create_app(chat_service=_service("first")))
    second = TestClient(server.create_app(chat_service=_service("second")))
    unconfigured = TestClient(server.create_app())
    try:
        assert first.get("/api/provider").json() == {"provider": "first"}
        assert second.get("/api/provider").json() == {"provider": "second"}
        assert unconfigured.get("/api/provider").status_code == 503
        assert first.get("/api/health").json()["model"] == "first"
        assert second.get("/api/health").json()["model"] == "second"
        assert unconfigured.get("/api/health").status_code == 503
    finally:
        first.close()
        second.close()
        unconfigured.close()


def test_domain_owned_routes_keep_service_state_isolated(monkeypatch):
    from ollama_code.api import continuity, knowledge, workspace

    monkeypatch.setattr(
        workspace.gitinfo,
        "status",
        lambda root, **_options: {"ok": True, "workspace": root},
    )
    monkeypatch.setattr(
        knowledge,
        "_knowledge_store",
        lambda service, _workspace="": SimpleNamespace(
            settings=lambda: {"workspace": service.core.cwd}
        ),
    )
    monkeypatch.setattr(
        continuity,
        "_continuity_store",
        lambda: SimpleNamespace(
            list_snapshots=lambda workspace, **_options: [{"workspace": workspace}]
        ),
    )
    first = TestClient(server.create_app(chat_service=_service("first")))
    second = TestClient(server.create_app(chat_service=_service("second")))
    try:
        assert first.get("/api/git/status").json()["workspace"] == "first"
        assert second.get("/api/git/status").json()["workspace"] == "second"
        assert first.get("/api/knowledge/status").json()["workspace"] == "first"
        assert second.get("/api/knowledge/status").json()["workspace"] == "second"
        assert first.get("/api/sessions").json()["current"] == "first-session"
        assert second.get("/api/sessions").json()["current"] == "second-session"
        assert first.get("/api/context-snapshots").json()["snapshots"] == [{"workspace": "first"}]
        assert second.get("/api/context-snapshots").json()["snapshots"] == [{"workspace": "second"}]
        assert first.get("/api/schedules").json()["schedules"] == [{"service": "first"}]
        assert second.get("/api/schedules").json()["schedules"] == [{"service": "second"}]
        assert first.get("/api/usage/summary").json() == {"service": "first"}
        assert second.get("/api/usage/summary").json() == {"service": "second"}
    finally:
        first.close()
        second.close()


def test_websocket_routes_keep_service_state_isolated():
    first = TestClient(server.create_app(chat_service=_service("first"), auth_token="token"))
    second = TestClient(server.create_app(chat_service=_service("second"), auth_token="token"))
    try:
        with first.websocket_connect(
            "/ws/internal/codex", headers={"x-locus-token": "token"}
        ) as websocket:
            websocket.send_json({"op": "account"})
            assert websocket.receive_json() == {
                "type": "result",
                "result": {"service": "first"},
            }
        with second.websocket_connect(
            "/ws/internal/codex", headers={"x-locus-token": "token"}
        ) as websocket:
            websocket.send_json({"op": "account"})
            assert websocket.receive_json() == {
                "type": "result",
                "result": {"service": "second"},
            }
    finally:
        first.close()
        second.close()


def test_public_route_contract_matches_snapshot():
    snapshot = Path(__file__).parent / "fixtures" / "server-routes.txt"
    expected = snapshot.read_text(encoding="utf-8").splitlines()
    assert sorted(_route_contract()) == sorted(expected)
