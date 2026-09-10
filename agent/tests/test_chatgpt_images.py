from __future__ import annotations

import base64
from types import SimpleNamespace

import pytest
from test_image_generation import PNG

from ollama_code.api.providers import _chatgpt_efforts
from ollama_code.chatgpt_images import ChatGPTImageClient
from ollama_code.codex_app_server import CodexAppServerError, CodexAppServerManager
from ollama_code.image_generation import ImageGenerationService, ImageProviderConfig
from ollama_code.tools import ToolContext


def config(**changes):
    return ImageProviderConfig.parse({
        "provider": "chatgpt", "codex_home_id": "image-account", "model": "gpt-image-2",
        "chat_model": "gpt-5.6-sol", **changes,
    })


class Helper:
    def __init__(self, *, outcome="completed", disconnect=False):
        self.outcome = outcome
        self.disconnect = disconnect
        self.starts = []
        self.turns = []

    def start_thread(self, **kwargs):
        self.starts.append(kwargs)
        return "image-thread"

    def run_turn(self, **kwargs):
        self.turns.append(kwargs)
        assert not kwargs["should_interrupt"]()
        if self.outcome:
            kwargs["event_handler"]({
                "method": "item/completed", "params": {"item": {
                    "type": "imageGeneration", "id": "image-call", "status": self.outcome,
                    "result": base64.b64encode(PNG).decode(), "savedPath": "/untrusted/ignored.png",
                }},
            })
            assert kwargs["should_interrupt"]()
        if self.disconnect:
            raise CodexAppServerError("provider detail must not leak")
        return {"status": "completed"}


def test_current_helper_catalog_preserves_reasoning_effort_and_deduplicates():
    assert _chatgpt_efforts({"supportedReasoningEfforts": [
        {"reasoningEffort": "low", "description": "Fast"},
        {"reasoningEffort": "ultra", "description": "Thorough"},
        {"effort": "low"}, {"effort": "high"}, {"reasoningEffort": 5}, {}, None,
    ]}) == [
        {"effort": "low", "description": "Fast"},
        {"effort": "ultra", "description": "Thorough"},
        {"effort": "high", "description": ""},
    ]


@pytest.mark.parametrize("changes", [
    {"api_key": "secret"}, {"base_url": "https://api.openai.com"},
    {"model": "different-model"}, {"codex_home_id": "../account"}, {"chat_model": ""},
])
def test_chatgpt_image_configuration_rejects_api_credentials_and_invalid_routes(changes):
    with pytest.raises(ValueError):
        config(**changes)


def test_native_images_are_disabled_in_ordinary_threads():
    assert CodexAppServerManager.thread_config()["features"]["image_generation"] is False


def test_generate_uses_selected_account_and_existing_workspace_artifact_flow(tmp_path):
    helper = Helper()
    accounts = []
    service = ImageGenerationService(codex_for=lambda home: (accounts.append(home), helper)[1])
    service.configure(config())
    ctx = ToolContext(cwd=str(tmp_path))
    result = service.execute("generate_image", {"prompt": "A red kite"}, ctx)
    assert result.startswith("Created image")
    assert accounts == ["image-account"]
    assert len(helper.starts) == len(helper.turns) == 1
    start = helper.starts[0]
    assert start["ephemeral"] and start["tools"] == []
    flags = CodexAppServerManager.thread_config(start["options"])["features"]
    assert flags["image_generation"] and not flags["shell_tool"] and not flags["multi_agent"]
    assert list((tmp_path / "Locus Images").glob("*.png"))[0].read_bytes() == PNG
    assert ctx.image_generations_this_turn == 1
    assert service.state()["has_api_key"] is False


@pytest.mark.parametrize("outcome,disconnect", [("failed", False), (None, False), (None, True)])
def test_unresolved_generation_does_not_retry_or_save(tmp_path, outcome, disconnect):
    helper = Helper(outcome=outcome, disconnect=disconnect)
    service = ImageGenerationService(codex_for=lambda _: helper)
    service.configure(config())
    result = service.execute("generate_image", {"prompt": "A kite"}, ToolContext(cwd=str(tmp_path)))
    assert result.startswith("Error:") and "retry" in result
    assert len(helper.turns) == 1
    assert not list(tmp_path.rglob("*.png"))
    assert "provider detail" not in result


def test_completed_image_survives_followup_disconnect(tmp_path):
    client = ChatGPTImageClient(config(), Helper(disconnect=True))
    assert client.generate("Kite", "auto", "auto", ToolContext(cwd=str(tmp_path))) == PNG


def test_edit_passes_only_validated_image_bytes_and_refuses_masks(tmp_path):
    helper = Helper()
    client = ChatGPTImageClient(config(), helper)
    source = SimpleNamespace(data=PNG)
    ctx = ToolContext(cwd=str(tmp_path))
    assert client.edit("Make it blue", "auto", "auto", source, None, ctx) == PNG
    assert helper.turns[0]["input_items"][1]["url"].startswith("data:image/png;base64,")
    with pytest.raises(Exception, match="does not support masks"):
        client.edit("Change it", "auto", "auto", source, source, ctx)
    assert len(helper.turns) == 1


def test_user_stop_during_image_call_prevents_workspace_write(tmp_path):
    helper = Helper()
    stopped = False
    original = helper.run_turn

    def run(**kwargs):
        nonlocal stopped
        result = original(**kwargs)
        stopped = True
        return result

    helper.run_turn = run
    service = ImageGenerationService(codex_for=lambda _: helper)
    service.configure(config())
    ctx = ToolContext(cwd=str(tmp_path), should_stop=lambda: stopped)
    assert "interrupted" in service.execute("generate_image", {"prompt": "Kite"}, ctx)
    assert not list(tmp_path.rglob("*.png"))
