"""Tests for the agent core, tools, sessions and the HTTP/WebSocket contract.

Sessions and config are redirected to a temp directory so a developer's real
~/.ollama-code is never touched.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from ollama_code import config as config_mod
from ollama_code import sessions as sessions_mod
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse, OllamaError, process_chunk
from ollama_code.permissions import PermissionManager, build_preview
from ollama_code.render import ThinkFilter, strip_think
from ollama_code.sessions import SessionMeta, SessionStore, strip_prompt_decoration
from ollama_code.tools import ToolContext, execute_tool


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    """Point the session store AND the config file at a throwaway directory.

    Without the config redirect, anything that calls save_config (set_model,
    /permissions mode) would overwrite the developer's real
    ~/.ollama-code/config.json while the suite runs.
    """
    app_dir = tmp_path / "dot-ollama-code"
    monkeypatch.setattr(sessions_mod, "APP_DIR", app_dir)
    monkeypatch.setattr(sessions_mod, "SESSIONS_DIR", app_dir / "sessions")
    monkeypatch.setattr(sessions_mod, "TRASH_DIR", app_dir / "session-trash")
    monkeypatch.setattr(sessions_mod, "META_PATH", app_dir / "session-meta.json")
    monkeypatch.setattr(config_mod, "APP_DIR", app_dir)
    monkeypatch.setattr(config_mod, "CONFIG_PATH", app_dir / "config.json")
    return app_dir


def test_config_is_isolated_from_the_real_home(isolated_home):
    """Guards the fixture above: saving config must stay inside tmp_path."""
    config_mod.save_config({"model": "sentinel"})
    assert (isolated_home / "config.json").exists()
    assert config_mod.load_config()["model"] == "sentinel"


@pytest.fixture
def ctx(tmp_path):
    return ToolContext(cwd=str(tmp_path))


# --------------------------------------------------------------------- tools


def test_write_read_and_edit_roundtrip(ctx, tmp_path):
    assert "Wrote" in execute_tool("write_file", {"path": "a.txt", "content": "one\ntwo\n"}, ctx)
    body = execute_tool("read_file", {"path": "a.txt"}, ctx)
    assert "1\tone" in body and "2\ttwo" in body

    assert "Edited" in execute_tool(
        "edit_file", {"path": "a.txt", "old_string": "two", "new_string": "three"}, ctx
    )
    assert "three" in (tmp_path / "a.txt").read_text()


def test_edit_requires_unique_match(ctx, tmp_path):
    (tmp_path / "dup.txt").write_text("x\nx\n")
    result = execute_tool("edit_file", {"path": "dup.txt", "old_string": "x", "new_string": "y"}, ctx)
    assert result.startswith("Error") and "occurs 2 times" in result

    ok = execute_tool(
        "edit_file",
        {"path": "dup.txt", "old_string": "x", "new_string": "y", "replace_all": True},
        ctx,
    )
    assert ok.startswith("Edited")
    assert (tmp_path / "dup.txt").read_text() == "y\ny\n"


def test_multi_edit_is_atomic(ctx, tmp_path):
    (tmp_path / "m.txt").write_text("alpha\nbeta\n")
    failed = execute_tool(
        "multi_edit",
        {
            "path": "m.txt",
            "edits": [
                {"old_string": "alpha", "new_string": "ALPHA"},
                {"old_string": "nope", "new_string": "x"},
            ],
        },
        ctx,
    )
    assert failed.startswith("Error")
    assert (tmp_path / "m.txt").read_text() == "alpha\nbeta\n", "no edit may survive a failure"

    ok = execute_tool(
        "multi_edit",
        {
            "path": "m.txt",
            "edits": [
                {"old_string": "alpha", "new_string": "ALPHA"},
                {"old_string": "beta", "new_string": "BETA"},
            ],
        },
        ctx,
    )
    assert ok.startswith("Edited")
    assert (tmp_path / "m.txt").read_text() == "ALPHA\nBETA\n"


def test_read_file_rejects_binary(ctx, tmp_path):
    (tmp_path / "bin.dat").write_bytes(b"\x00\x01\x02binary")
    assert "binary" in execute_tool("read_file", {"path": "bin.dat"}, ctx)


def test_grep_and_glob_respect_cwd(ctx, tmp_path):
    (tmp_path / "pkg").mkdir()
    (tmp_path / "pkg" / "mod.py").write_text("def hello():\n    return 1\n")
    assert "mod.py" in execute_tool("glob", {"pattern": "**/*.py"}, ctx)
    hits = execute_tool("grep", {"pattern": "def hello"}, ctx)
    assert "mod.py:1:" in hits


def test_grep_ignores_vendor_directories(ctx, tmp_path):
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "junk.py").write_text("needle\n")
    (tmp_path / "keep.py").write_text("needle\n")
    hits = execute_tool("grep", {"pattern": "needle"}, ctx)
    assert "keep.py" in hits and "node_modules" not in hits


def test_bash_runs_in_workspace(ctx, tmp_path):
    out = execute_tool("bash", {"command": "pwd"}, ctx)
    assert str(tmp_path) in out


def test_bash_reports_exit_code(ctx):
    assert "[exit code 3]" in execute_tool("bash", {"command": "exit 3"}, ctx)


def test_todo_write_updates_context(ctx):
    execute_tool(
        "todo_write",
        {"todos": [{"content": "one", "status": "completed"}, {"content": "two", "status": "bogus"}]},
        ctx,
    )
    assert ctx.todos == [
        {"content": "one", "status": "completed"},
        {"content": "two", "status": "pending"},
    ]


def test_unknown_tool_lists_alternatives(ctx):
    assert "Available tools" in execute_tool("nope", {}, ctx)


def test_write_file_refuses_to_follow_a_symlink(ctx, tmp_path):
    outside = tmp_path.parent / "outside-target.txt"
    outside.write_text("original")
    link = tmp_path / "link.txt"
    link.symlink_to(outside)

    result = execute_tool("write_file", {"path": "link.txt", "content": "hijacked"}, ctx)
    assert result.startswith("Error") and "symlink" in result
    assert outside.read_text() == "original"


def test_bash_timeout_kills_the_whole_process_group(ctx, tmp_path):
    marker = tmp_path / "still-running.txt"
    # The shell exits at once; without a process-group kill the background
    # child survives the timeout and writes the marker.
    command = f"(sleep 3; echo alive > {marker}) & sleep 30"
    result = execute_tool("bash", {"command": command, "timeout": 1}, ctx)
    assert "timed out" in result
    time.sleep(4)
    assert not marker.exists(), "a child process outlived the timeout"


def test_web_fetch_identifies_itself_by_its_real_name(monkeypatch, tmp_path):
    """The model's browsing must say what it actually is.

    This header used to be the literal "ollama-code/0.2" — a product name we
    no longer ship under and a version that never moved. Deriving it from
    ``__version__`` is what stops it drifting again.
    """
    import requests

    import ollama_code

    seen = {}

    def fake_get(url, timeout=None, headers=None):
        seen["headers"] = headers or {}
        return FakeResponse(text="<html><body>hello</body></html>")

    monkeypatch.setattr(requests, "get", fake_get)
    execute_tool("web_fetch", {"url": "example.com"}, ToolContext(cwd=str(tmp_path)))

    agent = seen["headers"]["User-Agent"]
    assert agent == ollama_code.USER_AGENT
    assert ollama_code.__version__ in agent
    assert agent.startswith("Locus-Agent/")
    # The old literal, and anything claiming to be a client we are not.
    assert "ollama-code" not in agent.lower()
    assert "0.2" not in agent
    for impostor in ("claude", "codex", "kimi", "cursor", "curl", "mozilla"):
        assert impostor not in agent.lower()


# --------------------------------------------------------------- permissions


def test_permission_modes():
    perms = PermissionManager(mode="ask")
    assert perms.is_auto_allowed("read_file")       # safe tool
    assert not perms.is_auto_allowed("write_file")
    assert not perms.is_auto_allowed("bash")

    perms.set_mode("accept_edits")
    assert perms.is_auto_allowed("write_file")
    assert not perms.is_auto_allowed("bash")

    perms.set_mode("bypass")
    assert perms.is_auto_allowed("bash") and perms.skip_all


def test_permission_allowlist_and_reset():
    perms = PermissionManager()
    perms.allow_tool("bash")
    assert perms.is_auto_allowed("bash")
    perms.reset()
    assert not perms.is_auto_allowed("bash")


def test_deny_list_blocks_destructive_commands():
    perms = PermissionManager(deny_commands=["rm -rf /"])
    assert perms.blocked_reason("bash", {"command": "rm -rf /"}) is not None
    assert perms.blocked_reason("bash", {"command": "rm  -rf  /"}) is not None, "whitespace normalized"
    assert perms.blocked_reason("bash", {"command": "ls"}) is None


def test_deny_list_resists_wrappers_and_chaining():
    perms = PermissionManager(deny_commands=["rm -rf /", ":(){"])
    blocked = [
        "rm -rf /",
        "sudo rm -rf /",
        "/bin/rm -rf /",
        "env FOO=1 rm -rf /",
        "sudo env FOO=1 /bin/rm -rf /",
        "echo hi && rm -rf /",
        "echo hi; rm -rf /",
        "true | rm -rf /",
        "  RM=1 rm -rf /  ",
    ]
    for command in blocked:
        assert perms.blocked_reason("bash", {"command": command}) is not None, command
    for command in ["ls -la", "rm -rf ./build", "grep rm -rf ."]:
        assert perms.blocked_reason("bash", {"command": command}) is None, command


def test_auto_approval_is_scoped_to_the_workspace():
    perms = PermissionManager(mode="ask")
    assert perms.is_auto_allowed("read_file", inside_workspace=True)
    assert not perms.is_auto_allowed("read_file", inside_workspace=False)

    perms.set_mode("accept_edits")
    assert perms.is_auto_allowed("write_file", inside_workspace=True)
    assert not perms.is_auto_allowed("write_file", inside_workspace=False)


def test_workspace_containment_resolves_symlinks(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    outside = tmp_path / "outside.txt"
    outside.write_text("secret")
    link = workspace / "link.txt"
    link.symlink_to(outside)

    ctx = ToolContext(cwd=str(workspace))
    assert ctx.is_inside_workspace(workspace / "inner.txt")
    assert not ctx.is_inside_workspace(link)
    assert not ctx.is_inside_workspace(Path.home() / ".ssh" / "id_rsa")


def test_edit_preview_discloses_replace_all():
    _, plain = build_preview("edit_file", {"path": "x", "old_string": "a", "new_string": "b"})
    summary, _ = build_preview(
        "edit_file",
        {"path": "x", "old_string": "a", "new_string": "b", "replace_all": True},
    )
    assert "every occurrence" in summary
    assert plain  # unchanged behavior for the single-replacement case


def test_edit_preview_is_a_diff():
    summary, detail = build_preview(
        "edit_file", {"path": "x.py", "old_string": "a", "new_string": "b"}
    )
    assert summary == "edit x.py"
    assert "-a" in detail and "+b" in detail and "@@" in detail


# ------------------------------------------------------------------ streaming


def test_think_filter_strips_reasoning_across_chunks():
    f = ThinkFilter()
    out = "".join(f.feed(part) for part in ["Hel", "lo <thi", "nk>secret</thi", "nk> world"])
    assert "secret" not in out
    assert (out + f.flush()).strip() == "Hello  world".strip().replace("  ", "  ")


def test_strip_think_handles_unclosed_block():
    assert strip_think("answer <think>never closed") == "answer"


def test_process_chunk_parses_string_tool_arguments():
    resp = ChatResponse()
    process_chunk(
        {"message": {"tool_calls": [{"function": {"name": "bash", "arguments": '{"command": "ls"}'}}]}},
        resp,
    )
    assert resp.tool_calls[0].name == "bash"
    assert resp.tool_calls[0].arguments == {"command": "ls"}


def test_process_chunk_captures_native_thinking():
    """Reasoning text lands on the response, separate from the content token."""
    resp = ChatResponse()
    token = process_chunk({"message": {"content": "hi", "thinking": "hmm"}}, resp)
    assert token == "hi"
    assert resp.thinking == "hmm"
    assert resp.content == "hi"


# ------------------------------------------------------------------- sessions


def test_session_metadata_roundtrip(tmp_path):
    store = SessionStore(str(tmp_path))
    store.append({"type": "message", "message": {"role": "user", "content": "hello"}})
    sid = store.session_id

    AgentCore.update_session_metadata(sid, title="My session", pinned=True)
    summaries = SessionStore.summaries()
    entry = next(s for s in summaries if s["id"] == sid)
    assert entry["title"] == "My session" and entry["pinned"] is True

    AgentCore.update_session_metadata(sid, archived=True)
    assert all(s["id"] != sid for s in SessionStore.summaries())
    assert any(s["id"] == sid for s in SessionStore.summaries(include_archived=True))


def test_pinned_sessions_sort_first(tmp_path):
    old = SessionStore(str(tmp_path))
    old.append({"type": "message", "message": {"role": "user", "content": "old"}})
    new = SessionStore(str(tmp_path))
    new.append({"type": "message", "message": {"role": "user", "content": "new"}})
    AgentCore.update_session_metadata(old.session_id, pinned=True)
    assert SessionStore.summaries()[0]["id"] == old.session_id


def test_clear_moves_sessions_to_recoverable_trash(tmp_path):
    keep = SessionStore(str(tmp_path))
    keep.append({"type": "message", "message": {"role": "user", "content": "keep"}})
    gone = SessionStore(str(tmp_path))
    gone.append({"type": "message", "message": {"role": "user", "content": "gone"}})
    AgentCore.update_session_metadata(gone.session_id, title="Archived work")

    count, path = SessionStore.move_to_trash([gone.session_id])
    assert count == 1
    assert SessionStore.path_for(gone.session_id) is None
    assert SessionStore.path_for(keep.session_id) is not None

    manifest = json.loads((Path(path) / "manifest.json").read_text())
    assert manifest["sessions"][gone.session_id]["title"] == "Archived work"

    assert SessionStore.restore_from_trash() == 1
    assert SessionStore.path_for(gone.session_id) is not None
    assert SessionMeta.get(gone.session_id)["title"] == "Archived work"


def test_session_ids_cannot_escape_the_sessions_directory(tmp_path):
    outside = tmp_path / "secret.jsonl"
    outside.write_text("{}\n")
    for bogus in ["../secret", "../../etc/passwd", "/etc/passwd", "", ".hidden", "a/b"]:
        assert SessionStore.path_for(bogus) is None, bogus


def test_traversal_ids_are_404_over_http(client):
    assert client.get("/api/sessions/..%2F..%2Fetc%2Fpasswd").status_code in (404, 400)
    assert client.patch("/api/sessions/../escape", json={"title": "x"}).status_code in (404, 400, 405)


def test_session_append_is_thread_safe(tmp_path):
    """Concurrent writers must not interleave partial JSONL lines.

    Only one thread appends today, but the terminal pump adds a second.
    """
    import threading as _threading

    store = SessionStore(str(tmp_path))
    payload = "x" * 4000

    def write(index: int) -> None:
        for _ in range(5):
            store.append({"type": "message", "message": {"role": "user", "content": f"{index}{payload}"}})

    threads = [_threading.Thread(target=write, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    lines = [l for l in store.path.read_text(encoding="utf-8").splitlines() if l.strip()]
    for line in lines:
        json.loads(line)  # raises if a write was torn
    assert len(lines) == 20 * 5 + 1  # + the meta header


def test_preview_strips_gui_prompt_decoration(tmp_path):
    store = SessionStore(str(tmp_path))
    store.append({
        "type": "message",
        "message": {
            "role": "user",
            "content": "[Locus mode: Build]\nImplement it.\n\nUser request:\nFix the login flow",
        },
    })
    assert SessionStore.preview(store.path) == "Fix the login flow"


def test_strip_prompt_decoration_passthrough():
    assert strip_prompt_decoration("plain text") == "plain text"


def test_sanitize_messages_drops_system_and_keeps_tools():
    out = AgentCore.sanitize_messages([
        {"role": "system", "content": "hidden"},
        {"role": "user", "content": "[Locus mode: Ask]\nx\n\nUser request:\nhi"},
        {"role": "tool", "name": "bash", "content": "output"},
    ])
    assert [m["role"] for m in out] == ["user", "tool"]
    assert out[0]["content"] == "hi"
    assert out[1]["name"] == "bash"


# ------------------------------------------------------------ remote provider


class FakeResponse:
    """Minimal stand-in for a requests.Response."""

    def __init__(self, status_code=200, payload=None, lines=None, text=""):
        self.status_code = status_code
        self._payload = payload
        self._lines = lines or []
        self.text = text

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload

    def iter_lines(self, decode_unicode=False):
        return iter(self._lines)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_endpoint_urls_are_normalized():
    from ollama_code.remote import normalize_base_url

    expected = "https://abc123.us-east-1.aws.endpoints.huggingface.cloud/v1"
    for given in [
        "https://abc123.us-east-1.aws.endpoints.huggingface.cloud",
        "https://abc123.us-east-1.aws.endpoints.huggingface.cloud/",
        "https://abc123.us-east-1.aws.endpoints.huggingface.cloud/v1",
        "https://abc123.us-east-1.aws.endpoints.huggingface.cloud/v1/",
        "https://abc123.us-east-1.aws.endpoints.huggingface.cloud/v1/chat/completions",
        "abc123.us-east-1.aws.endpoints.huggingface.cloud",
    ]:
        assert normalize_base_url(given) == expected, given
    assert normalize_base_url("") == ""


def test_remote_client_sends_bearer_token(monkeypatch):
    from ollama_code import remote as remote_mod

    seen = {}

    def fake_get(url, headers=None, timeout=None):
        seen["url"] = url
        seen["headers"] = headers or {}
        return FakeResponse(payload={"data": [{"id": "meta-llama/Llama-3.1-8B-Instruct"}]})

    monkeypatch.setattr(remote_mod.requests, "get", fake_get)
    client = remote_mod.RemoteClient("https://endpoint.example", api_key="hf_secret")

    models = client.list_models()

    assert seen["url"] == "https://endpoint.example/v1/models"
    assert seen["headers"]["Authorization"] == "Bearer hf_secret"
    assert models[0]["name"] == "meta-llama/Llama-3.1-8B-Instruct"


def test_remote_client_adds_anthropic_headers_for_that_auth_style(monkeypatch):
    from ollama_code import remote as remote_mod

    seen = {}

    def fake_get(url, headers=None, timeout=None):
        seen["headers"] = headers or {}
        return FakeResponse(payload={"data": [{"id": "claude-sonnet-4-5"}]})

    monkeypatch.setattr(remote_mod.requests, "get", fake_get)
    client = remote_mod.RemoteClient(
        "https://api.anthropic.com/v1", api_key="sk-ant-secret"
    )
    client.list_models()

    # The bearer token still travels: chat completions authenticate with it,
    # and only the native model listing needs the pair below.
    assert seen["headers"]["Authorization"] == "Bearer sk-ant-secret"
    assert seen["headers"]["x-api-key"] == "sk-ant-secret"
    assert seen["headers"]["anthropic-version"] == remote_mod.ANTHROPIC_VERSION


def test_remote_client_identifies_itself_by_its_real_name():
    from ollama_code import USER_AGENT, __version__
    from ollama_code import remote as remote_mod

    # No key: the identity must still travel, so it cannot live inside the
    # Authorization branch.
    headers = remote_mod.RemoteClient("https://api.kimi.com/coding/v1")._headers()
    assert headers["User-Agent"] == USER_AGENT
    assert __version__ in headers["User-Agent"]
    assert "Authorization" not in headers

    agent = USER_AGENT.lower()
    for impostor in ("python-requests", "curl", "claude", "kimi", "cursor", "codex"):
        assert impostor not in agent, f"must not claim to be {impostor}"


def test_remote_chat_sends_the_user_agent(monkeypatch):
    """The streaming POST is the request that spends the subscription."""
    from ollama_code import USER_AGENT
    from ollama_code import remote as remote_mod

    seen = {}

    def fake_post(url, headers=None, json=None, stream=None, timeout=None):
        seen["headers"] = headers or {}
        return FakeResponse(lines=_sse([{"choices": [{"delta": {"content": "hi"}}]}]))

    monkeypatch.setattr(remote_mod.requests, "post", fake_post)
    client = remote_mod.RemoteClient(
        "https://api.kimi.com/coding/v1", api_key="secret", model="kimi-for-coding"
    )
    client.chat_stream(model="kimi-for-coding", messages=[{"role": "user", "content": "hi"}])

    assert seen["headers"]["User-Agent"] == USER_AGENT


def test_kimi_code_endpoints_survive_normalization():
    from ollama_code.remote import normalize_base_url

    expected = "https://api.kimi.com/coding/v1"
    for given in [
        expected,
        "https://api.kimi.com/coding/v1/",
        "https://api.kimi.com/coding/",
        "https://api.kimi.com/coding",
        "https://api.kimi.com/coding/v1/chat/completions",
        "api.kimi.com/coding/v1",
    ]:
        assert normalize_base_url(given) == expected, f"{given} lost the /coding path"


def test_remote_auth_style_is_inferred_and_coerced():
    from ollama_code import remote as remote_mod

    # Inferred from the host when unset, explicit when given, and anything
    # unrecognized falls back to a plain bearer token.
    assert remote_mod.RemoteClient("https://api.anthropic.com/v1").auth_style == "anthropic"
    assert remote_mod.RemoteClient("https://api.openai.com/v1").auth_style == "bearer"
    assert remote_mod.RemoteClient(
        "https://gateway.example", auth_style="anthropic"
    ).auth_style == "anthropic"
    assert remote_mod.RemoteClient(
        "https://gateway.example", auth_style="nonsense"
    ).auth_style == "bearer"

    other = remote_mod.RemoteClient("https://api.moonshot.ai/v1", api_key="sk-kimi")
    assert "x-api-key" not in other._headers()


def test_remote_client_falls_back_to_the_configured_model(monkeypatch):
    from ollama_code import remote as remote_mod

    monkeypatch.setattr(
        remote_mod.requests, "get", lambda *a, **k: FakeResponse(status_code=404)
    )
    client = remote_mod.RemoteClient("https://endpoint.example", model="my-model")

    assert [m["name"] for m in client.list_models()] == ["my-model"]
    client.check()  # a 404 on /models must not be treated as failure


def test_remote_auth_errors_explain_the_fix(monkeypatch):
    from ollama_code import remote as remote_mod

    monkeypatch.setattr(
        remote_mod.requests,
        "get",
        lambda *a, **k: FakeResponse(
            status_code=401, payload={"error": {"message": "Invalid credentials"}}
        ),
    )
    client = remote_mod.RemoteClient("https://endpoint.example", api_key="bad")

    with pytest.raises(OllamaError) as excinfo:
        client.check()
    message = str(excinfo.value)
    assert "rejected the API key" in message and "Invalid credentials" in message


def test_remote_sleeping_endpoint_is_explained(monkeypatch):
    from ollama_code import remote as remote_mod

    monkeypatch.setattr(
        remote_mod.requests, "get", lambda *a, **k: FakeResponse(status_code=503)
    )
    with pytest.raises(OllamaError) as excinfo:
        remote_mod.RemoteClient("https://endpoint.example").check()
    assert "not ready" in str(excinfo.value)


def _sse(chunks: list[dict]) -> list[str]:
    return [f"data: {json.dumps(c)}" for c in chunks] + ["data: [DONE]"]


def test_remote_streams_content_and_usage(monkeypatch):
    from ollama_code import remote as remote_mod

    lines = _sse([
        {"choices": [{"delta": {"content": "Hel"}}]},
        {"choices": [{"delta": {"content": "lo"}}]},
        {"choices": [{"delta": {}, "finish_reason": "stop"}],
         "usage": {"prompt_tokens": 11, "completion_tokens": 2}},
    ])
    monkeypatch.setattr(
        remote_mod.requests, "post", lambda *a, **k: FakeResponse(lines=lines)
    )
    client = remote_mod.RemoteClient("https://endpoint.example", model="m")

    tokens = []
    resp = client.chat_stream("m", [{"role": "user", "content": "hi"}], on_token=tokens.append)

    assert resp.content == "Hello"
    assert tokens == ["Hel", "lo"]
    assert resp.prompt_eval_count == 11 and resp.eval_count == 2


def test_remote_assembles_streamed_tool_calls(monkeypatch):
    from ollama_code import remote as remote_mod

    lines = _sse([
        {"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"name": "write_file", "arguments": '{"path"'}}
        ]}}]},
        {"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"arguments": ': "a.txt", "content": "hi"}'}}
        ]}}]},
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    ])
    monkeypatch.setattr(
        remote_mod.requests, "post", lambda *a, **k: FakeResponse(lines=lines)
    )
    client = remote_mod.RemoteClient("https://endpoint.example", model="m")

    resp = client.chat_stream("m", [{"role": "user", "content": "write it"}])

    assert len(resp.tool_calls) == 1
    call = resp.tool_calls[0]
    assert call.name == "write_file"
    assert call.arguments == {"path": "a.txt", "content": "hi"}


def test_remote_retries_without_tools_when_unsupported(monkeypatch):
    from ollama_code import remote as remote_mod

    attempts = []

    def fake_post(url, json=None, headers=None, stream=None, timeout=None):
        attempts.append("tools" in (json or {}))
        if "tools" in (json or {}):
            return FakeResponse(
                status_code=400,
                payload={"error": {"message": "tool calling is not supported"}},
            )
        return FakeResponse(lines=_sse([
            {"choices": [{"delta": {"content": "plain answer"}, "finish_reason": "stop"}]}
        ]))

    monkeypatch.setattr(remote_mod.requests, "post", fake_post)
    client = remote_mod.RemoteClient("https://endpoint.example", model="m")

    resp = client.chat_stream(
        "m", [{"role": "user", "content": "hi"}], tools=[{"type": "function"}]
    )

    assert attempts == [True, False], "it must retry once without tools"
    assert "plain answer" in resp.content
    assert "rejected tool calling" in resp.content


def test_remote_message_conversion_includes_tool_calls():
    from ollama_code.remote import _to_openai_message

    converted = _to_openai_message({
        "role": "assistant",
        "content": "",
        "tool_calls": [{"function": {"name": "bash", "arguments": {"command": "ls"}}}],
    })
    assert converted["tool_calls"][0]["function"]["name"] == "bash"
    assert json.loads(converted["tool_calls"][0]["function"]["arguments"]) == {"command": "ls"}

    tool_result = _to_openai_message({"role": "tool", "name": "bash", "content": "out"})
    assert tool_result["role"] == "tool" and tool_result["tool_call_id"] == "bash"


def test_core_switches_providers_and_keeps_keys_out_of_disk(tmp_path):
    core = _core(tmp_path, [])
    core.use_remote(
        "https://abc.endpoints.huggingface.cloud",
        api_key="hf_topsecret",
        model="llama-3.1-8b",
    )

    state = core.provider_state()
    assert state["provider"] == "remote"
    assert state["remote_base_url"].endswith("/v1")
    assert state["has_api_key"] is True
    assert "hf_topsecret" not in json.dumps(state), "the key must never be returned"
    assert core.model == "llama-3.1-8b"

    saved = config_mod.CONFIG_PATH.read_text()
    assert "hf_topsecret" not in saved, "the key must never be written to disk"
    assert "abc.endpoints.huggingface.cloud" in saved

    # Updating the URL without re-sending the key keeps it.
    core.use_remote("https://other.endpoints.huggingface.cloud", api_key=None)
    assert core.provider_state()["has_api_key"] is True

    core.use_ollama()
    assert core.provider == "ollama"
    assert core.session_info()["provider"] == "ollama"


def test_core_tracks_the_account_label_without_leaking_the_key(tmp_path):
    core = _core(tmp_path, [])
    core.use_remote(
        "https://api.anthropic.com/v1",
        api_key="sk-ant-topsecret",
        model="claude-sonnet-4-5",
        auth_style="anthropic",
        account_label="Claude — Work",
    )

    assert core.provider_state()["account_label"] == "Claude — Work"
    assert core.session_info()["account_label"] == "Claude — Work"

    saved_text = config_mod.CONFIG_PATH.read_text()
    saved = json.loads(saved_text)
    assert saved["remote_account_label"] == "Claude — Work", "the label survives a restart"
    assert saved["remote_auth_style"] == "anthropic"
    assert "sk-ant-topsecret" not in saved_text, "the key must never be written to disk"

    # A URL-only update keeps the label, the same way it keeps the key.
    core.use_remote("https://api.anthropic.com/v1", api_key=None)
    assert core.provider_state()["account_label"] == "Claude — Work"

    # Local Ollama has no account, so the label must not linger.
    core.use_ollama()
    assert core.provider_state()["account_label"] == ""
    assert core.session_info()["account_label"] == ""


def test_session_meta_records_the_provider_and_account(tmp_path):
    core = _core(tmp_path, [])
    core.use_remote(
        "https://api.moonshot.ai/v1",
        api_key="sk-kimi",
        model="kimi-k2",
        account_label="Kimi",
    )
    core.start_new_session()

    meta = json.loads(core.session.path.read_text().splitlines()[0])
    assert meta["type"] == "meta"
    assert meta["provider"] == "remote"
    assert meta["account"] == "Kimi"
    assert meta["model"] == "kimi-k2"


def test_provider_endpoints_round_trip(client):
    body = client.post("/api/provider", json={
        "provider": "remote",
        "base_url": "https://abc.endpoints.huggingface.cloud",
        "api_key": "hf_secret",
        "model": "llama-3.1-8b",
    }).json()
    assert body["provider"] == "remote"
    assert body["has_api_key"] is True
    assert "hf_secret" not in json.dumps(body)

    assert client.get("/api/provider").json()["remote_model"] == "llama-3.1-8b"
    assert client.get("/api/health").json()["provider"] == "remote"

    assert client.post("/api/provider", json={"provider": "nope"}).status_code == 422
    assert client.post("/api/provider", json={"provider": "remote"}).status_code == 422

    assert client.post("/api/provider", json={"provider": "ollama"}).json()["provider"] == "ollama"


def test_provider_endpoint_carries_the_account_identity(client):
    body = client.post("/api/provider", json={
        "provider": "remote",
        "base_url": "https://api.anthropic.com/v1",
        "api_key": "sk-ant-secret",
        "model": "claude-sonnet-4-5",
        "auth_style": "anthropic",
        "account_label": "Claude — Personal",
    }).json()
    assert body["account_label"] == "Claude — Personal"
    assert "sk-ant-secret" not in json.dumps(body)

    # Omitting the label keeps it: an older client updating only the model must
    # not erase which account the agent is holding a key for.
    kept = client.post("/api/provider", json={
        "provider": "remote",
        "base_url": "https://api.anthropic.com/v1",
        "model": "claude-haiku-4-5",
    }).json()
    assert kept["account_label"] == "Claude — Personal"

    assert client.post("/api/provider", json={"provider": "ollama"}).json()["account_label"] == ""


# ------------------------------------------------------------------- terminal


def _manager(tmp_path, perms=None, config=None):
    from ollama_code.terminal import TerminalManager

    events: list[dict] = []
    manager = TerminalManager(
        emit=events.append,
        perms=perms or PermissionManager(mode="ask"),
        config={"terminal_login_shell": False, **(config or {})},
    )
    return manager, events


def _wait_for(events, event_type, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for event in list(events):
            if event.get("type") == event_type:
                return event
        time.sleep(0.05)
    raise AssertionError(f"no {event_type} within {timeout}s: {[e.get('type') for e in events]}")


def _output(events):
    return "".join(e["text"] for e in events if e.get("type") == "terminal_output")


def test_terminal_streams_output_and_exits(tmp_path):
    manager, events = _manager(tmp_path)
    manager.start("printf 'hello\\nworld\\n'", cwd=str(tmp_path))

    exit_event = _wait_for(events, "terminal_exit")
    assert exit_event["exit_code"] == 0
    assert _output(events) == "hello\nworld\n"
    seqs = [e["seq"] for e in events if e["type"] == "terminal_output"]
    assert seqs == sorted(seqs)


def test_terminal_output_arrives_before_the_process_exits(tmp_path):
    """The whole point of the console: today's bash tool cannot do this."""
    manager, events = _manager(tmp_path)
    manager.start("printf 'first\\n'; sleep 3; printf 'second\\n'", cwd=str(tmp_path))

    deadline = time.monotonic() + 2.0
    saw_first = False
    while time.monotonic() < deadline:
        if "first" in _output(events):
            saw_first = True
            break
        time.sleep(0.05)

    assert saw_first, "output must stream while the command is still running"
    assert not any(e["type"] == "terminal_exit" for e in events), "it should still be running"
    manager.cancel(manager._run.run_id, force=True)
    _wait_for(events, "terminal_exit")


def test_terminal_stdin_answers_a_prompt(tmp_path):
    manager, events = _manager(tmp_path)
    run_id = manager.start("printf 'ok? '; read answer; printf 'got:%s\\n' \"$answer\"",
                           cwd=str(tmp_path))

    deadline = time.monotonic() + 5
    while "ok?" not in _output(events) and time.monotonic() < deadline:
        time.sleep(0.05)
    manager.send_input(run_id, "yes")

    exit_event = _wait_for(events, "terminal_exit")
    assert exit_event["exit_code"] == 0
    assert "got:yes" in _output(events)


def test_terminal_cancel_kills_the_process_tree(tmp_path):
    marker = tmp_path / "alive.txt"
    manager, events = _manager(tmp_path)
    run_id = manager.start(f"(sleep 3; echo alive > {marker}) & sleep 30", cwd=str(tmp_path))

    time.sleep(0.4)
    manager.cancel(run_id, force=True)
    exit_event = _wait_for(events, "terminal_exit")
    assert exit_event["reason"] == "cancelled"

    time.sleep(4)
    assert not marker.exists(), "a child outlived the cancel"


def test_terminal_deny_list_blocks_a_typed_command(tmp_path):
    from ollama_code.terminal import TerminalRejected

    perms = PermissionManager(deny_commands=["rm -rf /"])
    manager, events = _manager(tmp_path, perms=perms)

    with pytest.raises(TerminalRejected) as excinfo:
        manager.start("echo hi && rm -rf /", cwd=str(tmp_path))

    assert excinfo.value.code == "blocked"
    assert [e["type"] for e in events] == ["terminal_error"]
    assert not any(e["type"] == "terminal_started" for e in events), "nothing may spawn"


def test_terminal_never_touches_permission_state(tmp_path):
    """Typing a command is its own approval; it must not grant the model
    anything."""
    perms = PermissionManager(mode="ask")
    manager, events = _manager(tmp_path, perms=perms)
    manager.start("echo hi", cwd=str(tmp_path))
    _wait_for(events, "terminal_exit")

    assert perms.allowed == set()
    assert perms.always_allow == set()
    assert not any(e["type"] == "permission_request" for e in events)


def test_terminal_refuses_a_second_concurrent_run(tmp_path):
    from ollama_code.terminal import TerminalRejected

    manager, events = _manager(tmp_path)
    run_id = manager.start("sleep 5", cwd=str(tmp_path))

    with pytest.raises(TerminalRejected) as excinfo:
        manager.start("echo second", cwd=str(tmp_path))
    assert excinfo.value.code == "busy"

    manager.cancel(run_id, force=True)
    _wait_for(events, "terminal_exit")


def test_terminal_timeout_cancels_the_run(tmp_path):
    manager, events = _manager(tmp_path)
    manager.start("sleep 30", cwd=str(tmp_path), timeout=1)

    exit_event = _wait_for(events, "terminal_exit", timeout=20)
    assert exit_event["reason"] == "timeout"


def test_terminal_records_the_run_without_stdin(tmp_path):
    from ollama_code.terminal import TerminalManager

    events: list[dict] = []
    records: list[dict] = []
    manager = TerminalManager(
        emit=events.append,
        perms=PermissionManager(),
        record=records.append,
        config={"terminal_login_shell": False},
    )
    run_id = manager.start("read secret; echo done", cwd=str(tmp_path))
    time.sleep(0.3)
    manager.send_input(run_id, "hunter2")
    _wait_for(events, "terminal_exit")

    assert len(records) == 1
    record = records[0]
    assert record["type"] == "terminal"
    assert record["command"] == "read secret; echo done"
    assert record["inputs"] == 1
    assert "hunter2" not in json.dumps(record), "stdin must never reach disk"


def test_terminal_run_does_not_block_the_chat(client, tmp_path):
    svc = client.app.state.service
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()  # session_info
        ws.receive_json()  # terminal_state
        ws.send_json({"type": "terminal_run", "command": "sleep 5"})
        time.sleep(0.5)

        assert svc.busy is False, "the console must not occupy the chat turn slot"

        svc.terminal.cancel_all(force=True)


def test_terminal_ws_roundtrip_and_unknown_run(client):
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()
        ws.receive_json()  # terminal_state
        ws.send_json({"type": "terminal_run", "command": "echo streamed"})

        seen: list[str] = []
        for _ in range(40):
            event = ws.receive_json()
            seen.append(event["type"])
            if event["type"] == "terminal_exit":
                break
        assert "terminal_started" in seen and "terminal_exit" in seen

        ws.send_json({"type": "terminal_input", "run_id": "nope", "text": "x"})
        assert any(e.get("code") == "unknown_run" for e in drain(ws))


# ------------------------------------------------------------------------ git


@pytest.fixture
def git_repo(tmp_path, monkeypatch):
    """A throwaway repo with the developer's global git config neutralized.

    Without this the suite breaks on any machine with commit.gpgsign, a custom
    init.defaultBranch, or global hooks.
    """
    import shutil as _shutil

    if _shutil.which("git") is None:
        pytest.skip("git is not installed")

    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    monkeypatch.setenv("HOME", str(tmp_path))

    root = tmp_path / "repo"
    root.mkdir()
    run = lambda *a: subprocess.run(  # noqa: E731
        ["git", *a], cwd=root, check=True, capture_output=True
    )
    run("init", "-q")
    run("symbolic-ref", "HEAD", "refs/heads/main")
    run("config", "user.email", "t@example.com")
    run("config", "user.name", "Test")
    run("config", "commit.gpgsign", "false")
    return root


def _commit(root, message="initial"):
    subprocess.run(["git", "add", "-A"], cwd=root, check=True, capture_output=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", message], cwd=root, check=True, capture_output=True
    )


def test_git_status_reports_a_non_repository(tmp_path):
    from ollama_code import gitinfo

    result = gitinfo.status(str(tmp_path))
    assert result["ok"] is True
    assert result["is_repo"] is False
    assert result["files"] == []


def test_git_status_lists_staged_untracked_and_modified(git_repo):
    from ollama_code import gitinfo

    (git_repo / "tracked.txt").write_text("one\ntwo\n")
    _commit(git_repo)
    (git_repo / "tracked.txt").write_text("one\ntwo\nthree\n")
    (git_repo / "fresh.txt").write_text("new\n")
    subprocess.run(["git", "add", "fresh.txt"], cwd=git_repo, check=True, capture_output=True)
    (git_repo / "loose.txt").write_text("loose\n")

    result = gitinfo.status(str(git_repo))

    assert result["is_repo"] and result["ok"]
    assert result["branch"] == "main"
    by_path = {f["path"]: f for f in result["files"]}
    assert by_path["tracked.txt"]["status"] == "modified"
    assert by_path["tracked.txt"]["unstaged"] is True
    assert by_path["fresh.txt"]["staged"] is True
    assert by_path["loose.txt"]["untracked"] is True
    assert by_path["loose.txt"]["additions"] == 1
    assert result["counts"]["total"] == 3


def test_git_status_survives_renames_spaces_and_unicode(git_repo):
    """A porcelain-v2 rename record carries two NUL fields; a parser that
    assumes one silently corrupts every entry after it."""
    from ollama_code import gitinfo

    (git_repo / "old name.txt").write_text("hello\n")
    (git_repo / "ünïcode.txt").write_text("héllo\n")
    (git_repo / "after.txt").write_text("after\n")
    _commit(git_repo)

    subprocess.run(
        ["git", "mv", "old name.txt", "new name.txt"], cwd=git_repo, check=True, capture_output=True
    )
    (git_repo / "after.txt").write_text("after edited\n")

    result = gitinfo.status(str(git_repo))
    by_path = {f["path"]: f for f in result["files"]}

    assert "new name.txt" in by_path
    assert by_path["new name.txt"]["orig_path"] == "old name.txt"
    # The entry *after* the rename must still be intact.
    assert by_path["after.txt"]["status"] == "modified"
    assert "ünïcode.txt" not in by_path  # unchanged, so absent


def test_git_diff_of_a_tracked_file(git_repo):
    from ollama_code import gitinfo

    (git_repo / "a.txt").write_text("one\n")
    _commit(git_repo)
    (git_repo / "a.txt").write_text("one\ntwo\n")

    result = gitinfo.file_diff(str(git_repo), "a.txt")
    assert result["ok"] and not result["binary"]
    assert "+two" in result["raw"] and "@@" in result["raw"]


def test_git_diff_of_an_untracked_file_is_all_additions(git_repo):
    """--no-index exits 1 to mean "there are differences" — not failure."""
    from ollama_code import gitinfo

    (git_repo / "brand-new.txt").write_text("alpha\nbeta\n")

    result = gitinfo.file_diff(str(git_repo), "brand-new.txt")
    assert result["ok"] is True
    assert "+alpha" in result["raw"] and "+beta" in result["raw"]


def test_git_diff_marks_binary_files(git_repo):
    from ollama_code import gitinfo

    (git_repo / "blob.bin").write_bytes(bytes(range(256)) * 4)
    _commit(git_repo)
    (git_repo / "blob.bin").write_bytes(bytes(range(255, -1, -1)) * 4)

    result = gitinfo.file_diff(str(git_repo), "blob.bin")
    assert result["binary"] is True
    assert result["raw"] == ""


def test_git_diff_truncates_a_huge_diff(git_repo):
    from ollama_code import gitinfo

    (git_repo / "big.txt").write_text("")
    _commit(git_repo)
    (git_repo / "big.txt").write_text("\n".join(f"line {i}" for i in range(50_000)))

    result = gitinfo.file_diff(str(git_repo), "big.txt", max_bytes=5_000)
    assert result["truncated"] is True
    assert len(result["raw"]) <= 6_000


def test_git_diff_refuses_paths_outside_the_workspace(git_repo):
    from ollama_code import gitinfo

    for bogus in ["../../etc/passwd", "/etc/passwd"]:
        result = gitinfo.file_diff(str(git_repo), bogus)
        assert result["ok"] is False, bogus


def test_git_status_reports_a_missing_git_binary(tmp_path, monkeypatch):
    from ollama_code import gitinfo

    def explode(*a, **k):
        raise FileNotFoundError("git")

    monkeypatch.setattr(gitinfo.subprocess, "Popen", explode)
    result = gitinfo.status(str(tmp_path))
    assert result["ok"] is False
    assert "git" in (result["error"] or "")


def test_git_endpoints_are_reachable_and_origin_guarded(client):
    body = client.get("/api/git/status").json()
    assert "is_repo" in body and "files" in body

    assert client.get(
        "/api/git/status", headers={"Origin": "https://evil.example"}
    ).status_code == 403
    assert client.get(
        "/api/git/diff", params={"path": "x"}, headers={"Origin": "https://evil.example"}
    ).status_code == 403


def test_git_endpoints_work_while_the_agent_is_busy(client):
    from concurrent.futures import Future

    client.app.state.service.turn_future = Future()
    assert client.app.state.service.busy is True
    assert client.get("/api/git/status").status_code == 200


def test_mutating_tool_result_announces_a_workspace_change(client):
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()  # session_info
        ws.receive_json()  # terminal_state
        svc = client.app.state.service
        svc.emit({"type": "tool_result", "tool": "write_file", "ok": True, "denied": False})
        events = drain(ws)
        assert [e["type"] for e in events] == ["tool_result", "workspace_changed"]

        svc.emit({"type": "tool_result", "tool": "read_file", "ok": True, "denied": False})
        assert [e["type"] for e in drain(ws)] == ["tool_result"]


# --------------------------------------------------------------------- server


@pytest.fixture
def client(tmp_path, monkeypatch):
    """A TestClient whose core never talks to a real Ollama."""
    from ollama_code import server as server_mod

    core = AgentCore(cwd=str(tmp_path), config={"model": "test-model", "max_iterations": 5})
    core.model = "test-model"
    monkeypatch.setattr(core.client, "check", lambda: None)
    monkeypatch.setattr(
        core.client,
        "list_models",
        lambda: [{"name": "test-model", "size": 42, "details": {"parameter_size": "8B"}}],
    )
    monkeypatch.setattr(core.client, "context_length", lambda name: 32768)
    monkeypatch.setattr(core.client, "running_models", lambda: [
        {"name": "test-model", "context_length": 32768},
    ])
    core.messages = [core.system_message()]
    server_mod.app.state.service = server_mod.ChatService(core)
    with TestClient(server_mod.app) as c:
        yield c


def test_health_and_models(client):
    health = client.get("/api/health").json()
    assert health["ok"] is True and health["ollama"] is True

    models = client.get("/api/models").json()
    assert models["models"][0]["name"] == "test-model"
    assert models["models"][0]["context_length"] == 32768
    assert models["current"] == "test-model"


def test_models_report_the_window_a_model_is_really_running_in(client, monkeypatch):
    """The GUI meters against this number, so it has to be the real one."""
    core = client.app.state.service.core
    monkeypatch.setattr(core.client, "context_length", lambda name: 262_144)
    monkeypatch.setattr(core.client, "running_models", lambda: [
        {"name": "test-model", "context_length": 32_768},
    ])

    entry = client.get("/api/models").json()["models"][0]

    assert entry["context_length"] == 32_768, "the window in use"
    assert entry["trained_context_length"] == 262_144, "what the model supports"


def test_models_do_not_invent_a_window_for_a_model_that_is_not_loaded(client, monkeypatch):
    core = client.app.state.service.core
    monkeypatch.setattr(core.client, "context_length", lambda name: 262_144)
    monkeypatch.setattr(core.client, "running_models", lambda: [])

    entry = client.get("/api/models").json()["models"][0]

    assert entry["context_length"] == 0, "unknown, and the GUI knows what 0 means"
    assert entry["trained_context_length"] == 262_144


def test_models_do_not_report_a_local_window_for_a_remote_endpoint(client, monkeypatch):
    core = client.app.state.service.core
    core.provider = "remote"

    entry = client.get("/api/models").json()["models"][0]

    # An OpenAI-compatible endpoint advertises nothing, and a number read off
    # the local machine would be worse than saying so.
    assert entry["context_length"] == 0


def test_setting_the_context_window_takes_effect_without_a_restart(client):
    body = client.post("/api/config", json={"context_window": 16_384}).json()

    assert body["context_window"] == 16_384
    # The same number has to reach the compaction budget, not just the config.
    assert body["session_info"]["context_limit"] == 16_384
    assert client.app.state.service.core.chat_options() == {"num_ctx": 16_384}
    assert client.get("/api/config").json()["context_window"] == 16_384


def test_a_configured_window_is_only_claimed_for_the_model_in_use(client, monkeypatch):
    """`num_ctx` is sent for the current model alone, so saying the others run
    in that window too would be a guess about models nobody has loaded."""
    core = client.app.state.service.core
    monkeypatch.setattr(core.client, "list_models", lambda: [
        {"name": "test-model", "size": 1, "details": {"parameter_size": "8B"}},
        {"name": "other-model", "size": 2, "details": {"parameter_size": "3B"}},
    ])
    monkeypatch.setattr(core.client, "running_models", lambda: [])
    client.post("/api/config", json={"context_window": 16_384})

    rows = {m["name"]: m["context_length"] for m in client.get("/api/models").json()["models"]}

    assert rows["test-model"] == 16_384, "the one the agent is running"
    assert rows["other-model"] == 0, "not loaded, and not told to load that way"


def test_changing_the_window_mid_turn_is_refused_before_anything_is_applied(client, monkeypatch):
    svc = client.app.state.service
    monkeypatch.setattr(type(svc), "busy", property(lambda self: True))
    before = svc.core.cwd

    response = client.post("/api/config", json={"cwd": "/tmp", "context_window": 4_096})

    assert response.status_code == 409
    assert svc.core.cwd == before, "the cwd must not have been applied and then refused"
    assert config_mod.non_negative_int(svc.core.config.get("context_window")) != 4_096


def test_new_session_returns_session_info(client):
    before = client.get("/api/sessions").json()["current"]
    body = client.post("/api/sessions/new", json={"reason": "clear_chat"}).json()
    assert body["ok"] is True and body["reason"] == "clear_chat"
    assert body["session_info"]["session_id"] != before


def test_session_patch_and_detail(client):
    sid = client.get("/api/sessions").json()["current"]
    patched = client.patch(f"/api/sessions/{sid}", json={"title": "Named", "pinned": True}).json()
    assert patched == {"ok": True, "id": sid, "title": "Named", "pinned": True, "archived": False}

    detail = client.get(f"/api/sessions/{sid}").json()
    assert detail["title"] == "Named" and detail["pinned"] is True
    assert detail["cwd"] and detail["started"]


def test_patch_unknown_session_is_404(client):
    assert client.patch("/api/sessions/nope", json={"title": "x"}).status_code == 404


def _record_message(client, text: str) -> None:
    """Give the active session a message so it appears in listings."""
    core = client.app.state.service.core
    core.session.append({"type": "message", "message": {"role": "user", "content": text}})


def test_delete_sessions_preserves_active(client):
    active = client.get("/api/sessions").json()["current"]
    _record_message(client, "first session")
    client.post("/api/sessions/new", json={"reason": "clear_chat"})
    new_active = client.get("/api/sessions").json()["current"]
    _record_message(client, "second session")

    body = client.delete("/api/sessions").json()
    assert body["ok"] is True
    assert body["preserved_session_id"] == new_active
    assert body["count"] >= 1
    assert body["recovery_path"]
    remaining = [s["id"] for s in client.get("/api/sessions").json()["sessions"]]
    assert new_active in remaining and active not in remaining


def test_browser_origins_are_rejected(client):
    """A page on any site must not be able to drive the local agent."""
    assert client.get("/api/health", headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.delete("/api/sessions", headers={"Origin": "http://localhost:3000"}).status_code == 403
    # The native client sends no Origin header.
    assert client.get("/api/health").status_code == 200


def test_browser_websockets_are_rejected(client):
    from starlette.websockets import WebSocketDisconnect as WSDisconnect

    with pytest.raises((WSDisconnect, Exception)):
        with client.websocket_connect(
            "/ws/chat", headers={"Origin": "https://evil.example"}
        ) as ws:
            ws.receive_json()


def test_partial_stream_is_not_lost_when_the_model_fails(tmp_path):
    """Tokens the user already saw must survive a mid-stream failure."""
    from ollama_code.ollama import OllamaError

    class FailingClient(FakeClient):
        def chat_stream(self, model, messages, tools=None, on_token=None, **kwargs):
            if on_token:
                on_token("partial answer so far")
            raise OllamaError("connection dropped")

    core = _core(tmp_path, [])
    core.client = FailingClient([])
    events = []
    core.on_event(events.append)

    core.run_turn("question")

    assert any(e["type"] == "error" for e in events)
    assistant = [m for m in core.messages if m["role"] == "assistant"]
    assert assistant and "partial answer so far" in assistant[-1]["content"]
    saved = SessionStore.load(core.session.path)
    assert any("partial answer so far" in str(m.get("content")) for m in saved)


def test_reading_outside_the_workspace_requires_permission(tmp_path):
    from ollama_code.ollama import ToolCall

    secret = tmp_path.parent / "secret.txt"
    secret.write_text("private")
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "inside.txt").write_text("fine")

    core = _core(workspace, [
        ChatResponse(tool_calls=[ToolCall("read_file", {"path": str(secret)})], done=True),
        ChatResponse(tool_calls=[ToolCall("read_file", {"path": "inside.txt"})], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ])
    events = []
    core.on_event(events.append)
    asked = []

    core.run_turn("read things", decider=lambda *a: (asked.append(a[0]), "deny")[1])

    proposals = [e for e in events if e["type"] == "tool_call_proposed"]
    assert proposals[0]["auto"] is False, "a file outside the workspace must ask"
    assert proposals[1]["auto"] is True, "a file inside the workspace stays automatic"
    assert asked == ["read_file"]


def test_tools_and_permissions_endpoints(client):
    tools = client.get("/api/tools").json()["tools"]
    names = {t["name"] for t in tools}
    assert {"read_file", "edit_file", "multi_edit", "bash", "git_diff"} <= names

    perms = client.post("/api/permissions", json={"mode": "accept_edits"}).json()
    assert perms["mode"] == "accept_edits"
    assert client.get("/api/permissions").json()["mode"] == "accept_edits"
    assert client.post("/api/permissions", json={"mode": "nope"}).status_code == 422


def drain(ws, limit: int = 25) -> list[dict]:
    """Collect the events an action produced.

    A `ping` is sent as a sentinel: the server answers `pong`, and because the
    socket handler processes messages in order, everything received before the
    pong belongs to the preceding action. Without this the test would block
    forever whenever the event count changed.
    """
    ws.send_json({"type": "ping"})
    out: list[dict] = []
    for _ in range(limit):
        event = ws.receive_json()
        if event.get("type") == "pong":
            return out
        out.append(event)
    raise AssertionError(f"no pong after {limit} events: {[e.get('type') for e in out]}")


def test_websocket_sends_session_info_and_handles_messages(client):
    with client.websocket_connect("/ws/chat") as ws:
        first = ws.receive_json()
        assert first["type"] == "session_info"
        assert first["session_id"]

        ws.send_json({"type": "new_session", "reason": "clear_chat"})
        events = drain(ws)
        started = [e for e in events if e["type"] == "session_started"]
        assert started and started[0]["reason"] == "clear_chat"
        assert started[0]["session_info"]["session_id"] != first["session_id"]

        ws.send_json({"type": "bogus"})
        assert [e["type"] for e in drain(ws)] == ["error"]


def test_websocket_set_cwd_and_model(client, tmp_path):
    target = tmp_path / "workspace"
    target.mkdir()
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()  # session_info
        ws.send_json({"type": "set_cwd", "path": str(target)})
        events = drain(ws)
        assert any(
            e.get("type") == "session_info" and e.get("cwd") == str(target) for e in events
        )

        ws.send_json({"type": "set_model", "model": "test-model"})
        assert any(e.get("type") == "session_info" for e in drain(ws))


# ----------------------------------------------------------------- agent loop


class FakeClient:
    """Scripted Ollama client: yields a queued ChatResponse per call."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = 0
        #: Options seen per call. Recorded rather than discarded: `num_ctx` is
        #: only correct if it reaches the client, and a stub that swallows it
        #: makes the suite pass while proving nothing.
        self.seen_options: list[dict | None] = []
        #: What Ollama would report for a resident model, as /api/ps does, and
        #: the window the model was trained for, as /api/show does.
        self.loaded_window = 0
        self.trained_window = 262_144

    def chat_stream(self, model, messages, tools=None, on_token=None, should_stop=None,
                    on_thinking=None, think=False, options=None):
        self.calls += 1
        self.seen_options.append(options)
        resp = self._responses.pop(0)
        for part in resp.content_parts:
            if on_token:
                on_token(part)
        return resp

    def context_length(self, name):
        return self.trained_window

    def loaded_context_length(self, name):
        return self.loaded_window

    def list_models(self):
        return [{"name": "test-model"}]


def _core(tmp_path, responses):
    core = AgentCore(cwd=str(tmp_path), config={"model": "test-model", "max_iterations": 5})
    core.model = "test-model"
    core.client = FakeClient(responses)
    core.messages = [core.system_message()]
    return core


def test_run_turn_emits_streaming_and_turn_done(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["Hello ", "world"], done=True)])
    events = []
    core.on_event(events.append)

    core.run_turn("hi")

    types = [e["type"] for e in events]
    assert types[:2] == ["message_start", "token"]
    assert "message_end" in types
    done = next(e for e in events if e["type"] == "turn_done")
    assert done["reason"] == "complete"
    assert core.messages[-1]["content"] == "Hello world"


def test_tool_call_runs_and_reports(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("list_dir", {"path": "."})], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ]
    core = _core(tmp_path, responses)
    events = []
    core.on_event(events.append)

    core.run_turn("list the directory")

    proposed = next(e for e in events if e["type"] == "tool_call_proposed")
    assert proposed["tool"] == "list_dir" and proposed["auto"] is True
    result = next(e for e in events if e["type"] == "tool_result")
    assert result["ok"] is True
    assert core.messages[-2]["role"] == "tool"


def test_permission_denial_is_reported_to_the_model(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("write_file", {"path": "x", "content": "y"})], done=True),
        ChatResponse(content_parts=["ok"], done=True),
    ]
    core = _core(tmp_path, responses)
    events = []
    core.on_event(events.append)

    core.run_turn("write a file", decider=lambda *a: "deny")

    result = next(e for e in events if e["type"] == "tool_result")
    assert result["denied"] is True
    assert "Permission denied" in result["result"]
    assert not (tmp_path / "x").exists()


def test_always_decision_allows_subsequent_calls(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("write_file", {"path": "a", "content": "1"})], done=True),
        ChatResponse(tool_calls=[ToolCall("write_file", {"path": "b", "content": "2"})], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ]
    core = _core(tmp_path, responses)
    asked = []
    core.run_turn("write two files", decider=lambda *a: (asked.append(a), "always")[1])

    assert len(asked) == 1, "the second write must not ask again"
    assert (tmp_path / "a").exists() and (tmp_path / "b").exists()


def test_blocked_command_never_executes(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("bash", {"command": "rm -rf /"})], done=True),
        ChatResponse(content_parts=["stopped"], done=True),
    ]
    core = _core(tmp_path, responses)
    events = []
    core.on_event(events.append)
    called = []

    core.run_turn("delete everything", decider=lambda *a: (called.append(a), "once")[1])

    assert not called, "a denied command must never reach the permission prompt"
    result = next(e for e in events if e["type"] == "tool_result")
    assert result["denied"] is True and "deny list" in result["result"]


def test_retry_last_branches_to_a_new_session(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(content_parts=["first"], done=True),
        ChatResponse(content_parts=["second"], done=True),
    ])
    core.run_turn("question")
    original_session = core.session.session_id

    events = []
    core.on_event(events.append)
    assert core.retry_last() is True

    started = next(e for e in events if e["type"] == "session_started")
    assert started["reason"] == "retry"
    assert core.session.session_id != original_session
    assert core.messages[-1]["content"] == "second"
    assert [m["content"] for m in core.messages if m["role"] == "user"] == ["question"]


def test_retry_without_history_reports_an_error(tmp_path):
    core = _core(tmp_path, [])
    events = []
    core.on_event(events.append)
    assert core.retry_last() is False
    assert events[-1]["type"] == "error"


def test_new_session_emits_session_started_and_clears_state(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["hi"], done=True)])
    core.run_turn("hello")
    core.tool_ctx.todos = [{"content": "x", "status": "pending"}]
    events = []
    core.on_event(events.append)

    info = core.new_session(reason="clear_chat")

    started = next(e for e in events if e["type"] == "session_started")
    assert started["reason"] == "clear_chat"
    assert info["messages"] == 1  # just the system prompt
    assert core.tool_ctx.todos == []


def test_auto_compaction_runs_before_the_window_overflows(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(content_parts=["a summary"], done=True),   # the compaction call
        ChatResponse(content_parts=["answer"], done=True),      # the real turn
    ])
    core.client.loaded_window = 32_768
    core.messages = [
        core.system_message(),
        {"role": "user", "content": "x" * 60_000},
        {"role": "assistant", "content": "y" * 60_000},
    ]
    events = []
    core.on_event(events.append)

    core.run_turn("next question")

    notes = [e for e in events if e["type"] == "note"]
    assert notes and "compact" in notes[0]["text"].lower()
    assert any("a summary" in str(m.get("content")) for m in core.messages)
    assert core.approx_tokens() < 32_768


def test_auto_compaction_stays_off_below_the_threshold(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.client.loaded_window = 100_000
    core.run_turn("short question")
    assert core.client.calls == 1, "no compaction call should have been made"


def test_approx_tokens_counts_tool_call_arguments(tmp_path):
    core = _core(tmp_path, [])
    core.messages = [{"role": "assistant", "content": "", "tool_calls": [
        {"type": "function", "function": {"name": "write_file", "arguments": {"content": "z" * 4000}}}
    ]}]
    assert core.approx_tokens() > 900


# -------------------------------------------------------- context window
#
# Ollama does not give a model the window it was trained for. Without an
# explicit `num_ctx` every request gets Ollama's own default, so budgeting
# against the trained window overflows the real one long before the agent
# thinks it is close — and a tool call cut off partway through its JSON
# arguments comes back as "unexpected end of JSON input".


def test_the_window_in_use_comes_from_what_ollama_loaded():
    from ollama_code.ollama import effective_context_length

    # A model trained for 262k that Ollama loaded with a 32k window is running
    # in 32k, and that is the number a session has to be measured against.
    assert effective_context_length(32_768, 262_144) == 32_768
    # Not loaded and nothing configured: unknown, and unknown is not a licence
    # to invent a number.
    assert effective_context_length(0, 262_144) == 0
    assert effective_context_length(0, 0) == 0


def test_a_configured_window_wins_and_is_clamped_by_the_model():
    from ollama_code.ollama import effective_context_length

    # Asking for more than the model was trained for buys rope-extrapolated
    # garbage and a KV cache that cannot be filled.
    assert effective_context_length(0, 8_192, 65_536) == 8_192
    assert effective_context_length(0, 262_144, 65_536) == 65_536
    # An explicit setting beats whatever happened to be loaded earlier.
    assert effective_context_length(32_768, 262_144, 65_536) == 65_536
    # Unknown trained window: honour what the user asked for.
    assert effective_context_length(0, 0, 65_536) == 65_536


def test_loaded_window_is_read_from_ollamas_own_report(monkeypatch):
    from ollama_code import ollama as ollama_mod

    client = ollama_mod.OllamaClient("http://localhost:11434")
    monkeypatch.setattr(client, "running_models", lambda: [
        {"name": "other:latest", "context_length": 8_192},
        {"name": "wanted:latest", "model": "wanted:latest", "context_length": 32_768},
    ])
    assert client.loaded_context_length("wanted:latest") == 32_768
    assert client.loaded_context_length("not-loaded:latest") == 0

    def unreachable():
        raise OllamaError("connection refused")

    monkeypatch.setattr(client, "running_models", unreachable)
    assert client.loaded_context_length("wanted:latest") == 0


def test_context_length_prefers_the_text_models_own_key(monkeypatch):
    from ollama_code import ollama as ollama_mod

    client = ollama_mod.OllamaClient("http://localhost:11434")
    # A multimodal GGUF publishes a window for its vision encoder too, and it
    # can come first in dict order.
    monkeypatch.setattr(client, "show_model", lambda name: {"model_info": {
        "clip.vision.context_length": 4_096,
        "general.architecture": "qwen35moe",
        "qwen35moe.context_length": 262_144,
    }})
    assert client.context_length("m") == 262_144


def test_chat_stream_sends_num_ctx_under_options(monkeypatch):
    from ollama_code import ollama as ollama_mod

    seen = {}

    def fake_post(url, json=None, stream=None, timeout=None):
        seen["url"] = url
        seen["payload"] = json
        return FakeResponse(lines=[
            '{"message":{"content":"hi"},"done":true,"done_reason":"stop"}'
        ])

    monkeypatch.setattr(ollama_mod.requests, "post", fake_post)
    client = ollama_mod.OllamaClient("http://localhost:11434")

    client.chat_stream("m", [{"role": "user", "content": "hi"}], options={"num_ctx": 49_152})

    assert seen["url"] == "http://localhost:11434/api/chat"
    assert seen["payload"]["options"] == {"num_ctx": 49_152}


def test_nothing_is_pinned_unless_the_user_asked_for_a_window(tmp_path):
    """Ollama sizes the window itself, and overriding that with a guess would
    evict a resident runner for a number we can simply read back instead."""
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.client.loaded_window = 32_768

    core.run_turn("hi")

    assert core.context_limit == 32_768, "budgeted against the real window"
    assert core.client.seen_options == [None], "but nothing forced onto the request"


def test_the_window_is_known_by_the_end_of_the_very_first_turn(tmp_path):
    """Ollama only reports a window once the model is resident, which it is not
    when the first turn starts. The meter must not stay blank until turn two."""
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])

    class LoadsOnFirstUse(FakeClient):
        def chat_stream(self, *args, **kwargs):
            self.loaded_window = 32_768  # the model is resident from here on
            return super().chat_stream(*args, **kwargs)

    core.client = LoadsOnFirstUse([ChatResponse(content_parts=["answer"], done=True)])
    events = []
    core.on_event(events.append)

    core.run_turn("hi")

    assert core.context_limit == 32_768
    assert [e for e in events if e["type"] == "session_info"], (
        "the GUI has to be told once the window becomes known"
    )


def test_a_configured_window_is_sent_on_every_call_in_a_turn(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.config["context_window"] = 49_152

    core.run_turn("hi")

    assert core.client.seen_options == [{"num_ctx": 49_152}]


def test_compaction_asks_for_the_same_window_as_the_turn(tmp_path):
    # A different num_ctx mid-turn would make Ollama reload the model.
    core = _core(tmp_path, [
        ChatResponse(content_parts=["a summary"], done=True),
        ChatResponse(content_parts=["answer"], done=True),
    ])
    core.config["context_window"] = 32_768
    core.messages = [
        core.system_message(),
        {"role": "user", "content": "x" * 60_000},
        {"role": "assistant", "content": "y" * 60_000},
    ]

    core.run_turn("next question")

    assert core.client.seen_options == [{"num_ctx": 32_768}, {"num_ctx": 32_768}]


def test_the_remote_provider_is_never_sent_num_ctx(tmp_path):
    # RemoteClient splats options onto the top level of an OpenAI body, where
    # num_ctx means nothing and a strict gateway answers 400.
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.provider = "remote"
    core.config["context_window"] = 32_768

    core.run_turn("hi")

    assert core.client.seen_options == [None]
    assert core.context_limit == 32_768, "still budgeted against, just not sent"


def test_an_unknown_window_is_left_unknown(tmp_path, monkeypatch):
    """A model that is not loaded, or an Ollama that did not answer, must not
    turn into a confident number the GUI then meters against."""
    core = _core(tmp_path, [])
    monkeypatch.setattr(core.client, "context_length", lambda name: 262_144)
    core.client.loaded_window = 0

    core.refresh_context_limit()

    assert core.context_limit == 0
    assert core.chat_options() is None


def test_an_evicted_model_does_not_erase_the_window_we_already_knew(tmp_path):
    """Ollama unloads a model after five idle minutes and it drops off
    /api/ps. Forgetting the window then would switch compaction off for the
    rest of the session, silently."""
    core = _core(tmp_path, [])
    core.client.loaded_window = 32_768
    core.refresh_context_limit()
    assert core.context_limit == 32_768

    core.client.loaded_window = 0  # evicted
    core.refresh_context_limit()

    assert core.context_limit == 32_768


def test_the_trained_window_is_only_asked_for_once_per_model(tmp_path):
    """/api/show is a 15-second-timeout POST describing a file on disk, and
    refresh runs twice a turn."""
    core = _core(tmp_path, [])
    calls = []
    core.client.context_length = lambda name: (calls.append(name), 262_144)[1]

    for _ in range(5):
        core.refresh_context_limit()
    assert len(calls) == 1

    core.model = "another-model"
    core.refresh_context_limit()
    assert len(calls) == 2, "but a model switch does re-ask"


def test_switching_provider_does_not_block_on_ollama(tmp_path, monkeypatch):
    """The app awaits POST /api/provider on a short timeout, and resolving the
    window means an /api/ps plus an /api/show against a host that may be down."""
    core = _core(tmp_path, [])

    def unreachable(*args, **kwargs):
        raise AssertionError("provider switch must not talk to Ollama")

    monkeypatch.setattr(core.client, "context_length", unreachable)
    monkeypatch.setattr(core.client, "loaded_context_length", unreachable)

    core.use_ollama()
    core.use_remote("https://endpoint.example")


def test_a_configured_window_is_clamped_to_the_model(tmp_path, monkeypatch):
    core = _core(tmp_path, [])
    monkeypatch.setattr(core.client, "context_length", lambda name: 8_192)
    core.config["context_window"] = 65_536

    core.refresh_context_limit()

    assert core.context_limit == 8_192
    assert core.chat_options() == {"num_ctx": 8_192}


def test_a_window_written_in_thousands_is_not_honoured_as_tokens(tmp_path):
    """32 almost certainly means 32k. Sending `num_ctx: 32` would truncate
    every request, persist across restarts, and point at nothing."""
    from ollama_code.config import MINIMUM_CONTEXT_WINDOW, context_window

    assert context_window(32) == 0
    assert context_window(True) == 0, "a JSON true coerces to 1"
    assert context_window(MINIMUM_CONTEXT_WINDOW) == MINIMUM_CONTEXT_WINDOW

    core = _core(tmp_path, [])
    core.client.loaded_window = 32_768
    core.config["context_window"] = 32

    core.refresh_context_limit()

    assert core.context_limit == 32_768, "falls back to what Ollama chose"
    assert core.chat_options() is None


def test_a_window_written_in_thousands_is_refused_over_http(client):
    response = client.post("/api/config", json={"context_window": 32})

    assert response.status_code == 422
    assert "at least" in response.json()["detail"]
    # 0 stays legal — it is how you ask Ollama to size the window.
    assert client.post("/api/config", json={"context_window": 0}).status_code == 200


def test_a_hand_edited_window_cannot_take_the_agent_down(tmp_path):
    core = _core(tmp_path, [])
    core.client.loaded_window = 16_384
    # `1e999` is valid JSON and parses to float('inf'); int(inf) raises
    # OverflowError, which would kill the service before the user could reach
    # the setting to correct it.
    for bad in ("sixty-four thousand", None, -1, {}, float("inf"), float("nan")):
        core.config["context_window"] = bad
        core.refresh_context_limit()  # must not raise
        # Garbage is treated as "not configured", so the loaded window stands.
        assert core.context_limit == 16_384


def test_compaction_leaves_room_for_the_schemas_and_the_reply(tmp_path):
    from ollama_code.core import (
        ESTIMATE_OPTIMISM,
        RESERVED_REPLY_TOKENS,
        TOOL_SCHEMA_TOKENS,
    )

    core = _core(tmp_path, [ChatResponse(content_parts=["a summary"], done=True)])
    core.context_limit = 32_768
    core.messages = [
        core.system_message(),
        {"role": "user", "content": "x" * 44_000},
        {"role": "assistant", "content": "y" * 43_000},
    ]

    # The old rule was 75% of the whole window and nothing else, so a
    # conversation this size sat under the threshold and kept growing.
    assert core.approx_tokens() < int(core.context_limit * 0.75)
    # The new one takes the schemas and a reply out of the window first, then
    # discounts for `approx_tokens` being an optimistic count of code and JSON.
    budget = int(
        (core.context_limit - TOOL_SCHEMA_TOKENS - RESERVED_REPLY_TOKENS)
        * ESTIMATE_OPTIMISM
    )
    assert budget < core.approx_tokens()
    assert core.auto_compact_if_needed() is True


def test_a_small_window_still_compacts_rather_than_giving_up(tmp_path):
    """The reply allowance scales with the window. Reserving a flat 4k of an 8k
    window would leave a budget below the system prompt, and compacting on
    every turn while never getting under it is worse than not compacting."""
    core = _core(tmp_path, [ChatResponse(content_parts=["a summary"], done=True)])
    core.context_limit = 8_192
    core.messages = [
        core.system_message(),
        {"role": "user", "content": "x" * 20_000},
        {"role": "assistant", "content": "y" * 20_000},
    ]

    assert core.auto_compact_if_needed() is True


def test_a_window_too_small_to_reclaim_anything_does_not_thrash(tmp_path):
    # Below the size of the system prompt there is nothing for a summary to
    # win back, so compacting every turn would be pure loss.
    core = _core(tmp_path, [])
    core.context_limit = 512
    core.messages = [
        core.system_message(),
        {"role": "user", "content": "x" * 8_000},
        {"role": "assistant", "content": "y" * 8_000},
    ]

    assert core.auto_compact_if_needed() is False


def test_compaction_is_not_announced_when_there_is_nothing_to_compact(tmp_path):
    core = _core(tmp_path, [])
    core.context_limit = 32_768
    core.messages = [core.system_message(), {"role": "user", "content": "x" * 200_000}]
    events = []
    core.on_event(events.append)

    assert core.auto_compact_if_needed() is False
    assert not [e for e in events if e["type"] == "note"]


def test_interrupt_leaves_no_unanswered_tool_calls(tmp_path):
    from ollama_code.ollama import ToolCall

    # write_file asks for permission, so the decider (which interrupts) runs.
    core = _core(tmp_path, [
        ChatResponse(
            tool_calls=[
                ToolCall("write_file", {"path": "a.txt", "content": "1"}),
                ToolCall("write_file", {"path": "b.txt", "content": "2"}),
            ],
            done=True,
        ),
    ])

    def decider(*_args):
        core.interrupt()
        return "once"

    core.run_turn("do two things", decider=decider)

    calls = sum(len(m.get("tool_calls") or []) for m in core.messages)
    results = sum(1 for m in core.messages if m.get("role") == "tool")
    assert results == calls, "every proposed tool call needs a result message"


def test_truncated_generation_is_reported(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(content_parts=["cut off"], done=True, done_reason="length"),
    ])
    events = []
    core.on_event(events.append)
    core.run_turn("write a long thing")
    assert any("output limit" in e.get("text", "") for e in events if e["type"] == "note")


def test_empty_sessions_are_hidden_from_the_listing(tmp_path):
    empty = SessionStore(str(tmp_path))
    used = SessionStore(str(tmp_path))
    used.append({"type": "message", "message": {"role": "user", "content": "hi"}})

    ids = [s["id"] for s in SessionStore.summaries()]
    assert used.session_id in ids
    assert empty.session_id not in ids


def test_restore_does_not_overwrite_a_recreated_session(tmp_path):
    original = SessionStore(str(tmp_path))
    original.append({"type": "message", "message": {"role": "user", "content": "original"}})
    session_id = original.session_id
    SessionStore.move_to_trash([session_id])

    # A new session takes the same name before the user restores the batch.
    recreated = SessionStore.path_for(session_id)
    assert recreated is None
    (sessions_mod.SESSIONS_DIR / f"{session_id}.jsonl").write_text(
        json.dumps({"type": "message", "message": {"role": "user", "content": "newer"}}) + "\n"
    )

    assert SessionStore.restore_from_trash() == 1
    surviving = (sessions_mod.SESSIONS_DIR / f"{session_id}.jsonl").read_text()
    assert "newer" in surviving, "the existing transcript must not be overwritten"
    restored = list(sessions_mod.SESSIONS_DIR.glob(f"{session_id}-restored-*.jsonl"))
    assert restored and "original" in restored[0].read_text()


def test_slash_help_and_tools(tmp_path):
    core = _core(tmp_path, [])
    assert "/compact" in core.handle_slash("/help")["text"]
    tools = core.handle_slash("/tools")
    assert "multi_edit" in tools["text"]
    assert "read_file" in tools["data"]["tools"]


def test_slash_unknown_is_flagged(tmp_path):
    core = _core(tmp_path, [])
    result = core.handle_slash("/nope")
    assert result["error"] is True and "Unknown command" in result["text"]


def test_slash_permissions_mode(tmp_path):
    core = _core(tmp_path, [])
    assert core.handle_slash("/permissions mode bypass")["text"].endswith("bypass.")
    assert core.perms.mode == "bypass"
    assert core.handle_slash("/permissions mode nonsense")["error"] is True


def test_slash_compact_replaces_history(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(content_parts=["answer"], done=True),
        ChatResponse(content_parts=["a summary"], done=True),
    ])
    core.run_turn("a question")
    result = core.handle_slash("/compact")
    assert result["command"] == "compact"
    assert "a summary" in core.messages[1]["content"]
    assert len(core.messages) == 2


def test_resume_session_restores_messages(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.run_turn("remember this")
    sid = core.session.session_id

    core.new_session()
    assert len(core.messages) == 1

    result = core.resume_session(sid)
    assert "Resumed" in result["text"]
    assert any(m.get("content") == "remember this" for m in core.messages)


def test_clear_saved_sessions_keeps_the_active_one(tmp_path):
    core = _core(tmp_path, [])
    first = core.session.session_id
    core.session.append({"type": "message", "message": {"role": "user", "content": "a"}})
    core.new_session()
    active = core.session.session_id

    result = core.clear_saved_sessions()
    assert result["preserved_session_id"] == active
    assert result["count"] >= 1
    assert SessionStore.path_for(active) is not None
    assert SessionStore.path_for(first) is None


# ------------------------------------------------- mid-turn window resilience


class OverflowingClient(FakeClient):
    """FakeClient that raises the verbatim llama-server overflow on chosen calls."""

    def __init__(self, responses, fail_on_calls=()):
        super().__init__(responses)
        self.fail_on_calls = set(fail_on_calls)

    def chat_stream(self, model, messages, tools=None, on_token=None, **kwargs):
        self.calls += 1
        self.seen_options.append(kwargs.get("options"))
        if self.calls in self.fail_on_calls:
            from ollama_code.ollama import OllamaError

            raise OllamaError(
                'llama-server returned invalid tool call arguments for '
                '"write_file": unexpected end of JSON input'
            )
        resp = self._responses.pop(0)
        for part in resp.content_parts:
            if on_token:
                on_token(part)
        return resp


def test_mid_turn_eviction_keeps_tool_pairing_and_the_newest_result(tmp_path, monkeypatch):
    """A single turn can out-read the window; old results are stubbed in place."""
    from ollama_code.ollama import ToolCall

    monkeypatch.setattr("ollama_code.core.execute_tool", lambda *a, **k: "x" * 25_000)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[
            ToolCall("read_file", {"path": "a"}),
            ToolCall("read_file", {"path": "b"}),
            ToolCall("read_file", {"path": "c"}),
        ], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ])
    core.client.loaded_window = 8_192
    events = []
    core.on_event(events.append)

    core.run_turn("read everything")

    tool_messages = [m for m in core.messages if m.get("role") == "tool"]
    stubbed = [m for m in tool_messages if "dropped to fit the context window" in m["content"]]
    assert stubbed, "the guard must have evicted something"
    assert len(stubbed) < len(tool_messages), "never all of them"
    assert tool_messages[-1]["content"] == "x" * 25_000, "the newest result is protected"
    # Pairing is intact: every proposed call still has a tool reply.
    proposed = sum(len(m.get("tool_calls") or []) for m in core.messages)
    assert proposed == len(tool_messages)
    notes = [e for e in events if e["type"] == "note" and "older tool result" in e["text"]]
    assert len(notes) == 1, "one eviction event, one note"
    assert not any(e["type"] == "error" for e in events)
    # The session file keeps the full outputs: eviction is in-memory only.
    saved = SessionStore.load(core.session.path)
    full = [m for m in saved if m.get("role") == "tool" and m.get("content") == "x" * 25_000]
    assert len(full) == 3


def test_a_tool_call_cut_off_by_the_window_is_retried_once(tmp_path, monkeypatch):
    from ollama_code.ollama import ToolCall

    monkeypatch.setattr("ollama_code.core.execute_tool", lambda *a, **k: "y" * 25_000)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[
            ToolCall("read_file", {"path": "a"}),
            ToolCall("read_file", {"path": "b"}),
        ], done=True),
        ChatResponse(content_parts=["recovered"], done=True),
    ])
    core.client = OverflowingClient(core.client._responses, fail_on_calls={2})
    core.client.loaded_window = 8_192
    events = []
    core.on_event(events.append)

    core.run_turn("read then write")

    done = next(e for e in events if e["type"] == "turn_done")
    assert done["reason"] == "complete"
    assert not any(e["type"] == "error" for e in events)
    retry_notes = [e for e in events if e["type"] == "note" and "retrying" in e["text"]]
    assert len(retry_notes) == 1
    assert core.client.calls == 3, "initial + failed + successful retry"
    starts = sum(1 for e in events if e["type"] == "message_start")
    ends = sum(1 for e in events if e["type"] == "message_end")
    assert starts == ends, "the aborted call closes its own message pair"
    assert core.messages[-1]["content"] == "recovered"


def test_a_second_overflow_failure_surfaces_the_error(tmp_path, monkeypatch):
    from ollama_code.ollama import ToolCall

    monkeypatch.setattr("ollama_code.core.execute_tool", lambda *a, **k: "z" * 25_000)
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[
            ToolCall("read_file", {"path": "a"}),
            ToolCall("read_file", {"path": "b"}),
        ], done=True),
    ])
    core.client = OverflowingClient(core.client._responses, fail_on_calls={2, 3})
    core.client.loaded_window = 8_192
    events = []
    core.on_event(events.append)

    core.run_turn("read then write")

    assert any(e["type"] == "error" for e in events)
    assert next(e for e in events if e["type"] == "turn_done")["reason"] == "error"
    retry_notes = [e for e in events if e["type"] == "note" and "retrying" in e["text"]]
    assert len(retry_notes) == 1, "exactly one retry is attempted"
    assert core.client.calls == 3


def test_overflow_recovery_gives_up_when_nothing_is_evictable(tmp_path):
    core = _core(tmp_path, [])
    core.client = OverflowingClient([], fail_on_calls={1})
    core.client.loaded_window = 8_192
    events = []
    core.on_event(events.append)

    core.run_turn("first question")

    # A fresh turn holds no sizable tool output: a retry with the identical
    # prompt would only fail identically, so none is attempted.
    assert core.client.calls == 1
    assert any(e["type"] == "error" for e in events)
    assert not any(e["type"] == "note" and "retrying" in e.get("text", "") for e in events)


def test_a_cold_turn_learns_its_window_between_iterations(tmp_path):
    """The window must be known by iteration 2, not a whole turn late."""
    from ollama_code.ollama import ToolCall

    class WindowRecorder(FakeClient):
        core = None

        def __init__(self, responses):
            super().__init__(responses)
            self.seen_limits = []

        def chat_stream(self, model, messages, **kwargs):
            self.seen_limits.append(self.core.context_limit)
            result = super().chat_stream(model, messages, **kwargs)
            # The first reply is what makes the model resident on /api/ps.
            self.loaded_window = 32_768
            return result

    core = _core(tmp_path, [])
    client = WindowRecorder([
        ChatResponse(tool_calls=[ToolCall("list_dir", {"path": "."})], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ])
    client.trained_window = 262_144
    client.loaded_window = 0
    client.core = core
    core.client = client

    core.run_turn("look around")

    assert client.seen_limits == [0, 32_768]


def test_compaction_transcript_is_capped_so_it_cannot_overflow_itself(tmp_path):
    from ollama_code.core import COMPACT_TRANSCRIPT_CAP_CHARS

    class RecordingClient(FakeClient):
        def __init__(self, responses):
            super().__init__(responses)
            self.seen_messages = []

        def chat_stream(self, model, messages, **kwargs):
            self.seen_messages.append([dict(m) for m in messages])
            return super().chat_stream(model, messages, **kwargs)

    core = _core(tmp_path, [])
    core.client = RecordingClient([ChatResponse(content_parts=["summary"], done=True)])
    core.context_limit = 32_768
    for i in range(40):
        role = "user" if i % 2 == 0 else "assistant"
        core.messages.append({"role": role, "content": f"marker-{i} " + "x" * 2_000})

    result = core._slash_compact()

    assert not result.get("error")
    request = core.client.seen_messages[0][-1]["content"]
    assert len(request) <= COMPACT_TRANSCRIPT_CAP_CHARS + 500
    assert "marker-39" in request, "the newest message survives"
    assert "marker-0" not in request, "the oldest is dropped first"
    assert "Earlier messages omitted" in request


def test_think_fallback_does_not_replay_streamed_tokens(monkeypatch):
    from ollama_code import ollama as ollama_mod

    client = ollama_mod.OllamaClient()
    attempts = []

    def stream_that_fails_after_tokens(self, payload, on_token, should_stop=None, on_thinking=None):
        attempts.append(payload.get("think"))
        if len(attempts) == 1:
            if on_token:
                on_token("half an answer")
            raise ollama_mod.OllamaError("think is not supported")
        return ChatResponse(done=True)

    monkeypatch.setattr(ollama_mod.OllamaClient, "_stream", stream_that_fails_after_tokens)
    with pytest.raises(ollama_mod.OllamaError):
        client.chat_stream("m", [], think=True, on_token=lambda t: None)
    assert len(attempts) == 1, "tokens already reached the UI; replaying them is worse"

    attempts.clear()

    def stream_that_fails_before_tokens(self, payload, on_token, should_stop=None, on_thinking=None):
        attempts.append(payload.get("think"))
        if len(attempts) == 1:
            raise ollama_mod.OllamaError("think is not supported")
        return ChatResponse(done=True)

    monkeypatch.setattr(ollama_mod.OllamaClient, "_stream", stream_that_fails_before_tokens)
    resp = client.chat_stream("m", [], think=True, on_token=lambda t: None)
    assert attempts == [True, None], "nothing streamed yet, so the fallback retries without think"
    assert resp.done


def test_window_overflow_classifier_matches_only_overflow_shapes():
    from ollama_code.core import _looks_like_window_overflow

    assert _looks_like_window_overflow(
        'llama-server returned invalid tool call arguments for "write_file": '
        "unexpected end of JSON input"
    )
    assert _looks_like_window_overflow("Error Parsing Tool Call: boom")
    assert not _looks_like_window_overflow("connection dropped")
    assert not _looks_like_window_overflow("chat request failed: timeout")


def test_local_ollama_is_the_default_with_no_account_configured():
    """A fresh install talks to the local runtime, not to anything hosted."""
    from ollama_code.config import DEFAULTS

    assert DEFAULTS["provider"] == "ollama"
    assert DEFAULTS["remote_base_url"] == ""
    assert DEFAULTS["remote_model"] == ""


def test_switching_endpoints_does_not_carry_the_old_model_over(tmp_path, monkeypatch):
    """A model name belongs to the endpoint it came from.

    The failure this prevents was real: a config left holding
    remote_model "kimi-k2" against an Anthropic base URL, which would have
    surfaced as a model-not-found naming neither the model nor the host.
    """
    from ollama_code import config as config_mod
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")
    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})

    core.use_remote("https://api.moonshot.ai/v1", api_key="k", model="kimi-k2")
    assert core.config["remote_model"] == "kimi-k2"

    # A different provider, no model named: the old one must not follow.
    core.use_remote("https://api.anthropic.com/v1")
    assert core.config["remote_model"] == ""
    # The live model matters more than the stored one: it is what
    # session_info reports and what chat_stream actually sends.
    assert core.model == "", "the previous endpoint's model is still loaded"

    # The same host with a different path keeps it — still the same service.
    core.use_remote("https://api.anthropic.com/v1", model="claude-sonnet-4-5")
    core.use_remote("https://api.anthropic.com")
    assert core.config["remote_model"] == "claude-sonnet-4-5"


def test_a_measured_context_window_survives_the_model_being_evicted(tmp_path, monkeypatch):
    """Ollama evicts after five idle minutes, so "not resident" is the normal
    state. Re-measuring is impossible then, but the last real measurement is
    still an observation and keeps the meter and compaction working."""
    from ollama_code import config as config_mod
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")
    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.model = "qwen3:8b"

    class Resident:
        def loaded_context_length(self, _model): return 8192
        def context_length(self, _model): return 32768

    class Evicted:
        def loaded_context_length(self, _model): return 0
        def context_length(self, _model): return 32768

    core.client = Resident()
    core.refresh_context_limit()
    assert core.context_limit == 8192
    # Through the accessor rather than the raw key: how the mapping is keyed
    # is an implementation detail (it is scoped by host too).
    assert core.remembered_model_window("qwen3:8b") == 8192

    # A fresh process, same config: the model is not loaded and cannot be
    # measured, but it was measured before.
    revived = AgentCore(cwd=str(tmp_path), config=dict(core.config))
    revived.model = "qwen3:8b"
    revived.client = Evicted()
    revived.refresh_context_limit()
    assert revived.context_limit == 8192, "a remembered window must survive a restart"


def test_a_window_is_only_remembered_when_it_was_measured(tmp_path, monkeypatch):
    """The trained window is not the running window — remembering it would
    reinstate exactly the over-reporting effective_context_length prevents."""
    from ollama_code import config as config_mod
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")
    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.model = "qwen3:8b"

    class NeverLoaded:
        def loaded_context_length(self, _model): return 0
        def context_length(self, _model): return 262144

    core.client = NeverLoaded()
    core.refresh_context_limit()
    assert core.config["model_windows"] == {}, "nothing was measured"
    assert core.context_limit == 0, "unknown stays unknown"


def test_corrupt_remembered_windows_are_dropped_not_trusted(tmp_path, monkeypatch):
    from ollama_code import config as config_mod

    path = tmp_path / "config.json"
    path.write_text(json.dumps({
        "model_windows": {"good": 8192, "negative": -1, "text": "lots", "zero": 0}
    }))
    monkeypatch.setattr(config_mod, "CONFIG_PATH", path)
    assert config_mod.load_config()["model_windows"] == {"good": 8192}

    path.write_text(json.dumps({"model_windows": "not a mapping"}))
    assert config_mod.load_config()["model_windows"] == {}


def test_one_agent_does_not_leak_its_windows_into_another(tmp_path, monkeypatch):
    """DEFAULTS holds a real dict and configs are built by shallow-copying it,
    so mutating that mapping in place would share one session's measurements
    with every other core in the process."""
    from ollama_code import config as config_mod
    from ollama_code.config import DEFAULTS
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")

    class Resident:
        def loaded_context_length(self, _model): return 4096
        def context_length(self, _model): return 32768

    first = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    first.model = "a-model"
    first.client = Resident()
    first.refresh_context_limit()

    second = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    assert second.config["model_windows"] == {}, "windows leaked between cores"
    assert DEFAULTS["model_windows"] == {}, "the defaults themselves were mutated"


def test_a_provider_without_a_model_listing_is_not_reported_offline(monkeypatch):
    """Kimi Code documents chat completions and no listing. Probing /models
    there answers with an auth error whatever the key is, and reporting that
    as offline condemns a working subscription on every health poll."""
    from ollama_code import remote as remote_mod

    def explode(*a, **k):  # the probe must not even be attempted
        raise AssertionError("checked /models on a provider that serves none")

    monkeypatch.setattr(remote_mod.requests, "get", explode)
    client = remote_mod.RemoteClient(
        "https://api.kimi.com/coding/v1", api_key="k", lists_models=False
    )
    client.check()  # must not raise

    # The default is unchanged for everyone else.
    assert remote_mod.RemoteClient("https://api.openai.com/v1").lists_models is True


def test_the_listing_capability_reaches_the_client_from_the_provider_call(tmp_path, monkeypatch):
    from ollama_code import config as config_mod
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")
    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.use_remote("https://api.kimi.com/coding/v1", api_key="k", lists_models=False)
    assert core.client.lists_models is False
    assert core.config["remote_lists_models"] is False

    # Missing means keep, like the key and the label.
    core.use_remote("https://api.kimi.com/coding/v1", model="kimi-for-coding")
    assert core.client.lists_models is False


def test_a_remembered_window_does_not_follow_a_model_to_another_host(tmp_path, monkeypatch):
    """The same model runs in different windows on different Ollama hosts.

    A GPU box on the LAN may serve qwen3:8b at 32768 while this laptop serves
    it at 4096. Carrying the big number to the small host would budget
    compaction against a window that does not exist — the exact failure
    effective_context_length prevents everywhere else.
    """
    from ollama_code import config as config_mod
    from ollama_code.core import AgentCore

    monkeypatch.setattr(config_mod, "CONFIG_PATH", tmp_path / "config.json")

    class Serving:
        def __init__(self, window): self.window = window
        def loaded_context_length(self, _m): return self.window
        def context_length(self, _m): return 262144

    class Evicted:
        def loaded_context_length(self, _m): return 0
        def context_length(self, _m): return 262144

    # Measured on the LAN box.
    remote = AgentCore(cwd=str(tmp_path), config={"provider": "ollama", "host": "http://192.168.50.99:11434"})
    remote.model = "qwen3:8b"
    remote.client = Serving(32768)
    remote.refresh_context_limit()
    assert remote.context_limit == 32768

    # Same model, same config, different host, nothing resident to measure.
    local = AgentCore(
        cwd=str(tmp_path),
        config={**remote.config, "host": "http://localhost:11434"},
    )
    local.model = "qwen3:8b"
    local.client = Evicted()
    local.refresh_context_limit()
    assert local.context_limit == 0, "the LAN box's window followed the model home"

    # And the LAN box still remembers its own.
    again = AgentCore(cwd=str(tmp_path), config=dict(remote.config))
    again.model = "qwen3:8b"
    again.client = Evicted()
    again.refresh_context_limit()
    assert again.context_limit == 32768
