"""Image generation and editing: provider route, tools, permissions and staging."""
from __future__ import annotations

import base64
import json
import os
from concurrent.futures import Future
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from test_backend import FakeClient, FakeResponse, _core
from test_image_files import jpeg_bytes, png_bytes

from ollama_code import image_generation
from ollama_code.capabilities import CAPABILITY_ENV
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.image_files import image_info
from ollama_code.image_generation import (
    IMAGE_TOOL_NAMES,
    INTERRUPTED,
    MAX_IMAGES_PER_SESSION,
    MAX_IMAGES_PER_TURN,
    SETUP_HINT,
    ImageGenerationService,
    ImageProviderConfig,
    plan_destination,
)
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.permissions import build_preview, file_effects
from ollama_code.sessions import MAX_SESSION_LINE_BYTES
from ollama_code.tools import EDIT_TOOLS, SAFE_TOOLS, ToolContext, execute_tool

KEY = "sk-live-secret-key-4242"
PNG = png_bytes(64, 48)
PNG_B64 = base64.b64encode(PNG).decode()


def _provider_config(**overrides) -> ImageProviderConfig:
    fields = dict(base_url="https://images.example.com/v1", api_key=KEY, model="gpt-image-1",
                  account_id="acct-1", account_label="OpenAI — Work")
    fields.update(overrides)
    return ImageProviderConfig(**fields)


def _install(core: AgentCore, config: ImageProviderConfig | None = None) -> ImageGenerationService:
    """Wire a configured service into a bare core the way ChatService + the route do."""
    service = ImageGenerationService()
    config = config or _provider_config()
    service.configure(config)
    core.tool_registry.image_generation_enabled = True
    core.tool_ctx.image_provider = config.public()
    core.tool_ctx.image_generation = lambda name, args: service.execute(name, args, core.tool_ctx)
    return service


def _ok(data: bytes = PNG) -> FakeResponse:
    return FakeResponse(200, text=json.dumps({"data": [{"b64_json": base64.b64encode(data).decode()}]}))


class ProviderStub:
    """Records every outbound call and answers from a queue (default: one PNG)."""

    def __init__(self, monkeypatch, responses=None):
        self.calls: list[tuple[str, dict]] = []
        self.responses = list(responses or [])
        monkeypatch.setattr(image_generation.requests, "post", self)

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.responses.pop(0) if self.responses else _ok()


def _names(core: AgentCore, *, parity: bool = False, plan_mode: bool = False) -> set[str]:
    schemas = core.tool_registry.parity_schemas(plan_mode=plan_mode) if parity else core.tool_registry.schemas()
    return {schema["function"]["name"] for schema in schemas}


def _images(root: Path) -> list[str]:
    folder = root / "Locus Images"
    return sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []


def _once(tool, summary, detail, request_id):
    return "once"


@pytest.fixture
def client(tmp_path, monkeypatch):
    from ollama_code import server as server_mod

    core = AgentCore(cwd=str(tmp_path), config={"model": "test-model", "max_iterations": 5})
    core.model = "test-model"
    monkeypatch.setattr(core.client, "check", lambda: None)
    monkeypatch.setattr(core.client, "list_models", lambda: [{"name": "test-model", "size": 1, "details": {}}])
    monkeypatch.setattr(core.client, "context_length", lambda name: 32768)
    monkeypatch.setattr(core.client, "running_models", lambda: [{"name": "test-model", "context_length": 32768}])
    core.messages = [core.system_message()]
    app = server_mod.create_app(chat_service=server_mod.ChatService(core))
    with TestClient(app) as c:
        yield c


# ------------------------------------------------------------- availability


def test_chatgpt_model_catalog_exposes_astra_and_current_helper_efforts(client, monkeypatch):
    from types import SimpleNamespace

    homes = []
    helper = SimpleNamespace(
        available=True,
        account=lambda **_: {"account": {"type": "chatgpt", "planType": "pro"}},
        models=lambda: [{
            "id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra",
            "supportedReasoningEfforts": [{"reasoningEffort": "high"}, {"reasoningEffort": "ultra"}],
            "defaultReasoningEffort": "high",
        }],
    )
    monkeypatch.setattr(client.app.state.service, "codex_for", lambda home: (homes.append(home), helper)[1])
    response = client.get("/api/chatgpt/models", params={"account_id": "selected-account"})
    assert response.status_code == 200
    row = response.json()["models"][0]
    assert row["id"] == "gpt-6-astra"
    assert [option["effort"] for option in row["supported_reasoning_efforts"]] == ["high", "ultra"]
    assert set(homes) == {"selected-account"}


def test_chatgpt_image_provider_endpoint_preserves_managed_account_without_keys(client):
    response = client.post("/api/images/provider", json={
        "provider": "chatgpt", "model": "gpt-image-2", "codex_home_id": "selected-account",
        "chat_model": "gpt-5.6-sol", "account_id": "display-account",
    })
    assert response.status_code == 200
    assert response.json()["model"] == "gpt-image-2"
    assert response.json()["has_api_key"] is False
    assert response.json()["host"] == "chatgpt.com"
    assert client.app.state.service.image_generation.configured
    assert IMAGE_TOOL_NAMES <= _names(client.app.state.service.core)


def test_image_tools_are_absent_until_configured_and_gone_when_cleared(tmp_path):
    core = _core(tmp_path, [])
    assert not IMAGE_TOOL_NAMES & _names(core)
    assert not IMAGE_TOOL_NAMES & _names(core, parity=True)
    assert core.tool_registry.tool_info("generate_image") is None
    assert not IMAGE_TOOL_NAMES & SAFE_TOOLS and not IMAGE_TOOL_NAMES & EDIT_TOOLS

    _install(core)
    assert IMAGE_TOOL_NAMES <= _names(core)
    assert IMAGE_TOOL_NAMES <= _names(core, parity=True)
    # Plan mode modifies no files, so the parity surface leaves them out there.
    assert not IMAGE_TOOL_NAMES & _names(core, parity=True, plan_mode=True)
    assert core.tool_registry.tool_info("edit_image") == {
        "origin": "builtin", "annotations": {"readOnlyHint": False, "openWorldHint": True},
    }
    assert not core.tool_registry.is_read_only_tool("generate_image")
    # Root-only: a Solo helper never inherits them.
    assert not IMAGE_TOOL_NAMES & {s["function"]["name"] for s in core.solo_worker_tool_schemas()}

    core.tool_registry.image_generation_enabled = False
    assert not IMAGE_TOOL_NAMES & _names(core)
    assert not IMAGE_TOOL_NAMES & _names(core, parity=True)
    assert core.tool_registry.tool_info("generate_image") is None


def test_unconfigured_core_and_missing_executor_refuse_without_network(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "a cat"}), _once)
    assert result.startswith("Error:") and "Manage Accounts › Image generation" in result
    # Even with the executor wired, an unconfigured service says how to set it up.
    ctx = ToolContext(cwd=str(tmp_path))
    ctx.image_generation = lambda name, args: ImageGenerationService().execute(name, args, ctx)
    assert "Image generation" in execute_tool("generate_image", {"prompt": "a cat"}, ctx)
    assert execute_tool("edit_image", {"prompt": "x", "source": "a.png"}, ToolContext(cwd=str(tmp_path))) == (
        "Error: image generation is unavailable in this session."
    )
    assert stub.calls == [] and _images(tmp_path) == []


# ------------------------------------------------------------------- route


@pytest.mark.parametrize("model", [
    "gpt-image-2.5-sunburst", "gpt-image-2.5-flare",
    "gpt-image-2.5-sunburst-2026-09-08", "gpt-image-2.5-flare-2026-09-08",
])
@pytest.mark.parametrize("tool,quality", [("generate_image", "max"), ("edit_image", "xhigh")])
def test_new_image_models_reach_generation_and_editing_from_provider_route(client, tmp_path, monkeypatch, model, tool, quality):
    stub = ProviderStub(monkeypatch)
    configured = client.post("/api/images/provider", json={
        "base_url": "https://images.example.com/v1", "api_key": KEY,
        "model": model, "size": "1536x864", "quality": quality,
    })
    assert configured.status_code == 200
    core = client.app.state.service.core
    args = {"prompt": "A harbour at dusk"}
    if tool == "edit_image":
        (tmp_path / "photo.png").write_bytes(PNG)
        (tmp_path / "mask.png").write_bytes(PNG)
        args.update(source="photo.png", mask="mask.png")
    permissions = []

    def approve(name, summary, detail, request_id):
        permissions.append(detail)
        return "once"

    result = core._run_tool_call(ToolCall(tool, args), approve)
    assert not result.startswith("Error:"), result
    assert len(stub.calls) == 1
    url, request = stub.calls[0]
    assert url.endswith("/images/generations" if tool == "generate_image" else "/images/edits")
    payload = request["json"] if tool == "generate_image" else request["data"]
    assert {key: payload[key] for key in ("model", "size", "quality")} == {
        "model": model, "size": "1536x864", "quality": quality,
    }
    assert any(f"{model} · 1536x864 · {quality}" in detail for detail in permissions)
    if tool == "edit_image":
        assert request["files"] == {
            "image": ("photo.png", PNG, "image/png"),
            "mask": ("mask.png", PNG, "image/png"),
        }
        assert (tmp_path / "photo.png").read_bytes() == PNG
        assert (tmp_path / "photo-edited.png").read_bytes() == PNG
    else:
        assert (tmp_path / "Locus Images" / "a-harbour-at-dusk.png").read_bytes() == PNG


@pytest.mark.parametrize("size", ["1024x640", "1536x864", "3840x2160", "2160x3840", "3840x1280"])
def test_image_provider_accepts_supported_custom_dimension_boundaries(client, size):
    for model in ("gpt-image-2", "gpt-image-2-2026-04-21", "gpt-image-2.5-flare"):
        response = client.post("/api/images/provider", json={
            "base_url": "https://images.example.com/v1", "model": model, "size": size,
        })
        assert response.status_code == 200, response.text
        assert response.json()["size"] == size


def test_image_provider_and_tools_reject_unsupported_options_without_dispatch(client, tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    base = {"base_url": "https://images.example.com/v1", "model": "gpt-image-2.5-sunburst"}
    configured = client.post("/api/images/provider", json={**base, "size": "1536x864", "quality": "max"})
    assert configured.status_code == 200
    core = client.app.state.service.core
    invalid_sizes = ("16x16", "1024x624", "1537x864", "4096x2048", "3840x3840", "3840x1264", "0x1024", "9" * 100 + "x1024")
    invalid = [{"size": size} for size in invalid_sizes] + [
        {"quality": "ultra"}, {"model": "gpt-image-1.5", "size": "1536x864"},
        {"model": "gpt-image-1.5", "quality": "max"},
        {"model": "gpt-image-2", "quality": "xhigh"},
        {"model": "gpt-image-2.5-flare-preview", "quality": "max"},
    ]
    for options in invalid:
        rejected = client.post("/api/images/provider", json={**base, **options})
        assert rejected.status_code == 422, (options, rejected.text)
        assert client.get("/api/images/provider").json() == configured.json()
    # Tool arguments have their own admission check; a valid saved provider
    # does not let a model override it with unsupported request options.
    (tmp_path / "photo.png").write_bytes(PNG)
    for tool in ("generate_image", "edit_image"):
        for options in [{"size": size} for size in invalid_sizes] + [{"quality": "ultra"}]:
            result = core._run_tool_call(ToolCall(tool, {"prompt": "Harbour", "source": "photo.png", **options}), _once)
            assert result.startswith(f"Error: '{next(iter(options))}'"), (options, result)
    assert stub.calls == []
    assert core.tool_ctx.image_generations_this_turn == 0
    assert core.tool_ctx.image_generations_this_session == 0
    assert _images(tmp_path) == []
    assert not (tmp_path / "photo-edited.png").exists()


def test_image_provider_default_is_sunburst_and_explicit_legacy_choice_is_preserved(client):
    base = {"base_url": "https://images.example.com/v1"}
    assert client.post("/api/images/provider", json=base).json()["model"] == "gpt-image-2.5-sunburst"
    for model in ("gpt-image-1", "gpt-image-1-mini", "gpt-image-1.5", "gpt-image-2"):
        response = client.post("/api/images/provider", json={**base, "model": model, "quality": "high"})
        assert response.status_code == 200
        assert response.json()["model"] == model


def test_provider_route_never_persists_logs_or_echoes_the_key(client, tmp_path, monkeypatch):
    from ollama_code import config as config_mod

    svc = client.app.state.service
    body = {"enabled": True, "account_id": "acct-1", "account_label": "OpenAI — Work",
            "base_url": "https://images.example.com", "api_key": KEY,
            "model": "gpt-image-1", "size": "auto", "quality": "high"}
    response = client.post("/api/images/provider", json=body)
    assert response.status_code == 200
    assert response.json() == {
        "configured": True, "host": "images.example.com", "model": "gpt-image-1",
        "size": "auto", "quality": "high", "account_id": "acct-1",
        "account_label": "OpenAI — Work", "has_api_key": True,
        "provider": "api",
    }
    assert client.get("/api/images/provider").json() == response.json()
    for text in (response.text, client.get("/api/config").text, client.get("/api/provider").text,
                 json.dumps(svc.core.provider_state()), json.dumps(svc.core.config, default=str)):
        assert KEY not in text
    config_mod.save_config(svc.core.config)
    assert KEY not in config_mod.CONFIG_PATH.read_text()
    assert IMAGE_TOOL_NAMES <= _names(svc.core)
    assert svc.core.tool_ctx.image_provider["host"] == "images.example.com"
    assert "api_key" not in svc.core.tool_ctx.image_provider

    stub = ProviderStub(monkeypatch)
    core = svc.core
    core.client = FakeClient([
        ChatResponse(tool_calls=[ToolCall("generate_image", {"prompt": "A harbour at dusk"})], done=True),
        ChatResponse(content_parts=["Here is the harbour."], done=True),
    ])
    core.perms.set_mode("bypass")
    svc.run_store.start_run("run-img", session_id=core.session.session_id, state="running",
                            run_kind="solo", manifest={})
    svc.active_run_id = "run-img"
    events = []
    forward = core._event_handler
    core.on_event(lambda event: (events.append(event), forward(event)))
    core.run_turn("Make me a harbour picture")
    assert stub.calls[0][1]["headers"]["Authorization"] == f"Bearer {KEY}"
    assert _images(tmp_path) == ["a-harbour-at-dusk.png"]
    for text in (json.dumps(events, default=str), core.session.path.read_text(),
                 json.dumps(svc.run_store.events("run-img"), default=str)):
        assert KEY not in text and PNG_B64 not in text

    cleared = client.post("/api/images/provider", json={"enabled": False})
    assert cleared.status_code == 200 and cleared.json()["configured"] is False
    assert cleared.json()["has_api_key"] is False
    assert not IMAGE_TOOL_NAMES & _names(core)
    assert core.tool_ctx.image_provider is None
    assert core._run_tool_call(ToolCall("generate_image", {"prompt": "again"}), _once).startswith("Error:")
    assert len(stub.calls) == 1


def test_provider_route_validates_url_enums_capability_and_busy_state(client, monkeypatch):
    base = {"enabled": True, "api_key": KEY, "model": "gpt-image-1"}
    rejected = client.post("/api/images/provider", json={**base, "base_url": "http://images.example.com"})
    assert rejected.status_code == 422 and "HTTPS" in rejected.text
    assert client.get("/api/images/provider").json()["configured"] is False
    keyless = client.post("/api/images/provider", json={**base, "api_key": "", "base_url": "http://images.example.com"})
    assert keyless.status_code == 422
    loopback = client.post("/api/images/provider", json={**base, "base_url": "http://localhost:8080"})
    assert loopback.status_code == 200 and loopback.json()["host"] == "localhost"
    for bad in (
        {**base, "base_url": "https://images.example.com", "size": "huge"},
        {**base, "base_url": "https://images.example.com", "quality": "ultra"},
        {**base, "base_url": "https://images.example.com", "model": "bad model!"},
        {**base, "base_url": "https://user:pw@images.example.com"},
        {**base, "base_url": "https://images.example.com", "api_key": "k" * 4097},
        {**base, "base_url": "https://images.example.com", "enabled": "yes"},
        {"enabled": True},
    ):
        assert client.post("/api/images/provider", json=bad).status_code == 422, bad
    assert client.get("/api/images/provider").json()["host"] == "localhost"

    svc = client.app.state.service
    svc.turn_future = Future()
    busy = client.post("/api/images/provider", json={**base, "base_url": "https://images.example.com"})
    assert busy.status_code == 409
    svc.turn_future = None

    monkeypatch.setenv(CAPABILITY_ENV["image_generation_v1"], "0")
    assert client.get("/api/images/provider").status_code == 404
    off = client.post("/api/images/provider", json={**base, "base_url": "https://images.example.com"})
    assert off.status_code == 404 and "image_generation_v1" in off.text
    assert not svc.core.tool_registry.image_tool_allowed("generate_image")


# ----------------------------------------------------------------- previews


def test_preview_names_prompt_model_host_destination_and_counters(tmp_path):
    core = _core(tmp_path, [])
    _install(core)
    ctx = core.tool_ctx
    ctx.image_generations_this_turn = 1
    ctx.image_generations_this_session = 3
    prompt = "A sunset over the harbour, painterly, with fishing boats and a lighthouse on the far pier"
    summary, detail = build_preview("generate_image", {"prompt": prompt, "size": "1024x1536"}, ctx)
    assert summary == 'generate image: "A sunset over the harbour, painterly, with fishing boats and…"'
    assert f"Prompt: {prompt}" in detail
    assert "Model · Size · Quality: gpt-image-1 · 1024x1536 · auto" in detail
    assert "Provider host: images.example.com (OpenAI — Work)" in detail
    assert "Saves to: Locus Images/a-sunset-over-the-harbour-painterly-with-fishing.png" in detail
    assert f"Limit: 1 of {MAX_IMAGES_PER_TURN} used this turn, 3 of {MAX_IMAGES_PER_SESSION} this session." in detail
    assert "The prompt is sent to the provider." in detail
    assert KEY not in detail and "Sends:" not in detail
    assert file_effects("generate_image", {"prompt": prompt}, ctx) == [
        {"path": "Locus Images/a-sunset-over-the-harbour-painterly-with-fishing.png", "effect": "create"},
    ]

    (tmp_path / "photo.png").write_bytes(PNG)
    (tmp_path / "mask.png").write_bytes(png_bytes(64, 48))
    summary, detail = build_preview("edit_image", {"prompt": "Make it night", "source": "photo.png", "mask": "mask.png"}, ctx)
    assert summary == 'edit image photo.png: "Make it night"'
    assert f"Sends: photo.png ({len(PNG)} bytes) and mask.png ({len(PNG)} bytes) leave this Mac." in detail
    assert "Saves to: photo-edited.png" in detail
    assert file_effects("edit_image", {"prompt": "x", "source": "photo.png"}, ctx) == [
        {"path": "photo-edited.png", "effect": "create"},
    ]
    assert file_effects("edit_image", {"prompt": "x", "source": "attachment:shot.png"}, ctx) == [
        {"path": "Locus Images/x.png", "effect": "create"},
    ]
    assert file_effects("generate_image", {"prompt": "x", "filename": "/etc/x.png"}, ctx) == []

    bare = ToolContext(cwd=str(tmp_path))
    _, unconfigured = build_preview("generate_image", {"prompt": "x"}, bare)
    assert "Provider host: not configured" in unconfigured


def test_generate_may_be_always_for_the_session_while_edit_asks_every_time(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core)
    (tmp_path / "photo.png").write_bytes(PNG)
    events = []
    core.on_event(events.append)
    decisions = []

    def always(tool, summary, detail, request_id):
        decisions.append(tool)
        return "always"

    assert not core._run_tool_call(ToolCall("generate_image", {"prompt": "one"}), always).startswith("Error:")
    assert not core._run_tool_call(ToolCall("generate_image", {"prompt": "two"}), always).startswith("Error:")
    requests_seen = [e for e in events if e["type"] == "permission_request"]
    assert [e["tool"] for e in requests_seen] == ["generate_image"]
    assert requests_seen[0]["always_eligible"] is True
    assert decisions == ["generate_image"]
    assert "generate_image" in core.perms.allowed and "generate_image" not in core.perms.always_allow

    for _ in range(2):
        assert not core._run_tool_call(ToolCall("edit_image", {"prompt": "night", "source": "photo.png"}), always).startswith("Error:")
    edits = [e for e in events if e["type"] == "permission_request" and e["tool"] == "edit_image"]
    assert len(edits) == 2 and all(e["always_eligible"] is False for e in edits)
    assert "edit_image" not in core.perms.allowed
    assert len(stub.calls) == 4

    denied = core._run_tool_call(ToolCall("edit_image", {"prompt": "x", "source": "photo.png"}), lambda *a: "deny")
    assert denied.startswith("Permission denied") and len(stub.calls) == 4


# -------------------------------------------------------------- generation


def test_generate_writes_png_stages_image_part_and_reports_effects_without_bytes(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("generate_image", {"prompt": "A sunset over the harbour", "title": "Harbour sunset"})], done=True),
        ChatResponse(content_parts=["Done."], done=True),
    ])
    _install(core)
    events = []
    core.on_event(events.append)
    core.run_turn("Paint me a harbour", _once)

    url, kwargs = stub.calls[0]
    assert url == "https://images.example.com/v1/images/generations"
    assert kwargs["json"] == {"model": "gpt-image-1", "prompt": "A sunset over the harbour", "n": 1}
    assert kwargs["headers"]["Authorization"] == f"Bearer {KEY}" and "User-Agent" in kwargs["headers"]
    assert kwargs["timeout"] == (10, 180) and kwargs["stream"] is True and kwargs["allow_redirects"] is False

    written = tmp_path / "Locus Images" / "a-sunset-over-the-harbour.png"
    assert written.read_bytes() == PNG and image_info(written).width == 64
    assert oct(written.stat().st_mode & 0o777) == "0o644"
    assert _images(tmp_path) == ["a-sunset-over-the-harbour.png"]

    result = next(e for e in events if e["type"] == "tool_result")
    assert result["ok"] is True
    assert result["result"].startswith(
        f"Created image Locus Images/a-sunset-over-the-harbour.png (64×48 PNG, {len(PNG)} bytes, gpt-image-1). "
        "It is attached to your final answer as an image card; do not repeat it in prose or Markdown. "
        f"{MAX_IMAGES_PER_TURN - 1} generations remain this turn."
    )
    assert PNG_B64 not in result["result"] and len(result["result"]) < 400
    assert result["file_effects"] == [{"path": "Locus Images/a-sunset-over-the-harbour.png", "effect": "create"}]
    assert result["activity_label"] == "Created image Locus Images/a-sunset-over-the-harbour.png"
    proposed = next(e for e in events if e["type"] == "tool_call_proposed")
    assert proposed["summary"] == 'generate image: "A sunset over the harbour"'

    staged = [e for e in core.session.load(core.session.path) if False]  # journal is checked below
    journal = [json.loads(line) for line in core.session.path.read_text().splitlines()]
    assert any(entry.get("type") == "response_parts_staged" and entry["parts"][0]["type"] == "image" for entry in journal)
    final = core.messages[-1]
    part = final["_response_parts"]["parts"][1]
    assert part["type"] == "image" and part["path"] == "Locus Images/a-sunset-over-the-harbour.png"
    assert (part["width"], part["height"], part["format"], part["size"]) == (64, 48, "png", len(PNG))
    assert part["title"] == "Harbour sunset" and part["alt"] == "Harbour sunset"
    assert part["prompt"] == "A sunset over the harbour" and "source_path" not in part
    assert "![Harbour sunset](" in final["content"] and "Locus%20Images/a-sunset-over-the-harbour.png" in final["content"]
    assert staged == []
    for line in core.session.path.read_text().splitlines():
        assert len(line.encode()) < MAX_SESSION_LINE_BYTES and PNG_B64 not in line


def test_generate_never_overwrites_and_respects_size_quality_and_filename(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core, _provider_config(size="1024x1024", quality="low", model="dall-e-3"))
    folder = tmp_path / "Locus Images"
    folder.mkdir()
    (folder / "logo.png").write_bytes(b"existing")
    core.perms.set_mode("bypass")
    first = core._run_tool_call(ToolCall("generate_image", {"prompt": "Logo", "quality": "high"}), None)
    assert "Created image Locus Images/logo-2.png" in first
    assert stub.calls[0][1]["json"] == {"model": "dall-e-3", "prompt": "Logo", "n": 1, "size": "1024x1024",
                                        "quality": "high", "response_format": "b64_json"}
    second = core._run_tool_call(ToolCall("generate_image", {"prompt": "Logo"}), None)
    assert "Created image Locus Images/logo-3.png" in second
    assert (folder / "logo.png").read_bytes() == b"existing"
    custom = core._run_tool_call(ToolCall("generate_image", {"prompt": "Logo", "filename": "art/brand.jpg"}), None)
    assert "Created image art/brand.png" in custom and (tmp_path / "art" / "brand.png").read_bytes() == PNG
    assert core._run_tool_call(ToolCall("generate_image", {"prompt": "Logo", "size": "9000x9000"}), None).startswith("Error: 'size'")
    assert _images(tmp_path) == ["logo-2.png", "logo-3.png", "logo.png"]
    assert not any(name.startswith(".tmp") for name in _images(tmp_path))


@pytest.mark.parametrize("filename, reason", [
    ("/tmp/outside.png", "relative"),
    ("~/outside.png", "relative"),
    ("../outside.png", "'..'"),
    ("art/../../outside.png", "'..'"),
    (".hidden/picture.png", "dot"),
    ("art/.picture.png", "dot"),
    ("linked/picture.png", "symlink"),
])
def test_generate_refuses_escaping_hidden_and_symlinked_filenames(tmp_path, monkeypatch, filename, reason):
    stub = ProviderStub(monkeypatch)
    outside = tmp_path.parent / "outside-target"
    outside.mkdir(exist_ok=True)
    (tmp_path / "linked").symlink_to(outside, target_is_directory=True)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "x", "filename": filename}), None)
    assert result.startswith("Error:") and reason in result
    assert stub.calls == [] and _images(tmp_path) == [] and not list(outside.iterdir())
    with pytest.raises(ValueError):
        plan_destination(core.tool_ctx, filename, "x")


@pytest.mark.parametrize("response, reason", [
    (FakeResponse(302, text=""), "redirected"),
    (FakeResponse(200, text=json.dumps({"data": [{"url": "https://cdn.example.com/x.png"}]})), "image URL"),
    (FakeResponse(200, text=json.dumps({"data": []})), "no image"),
    (FakeResponse(200, text=json.dumps({"data": [{"b64_json": "@@@not base64@@@"}]})), "unreadable image data"),
    (FakeResponse(200, text=json.dumps({"data": [{"b64_json": base64.b64encode(b"<svg/>").decode()}]})), "not a PNG"),
    (FakeResponse(200, text=json.dumps({"data": [{"b64_json": base64.b64encode(jpeg_bytes()).decode()}]})), "not a PNG"),
    (FakeResponse(200, text="not json at all"), "unreadable response"),
])
def test_bad_provider_payloads_are_refused_without_writing(tmp_path, monkeypatch, response, reason):
    ProviderStub(monkeypatch, [response])
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "x"}), None)
    assert result.startswith("Error:") and reason in result
    assert _images(tmp_path) == [] and core.tool_ctx.response_parts == {}
    assert core.tool_ctx.image_generations_this_turn == 0


def test_oversize_bodies_and_images_are_refused_before_writing(tmp_path, monkeypatch):
    monkeypatch.setattr(image_generation, "MAX_RESPONSE_BYTES", 2_000)
    ProviderStub(monkeypatch, [FakeResponse(200, text="x" * 3_000)])
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "x"}), None)
    assert result.startswith("Error:") and "safety limit" in result
    monkeypatch.setattr(image_generation, "MAX_RESPONSE_BYTES", 40_000_000)
    monkeypatch.setattr(image_generation, "MAX_DECODED_BYTES", len(PNG) - 1)
    ProviderStub(monkeypatch, [_ok()])
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "x"}), None)
    assert result.startswith("Error:") and "over 20 MB" in result
    assert _images(tmp_path) == []


def test_provider_errors_are_redacted_and_carry_no_response_body(tmp_path, monkeypatch):
    import requests

    body = json.dumps({"error": {"code": "moderation_blocked", "message": f"leaked {KEY} and a long body"}})
    responses = [
        FakeResponse(400, text=body),
        FakeResponse(401, text=json.dumps({"error": {"message": f"bad key {KEY}"}})),
        FakeResponse(429, text=""),
        FakeResponse(503, text="<html>gateway</html>"),
        FakeResponse(400, text=json.dumps({"error": {"code": "x" * 41}})),
    ]
    stub = ProviderStub(monkeypatch, responses)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    call = ToolCall("generate_image", {"prompt": "x"})
    blocked = core._run_tool_call(call, None)
    assert "moderation_blocked" in blocked and "do not retry the same prompt" in blocked
    unauthorized = core._run_tool_call(call, None)
    assert "(401)" in unauthorized and "check the account in Settings" in unauthorized
    limited = core._run_tool_call(call, None)
    assert "(429)" in limited and "do not retry automatically" in limited
    down = core._run_tool_call(call, None)
    assert "unavailable (503)" in down
    generic = core._run_tool_call(call, None)
    assert generic == "Error: the provider rejected the request (400)."
    for text in (blocked, unauthorized, limited, down, generic):
        assert KEY not in text and "leaked" not in text and "gateway" not in text and "long body" not in text

    monkeypatch.setenv("HTTPS_PROXY", "http://alice:s3cret@proxy.corp:3128")

    def explode(url, **kwargs):
        raise requests.exceptions.InvalidURL(f"Failed to parse {KEY} via http://alice:s3cret@proxy.corp:3128")

    monkeypatch.setattr(image_generation.requests, "post", explode)
    failed = core._run_tool_call(call, None)
    assert failed.startswith("Error: the provider request failed: InvalidURL")
    assert "[redacted]" in failed and KEY not in failed and "s3cret" not in failed
    assert len(stub.calls) == 5 and _images(tmp_path) == []


def test_interrupt_closes_the_response_and_writes_nothing(tmp_path, monkeypatch):
    class Stoppable(FakeResponse):
        closed = False

        def iter_content(self, chunk_size=64 * 1024):
            ctx.should_stop = lambda: True
            yield b"{\"data\": [{\"b64_json\": \""
            yield PNG_B64.encode() + b"\"}]}"

        def close(self):
            self.closed = True

    response = Stoppable(200)
    ProviderStub(monkeypatch, [response])
    ctx = ToolContext(cwd=str(tmp_path))
    service = ImageGenerationService()
    service.configure(_provider_config())
    assert service.execute("generate_image", {"prompt": "x"}, ctx) == INTERRUPTED
    assert response.closed is True
    assert _images(tmp_path) == [] and ctx.image_generations_this_turn == 0

    ctx.should_stop = lambda: True
    calls = ProviderStub(monkeypatch)
    assert service.execute("generate_image", {"prompt": "x"}, ctx) == INTERRUPTED
    assert calls.calls == []


def test_stop_during_the_provider_header_wait_returns_at_once_and_closes_the_late_response(tmp_path, monkeypatch):
    """The Images API sends no headers until the picture is done; Stop must not wait for it."""
    import threading
    import time

    class Late(FakeResponse):
        closed = False

        def close(self):
            self.closed = True

    release = threading.Event()
    arrived = threading.Event()
    late = Late(200, text=json.dumps({"data": [{"b64_json": PNG_B64}]}))

    def blocking_post(url, **kwargs):
        release.wait(5)
        arrived.set()
        return late

    monkeypatch.setattr(image_generation.requests, "post", blocking_post)
    ctx = ToolContext(cwd=str(tmp_path))
    stop = threading.Event()
    ctx.should_stop = stop.is_set
    service = ImageGenerationService()
    service.configure(_provider_config())
    threading.Timer(0.1, stop.set).start()
    started = time.monotonic()
    assert service.execute("generate_image", {"prompt": "x"}, ctx) == INTERRUPTED
    assert time.monotonic() - started < 1.0
    assert _images(tmp_path) == [] and ctx.image_generations_this_turn == 0
    assert not arrived.is_set() and late.closed is False

    release.set()
    assert arrived.wait(2)
    deadline = time.monotonic() + 2
    while not late.closed and time.monotonic() < deadline:
        time.sleep(0.01)
    assert late.closed is True, "the abandoned late response must be closed by the helper thread"


def test_keys_with_control_characters_are_rejected_and_redacted_in_escaped_form(client, tmp_path):
    body = {"enabled": True, "base_url": "https://images.example.com", "model": "gpt-image-1"}
    for key in ("sk-abc\ndef-SECRET", "sk-abc\tdef-SECRET", "sk-abc\x00def-SECRET", "sk-abc def-SECRET"):
        rejected = client.post("/api/images/provider", json={**body, "api_key": key})
        assert rejected.status_code == 422, repr(key)
        assert "control characters" in rejected.text
        assert "SECRET" not in rejected.text and "sk-abc" not in rejected.text
    assert client.get("/api/images/provider").json()["configured"] is False

    # Belt and braces: a key that bypassed parse still never reaches the model
    # in the repr-escaped form ``requests`` puts into ``InvalidHeader``.
    key = "sk-abc\ndef-SECRET"
    ctx = ToolContext(cwd=str(tmp_path))
    service = ImageGenerationService()
    service.configure(_provider_config(api_key=key))
    result = service.execute("generate_image", {"prompt": "x"}, ctx)
    assert result.startswith("Error: the provider request failed: InvalidHeader")
    assert "[redacted]" in result
    for leak in (key, repr(key)[1:-1], "sk-abc\\ndef", "SECRET"):
        assert leak not in result, leak
    assert _images(tmp_path) == []


def test_oversize_error_bodies_report_the_real_limit_in_kilobytes(tmp_path, monkeypatch):
    ProviderStub(monkeypatch, [FakeResponse(503, text="<html>" + "x" * 70_000)])
    ctx = ToolContext(cwd=str(tmp_path))
    service = ImageGenerationService()
    service.configure(_provider_config())
    result = service.execute("generate_image", {"prompt": "x"}, ctx)
    assert result == "Error: the provider response exceeds the 66 KB safety limit."
    assert "0 MB" not in result and "<html>" not in result

    monkeypatch.setattr(image_generation, "MAX_RESPONSE_BYTES", 3_000_000)
    ProviderStub(monkeypatch, [FakeResponse(200, text="x" * 3_000_001)])
    assert service.execute("generate_image", {"prompt": "x"}, ctx) == (
        "Error: the provider response exceeds the 3.0 MB safety limit."
    )
    assert _images(tmp_path) == []


# ------------------------------------------------------------------- limits


def test_caps_hold_per_turn_and_per_session_in_bypass_and_reset_on_new_turn_and_retry(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [ChatResponse(content_parts=["ok"], done=True), ChatResponse(content_parts=["ok"], done=True)])
    _install(core)
    core.perms.set_mode("bypass")
    call = ToolCall("generate_image", {"prompt": "x"})
    for expected in range(MAX_IMAGES_PER_TURN - 1, -1, -1):
        assert f"{expected} generation{'' if expected == 1 else 's'} remain this turn" in core._run_tool_call(call, None)
    capped = core._run_tool_call(call, None)
    assert capped.startswith("Error:") and f"{MAX_IMAGES_PER_TURN} images per turn" in capped
    assert "ask the user before generating more" in capped
    assert len(stub.calls) == MAX_IMAGES_PER_TURN and len(_images(tmp_path)) == MAX_IMAGES_PER_TURN
    assert core.tool_ctx.image_generations_this_session == MAX_IMAGES_PER_TURN

    core.run_turn("next")
    assert core.tool_ctx.image_generations_this_turn == 0
    assert core.tool_ctx.image_generations_this_session == MAX_IMAGES_PER_TURN
    assert not core._run_tool_call(call, None).startswith("Error:")

    core.tool_ctx.image_generations_this_turn = MAX_IMAGES_PER_TURN
    assert core.retry_last_response() is True
    assert core.tool_ctx.image_generations_this_turn == 0

    core.tool_ctx.image_generations_this_session = MAX_IMAGES_PER_SESSION
    session_capped = core._run_tool_call(call, None)
    assert session_capped.startswith("Error:") and f"{MAX_IMAGES_PER_SESSION} images per session" in session_capped
    before = len(stub.calls)
    assert core._run_tool_call(ToolCall("edit_image", {"prompt": "x", "source": "Locus Images/x.png"}), None).startswith("Error:")
    assert len(stub.calls) == before

    core.reset_conversation()
    assert core.tool_ctx.image_generations_this_session == 0
    assert core.tool_ctx.image_generations_this_turn == 0


# ------------------------------------------------------------------ editing


def test_edit_uploads_workspace_source_and_mask_as_multipart(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    (tmp_path / "shots").mkdir()
    source = tmp_path / "shots" / "photo.png"
    source.write_bytes(PNG)
    mask = png_bytes(64, 48)
    (tmp_path / "shots" / "mask.png").write_bytes(mask)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("edit_image", {"prompt": "Make it night", "source": "shots/photo.png", "mask": "shots/mask.png", "size": "1536x1024"})], done=True),
        ChatResponse(content_parts=["Edited."], done=True),
    ])
    _install(core)
    events = []
    core.on_event(events.append)
    core.run_turn("Edit my photo", _once)

    url, kwargs = stub.calls[0]
    assert url == "https://images.example.com/v1/images/edits"
    assert kwargs["json"] is None
    assert kwargs["files"] == {"image": ("photo.png", PNG, "image/png"), "mask": ("mask.png", mask, "image/png")}
    assert kwargs["data"] == {"model": "gpt-image-1", "prompt": "Make it night", "n": "1", "size": "1536x1024"}
    result = next(e for e in events if e["type"] == "tool_result")
    assert result["result"].startswith("Edited image shots/photo-edited.png from photo.png (64×48 PNG")
    assert result["activity_label"] == "Edited image shots/photo-edited.png"
    assert result["file_effects"] == [{"path": "shots/photo-edited.png", "effect": "create"}]
    assert (tmp_path / "shots" / "photo-edited.png").read_bytes() == PNG and source.read_bytes() == PNG
    part = core.messages[-1]["_response_parts"]["parts"][1]
    assert part["source_path"] == "shots/photo.png" and part["path"] == "shots/photo-edited.png"
    assert "edited from shots/photo.png" in core.messages[-1]["content"]
    request = next(e for e in events if e["type"] == "permission_request")
    assert request["always_eligible"] is False and "Sends: shots/photo.png" in request["detail"]


def test_edit_rejects_bad_sources_and_masks_without_uploading(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    (tmp_path / "notes.txt").write_text("text")
    (tmp_path / "fake.png").write_text("not an image")
    (tmp_path / "photo.png").write_bytes(PNG)
    (tmp_path / "photo.jpg").write_bytes(jpeg_bytes())
    outside = tmp_path.parent / "outside-source"
    outside.mkdir(exist_ok=True)
    (outside / "leak.png").write_bytes(PNG)
    (tmp_path / "escape").symlink_to(outside, target_is_directory=True)
    big = tmp_path / "big.png"
    big.write_bytes(PNG)
    os.truncate(big, 15 * 1024 * 1024 + 1)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    for args, reason in [
        ({"prompt": "x"}, "'source' is required"),
        ({"prompt": "x", "source": "missing.png"}, "not found"),
        ({"prompt": "x", "source": "notes.txt"}, "PNG, JPEG, GIF or WebP"),
        ({"prompt": "x", "source": "fake.png"}, "not a readable"),
        ({"prompt": "x", "source": "../outside-source/leak.png"}, "inside the workspace"),
        ({"prompt": "x", "source": "escape/leak.png"}, "symlink"),
        ({"prompt": "x", "source": str(outside / "leak.png")}, "inside the workspace"),
        ({"prompt": "x", "source": "big.png"}, "15 MB"),
        ({"prompt": "x", "source": "photo.png", "mask": "photo.jpg"}, "mask must be a PNG"),
        ({"prompt": "x", "source": "photo.png", "mask": "missing.png"}, "not found"),
        ({"prompt": "x", "source": "attachment:nothing.png"}, "no image named"),
        ({"prompt": "", "source": "photo.png"}, "'prompt' is required"),
        ({"prompt": "p" * 4001, "source": "photo.png"}, "at most 4000"),
    ]:
        result = core._run_tool_call(ToolCall("edit_image", args), None)
        assert result.startswith("Error:") and reason in result, (args, result)
    assert stub.calls == [] and not (tmp_path / "photo-edited.png").exists()


def test_attachment_sources_resolve_for_the_current_turn_only(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    shot = png_bytes(20, 10)
    attachment = {"name": "shot.png", "mime_type": "image/png", "data": base64.b64encode(shot).decode()}
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("edit_image", {"prompt": "Brighten", "source": "attachment:shot.png"})], done=True),
        ChatResponse(content_parts=["Brightened."], done=True),
        ChatResponse(tool_calls=[ToolCall("edit_image", {"prompt": "Again", "source": "attachment:shot.png"})], done=True),
        ChatResponse(content_parts=["Could not."], done=True),
    ])
    _install(core)
    core.perms.set_mode("bypass")
    events = []
    core.on_event(events.append)
    core.run_turn("Brighten this", attachments=[attachment])
    assert stub.calls[0][1]["files"] == {"image": ("shot.png", shot, "image/png")}
    first = [e for e in events if e["type"] == "tool_result"][0]
    assert first["result"].startswith("Edited image Locus Images/brighten.png from shot.png")
    assert "source_path" not in core.messages[-1]["_response_parts"]["parts"][1]
    assert base64.b64encode(shot).decode() not in core.session.path.read_text()

    core.run_turn("Do it again")
    assert core.tool_ctx.turn_attachments == []
    second = [e for e in events if e["type"] == "tool_result"][-1]
    assert second["result"].startswith("Error:") and "no image named 'shot.png'" in second["result"]
    assert len(stub.calls) == 1

    # A text attachment with an image name is not an image.
    core.tool_ctx.turn_attachments = [{"name": "doc.png", "mime_type": "text/plain", "data": "aGk="}]
    assert "not an image" in core._run_tool_call(ToolCall("edit_image", {"prompt": "x", "source": "attachment:doc.png"}), None)


# ------------------------------------------------------------- authority


def test_image_tools_are_unavailable_to_ask_identity_role_contract_helpers_and_unattended_runs(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    call = ToolCall("generate_image", {"prompt": "x"})

    assert core._run_tool_call(call, None, track_active=False).startswith("Error: image tools belong only")
    core.helper_allowed_tools = {"read_file"}
    assert core._run_tool_call(call, None).startswith("Error: image tools belong only")
    del core.helper_allowed_tools
    core._turn_allows_tools = False
    assert core._run_tool_call(call, None).startswith("Error: image tools belong only")
    core._turn_allows_tools = True
    core.configure_agent({}, mode="work", role_contract="You are a reviewer.")
    assert core.agent_role_contract and core._run_tool_call(call, None).startswith("Error: image tools belong only")
    core.configure_agent({}, mode="work")
    core.identity_mode = True
    assert core._run_tool_call(call, None).startswith("Error: image tools belong only")
    core.identity_mode = False
    assert stub.calls == [] and _images(tmp_path) == []
    # Ask mode runs with tools off, which the root guard above already refuses.
    ask = _core(tmp_path, [ChatResponse(content_parts=["No tools here."], done=True)])
    _install(ask)
    ask.run_turn("Draw me something", allow_tools=False)
    assert stub.calls == [] and ask.tool_ctx.response_parts == {}

    svc = ChatService(core)
    # The service owns the executor; configure it the way the route does.
    svc.configure_image_provider({"enabled": True, "base_url": "https://images.example.com", "api_key": KEY})
    svc.core.perms.set_mode("bypass")
    for manifest in ({"scheduled": True}, {"event_triggered": True}, {"automation_workflow": True}):
        monkeypatch.setattr(svc.run_store, "run", lambda run_id, manifest=manifest, **_: {"manifest": manifest})
        svc.active_run_id = "run-unattended"
        result = core._run_tool_call(call, None)
        assert result.startswith("Error: image generation is unavailable in unattended runs"), manifest
    assert stub.calls == []
    monkeypatch.setattr(svc.run_store, "run", lambda run_id, **_: {"manifest": {"solo_swarm": False}})
    assert not core._run_tool_call(call, None).startswith("Error:")
    assert len(stub.calls) == 1


def test_capability_policy_off_removes_image_tools_and_refuses_at_dispatch_naming_the_cause(tmp_path, monkeypatch):
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    call = ToolCall("generate_image", {"prompt": "x"})
    policy_refusal = ("Error: generate_image is not allowed by this agent's capability policy; "
                      "it needs both network and workspace write access.")
    for policy in ({"network": False}, {"workspace_write": False}):
        core.tool_registry.set_user_capability_policy(policy)
        assert not IMAGE_TOOL_NAMES & _names(core), policy
        assert not IMAGE_TOOL_NAMES & _names(core, parity=True), policy
        assert not core.tool_registry.image_tool_allowed("generate_image")
        assert core._run_tool_call(call, None) == policy_refusal, policy
    core.tool_registry.set_user_capability_policy({})
    assert IMAGE_TOOL_NAMES <= _names(core)

    core.tool_registry.set_mcp_agent_policy(None, access_ceiling="read_only")
    assert not IMAGE_TOOL_NAMES & _names(core) and not IMAGE_TOOL_NAMES & _names(core, parity=True)
    assert core._run_tool_call(call, None) == "Error: generate_image is not available to a read-only agent."
    core.tool_registry.set_mcp_agent_policy(None)

    monkeypatch.setenv(CAPABILITY_ENV["image_generation_v1"], "off")
    assert not IMAGE_TOOL_NAMES & _names(core)
    assert core._run_tool_call(call, None) == (
        "Error: generate_image is disabled in this build (the image_generation_v1 capability is off)."
    )
    monkeypatch.delenv(CAPABILITY_ENV["image_generation_v1"])

    # Only a missing provider earns the setup hint; every other gate names itself.
    core.tool_registry.image_generation_enabled = False
    unconfigured = core._run_tool_call(call, None)
    assert unconfigured == f"Error: generate_image is not available in this session; {SETUP_HINT}."
    core.tool_registry.image_generation_enabled = True
    for text in (policy_refusal, unconfigured):
        assert (SETUP_HINT in text) == (text is unconfigured)
    assert stub.calls == [] and _images(tmp_path) == []
    assert not core._run_tool_call(call, None).startswith("Error:")


def test_plan_mode_hides_image_tools_on_both_routes_and_refuses_a_guessed_call(tmp_path, monkeypatch):
    """PROTOCOL.md: the tools are advertised only outside Plan mode, on the classic route too."""
    stub = ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    call = ToolCall("generate_image", {"prompt": "x"})
    assert IMAGE_TOOL_NAMES <= _names(core) and IMAGE_TOOL_NAMES <= _names(core, parity=True)

    core.configure_agent(None, mode="plan")
    assert core.tool_registry.plan_mode is True
    assert not IMAGE_TOOL_NAMES & _names(core), "classic route"
    assert not IMAGE_TOOL_NAMES & _names(core, parity=True, plan_mode=True), "parity route"
    assert not IMAGE_TOOL_NAMES & _names(core, parity=True), "the registry flag alone hides them"
    assert "submit_plan" in _names(core, parity=True, plan_mode=True)
    assert core._run_tool_call(call, None) == (
        "Error: generate_image is not available in Plan mode; planning modifies no files."
    )
    assert core._run_tool_call(ToolCall("edit_image", {"prompt": "x", "source": "a.png"}), None).startswith(
        "Error: edit_image is not available in Plan mode"
    )
    assert stub.calls == [] and _images(tmp_path) == []

    # A direct mode assignment (the /api/agent/mode route) re-arms them too.
    core.agent_mode = "work"
    assert core.tool_registry.plan_mode is False
    assert IMAGE_TOOL_NAMES <= _names(core) and IMAGE_TOOL_NAMES <= _names(core, parity=True)
    assert not core._run_tool_call(call, None).startswith("Error:")
    assert len(stub.calls) == 1


# ------------------------------------------------------------------ output


def test_staging_unavailable_result_points_the_model_at_a_markdown_link(tmp_path, monkeypatch):
    ProviderStub(monkeypatch)
    ctx = ToolContext(cwd=str(tmp_path))
    ctx.response_parts_enabled = False
    service = ImageGenerationService()
    service.configure(_provider_config())
    result = service.execute("generate_image", {"prompt": "A tiny robot"}, ctx)
    assert result.startswith("Created image Locus Images/a-tiny-robot.png (64×48 PNG")
    assert "reference it in your answer as ![A tiny robot](Locus%20Images/a-tiny-robot.png)" in result
    assert "attached to your final answer" not in result
    assert (tmp_path / "Locus Images" / "a-tiny-robot.png").read_bytes() == PNG
    assert ctx.response_parts == {} and ctx.image_generations_this_turn == 1
    assert ctx.last_image_result["path"] == "Locus Images/a-tiny-robot.png"


def test_silent_image_only_deliverable_becomes_a_written_answer(tmp_path, monkeypatch):
    ProviderStub(monkeypatch)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("generate_image", {"prompt": "A fox", "title": "Fox"})], done=True),
        ChatResponse(content_parts=[], done=True),
    ])
    _install(core)
    core.perms.set_mode("bypass")
    events = []
    core.on_event(events.append)
    core.run_turn("Show me a fox")
    assert core.client.calls == 2
    final = core.messages[-1]
    assert final["role"] == "assistant" and final["_phase"] == "final_answer"
    assert [part["type"] for part in final["_response_parts"]["parts"]] == ["image"]
    assert final["content"].startswith("![Fox](") and final["content"].endswith("\n\nFox")
    ended = [e for e in events if e["type"] in {"message_end", "assistant_item_end"}][-1]
    assert ended["response_parts"] == final["_response_parts"]
    assert core.tool_ctx.response_parts == {}


def test_image_staging_holds_the_parts_lock_and_survives_a_stage_error(tmp_path, monkeypatch):
    ProviderStub(monkeypatch)
    core = _core(tmp_path, [])
    _install(core)
    core.perms.set_mode("bypass")
    seen = []
    original = core._stage_response_parts

    def observed(parts):
        seen.append(core._response_parts_lock.acquire(blocking=False))
        if seen[-1]:
            core._response_parts_lock.release()
        return original(parts)

    core.tool_ctx.stage_response_parts = observed
    assert core._run_tool_call(ToolCall("generate_image", {"prompt": "x"}), None).startswith("Created image")
    assert seen == [True]  # an RLock re-acquires for its owner: the call ran on this thread under the lock
    assert list(core.tool_ctx.response_parts) == ["image-x"]

    core.tool_ctx.stage_response_parts = lambda parts: "Error: staged output exceeds the response document limit"
    result = core._run_tool_call(ToolCall("generate_image", {"prompt": "y"}), None)
    assert result.startswith("Created image Locus Images/y.png") and "reference it in your answer" in result
    assert (tmp_path / "Locus Images" / "y.png").exists()
