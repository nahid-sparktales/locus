"""MCP images reach providers and chat without becoming paths or log payloads."""
import base64
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from ollama_code import mcp_media as media
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.sessions import SessionStore

# A complete 1x1 PNG; provider adapters should carry its bytes without alteration.
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf9sAAAAASUVORK5CYII=")
ENCODED = base64.b64encode(PNG).decode()


def image():
    return {"type": "image", "mimeType": "image/png", "data": ENCODED}


def attachments():
    images, notes = media.normalize_mcp_media([image()])
    assert not notes
    return images


def test_inline_embedded_and_resource_images_are_validated_without_server_paths():
    images, notes = media.normalize_mcp_media([
        SimpleNamespace(type="image", mime_type="image/png", data=ENCODED),
        {"type": "resource", "resource": {"uri": "../../escape.png", "mimeType": "image/png", "blob": ENCODED}},
        SimpleNamespace(uri="file:///private/screenshot.png", mime_type="image/png", blob=ENCODED),
        {"type": "text", "text": "evidence"},
    ])
    assert not notes and len(images) == 3
    assert all(item["data"] == ENCODED and item["width"] == item["height"] == 1 for item in images)
    assert [item["name"] for item in images] == [f"mcp-image-{i}.png" for i in range(1, 4)]


@pytest.mark.parametrize("update,expected", [
    ({"data": "not base64"}, "malformed"),
    ({"mimeType": "image/jpeg"}, "bytes do not match"),
    ({"mimeType": "image/svg+xml"}, "unsupported"),
    ({"data": ""}, "missing"),
])
def test_malformed_images_are_omitted_with_reason(update, expected):
    images, notes = media.normalize_mcp_media([{**image(), **update}])
    assert not images and expected in notes[0]


def test_count_and_byte_bounds_are_enforced_before_delivery(monkeypatch):
    images, notes = media.normalize_mcp_media([image()] * 11)
    assert len(images) == 10 and "10 images" in notes[0]
    monkeypatch.setattr(media, "MAX_IMAGE_BYTES", len(PNG) - 2)
    images, notes = media.normalize_mcp_media([image()])
    assert not images and notes
    monkeypatch.setattr(media, "MAX_IMAGE_BYTES", 1024)
    monkeypatch.setattr(media, "MAX_TOTAL_BYTES", len(PNG))
    images, notes = media.normalize_mcp_media([image(), image()])
    assert len(images) == 1 and "25 MiB" in notes[0]


def test_string_and_rich_broker_results_map_to_claude_and_preserve_errors():
    assert media.native_tool_result("plain", []) == "plain"
    assert media.validate_native_tool_result("plain") == "plain"
    rich = media.native_tool_result("Error: screenshot has partial evidence", attachments())
    assert media.validate_native_tool_result(json.loads(json.dumps(rich))) == rich
    assert rich["success"] is False
    claude = media.claude_tool_result(rich)
    assert claude["isError"] is True
    assert claude["content"][1] == {"type": "image", "mimeType": "image/png", "data": ENCODED}
    assert media.claude_tool_result("plain") == {"content": [{"type": "text", "text": "plain"}], "isError": False}
    with pytest.raises(ValueError):
        media.validate_native_tool_result({"content_items": [{"type": "inputImage", "imageUrl": "https://example.org/image.png"}]})


def test_cache_is_session_scoped_and_uses_only_opaque_ids(tmp_path):
    first, second = SessionStore(str(tmp_path)), SessionStore(str(tmp_path))
    saved = media.cache_media(first.session_id, "call-1", attachments())[0]
    data, metadata = media.read_cached_media(first.session_id, saved["id"])
    assert data == PNG and metadata["invocation_id"] == "call-1"
    assert "data" not in metadata and "path" not in metadata
    assert (media.media_directory(first.session_id) / f"{saved['id']}.image").stat().st_mode & 0o777 == 0o600
    with pytest.raises(OSError):
        media.read_cached_media(second.session_id, saved["id"])
    with pytest.raises(ValueError):
        media.read_cached_media(first.session_id, "../escape")
    cached = media.media_directory(first.session_id) / f"{saved['id']}.image"
    cached.unlink()
    cached.symlink_to(tmp_path / "outside")
    with pytest.raises(ValueError):
        media.read_cached_media(first.session_id, saved["id"])


def test_media_follows_duplicate_trash_restore_including_id_collision(tmp_path):
    session = SessionStore(str(tmp_path))
    saved = media.cache_media(session.session_id, "original", attachments())
    session.append_strict({"type": "message", "message": {"role": "tool", "content": "Image", "media": saved}})
    clone = SessionStore.duplicate(session.path)
    assert media.read_cached_media(clone.session_id, saved[0]["id"])[0] == PNG
    count, batch = SessionStore.move_to_trash([session.session_id])
    assert count == 1 and not media.media_directory(session.session_id).exists()
    session.path.write_text('{"type":"meta","cwd":"existing"}\n')
    restored = SessionStore.restore_from_trash_details(Path(batch).name)
    assert len(restored) == 1 and restored[0] != session.session_id
    assert media.read_cached_media(restored[0], saved[0]["id"])[0] == PNG
    assert not Path(batch).exists()


def test_duplicate_rolls_back_transcript_and_media_when_preview_copy_fails(tmp_path, monkeypatch):
    session = SessionStore(str(tmp_path))
    saved = media.cache_media(session.session_id, "original", attachments())
    session.append_strict({"type": "message", "message": {"role": "tool", "content": "Image", "media": saved}})
    original_copy, destinations = media.copy_session_media, []
    def fail_copy(source_id, destination_id, records):
        destinations.append(destination_id)
        original_copy(source_id, destination_id, records)
        raise OSError("disk full after preview copy")
    monkeypatch.setattr(media, "copy_session_media", fail_copy)
    with pytest.raises(OSError, match="disk full"):
        SessionStore.duplicate(session.path)
    assert destinations and SessionStore.path_for(destinations[0]) is None
    assert not media.media_directory(destinations[0]).exists()
    assert session.path.exists() and media.read_cached_media(session.session_id, saved[0]["id"])[0] == PNG


def test_media_batch_failure_rolls_back_only_new_files(tmp_path, monkeypatch):
    session = SessionStore(str(tmp_path))
    original = media.cache_media(session.session_id, "original", attachments())[0]
    identifiers = iter(["a" * 32, original["id"]])
    monkeypatch.setattr(media.uuid, "uuid4", lambda: SimpleNamespace(hex=next(identifiers)))
    with pytest.raises(FileExistsError):
        media.cache_media(session.session_id, "new", attachments() * 2)
    assert media.read_cached_media(session.session_id, original["id"])[0] == PNG
    assert not (media.media_directory(session.session_id) / ("a" * 32 + ".image")).exists()


def test_trash_batch_rolls_back_prior_media_when_later_storage_is_invalid(tmp_path):
    first, second = SessionStore(str(tmp_path)), SessionStore(str(tmp_path))
    saved = media.cache_media(first.session_id, "original", attachments())[0]
    outside = tmp_path / "outside-media"
    outside.mkdir()
    media.media_directory(second.session_id).symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        SessionStore.move_to_trash([first.session_id, second.session_id], require_all=True)
    assert first.path.exists() and second.path.exists()
    assert media.read_cached_media(first.session_id, saved["id"])[0] == PNG
    assert media.media_directory(first.session_id).exists()


def test_duplicate_api_removes_previews_when_later_setup_fails(tmp_path, monkeypatch):
    from ollama_code.core import AgentCore
    from ollama_code.server import ChatService, create_app
    from ollama_code.sessions import SessionMeta

    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    service = ChatService(core)
    app = create_app(chat_service=service)
    app.state.auth_token = "media-test-token"
    source_id = core.session.session_id
    saved = media.cache_media(source_id, "original", attachments())
    core.session.append_strict({"type": "message", "message": {"role": "tool", "content": "Image", "media": saved}})
    destinations = []
    def fail_metadata(session_id, **fields):
        destinations.append(session_id)
        assert media.media_directory(session_id).exists()
        raise OSError("metadata save failed")
    monkeypatch.setattr(SessionMeta, "update", staticmethod(fail_metadata))
    with TestClient(app) as client:
        result = client.post(f"/api/sessions/{source_id}/duplicate", json={}, headers={"X-Locus-Token": "media-test-token"})
    assert result.status_code == 409 and destinations
    assert SessionStore.path_for(destinations[0]) is None
    assert not media.media_directory(destinations[0]).exists()
    assert media.read_cached_media(source_id, saved[0]["id"])[0] == PNG


@pytest.mark.parametrize("ownership", ["historical", "current", "deleted"])
def test_task_lookup_media_uses_snapshotted_owning_session(tmp_path, monkeypatch, ownership):
    from ollama_code.api.runs import mcp_task_lookup

    monkeypatch.setenv("LOCUS_CAPABILITY_MODERN_MCP", "1")
    current, historical, switched = [SessionStore(str(tmp_path)) for _ in range(3)]
    task = {"run_id": "old-run" if ownership != "current" else "", "tool_call_id": "original-call"}
    core = SimpleNamespace(session=current)
    def lookup(task_id):
        core.session = switched
        return {"task": task, "result": "Completed evidence", "attachments": attachments()}
    core.mcp = SimpleNamespace(lookup_task=lookup)
    service = SimpleNamespace(core=core, run_store=SimpleNamespace(
        mcp_task=lambda task_id: task, run=lambda run_id: {"session_id": historical.session_id},
    ))
    if ownership == "deleted":
        historical.path.unlink()
    result = mcp_task_lookup(service, "remote-task")
    if ownership == "deleted":
        assert "attachments" not in result and result["media_warning"]
        assert not media.media_directory(historical.session_id).exists()
    else:
        expected = historical if ownership == "historical" else current
        assert result["session_id"] == expected.session_id
        image_id = result["attachments"][0]["id"]
        data, metadata = media.read_cached_media(expected.session_id, image_id)
        assert data == PNG and metadata["invocation_id"] == "original-call"
    assert not media.media_directory(switched.session_id).exists()
    assert ENCODED not in json.dumps(result)


def test_media_endpoint_requires_authentication_and_correct_session(tmp_path):
    from ollama_code.core import AgentCore
    from ollama_code.server import ChatService, create_app
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    service = ChatService(core)
    app = create_app(chat_service=service)
    app.state.auth_token = "media-test-token"
    saved = media.cache_media(core.session.session_id, "tool-1", attachments())[0]
    path = f"/api/sessions/{core.session.session_id}/media/{saved['id']}"
    with TestClient(app) as client:
        assert client.get(path).status_code == 401
        response = client.get(path, headers={"X-Locus-Token": "media-test-token"})
        assert response.status_code == 200 and response.content == PNG
        assert response.headers["content-type"] == "image/png"
        assert response.headers["x-content-type-options"] == "nosniff"
        other = SessionStore(str(tmp_path))
        assert client.get(path.replace(core.session.session_id, other.session_id), headers={"X-Locus-Token": "media-test-token"}).status_code == 404


def test_classic_batch_images_reach_next_model_step_without_base64_in_transcript(tmp_path):
    from test_backend import _core
    from test_extensions import _FakeMCP

    from ollama_code.tool_registry import ToolRegistry
    calls = [ToolCall("mcp__Linear__list_issues", {}, "one"), ToolCall("mcp__Linear__list_issues", {}, "two")]
    core = _core(tmp_path, [ChatResponse(tool_calls=calls), ChatResponse(content_parts=["I can see both images."])])
    core.mcp.close()
    class ImageMCP(_FakeMCP):
        def call_tool(self, server_id, tool_name, arguments, should_stop=None, *, media_receiver=None, invocation_context=None):
            assert media_receiver is not None
            assert invocation_context["tool_call_id"] in {"one", "two"}
            media_receiver(attachments())
            return "Screenshot evidence"
    core.mcp = ImageMCP()
    core.tool_registry = ToolRegistry(core.extensions, core.mcp)
    core.run_turn("Inspect the screenshots")
    messages = core.client.seen_messages[-1]
    observed = [item for item in messages if item.get("attachments")]
    assert len(observed) == 2 and all(item["attachments"][0]["data"] == ENCODED for item in observed)
    tool_positions = [i for i, item in enumerate(messages) if item.get("role") == "tool"]
    assert max(tool_positions) < min(i for i, item in enumerate(messages) if item.get("attachments"))
    assert ENCODED not in core.session.path.read_text()
    assert all(not call.result_media for call in calls)


def test_resource_templates_keep_original_identity_for_permissions_and_forward_arguments(tmp_path):
    from test_extensions import _FakeMCP

    from ollama_code.extensions import ExtensionManager
    from ollama_code.tool_registry import ToolRegistry
    from ollama_code.tools import ToolContext
    received = []
    class ResourceMCP(_FakeMCP):
        def available_resources(self):
            return [{"server_id": "fixture", "server_name": "Fixture", "name": "Images", "uri": "image://{path}",
                     "template": True, "source_tool": "snapshot", "source_tool_call_id": "call-42"}]
        def read_resource(self, server_id, uri, arguments=None, **kwargs):
            received.append((server_id, uri, arguments))
            return "read"
    registry = ToolRegistry(ExtensionManager(str(tmp_path)), ResourceMCP())
    registry.set_mcp_agent_policy({"server_ids": ["fixture"], "resources": ["image://{path}"]})
    ctx = ToolContext(cwd=str(tmp_path))
    assert registry.execute("read_extension_resource", {"server_id": "fixture", "uri": "image://{path}", "arguments": {"path": "Screenshot"}}, ctx) == "read"
    assert received == [("fixture", "image://{path}", {"path": "Screenshot"})]
    assert registry.execute("read_extension_resource", {"server_id": "fixture", "uri": "image://Screenshot"}, ctx).startswith("Error")
    search = registry.execute("search_extension_resources", {"query": "images"}, ctx)
    assert "tool=snapshot call_id=call-42" in search


def test_allowed_prompt_images_reach_classic_model_and_chat_with_call_identity(tmp_path):
    from test_backend import _core
    from test_extensions import _FakeMCP

    from ollama_code.tool_registry import ToolRegistry

    calls = []
    prompt_call = ToolCall("load_extension_prompt", {"server_id": "remote-1", "prompt": "triage", "arguments": {"project": "app"}}, "prompt-image")
    core = _core(tmp_path, [ChatResponse(tool_calls=[prompt_call]), ChatResponse(content_parts=["I can see the prompt image."])])
    core.mcp.close()
    class PromptMCP(_FakeMCP):
        def load_prompt(self, server_id, prompt_name, arguments, *, media_receiver=None, invocation_context=None):
            calls.append((server_id, prompt_name, arguments, invocation_context))
            media_receiver(attachments())
            return "Untrusted prompt text"
    core.mcp = PromptMCP()
    core.tool_registry = ToolRegistry(core.extensions, core.mcp)
    core.tool_registry.set_mcp_agent_policy({"server_ids": ["remote-1"], "prompts": ["triage"]})
    core.run_turn("Load the triage prompt")
    assert calls == [("remote-1", "triage", {"project": "app"}, {"tool_call_id": "prompt-image"})]
    observations = [message for message in core.client.seen_messages[-1] if message.get("attachments")]
    assert len(observations) == 1 and observations[0]["attachments"][0]["data"] == ENCODED
    saved = core.session.path.read_text()
    assert ENCODED not in saved and '"media"' in saved


def test_concurrent_invocations_own_distinct_media_and_stop_drops_late_delivery(tmp_path):
    from ollama_code.core import AgentCore
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.mcp.close()
    calls = [ToolCall("snapshot", {}, str(i)) for i in range(8)]
    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(lambda call: core._receive_mcp_media(call, attachments()), calls))
    assert len({call.result_media[0]["id"] for call in calls}) == len(calls)
    for call in calls:
        _, metadata = media.read_cached_media(core.session.session_id, call.result_media[0]["id"])
        assert metadata["invocation_id"] == call.call_id
    core._interrupt.set()
    late = ToolCall("snapshot", {}, "late")
    core._receive_mcp_media(late, attachments())
    assert late.result_media == []


def test_native_core_passes_images_to_helper_and_persists_only_references(tmp_path):
    from test_chatgpt_app_server import ParityFakeRuntime, _managed_core
    from test_extensions import _FakeMCP

    from ollama_code.tool_registry import ToolRegistry
    replies = []
    class Runtime(ParityFakeRuntime):
        def run_turn(self, *, text, event_handler, tool_handler=None, **kwargs):
            if tool_handler:
                replies.append(tool_handler("mcp__Linear__list_issues", {}, "native-image-call"))
            return super().run_turn(text=text, event_handler=event_handler, **kwargs)
    class ImageMCP(_FakeMCP):
        def call_tool(self, *args, media_receiver=None, invocation_context=None):
            assert invocation_context["tool_call_id"] == "native-image-call"
            media_receiver(attachments())
            return "Image evidence"
    core = _managed_core(tmp_path, Runtime())
    core.mcp.close()
    core.mcp = ImageMCP()
    core.tool_registry = ToolRegistry(core.extensions, core.mcp)
    core.run_turn("Inspect the screenshot")
    assert replies and replies[0]["content_items"][1]["imageUrl"] == f"data:image/png;base64,{ENCODED}"
    saved = core.session.path.read_text()
    assert ENCODED not in saved and '"media"' in saved
    assert any(message.get("media") for message in SessionStore.load(core.session.path))


def test_broker_client_preserves_rich_result_json(monkeypatch):
    from ollama_code.codex_app_server import CodexBrokerClient
    outgoing = []
    incoming = iter([
        {"type": "tool_call", "tool": "snapshot", "arguments": {}, "call_id": "one"},
        {"type": "completed", "turn": {"status": "completed"}},
    ])
    class Socket:
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False
        def send(self, value):
            outgoing.append(json.loads(value))
        def recv(self, **kwargs):
            return json.dumps(next(incoming))
    client = CodexBrokerClient("ws://fixture/broker", "fixture-token")
    monkeypatch.setattr(client, "_connect", Socket)
    result = media.native_tool_result("Screenshot", attachments())
    client.run_turn(thread_id="thread", text="inspect", tool_handler=lambda *args: result)
    assert outgoing[-1] == {"type": "tool_result", "call_id": "one", "result": result}


def test_solo_authority_preserves_image_envelope_and_worker_provenance(tmp_path):
    from test_backend import _core
    from test_extensions import _FakeMCP

    from ollama_code.tool_registry import ToolRegistry

    contexts = []
    class ImageMCP(_FakeMCP):
        def call_tool(self, *args, media_receiver=None, invocation_context=None):
            contexts.append(invocation_context)
            media_receiver(attachments())
            return "Worker screenshot"
    core = _core(tmp_path, [])
    core.mcp.close()
    core.mcp = ImageMCP()
    core.tool_registry = ToolRegistry(core.extensions, core.mcp)
    events = []
    core.on_event(events.append)
    core.tool_registry.begin_turn("Use Linear", str(tmp_path))
    core.tool_registry.execute("search_extension_tools", {"query": "Linear"}, core.tool_ctx)
    output = core.run_solo_worker_tool(
        "mcp__Linear__list_issues", {}, "worker-image-call", None,
        event_context={"job_id": "worker", "node_id": "/root/worker"}, execution_lock=None,
    )
    assert isinstance(output, dict), output
    assert output["content_items"][1]["imageUrl"] == f"data:image/png;base64,{ENCODED}"
    assert contexts == [{"tool_call_id": "worker-image-call", "job_id": "worker"}]
    result = next(event for event in events if event["type"] == "tool_result")
    assert result["node_id"] == "/root/worker" and result["media"]
    assert ENCODED not in json.dumps(events)
    assert ENCODED not in core.session.path.read_text()
    assert any(item.get("media") for item in SessionStore.load(core.session.path))


@pytest.mark.parametrize("reject_images", [False, True])
def test_solo_classic_worker_delivers_bounded_images_and_retries_only_model(tmp_path, reject_images):
    from ollama_code.ollama import OllamaError
    from ollama_code.solo_swarm import SoloSwarmExecutor, SoloSwarmRoute

    captured, executed, events = [], [], []
    final = {"id": "worker", "label": "Worker", "status": "completed", "findings": "Evidence", "evidence": [], "uncertainties": []}
    class Client:
        def chat_stream(self, model, messages, **kwargs):
            captured.append(json.loads(json.dumps(messages)))
            if len(captured) == 1:
                return ChatResponse(tool_calls=[ToolCall("snapshot", {}, "one"), ToolCall("snapshot", {}, "two")])
            if reject_images and len(captured) == 2:
                raise OllamaError("this model does not support image input")
            return ChatResponse(content_parts=[json.dumps(final)])
    def execute(name, arguments, call_id, context, lock):
        executed.append(call_id)
        assert context["node_id"] == "/root/worker"
        return media.native_tool_result("Screenshot " + call_id, attachments() * 10)
    worker = SoloSwarmExecutor(
        SoloSwarmRoute("ollama", "fixture", "Selected", Client(), {}, str(tmp_path)),
        emit=events.append, should_stop=lambda: False,
        tool_schemas=lambda: [{"type": "function", "function": {"name": "snapshot", "parameters": {"type": "object"}}}],
        tool_execute=execute,
    )
    result = worker._run_chat_completion({"id": "worker", "label": "Worker", "goal": "Inspect", "_allowed_tools": ["snapshot"]})
    assert result["status"] == "completed" and executed == ["one", "two"]
    messages = captured[1]
    observations = [item for item in messages if item.get("attachments")]
    assert sum(len(item["attachments"]) for item in observations) == 10
    assert "tool call two" in observations[0]["content"]
    assert [item["content"] for item in messages if item["role"] == "tool"] == ["Screenshot one", "Screenshot two"]
    assert max(i for i, item in enumerate(messages) if item["role"] == "tool") < min(i for i, item in enumerate(messages) if item.get("attachments"))
    assert len(captured) == (3 if reject_images else 2)
    if reject_images:
        assert not any(item.get("attachments") for item in captured[-1])
        assert worker._image_input_disabled.is_set() and any(event["type"] == "note" for event in events)


def test_image_rejection_retries_model_only_and_keeps_chat_previews(tmp_path, monkeypatch):
    from test_backend import FakeClient, _core

    from ollama_code.ollama import OllamaError
    call = ToolCall("snapshot", {}, "first")
    core = _core(tmp_path, [])
    class Rejecting(FakeClient):
        def chat_stream(self, *args, **kwargs):
            if any(item.get("attachments") for item in kwargs.get("messages", args[1] if len(args) > 1 else [])):
                self.calls += 1
                raise OllamaError("this model does not support image input")
            return super().chat_stream(*args, **kwargs)
    core.client = Rejecting([ChatResponse(tool_calls=[call]), ChatResponse(content_parts=["Text answer"])])
    executed = []
    def execute(tool, decider):
        executed.append(tool.call_id)
        core._receive_mcp_media(tool, attachments())
        return "Text evidence"
    monkeypatch.setattr(core, "_run_tool_call", execute)
    core.run_turn("Inspect")
    assert executed == ["first"] and core.client.calls == 3
    assert core._computer_route_key() in core._mcp_text_only_routes
    later = ToolCall("snapshot", {}, "later")
    core._receive_mcp_media(later, attachments())
    assert later.result_media[0]["_model_visible"] is False
    assert core._media_references(later)
    assert media.native_tool_result("Text", later.result_media) == "Text"
