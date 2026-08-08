"""Tests for the agent core, tools, sessions and the HTTP/WebSocket contract.

Every agent data path is redirected into a per-test temp directory by
``conftest.py``, which also fails the suite if anything writes to a developer's
real ~/.ollama-code. Nothing here needs to arrange that.
"""
from __future__ import annotations

import asyncio
import json
import os
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import Future
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from ollama_code import config as config_mod
from ollama_code import core as core_module
from ollama_code import server as server_mod
from ollama_code import sessions as sessions_mod
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse, OllamaError, process_chunk
from ollama_code.orchestration import AgentResult
from ollama_code.permissions import PermissionManager, build_preview
from ollama_code.render import ThinkFilter, strip_think
from ollama_code.sessions import SessionMeta, SessionStore, strip_prompt_decoration
from ollama_code.tools import ToolContext, execute_tool


def test_provider_keys_are_consumed_from_the_environment(monkeypatch):
    monkeypatch.setenv("LOCUS_REMOTE_API_KEY", "secret-from-env")
    monkeypatch.setenv("OPENAI_API_KEY", "unused-copy")

    config = config_mod.load_config()

    assert config["remote_api_key"] == "secret-from-env"
    assert "LOCUS_REMOTE_API_KEY" not in os.environ
    assert "OPENAI_API_KEY" not in os.environ


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


def test_atomic_edit_failure_preserves_original_and_removes_temp(
    ctx,
    tmp_path,
    monkeypatch,
):
    from ollama_code import tools as tools_mod

    path = tmp_path / "stable.txt"
    path.write_text("original")

    def fail_replace(source, destination):
        raise OSError("simulated disk failure")

    monkeypatch.setattr(tools_mod.os, "replace", fail_replace)
    result = execute_tool(
        "edit_file",
        {"path": "stable.txt", "old_string": "original", "new_string": "changed"},
        ctx,
    )

    assert result.startswith("Error")
    assert path.read_text() == "original"
    assert list(tmp_path.glob(".stable.txt.*.tmp")) == []


def test_read_file_rejects_binary(ctx, tmp_path):
    (tmp_path / "bin.dat").write_bytes(b"\x00\x01\x02binary")
    assert "binary" in execute_tool("read_file", {"path": "bin.dat"}, ctx)


def test_text_tools_bound_individual_file_reads(ctx, tmp_path):
    from ollama_code import tools as tools_mod

    large = tmp_path / "large.txt"
    with large.open("wb") as handle:
        handle.seek(tools_mod.MAX_TEXT_FILE_BYTES)
        handle.write(b"x")

    read = execute_tool("read_file", {"path": "large.txt"}, ctx)
    grep = execute_tool("grep", {"path": ".", "pattern": "x"}, ctx)

    assert "text-read limit" in read
    assert "large.txt" not in grep


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


def test_all_edit_tools_refuse_a_symlinked_workspace_parent(ctx, tmp_path):
    target = tmp_path / "real"
    target.mkdir()
    original = target / "a.txt"
    original.write_text("one")
    link = tmp_path / "linked"
    link.symlink_to(target, target_is_directory=True)

    edit = execute_tool(
        "edit_file",
        {"path": "linked/a.txt", "old_string": "one", "new_string": "two"},
        ctx,
    )
    multi = execute_tool(
        "multi_edit",
        {
            "path": "linked/a.txt",
            "edits": [{"old_string": "one", "new_string": "three"}],
        },
        ctx,
    )
    write = execute_tool(
        "write_file",
        {"path": "linked/new.txt", "content": "hidden target"},
        ctx,
    )

    assert all(result.startswith("Error") for result in (edit, multi, write))
    assert original.read_text() == "one"
    assert not (target / "new.txt").exists()
    _, detail = build_preview("read_file", {"path": "linked/a.txt"}, ctx)
    assert "resolves to:" in detail


def test_recursive_read_tools_do_not_follow_workspace_symlinks(ctx, tmp_path):
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("do not expose")
    link = tmp_path / "linked"
    link.symlink_to(outside, target_is_directory=True)

    globbed = execute_tool(
        "glob",
        {"pattern": "linked/**/*"},
        ctx,
    )
    grepped = execute_tool(
        "grep",
        {"pattern": "do not expose", "path": "."},
        ctx,
    )
    listed = execute_tool(
        "list_dir",
        {"path": ".", "depth": 3},
        ctx,
    )

    assert "secret.txt" not in globbed
    assert "do not expose" not in grepped
    assert "secret.txt" not in listed


def test_bash_timeout_kills_the_whole_process_group(ctx, tmp_path):
    marker = tmp_path / "still-running.txt"
    # The shell exits at once; without a process-group kill the background
    # child survives the timeout and writes the marker.
    command = f"(sleep 3; echo alive > {marker}) & sleep 30"
    result = execute_tool("bash", {"command": command, "timeout": 1}, ctx)
    assert "timed out" in result
    time.sleep(4)
    assert not marker.exists(), "a child process outlived the timeout"


def test_bash_stop_terminates_the_process_group_promptly(tmp_path):
    stop = threading.Event()
    ctx = ToolContext(cwd=str(tmp_path), should_stop=stop.is_set)
    result = {}
    worker = threading.Thread(
        target=lambda: result.setdefault(
            "text",
            execute_tool("bash", {"command": "sleep 30"}, ctx),
        )
    )
    worker.start()
    time.sleep(0.2)
    stop.set()
    worker.join(2)

    assert not worker.is_alive()
    assert "interrupted" in result["text"]


def test_web_fetch_identifies_itself_by_its_real_name(monkeypatch, tmp_path):
    """The model's browsing must say what it actually is.

    This header used to be the literal "ollama-code/0.2" — a product name we
    no longer ship under and a version that never moved. Deriving it from
    ``__version__`` is what stops it drifting again.
    """
    import requests

    import ollama_code

    seen = {}

    def fake_get(
        url,
        timeout=None,
        headers=None,
        stream=None,
        allow_redirects=None,
    ):
        seen["headers"] = headers or {}
        seen["allow_redirects"] = allow_redirects
        return FakeResponse(text="<html><body>hello</body></html>")

    monkeypatch.setattr(requests, "get", fake_get)
    execute_tool("web_fetch", {"url": "example.com"}, ToolContext(cwd=str(tmp_path)))

    agent = seen["headers"]["User-Agent"]
    assert agent == ollama_code.USER_AGENT
    assert seen["allow_redirects"] is False
    assert ollama_code.__version__ in agent
    assert agent.startswith("Locus-Agent/")
    # The old literal, and anything claiming to be a client we are not.
    assert "ollama-code" not in agent.lower()
    assert "0.2" not in agent
    for impostor in ("claude", "codex", "kimi", "cursor", "curl", "mozilla"):
        assert impostor not in agent.lower()


def test_web_fetch_refuses_redirects_and_oversized_responses(monkeypatch, tmp_path):
    import requests

    from ollama_code import tools as tools_mod

    ctx = ToolContext(cwd=str(tmp_path))
    monkeypatch.setattr(
        requests,
        "get",
        lambda *args, **kwargs: FakeResponse(status_code=302),
    )
    assert "redirects" in execute_tool(
        "web_fetch",
        {"url": "https://approved.example"},
        ctx,
    )

    monkeypatch.setattr(
        requests,
        "get",
        lambda *args, **kwargs: FakeResponse(
            text="x" * (tools_mod.MAX_WEB_FETCH_BYTES + 1)
        ),
    )
    assert "safety limit" in execute_tool(
        "web_fetch",
        {"url": "https://large.example"},
        ctx,
    )


def test_web_fetch_stop_closes_a_stalled_response(monkeypatch, tmp_path):
    import requests

    class StalledResponse(FakeResponse):
        def __init__(self):
            super().__init__()
            self.closed = threading.Event()

        def iter_content(self, chunk_size=64 * 1024):
            self.closed.wait(2)
            return iter(())

        def close(self):
            self.closed.set()

    response = StalledResponse()
    monkeypatch.setattr(requests, "get", lambda *args, **kwargs: response)
    stop = threading.Event()
    ctx = ToolContext(cwd=str(tmp_path), should_stop=stop.is_set)
    result = {}
    worker = threading.Thread(
        target=lambda: result.setdefault(
            "text",
            execute_tool(
                "web_fetch",
                {"url": "https://stalled.example"},
                ctx,
            ),
        )
    )
    worker.start()
    time.sleep(0.1)
    stop.set()
    worker.join(1)

    assert not worker.is_alive()
    assert response.closed.is_set()
    assert "interrupted" in result["text"]


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


def test_computer_guardrails_remain_above_bypass():
    perms = PermissionManager(mode="bypass")
    assert perms.blocked_reason(
        "computer_type_text", {"app": "Safari", "text": "enter password"}
    ) is not None
    assert perms.requires_confirmation(
        "computer_click", {"app": "Finder", "element": "upload-file"}
    )
    assert not perms.requires_confirmation(
        "computer_click", {"app": "Notes", "element": "snapshot-3"}
    )


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


def test_default_deny_list_resists_option_reordering_and_nested_shells():
    perms = PermissionManager(
        deny_commands=["rm -rf /", "mkfs", "dd if=", ":(){"]
    )
    blocked = [
        "rm -fr /",
        "rm --recursive --force -- /",
        "bash -c 'rm -rf /'",
        "eval 'rm -rf /'",
        "sudo -u root rm -rf /",
        "sudo --user=root env -i rm --recursive --force /",
        "env -u PATH /bin/rm -fr /",
        "nohup command -- rm -rf /",
        "xargs -0 rm -rf /",
        "`printf rm` -rf /",
        "sudo /sbin/mkfs.ext4 /dev/disk9",
        "env dd bs=1m if=/dev/zero of=/dev/disk9",
    ]
    for command in blocked:
        assert perms.blocked_reason("bash", {"command": command}) is not None, command
    for command in ["echo 'rm -rf /'", "printf '%s' mkfs", "rm -rf ./build"]:
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
    assert f.take_thinking() == "secret"


def test_thinking_alias_is_streamed_as_reasoning_not_answer_text():
    f = ThinkFilter()
    visible = "".join(f.feed(part) for part in ["<think", "ing>careful", " work</thinking>", "Answer"])
    visible += f.flush()
    assert visible == "Answer"
    assert f.take_thinking() == "careful work"


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

    lines = [
        line
        for line in store.path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
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
        {"role": "user", "content": "[Locus mode: Ask]\nx\n\nUser request:\nhi",
         "team_run_id": "run-42"},
        {"role": "tool", "name": "bash", "content": "output"},
    ])
    assert [m["role"] for m in out] == ["user", "tool"]
    assert out[0]["content"] == "hi"
    assert out[0]["team_run_id"] == "run-42"
    assert out[1]["name"] == "bash"


# ------------------------------------------------------------ remote provider


class FakeResponse:
    """Minimal stand-in for a requests.Response."""

    def __init__(self, status_code=200, payload=None, lines=None, text=""):
        self.status_code = status_code
        self._payload = payload
        self._lines = lines or []
        self.text = text
        self.encoding = "utf-8"

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload

    def iter_lines(self, decode_unicode=False):
        return iter(self._lines)

    def iter_content(self, chunk_size=64 * 1024):
        raw = self.text.encode(self.encoding)
        return (
            raw[index : index + chunk_size]
            for index in range(0, len(raw), chunk_size)
        )

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

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
    assert (
        normalize_base_url("https://api.anthropic.com/v1/messages")
        == "https://api.anthropic.com/v1"
    )
    assert normalize_base_url("") == ""


def test_remote_client_sends_bearer_token(monkeypatch):
    from ollama_code import remote as remote_mod

    seen = {}

    def fake_get(url, headers=None, timeout=None, allow_redirects=None):
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

    def fake_get(url, headers=None, timeout=None, allow_redirects=None):
        seen["headers"] = headers or {}
        return FakeResponse(payload={"data": [{"id": "claude-sonnet-4-5"}]})

    monkeypatch.setattr(remote_mod.requests, "get", fake_get)
    client = remote_mod.RemoteClient(
        "https://api.anthropic.com/v1", api_key="sk-ant-secret"
    )
    client.list_models()

    assert "Authorization" not in seen["headers"]
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


def test_remote_credentials_require_https_except_on_loopback():
    from ollama_code import remote as remote_mod

    with pytest.raises(ValueError, match="HTTPS"):
        remote_mod.RemoteClient("http://provider.example/v1", api_key="secret")
    assert remote_mod.RemoteClient("http://provider.example/v1").base_url
    assert remote_mod.RemoteClient(
        "http://127.0.0.1:8000/v1",
        api_key="secret",
    ).base_url
    with pytest.raises(ValueError, match="API key field"):
        remote_mod.RemoteClient("https://name:secret@provider.example/v1")


def test_rejected_remote_transport_leaves_the_current_provider_intact(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "test-model"})
    before = (core.provider, core.host, core.model)

    with pytest.raises(ValueError, match="HTTPS"):
        core.use_remote(
            "http://provider.example/v1",
            api_key="secret",
            model="remote-model",
        )

    assert (core.provider, core.host, core.model) == before
    with pytest.raises(ValueError, match="context_window"):
        core.use_remote(
            "https://provider.example/v1",
            api_key="secret",
            model="remote-model",
            context_window_tokens=32,
        )
    assert (core.provider, core.host, core.model) == before


def test_remote_chat_sends_the_user_agent(monkeypatch):
    """The streaming POST is the request that spends the subscription."""
    from ollama_code import USER_AGENT
    from ollama_code import remote as remote_mod

    seen = {}

    def fake_post(
        url,
        headers=None,
        json=None,
        stream=None,
        timeout=None,
        allow_redirects=None,
    ):
        seen["headers"] = headers or {}
        return FakeResponse(lines=_sse([{"choices": [{"delta": {"content": "hi"}}]}]))

    monkeypatch.setattr(remote_mod.requests, "post", fake_post)
    client = remote_mod.RemoteClient(
        "https://api.kimi.com/coding/v1", api_key="secret", model="kimi-for-coding"
    )
    client.chat_stream(model="kimi-for-coding", messages=[{"role": "user", "content": "hi"}])

    assert seen["headers"]["User-Agent"] == USER_AGENT


def test_anthropic_uses_native_messages_stream_and_tool_schema(monkeypatch):
    from ollama_code import remote as remote_mod

    seen = {}
    events = [
        {
            "type": "message_start",
            "message": {"usage": {"input_tokens": 11}},
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "native reply"},
        },
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "thinking", "thinking": ""},
        },
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "thinking_delta", "thinking": "private reasoning"},
        },
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "signature_delta", "signature": "signed-state"},
        },
        {
            "type": "content_block_start",
            "index": 2,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_native_1",
                "name": "read_file",
                "input": {},
            },
        },
        {
            "type": "content_block_delta",
            "index": 2,
            "delta": {"type": "input_json_delta", "partial_json": '{"path":"a.txt"}'},
        },
        {
            "type": "message_delta",
            "delta": {"stop_reason": "tool_use"},
            "usage": {"output_tokens": 7},
        },
        {"type": "message_stop"},
    ]

    def fake_post(url, **kwargs):
        seen.update(url=url, **kwargs)
        return FakeResponse(lines=_sse(events))

    monkeypatch.setattr(remote_mod.requests, "post", fake_post)
    client = remote_mod.RemoteClient(
        "https://api.anthropic.com/v1",
        api_key="sk-ant-secret",
        model="claude-sonnet-5",
    )
    response = client.chat_stream(
        "claude-sonnet-5",
        [
            {"role": "system", "content": "system instructions"},
            {"role": "user", "content": "read it"},
        ],
        tools=[{
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file",
                "parameters": {"type": "object", "properties": {}},
            },
        }],
    )

    assert seen["url"] == "https://api.anthropic.com/v1/messages"
    assert seen["allow_redirects"] is False
    assert seen["headers"]["x-api-key"] == "sk-ant-secret"
    assert "Authorization" not in seen["headers"]
    assert seen["json"]["system"] == "system instructions"
    assert seen["json"]["tools"][0]["input_schema"]["type"] == "object"
    assert response.content == "native reply"
    assert response.thinking == "private reasoning"
    assert response.prompt_eval_count == 11
    assert response.eval_count == 7
    assert response.tool_calls[0].name == "read_file"
    assert response.tool_calls[0].arguments == {"path": "a.txt"}
    assert response.tool_calls[0].call_id == "toolu_native_1"
    preserved = response.provider_fields["anthropic_content"]
    assert preserved[1] == {
        "type": "thinking",
        "thinking": "private reasoning",
        "signature": "signed-state",
    }
    assert preserved[2]["input"] == {"path": "a.txt"}


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
    assert (
        remote_mod.RemoteClient(
            "https://api.anthropic.com.attacker.example/v1"
        ).auth_style
        == "bearer"
    )
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
            {
                "index": 0,
                "id": "call_openai_1",
                "function": {"name": "write_file", "arguments": '{"path"'},
            }
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
    assert call.call_id == "call_openai_1"


def test_remote_retries_without_tools_when_unsupported(monkeypatch):
    from ollama_code import remote as remote_mod

    attempts = []

    def fake_post(
        url,
        json=None,
        headers=None,
        stream=None,
        timeout=None,
        allow_redirects=None,
    ):
        attempts.append(dict(json or {}))
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
        "m",
        [{"role": "user", "content": "hi"}],
        tools=[{"type": "function"}],
        options={
            "tool_choice": {"type": "function", "function": {"name": "submit"}},
            "parallel_tool_calls": False,
        },
    )

    assert len(attempts) == 2, "it must retry exactly once"
    assert {"tools", "tool_choice", "parallel_tool_calls"} <= attempts[0].keys()
    assert {"tools", "tool_choice", "parallel_tool_calls"}.isdisjoint(attempts[1])
    assert "plain answer" in resp.content
    assert "rejected tool calling" in resp.content
    assert resp.provider_fields["tools_rejected"] is True


def test_remote_stream_interrupt_closes_a_stalled_response(monkeypatch):
    from ollama_code import remote as remote_mod

    class StalledResponse(FakeResponse):
        def __init__(self):
            super().__init__()
            self.closed = threading.Event()

        def iter_lines(self, decode_unicode=True):
            self.closed.wait(2)
            # urllib3 may dereference its cleared file handle after another
            # thread closes the response. Cancellation still has to be
            # reported as interrupted rather than entering provider fallback.
            raise AttributeError("'NoneType' object has no attribute 'read'")

        def close(self):
            self.closed.set()

    response = StalledResponse()
    monkeypatch.setattr(remote_mod.requests, "post", lambda *a, **k: response)
    stop = threading.Event()
    result = {}
    worker = threading.Thread(
        target=lambda: result.setdefault(
            "response",
            remote_mod.RemoteClient(
                "https://endpoint.example",
                model="m",
            ).chat_stream(
                "m",
                [{"role": "user", "content": "hi"}],
                should_stop=stop.is_set,
            ),
        )
    )
    worker.start()
    time.sleep(0.1)
    stop.set()
    worker.join(1)

    assert not worker.is_alive()
    assert response.closed.is_set()
    assert result["response"].done_reason == "interrupted"


def test_remote_message_conversion_includes_tool_calls():
    from ollama_code.remote import _to_anthropic_messages, _to_openai_message

    converted = _to_openai_message({
        "role": "assistant",
        "content": "",
        "reasoning_content": "provider-required state",
        "tool_calls": [{
            "id": "call_123",
            "function": {"name": "bash", "arguments": {"command": "ls"}},
        }],
    })
    assert converted["tool_calls"][0]["function"]["name"] == "bash"
    assert converted["tool_calls"][0]["id"] == "call_123"
    assert converted["reasoning_content"] == "provider-required state"
    assert json.loads(converted["tool_calls"][0]["function"]["arguments"]) == {"command": "ls"}

    tool_result = _to_openai_message({
        "role": "tool",
        "name": "bash",
        "tool_call_id": "call_123",
        "content": "out",
    })
    assert tool_result["role"] == "tool"
    assert tool_result["tool_call_id"] == "call_123"

    _, anthropic = _to_anthropic_messages([{
        "role": "assistant",
        "content": "",
        "tool_calls": [{
            "id": "call_123",
            "function": {"name": "bash", "arguments": {"command": "ls"}},
        }],
    }, {
        "role": "tool",
        "name": "bash",
        "tool_call_id": "call_123",
        "content": "out",
    }])
    assert anthropic[0]["content"][0]["id"] == "call_123"
    assert anthropic[1]["content"][0]["tool_use_id"] == "call_123"

    preserved = [{
        "type": "thinking",
        "thinking": "required state",
        "signature": "signed-state",
    }, {
        "type": "tool_use",
        "id": "call_123",
        "name": "bash",
        "input": {"command": "ls"},
    }]
    _, anthropic = _to_anthropic_messages([{
        "role": "assistant",
        "content": "",
        "anthropic_content": preserved,
        "tool_calls": [{
            "id": "call_123",
            "function": {"name": "bash", "arguments": {"command": "ls"}},
        }],
    }])
    assert anthropic[0]["content"] == preserved


def test_remote_message_conversion_includes_explicit_chat_images():
    from ollama_code.remote import _to_anthropic_messages, _to_openai_message

    image = {
        "name": "diagram.png",
        "mime_type": "image/png",
        "data": "cG5n",
    }
    converted = _to_openai_message({
        "role": "user",
        "content": "Explain this image.",
        "attachments": [image],
    })
    assert converted["content"][0] == {"type": "text", "text": "Explain this image."}
    assert converted["content"][1]["image_url"]["url"] == "data:image/png;base64,cG5n"

    _, anthropic = _to_anthropic_messages([{
        "role": "user",
        "content": "Explain this image.",
        "attachments": [image],
    }])
    assert anthropic[0]["content"][1] == {
        "type": "image",
        "source": {"type": "base64", "media_type": "image/png", "data": "cG5n"},
    }


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


def test_terminal_record_stays_with_the_session_where_it_started(client):
    svc = client.app.state.service
    original = svc.core.session
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()
        ws.receive_json()
        ws.send_json({
            "type": "terminal_run",
            "run_id": "session-bound",
            "command": "sleep 0.2; echo finished",
        })
        while ws.receive_json().get("type") != "terminal_started":
            pass

        ws.send_json({"type": "new_session", "reason": "new_session"})
        assert any(event["type"] == "session_started" for event in drain(ws))
        replacement = svc.core.session
        assert replacement.session_id != original.session_id

        time.sleep(0.4)
        drain(ws)

    assert '"run_id": "session-bound"' in original.path.read_text()
    assert '"run_id": "session-bound"' not in replacement.path.read_text()


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


def test_local_service_capability_guards_http_and_websocket(client):
    app = client.app
    app.state.auth_token = "test-capability"
    try:
        assert client.get("/api/health").status_code == 401
        assert client.get(
            "/api/health",
            headers={"X-Locus-Token": "test-capability"},
        ).status_code == 200
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("/ws/chat"):
                pass
        with client.websocket_connect(
            "/ws/chat",
            headers={"X-Locus-Token": "test-capability"},
        ) as ws:
            assert ws.receive_json()["type"] == "session_info"
    finally:
        app.state.auth_token = ""


def test_parent_pid_configuration_is_tolerant_and_rejects_self(monkeypatch):
    from ollama_code import server

    monkeypatch.setenv("LOCUS_PARENT_PID", "not-a-pid")
    assert server._configured_parent_pid() == 0
    monkeypatch.setenv("LOCUS_PARENT_PID", str(os.getpid()))
    assert server._configured_parent_pid() == 0
    monkeypatch.setenv("LOCUS_PARENT_PID", str(os.getppid()))
    assert server._configured_parent_pid() == os.getppid()


def test_parent_watchdog_terminates_after_reparenting(monkeypatch):
    import asyncio
    import signal

    from ollama_code import server

    killed: list[tuple[int, int]] = []

    async def immediate_sleep(_seconds):
        return None

    monkeypatch.setattr(server.asyncio, "sleep", immediate_sleep)
    monkeypatch.setattr(server.os, "getppid", lambda: 1)
    monkeypatch.setattr(server.os, "kill", lambda pid, sig: killed.append((pid, sig)))

    asyncio.run(server._watch_parent(12345))

    assert killed == [(os.getpid(), signal.SIGTERM)]


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


def test_cancel_rejects_a_run_owned_by_another_worker(client, tmp_path):
    svc = client.app.state.service
    svc.run_store.start_run(
        "foreign-run",
        session_id=svc.core.session.session_id,
        team_id="team-1",
        team_name="Team",
        worker_id="worker-in-another-process",
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        task_id="",
        request="Build something",
        manifest={},
        state="dispatching",
    )

    response = client.post("/api/orchestrations/foreign-run/cancel")

    assert response.status_code == 409
    assert "another worker" in response.json()["detail"]
    assert svc.run_store.run("foreign-run")["state"] == "dispatching"


def test_cancel_interrupts_the_worker_that_owns_the_run(client, tmp_path):
    svc = client.app.state.service
    run_id = "local-run"
    svc.run_store.start_run(
        run_id,
        session_id=svc.core.session.session_id,
        team_id="team-1",
        team_name="Team",
        worker_id=svc.worker_id,
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        task_id="",
        request="Build something",
        manifest={},
        state="waiting_dispatch_approval",
    )
    turn: Future[None] = Future()
    svc.turn_future = turn
    svc.active_run_id = run_id
    try:
        response = client.post(f"/api/orchestrations/{run_id}/cancel")

        assert response.status_code == 200
        assert response.json()["state"] == "cancelled"
        assert svc.core._interrupt.is_set()
        assert run_id in svc.cancel_requested_runs
        record = svc.run_store.run(run_id)
        assert record["state"] == "cancelled"
        assert record["recoverable"] is False
    finally:
        turn.set_result(None)
        svc.turn_future = None
        svc.active_run_id = None
        svc.cancel_requested_runs.discard(run_id)
        svc.core._interrupt.clear()


def test_running_run_cannot_be_assessed_or_resumed_from_stale_recovery_flag(
    client, tmp_path,
):
    svc = client.app.state.service
    run_id = "stale-running-recovery"
    svc.run_store.start_run(
        run_id,
        session_id=svc.core.session.session_id,
        team_id="team-1",
        team_name="Team",
        worker_id=svc.worker_id,
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        request="Build something",
        manifest={},
        state="running",
    )
    # Reproduce the pre-fix database combination loaded by Team Runs.
    with sqlite3.connect(svc.run_store.path) as connection:
        connection.execute(
            "UPDATE runs SET recoverable=1, recovery_reason=? WHERE id=?",
            ("Stale approval checkpoint.", run_id),
        )

    assessment = client.post(
        f"/api/orchestrations/{run_id}/recovery-assessment",
        json={"manifest": {}},
    )
    resume = client.post(
        f"/api/orchestrations/{run_id}/resume",
        json={"manifest": {}},
    )
    retry = client.post(
        f"/api/orchestrations/{run_id}/jobs/job-1/retry",
        json={"manifest": {}},
    )
    reassign = client.post(
        f"/api/orchestrations/{run_id}/jobs/job-1/reassign",
        json={"manifest": {}, "agent_id": "agent-2"},
    )

    assert assessment.status_code == 200
    assert assessment.json()["can_resume"] is False
    assert any(
        "not paused or interrupted" in item
        for item in assessment.json()["repair_checklist"]
    )
    assert resume.status_code == 409
    assert retry.status_code == 409
    assert reassign.status_code == 409
    assert "not in a recoverable state" in resume.json()["detail"]
    assert svc.run_store.run(run_id)["state"] == "running"


def test_confirmed_worker_exit_makes_active_run_recoverable(client, tmp_path):
    svc = client.app.state.service
    run_id = "exited-worker-run"
    svc.run_store.start_run(
        run_id,
        session_id=svc.core.session.session_id,
        team_id="team-1",
        team_name="Team",
        worker_id="exited-worker",
        workspace_root=str(tmp_path),
        execution_path=str(tmp_path),
        request="Build something",
        manifest={},
        state="running",
    )
    with sqlite3.connect(svc.run_store.path) as connection:
        connection.execute(
            "UPDATE runs SET owner_pid=? WHERE id=?", (999_999_999, run_id),
        )

    response = client.post(
        f"/api/orchestrations/{run_id}/reconcile-worker-exit",
        json={"worker_id": "exited-worker"},
    )

    assert response.status_code == 200
    assert response.json()["state"] == "interrupted"
    assert response.json()["recoverable"] is True


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

    # A number read off the local machine would be worse than saying nothing:
    # this listing comes from the endpoint, and the local /api/show has no
    # bearing on what a hosted deployment serves.
    assert entry["context_length"] == 0


def test_models_report_a_window_the_endpoint_stated(client, monkeypatch):
    """The listing is already being fetched, and vLLM-style deployments state
    their window in it. Forcing this to zero for every remote provider is why a
    hosted account's model list could never fill the meter."""
    core = client.app.state.service.core
    core.provider = "remote"
    asked: list[str] = []

    def listing():
        asked.append("models")
        return [{
            "name": "hosted-model",
            "size": 0,
            "details": {},
            "context_length": 32_768,
            "trained_context_length": 262_144,
        }]

    monkeypatch.setattr(core.client, "list_models", listing)
    # A remote client cannot answer /api/show, and asking would be a bug.
    monkeypatch.setattr(
        core.client, "context_length", lambda name: pytest.fail("asked /api/show")
    )

    entry = client.get("/api/models").json()["models"][0]

    assert entry["context_length"] == 32_768
    assert entry["trained_context_length"] == 262_144
    assert asked == ["models"], "one request, no per-model fan-out"


def test_model_details_are_asked_for_once_per_model(monkeypatch):
    """/api/models used to POST /api/show once per installed model, and the app
    polls that route every 15 seconds — so six installed models meant 24 of those
    POSTs a minute, each describing a file that had not changed."""
    from ollama_code.ollama import OllamaClient

    calls: list[str] = []

    class Response:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return {"model_info": {"general.architecture": "qwen", "qwen.context_length": 32_768}}

    def fake_post(url, **kwargs):
        calls.append(str(kwargs.get("json", {}).get("name")))
        return Response()

    monkeypatch.setattr("ollama_code.ollama.requests.post", fake_post)
    ollama = OllamaClient("http://localhost:11434")

    for _ in range(5):
        assert ollama.context_length("qwen3:8b") == 32_768
    assert ollama.supports_tools("qwen3:8b") in (True, False)

    assert calls == ["qwen3:8b"], "memoised across every reader"

    # A pull replaces the file on disk, so the trained window may really differ.
    ollama.forget_model_details("qwen3:8b")
    ollama.context_length("qwen3:8b")
    assert len(calls) == 2


def test_setting_the_context_window_takes_effect_without_a_restart(client):
    body = client.post("/api/config", json={"context_window": 16_384}).json()

    assert body["context_window"] == 16_384
    # The same number has to reach the compaction budget, not just the config.
    assert body["session_info"]["context_limit"] == 16_384
    assert client.app.state.service.core.chat_options() == {"num_ctx": 16_384}
    assert client.get("/api/config").json()["context_window"] == 16_384


def test_project_context_can_be_reloaded_without_restarting(client, tmp_path):
    core = client.app.state.service.core
    assert core.project_context is None
    (tmp_path / "OLLAMA.md").write_text("legacy fallback")
    (tmp_path / "AGENTS.md").write_text("Run the focused verification suite.")

    body = client.post("/api/context/reload").json()

    assert body == {"ok": True, "file": "AGENTS.md"}
    assert core.project_context == ("AGENTS.md", "Run the focused verification suite.")
    assert "Run the focused verification suite." in core.messages[0]["content"]
    assert core.session_info()["has_project_context"] is True


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


def test_every_rest_state_mutation_is_rejected_while_busy(client):
    from concurrent.futures import Future

    svc = client.app.state.service
    svc.turn_future = Future()
    session_id = svc.core.session.session_id
    requests = [
        client.post("/api/config", json={"model": "other"}),
        client.post("/api/context/reload"),
        client.post("/api/provider", json={"provider": "ollama"}),
        client.post("/api/permissions", json={"mode": "bypass"}),
        client.post("/api/sessions/new", json={"reason": "test"}),
        client.delete("/api/sessions"),
        client.delete(f"/api/sessions/{session_id}"),
        client.post("/api/sessions/restore", json={}),
    ]

    assert all(response.status_code == 409 for response in requests)
    assert svc.core.session.session_id == session_id
    assert svc.core.perms.mode == "ask"


def test_new_session_returns_session_info(client):
    before = client.get("/api/sessions").json()["current"]
    body = client.post("/api/sessions/new", json={"reason": "clear_chat"}).json()
    assert body["ok"] is True and body["reason"] == "clear_chat"
    assert body["session_info"]["session_id"] != before


def test_new_session_can_target_a_workspace(client, tmp_path):
    workspace = tmp_path / "second-workspace"
    workspace.mkdir()

    body = client.post(
        "/api/sessions/new",
        json={"reason": "workspace_chat", "cwd": str(workspace)},
    ).json()

    assert body["ok"] is True
    assert body["session_info"]["cwd"] == str(workspace)
    assert client.app.state.service.core.cwd == str(workspace)


def test_session_summary_includes_workspace_from_header(client):
    _record_message(client, "workspace-aware summary")

    row = client.get("/api/sessions").json()["sessions"][0]

    assert row["cwd"] == client.app.state.service.core.cwd


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


def test_delete_one_inactive_chat_and_restore_it(client):
    old = client.get("/api/sessions").json()["current"]
    _record_message(client, "delete this one")
    client.post("/api/sessions/new", json={"reason": "next"})
    _record_message(client, "keep this one")

    deleted = client.delete(f"/api/sessions/{old}").json()

    assert deleted["ok"] is True
    assert deleted["id"] == old
    assert deleted["deleted_active"] is False
    assert deleted["replacement_session_info"] is None
    assert deleted["trash_batch"]
    assert old not in {row["id"] for row in client.get("/api/sessions").json()["sessions"]}

    restored = client.post(
        "/api/sessions/restore", json={"batch": deleted["trash_batch"]}
    ).json()
    assert restored["restored"] == 1
    assert restored["session_ids"] == [old]


def test_delete_active_chat_creates_same_workspace_replacement(client):
    active = client.get("/api/sessions").json()["current"]
    workspace = client.app.state.service.core.cwd
    _record_message(client, "active chat")

    deleted = client.delete(f"/api/sessions/{active}").json()

    replacement = deleted["replacement_session_info"]
    assert deleted["deleted_active"] is True
    assert replacement["session_id"] != active
    assert replacement["cwd"] == workspace
    assert client.get("/api/sessions").json()["current"] == replacement["session_id"]
    assert SessionStore.path_for(active) is None

    restored = client.post(
        "/api/sessions/restore", json={"batch": deleted["trash_batch"]}
    ).json()
    assert restored["session_ids"] == [active]


def test_individual_delete_batches_never_collide(client):
    first = client.get("/api/sessions").json()["current"]
    _record_message(client, "first")
    client.post("/api/sessions/new", json={"reason": "second"})
    second = client.get("/api/sessions").json()["current"]
    _record_message(client, "second")
    client.post("/api/sessions/new", json={"reason": "third"})

    first_delete = client.delete(f"/api/sessions/{first}").json()
    second_delete = client.delete(f"/api/sessions/{second}").json()

    assert first_delete["trash_batch"] != second_delete["trash_batch"]


def test_individual_delete_rejects_missing_or_unsafe_ids(client):
    assert client.delete("/api/sessions/missing").status_code == 404
    assert client.delete("/api/sessions/..").status_code in {404, 405}


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
        ChatResponse(
            tool_calls=[ToolCall("glob", {"pattern": str(secret.parent / "*")})],
            done=True,
        ),
        ChatResponse(content_parts=["done"], done=True),
    ])
    events = []
    core.on_event(events.append)
    asked = []

    core.run_turn("read things", decider=lambda *a: (asked.append(a[0]), "deny")[1])

    proposals = [e for e in events if e["type"] == "tool_call_proposed"]
    assert proposals[0]["auto"] is False, "a file outside the workspace must ask"
    assert proposals[1]["auto"] is True, "a file inside the workspace stays automatic"
    assert proposals[2]["auto"] is False, "an absolute glob outside the workspace must ask"
    assert asked == ["read_file", "glob"]


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
        assert [e["type"] for e in drain(ws)] == ["command_error"]


def test_replaced_websocket_does_not_interrupt_the_active_turn(client, monkeypatch):
    svc = client.app.state.service
    interrupts: list[bool] = []
    monkeypatch.setattr(svc.core, "interrupt", lambda: interrupts.append(True))

    with client.websocket_connect("/ws/chat") as first:
        first.receive_json()
        first.receive_json()
        with client.websocket_connect("/ws/chat") as second:
            second.receive_json()
            second.receive_json()
            time.sleep(0.05)
            assert interrupts == []


def test_reconnect_replays_events_queued_during_the_socket_gap(client):
    svc = client.app.state.service
    with client.websocket_connect("/ws/chat") as first:
        first.receive_json()
        first.receive_json()

    svc.queue_event({"type": "note", "text": "arrived during reconnect"})

    with client.websocket_connect("/ws/chat") as second:
        second.receive_json()
        second.receive_json()
        assert second.receive_json() == {
            "type": "note",
            "text": "arrived during reconnect",
        }


def test_nonloopback_server_bind_requires_a_capability():
    from ollama_code.server import _is_loopback_bind

    for host in ("127.0.0.1", "::1", "[::1]", "localhost"):
        assert _is_loopback_bind(host)
    for host in ("0.0.0.0", "::", "192.0.2.10", "agent.example"):
        assert not _is_loopback_bind(host)


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


def test_websocket_state_commands_are_nonterminal_rejections_while_busy(client, tmp_path):
    from concurrent.futures import Future

    svc = client.app.state.service
    original = (svc.core.cwd, svc.core.model, svc.core.session.session_id)
    target = tmp_path / "other"
    target.mkdir()
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()
        assert ws.receive_json()["type"] == "terminal_state"
        svc.turn_future = Future()
        for message in [
            {"type": "set_cwd", "path": str(target)},
            {"type": "set_model", "model": "test-model"},
            {"type": "set_permission_mode", "mode": "bypass"},
            {"type": "clear"},
            {"type": "new_session"},
        ]:
            ws.send_json(message)
            events = drain(ws)
            assert [event["type"] for event in events] == ["command_error"]
            assert events[0]["operation"] == message["type"]

    assert (svc.core.cwd, svc.core.model, svc.core.session.session_id) == original
    assert svc.core.perms.mode == "ask"


def test_websocket_rejects_malformed_and_oversized_messages(client, monkeypatch):
    from ollama_code import server as server_mod

    monkeypatch.setattr(server_mod, "MAX_USER_MESSAGE_CHARS", 5)
    with client.websocket_connect("/ws/chat") as ws:
        ws.receive_json()
        ws.receive_json()

        ws.send_json(["not", "an", "object"])
        assert drain(ws)[0]["operation"] == "invalid"

        ws.send_json({"type": "user_message", "text": "123456"})
        event = drain(ws)[0]
        assert event["type"] == "command_error"
        assert event["operation"] == "user_message"


def test_websocket_ask_mode_routes_through_the_tool_free_turn_boundary(client, monkeypatch):
    from ollama_code import server as server_mod

    service = client.app.state.service
    captured = []

    def capture_start(loop, call, *args):
        captured.append((call, args))
        return True

    monkeypatch.setattr(service, "start_turn", capture_start)
    asyncio.run(server_mod._handle_client_message(service, {
        "type": "user_message",
        "text": "/init",
        "mode": "ask",
    }))

    assert captured == [(server_mod._run_user_turn, (service, "/init", True, []))]


def test_websocket_ask_mode_validates_and_routes_image_attachments(client, monkeypatch):
    from ollama_code import server as server_mod

    service = client.app.state.service
    captured = []

    def capture_start(loop, call, *args):
        captured.append((call, args))
        return True

    monkeypatch.setattr(service, "start_turn", capture_start)
    asyncio.run(server_mod._handle_client_message(service, {
        "type": "user_message",
        "text": "What is in this image?",
        "mode": "ask",
        "attachments": [{
            "name": "photo.png",
            "mime_type": "image/png",
            "data": "cG5n",
        }],
    }))

    call, args = captured[0]
    assert call is server_mod._run_user_turn
    assert args[:3] == (service, "What is in this image?", True)
    assert args[3][0]["name"] == "photo.png"
    assert args[3][0]["data"] == "cG5n"

    with pytest.raises(ValueError, match="malformed"):
        server_mod._validated_chat_attachments([{
            "mime_type": "image/png",
            "data": "not base64!",
        }])


def test_http_request_body_limit_is_enforced(client, monkeypatch):
    from ollama_code import server as server_mod

    monkeypatch.setattr(server_mod, "MAX_HTTP_BODY_BYTES", 4)
    response = client.post("/api/config", json={"model": "test-model"})
    assert response.status_code == 413


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
        self.seen_messages: list[list[dict]] = []
        self.seen_tools: list[list[dict] | None] = []
        #: What Ollama would report for a resident model, as /api/ps does, and
        #: the window the model was trained for, as /api/show does.
        self.loaded_window = 0
        self.trained_window = 262_144
        #: Resident footprint, as /api/ps reports it. Defaults to fully on the
        #: GPU: a stub that looked like a spill would make every pinned window
        #: back off, in every test that never mentions memory.
        self.resident_size = 0
        self.resident_size_vram = 0

    def chat_stream(self, model, messages, tools=None, on_token=None, should_stop=None,
                    on_thinking=None, think=False, options=None):
        self.calls += 1
        self.seen_options.append(options)
        self.seen_messages.append(messages)
        self.seen_tools.append(tools)
        resp = self._responses.pop(0)
        for part in resp.content_parts:
            if on_token:
                on_token(part)
        return resp

    def context_length(self, name):
        return self.trained_window

    def loaded_context_length(self, name):
        return self.resident_state(name)["context_length"]

    def resident_state(self, name):
        return {
            "context_length": self.loaded_window,
            "size": self.resident_size,
            "size_vram": self.resident_size_vram,
        }

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
    assert isinstance(done["duration_ms"], int) and done["duration_ms"] >= 0
    assert core.messages[-1]["content"] == "Hello world"


def test_run_turn_names_a_smaller_team_call_limit_instead_of_iteration_limit(tmp_path):
    from ollama_code.ollama import ToolCall

    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall("list_dir", {"path": "."})], done=True),
        ChatResponse(tool_calls=[ToolCall("list_dir", {"path": "."})], done=True),
    ])
    events = []
    core.on_event(events.append)

    core.run_turn("inspect twice", model_call_limit=2)

    done = next(event for event in events if event["type"] == "turn_done")
    assert done["reason"] == "model_call_budget"
    assert done["model_calls"] == 2
    assert done["model_call_limit"] == 2
    assert done["iteration_limit"] == 5
    assert core.last_turn_result == done


def test_submit_plan_emits_structured_plan_ready(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("submit_plan", {
            "title": "Smooth streaming",
            "summary": "Make transcript updates bounded.",
            "steps": ["Buffer tokens", "Detach user scrolling"],
            "tests": ["Stream a 100 KB reply"],
        })], done=True),
        ChatResponse(content_parts=["Plan ready."], done=True),
    ]
    core = _core(tmp_path, responses)
    events = []
    core.on_event(events.append)

    core.run_turn("plan the fix")

    ready = next(event for event in events if event["type"] == "plan_ready")
    assert ready["plan"]["title"] == "Smooth streaming"
    assert ready["plan"]["steps"] == ["Buffer tokens", "Detach user scrolling"]
    assert ready["plan"]["tests"] == ["Stream a 100 KB reply"]


def test_local_and_inline_reasoning_are_resumable_without_provider_state(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(
            content_parts=["<thinking>inline thought</thinking>Visible answer"],
            thinking_parts=["native thought"],
            done=True,
        ),
    ])
    events = []
    core.on_event(events.append)

    core.run_turn("hi")

    assistant = next(message for message in reversed(core.messages) if message["role"] == "assistant")
    assert assistant["content"] == "Visible answer"
    assert assistant["_display_reasoning"] == "native thought\n\ninline thought"
    assert "_display_reasoning" not in core._request_messages()[-1]
    resumed = AgentCore.sanitize_messages([assistant])[0]
    assert resumed["reasoning"] == "native thought\n\ninline thought"
    thinking = "".join(event.get("text", "") for event in events if event["type"] == "thinking")
    assert "inline thought" in thinking


def test_sanitized_anthropic_reasoning_never_exposes_signatures_or_redactions():
    out = AgentCore.sanitize_messages([{
        "role": "assistant",
        "content": "answer",
        "anthropic_content": [
            {"type": "thinking", "thinking": "visible", "signature": "secret-signature"},
            {"type": "redacted_thinking", "data": "opaque-secret"},
        ],
    }])
    assert out[0]["reasoning"] == "visible"
    assert "signature" not in json.dumps(out)
    assert "opaque-secret" not in json.dumps(out)


def test_computer_tools_are_absent_until_native_broker_is_enabled(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=["ok"], done=True)])

    def names():
        return {schema["function"]["name"] for schema in core.tool_registry.schemas()}

    assert "computer_get_state" not in names()
    core.tool_registry.computer_enabled = True
    assert {"computer_get_state", "computer_click", "computer_type_text"} <= names()


def test_native_computer_tool_uses_permission_mode_and_bridge(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[ToolCall("computer_click", {"app": "Notes", "element": "snap-1"})], done=True),
        ChatResponse(content_parts=["done"], done=True),
    ]
    core = _core(tmp_path, responses)
    core.tool_registry.computer_enabled = True
    core.perms.set_mode("bypass")
    calls = []
    core.computer_executor = lambda name, args, request_id: calls.append((name, args, request_id)) or "clicked"

    core.run_turn("click the note")

    assert calls and calls[0][0] == "computer_click"
    assert calls[0][1]["element"] == "snap-1"


def test_steer_continues_same_turn_without_intermediate_turn_done(tmp_path):
    first_started = threading.Event()

    class SteeringClient(FakeClient):
        def __init__(self):
            super().__init__([])

        def chat_stream(self, model, messages, tools=None, on_token=None, should_stop=None,
                        on_thinking=None, think=False, options=None):
            self.seen_messages.append(messages)
            if len(self.seen_messages) == 1:
                on_token("Initial direction")
                first_started.set()
                deadline = time.time() + 2
                while time.time() < deadline and not should_stop():
                    time.sleep(0.005)
                return ChatResponse(done=True, done_reason="interrupted")
            on_token("Updated answer")
            return ChatResponse(done=True)

    core = _core(tmp_path, [])
    client = SteeringClient()
    core.client = client
    events = []
    core.on_event(events.append)
    worker = threading.Thread(target=core.run_turn, args=("start",), daemon=True)
    worker.start()
    assert first_started.wait(1)

    assert core.steer("focus on scrolling") == "interrupting_generation"
    worker.join(3)

    assert not worker.is_alive()
    assert len([event for event in events if event["type"] == "turn_done"]) == 1
    assert core.steer("too late") is None
    assert any(event["type"] == "steer_applied" for event in events)
    assert any(
        message.get("role") == "user" and message.get("content") == "focus on scrolling"
        for message in client.seen_messages[1]
    )


def test_steer_finishes_current_tool_but_skips_later_stale_actions(tmp_path):
    from ollama_code.ollama import ToolCall

    responses = [
        ChatResponse(tool_calls=[
            ToolCall("computer_click", {"app": "Notes", "element": "snap-1"}, call_id="first"),
            ToolCall("computer_scroll", {"app": "Notes", "delta_y": 200}, call_id="second"),
        ], done=True),
        ChatResponse(content_parts=["redirected"], done=True),
    ]
    core = _core(tmp_path, responses)
    core.tool_registry.computer_enabled = True
    core.perms.set_mode("bypass")
    started = threading.Event()
    release = threading.Event()
    calls = []

    def execute(name, args, request_id):
        calls.append(name)
        started.set()
        assert release.wait(2)
        return "done"

    core.computer_executor = execute
    worker = threading.Thread(target=core.run_turn, args=("start",), daemon=True)
    worker.start()
    assert started.wait(1)
    assert core.steer("do not scroll") == "after_current_action"
    release.set()
    worker.join(3)

    assert calls == ["computer_click"]
    assert not worker.is_alive()
    second_request = core.client.seen_messages[1]
    tool_results = [message for message in second_request if message.get("role") == "tool"]
    assert [message["tool_call_id"] for message in tool_results[-2:]] == ["first", "second"]
    assert "Not run" in tool_results[-1]["content"]
    assert second_request[-1]["content"] == "do not scroll"


def test_computer_screenshot_retries_only_for_explicit_image_rejection(tmp_path):
    class ImageRejectingClient(FakeClient):
        def chat_stream(self, model, messages, tools=None, on_token=None, should_stop=None,
                        on_thinking=None, think=False, options=None):
            self.calls += 1
            self.seen_messages.append(messages)
            if self.calls == 1:
                raise OllamaError("this model does not support image input")
            assert not any(message.get("attachments") for message in messages)
            if on_token:
                on_token("AX-only answer")
            return ChatResponse(content_parts=["AX-only answer"], done=True)

    core = _core(tmp_path, [])
    core.client = ImageRejectingClient([])
    core.messages.append({
        "role": "user",
        "content": "screen",
        "attachments": [{"mime_type": "image/png", "data": "aW1hZ2U="}],
        "_computer_observation": True,
    })

    core.run_turn("continue")

    assert core.client.calls == 2
    assert core._computer_route_key() in core._ax_only_routes


def test_terminal_event_is_not_sent_until_turn_slot_is_idle(tmp_path):
    async def scenario():
        core = _core(tmp_path, [])
        service = server_mod.ChatService(core)
        service.loop = asyncio.get_running_loop()
        service.turn_future = service.loop.create_future()

        class Socket:
            def __init__(self):
                self.events = []

            async def send_json(self, event):
                self.events.append(event)

        socket = Socket()
        pump = asyncio.create_task(server_mod._event_pump(service, socket))
        service.queue_event({"type": "turn_done", "reason": "interrupted"})
        await asyncio.sleep(0)
        assert socket.events == []

        service.turn_future.set_result(None)
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert socket.events == [{"type": "turn_done", "reason": "interrupted"}]
        pump.cancel()

    asyncio.run(scenario())


def test_starting_a_new_team_turn_clears_the_previous_interrupt(tmp_path):
    async def scenario():
        core = _core(tmp_path, [])
        service = server_mod.ChatService(core)
        service.loop = asyncio.get_running_loop()
        core.interrupt()
        observed = []

        def next_team_turn():
            observed.append(core._interrupt.is_set())

        next_team_turn.__name__ = "_run_team_turn"
        assert service.start_turn(service.loop, next_team_turn)
        await service.turn_future

        assert observed == [False]

    asyncio.run(scenario())


def test_uncaught_turn_worker_error_publishes_a_terminal_event(tmp_path):
    async def scenario():
        core = _core(tmp_path, [])
        service = server_mod.ChatService(core)
        service.loop = asyncio.get_running_loop()

        def broken_turn():
            raise RuntimeError("private diagnostic detail")

        assert service.start_turn(service.loop, broken_turn)
        with pytest.raises(RuntimeError, match="private diagnostic detail"):
            await service.turn_future
        await asyncio.sleep(0)

        events = []
        while not service.queue.empty():
            events.append(service.queue.get_nowait())
        error = next(event for event in events if event["type"] == "error")
        terminal = next(event for event in events if event["type"] == "turn_done")
        assert "internal error" in error["message"]
        assert "private diagnostic detail" not in error["message"]
        assert terminal["reason"] == "error"

    asyncio.run(scenario())


def test_team_turn_unexpected_error_is_persisted_as_failed(tmp_path, monkeypatch):
    core = _core(tmp_path, [])
    service = server_mod.ChatService(core)

    def broken_manifest(_manifest):
        raise RuntimeError("unexpected parser failure")

    monkeypatch.setattr(server_mod, "parse_manifest", broken_manifest)
    server_mod._run_team_turn(service, "do the work", {"run_id": "failed-team-run"})

    record = service.run_store.run("failed-team-run", include_events=True)
    assert record is not None
    assert record["state"] == "failed"
    assert any(
        event["type"] == "orchestration_completed" and event["state"] == "failed"
        for event in record["events"]
    )
    assert service.active_run_id is None


def test_specialist_token_streams_do_not_flood_durable_run_history(tmp_path):
    core = _core(tmp_path, [])
    service = server_mod.ChatService(core)
    service.run_store.start_run("stream-run", request="work")
    service.active_run_id = "stream-run"

    for token in ("one", "two", "three"):
        service.emit({
            "type": "agent_job_stream", "run_id": "stream-run",
            "job_id": "review", "text": token,
        })

    assert service.run_store.events("stream-run") == []


def test_dispatcher_rejection_is_persisted_as_a_bounded_durable_event(tmp_path):
    core = _core(tmp_path, [])
    service = server_mod.ChatService(core)
    service.run_store.start_run("dispatch-run", request="work")
    service.active_run_id = "dispatch-run"

    service.emit({
        "type": "dispatcher_plan_rejected",
        "run_id": "dispatch-run",
        "stage": "initial",
        "reason": "dispatcher plan has no jobs",
        "response_source": "tool_call",
        "will_retry": True,
        "message": "Correcting dispatcher plan…",
    })

    events = service.run_store.events("dispatch-run")
    assert len(events) == 1
    assert events[0]["type"] == "dispatcher_plan_rejected"
    assert events[0]["reason"] == "dispatcher plan has no jobs"
    assert events[0]["will_retry"] is True
    assert "content" not in events[0]
    assert "raw" not in events[0]


def test_team_writer_honors_its_preallocated_call_share():
    observed = {}
    core = SimpleNamespace(
        total_prompt_tokens=0,
        total_completion_tokens=0,
        last_turn_result={"model_calls": 0},
        messages=[{"role": "assistant", "content": "verified"}],
    )

    def run_turn(_prompt, _decider, **kwargs):
        observed["model_call_limit"] = kwargs["model_call_limit"]
        core.last_turn_result = {"model_calls": 2, "reason": "complete"}

    core.run_turn = run_turn
    writer = SimpleNamespace(
        id="writer", name="Writer", role="implementer", model="k3",
        route={"provider": "remote", "account_label": "Kimi"},
    )
    prepared = SimpleNamespace(
        run_id="run", writer=writer,
        team=SimpleNamespace(budget=SimpleNamespace()),
    )

    class Orchestrator:
        def remaining_model_calls(self, _budget):
            return 5

        def writer_slot(self, _run_id, _writer):
            return nullcontext()

        def account_writer_usage(self, *_args):
            return None

        def usage(self):
            return {"model_calls": 2}

    events = []
    service = SimpleNamespace(core=core, emit=events.append, decide=lambda *_args: "always")
    server_mod._run_team_writer(
        service,
        Orchestrator(),
        prepared,
        writer,
        "write",
        persisted_user_text="request",
        job_id="writer",
        goal="implement",
        model_call_limit=3,
    )

    assert observed["model_call_limit"] == 3
    assert events[0]["type"] == "agent_job_started"
    assert events[-1]["type"] == "agent_job_completed"


def test_ordered_coding_jobs_never_overlap_and_second_observes_first(monkeypatch):
    writer_one = SimpleNamespace(
        id="backend", name="Backend", role="implementer", can_write=True,
    )
    writer_two = SimpleNamespace(
        id="ui", name="UI", role="implementer", can_write=True,
    )
    jobs = (
        SimpleNamespace(id="backend-job", agent_id="backend", goal="Build API", kind="writer"),
        SimpleNamespace(id="ui-job", agent_id="ui", goal="Build UI", kind="writer"),
    )
    prepared = SimpleNamespace(
        run_id="run",
        writer_jobs=jobs,
        completed_writer_job_ids=set(),
        writer_results=[],
        profiles={"backend": writer_one, "ui": writer_two},
        plan=SimpleNamespace(jobs=list(jobs)),
        team=SimpleNamespace(budget=SimpleNamespace(max_rounds=1)),
    )
    core = SimpleNamespace(_interrupt=threading.Event(), last_turn_result={"reason": "complete"})
    checkpoints = []
    service = SimpleNamespace(
        core=core,
        current_task=None,
        checkpoint=lambda kind, state: checkpoints.append((kind, state)),
    )

    class Orchestrator:
        calls = 0

        def remaining_model_calls(self, _budget):
            return 6 - self.calls

        def usage(self):
            return {"model_calls": self.calls}

    orchestrator = Orchestrator()
    active = []
    observations = []

    def prompt_for_job(value, job):
        observations.append((job.id, [result.job_id for result in value.writer_results]))
        return job.goal

    def run_writer(_svc, _orchestrator, _prepared, writer, _prompt, **kwargs):
        assert not active, "two mutation-capable models must never overlap"
        active.append(writer.id)
        orchestrator.calls += 1
        active.pop()
        return AgentResult(
            kwargs["job_id"], writer.id, writer.name, "implementer",
            f"finished {writer.id}", [], 0, 0, 1,
        )

    monkeypatch.setattr(server_mod, "writer_prompt_for_job", prompt_for_job)
    monkeypatch.setattr(server_mod, "_install_writer_route", lambda _core, writer: writer.id)
    monkeypatch.setattr(server_mod, "_restore_writer_route", lambda _core, _snapshot: None)
    monkeypatch.setattr(server_mod, "_run_team_writer", run_writer)
    monkeypatch.setattr(
        server_mod,
        "_team_checkpoint_state",
        lambda value, state, _task, **_kwargs: {
            "state": state,
            "completed_writer_job_ids": sorted(value.completed_writer_job_ids),
        },
    )

    server_mod._run_prepared_writers(
        service, orchestrator, prepared, first_persisted_user_text="request",
    )

    assert observations == [
        ("backend-job", []),
        ("ui-job", ["backend-job"]),
    ]
    assert prepared.completed_writer_job_ids == {"backend-job", "ui-job"}
    assert checkpoints[-1][1]["state"] == "reviewing"


def test_coding_job_continues_in_bounded_slices_until_it_finishes(monkeypatch):
    writer = SimpleNamespace(
        id="backend", name="Backend", role="implementer", can_write=True,
    )
    job = SimpleNamespace(
        id="backend-job", agent_id="backend", goal="Build API", kind="writer",
    )
    prepared = SimpleNamespace(
        run_id="run",
        writer_jobs=(job,),
        completed_writer_job_ids=set(),
        writer_results=[],
        profiles={"backend": writer},
        plan=SimpleNamespace(jobs=[job]),
        team=SimpleNamespace(
            budget=SimpleNamespace(max_rounds=1, max_model_calls=20),
        ),
    )
    core = SimpleNamespace(_interrupt=threading.Event(), last_turn_result={})
    emitted = []
    checkpoints = []
    service = SimpleNamespace(
        core=core,
        current_task=None,
        emit=emitted.append,
        checkpoint=lambda kind, state: checkpoints.append((kind, state)),
    )

    class Orchestrator:
        calls = 0

        def remaining_model_calls(self, budget):
            return budget.max_model_calls - self.calls

        def usage(self):
            return {"model_calls": self.calls}

    orchestrator = Orchestrator()
    continuations = []

    def run_writer(_svc, _orchestrator, _prepared, _writer, _prompt, **kwargs):
        continuations.append(kwargs["continuation"])
        used = 12 if len(continuations) == 1 else 1
        orchestrator.calls += used
        core.last_turn_result = {
            "reason": "model_call_budget" if len(continuations) == 1 else "complete",
            "model_calls": used,
            "model_call_limit": kwargs["model_call_limit"],
            "iteration_limit": 100,
        }
        return AgentResult(
            kwargs["job_id"], writer.id, writer.name, writer.role,
            "partial" if len(continuations) == 1 else "finished", [], 0, 0, 1,
        )

    monkeypatch.setattr(server_mod, "writer_prompt_for_job", lambda _value, value: value.goal)
    monkeypatch.setattr(server_mod, "_install_writer_route", lambda _core, value: value.id)
    monkeypatch.setattr(server_mod, "_restore_writer_route", lambda _core, _snapshot: None)
    monkeypatch.setattr(server_mod, "_run_team_writer", run_writer)
    monkeypatch.setattr(
        server_mod,
        "_team_checkpoint_state",
        lambda value, state, _task, **_kwargs: {
            "state": state,
            "completed_writer_job_ids": sorted(value.completed_writer_job_ids),
        },
    )

    server_mod._run_prepared_writers(
        service, orchestrator, prepared, first_persisted_user_text="request",
    )

    assert continuations == [False, True]
    assert prepared.completed_writer_job_ids == {"backend-job"}
    assert prepared.writer_results[0].output == "finished"
    assert [event["type"] for event in emitted] == ["agent_job_completed"]
    assert checkpoints[-1][0] == "writer_complete:backend-job"


def test_unfinished_coding_job_pauses_recoverably_without_false_completion(monkeypatch):
    writer = SimpleNamespace(
        id="backend", name="Backend", role="implementer", can_write=True,
    )
    job = SimpleNamespace(
        id="backend-job", agent_id="backend", goal="Build API", kind="writer",
    )
    prepared = SimpleNamespace(
        run_id="run",
        writer_jobs=(job,),
        completed_writer_job_ids=set(),
        writer_results=[],
        profiles={"backend": writer},
        plan=SimpleNamespace(jobs=[job]),
        team=SimpleNamespace(
            budget=SimpleNamespace(max_rounds=1, max_model_calls=3),
        ),
    )
    core = SimpleNamespace(_interrupt=threading.Event(), last_turn_result={})
    emitted = []
    checkpoints = []
    service = SimpleNamespace(
        core=core,
        current_task=None,
        emit=emitted.append,
        checkpoint=lambda kind, state: checkpoints.append((kind, state)),
    )

    class Orchestrator:
        calls = 0

        def remaining_model_calls(self, budget):
            return budget.max_model_calls - self.calls

        def usage(self):
            return {"model_calls": self.calls}

    orchestrator = Orchestrator()

    def run_writer(_svc, _orchestrator, _prepared, _writer, _prompt, **kwargs):
        orchestrator.calls += 2
        core.last_turn_result = {
            "reason": "model_call_budget",
            "model_calls": 2,
            "model_call_limit": kwargs["model_call_limit"],
            "iteration_limit": 100,
        }
        return AgentResult(
            kwargs["job_id"], writer.id, writer.name, writer.role,
            "unfinished", [], 0, 0, 1,
        )

    monkeypatch.setattr(server_mod, "writer_prompt_for_job", lambda _value, value: value.goal)
    monkeypatch.setattr(server_mod, "_install_writer_route", lambda _core, value: value.id)
    monkeypatch.setattr(server_mod, "_restore_writer_route", lambda _core, _snapshot: None)
    monkeypatch.setattr(server_mod, "_run_team_writer", run_writer)
    monkeypatch.setattr(
        server_mod,
        "_team_checkpoint_state",
        lambda value, state, _task, **_kwargs: {
            "state": state,
            "completed_writer_job_ids": sorted(value.completed_writer_job_ids),
        },
    )

    with pytest.raises(server_mod.TeamWriterBudgetPause) as paused:
        server_mod._run_prepared_writers(
            service, orchestrator, prepared, first_persisted_user_text="request",
        )

    assert paused.value.reason == "model_call_budget"
    assert prepared.completed_writer_job_ids == set()
    assert prepared.writer_results == []
    assert [event["type"] for event in emitted] == ["agent_job_incomplete"]
    assert emitted[0]["model_calls"] == 2
    assert emitted[0]["limit"] == 2
    assert checkpoints[-1][0] == "writer_incomplete:backend-job"


def test_cancellation_after_first_coding_job_never_starts_the_next(monkeypatch):
    writer_one = SimpleNamespace(
        id="backend", name="Backend", role="implementer", can_write=True,
    )
    writer_two = SimpleNamespace(
        id="ui", name="UI", role="implementer", can_write=True,
    )
    jobs = (
        SimpleNamespace(id="backend-job", agent_id="backend", goal="Build API", kind="writer"),
        SimpleNamespace(id="ui-job", agent_id="ui", goal="Build UI", kind="writer"),
    )
    prepared = SimpleNamespace(
        run_id="run",
        writer_jobs=jobs,
        completed_writer_job_ids=set(),
        writer_results=[],
        profiles={"backend": writer_one, "ui": writer_two},
        plan=SimpleNamespace(jobs=list(jobs)),
        team=SimpleNamespace(budget=SimpleNamespace(max_rounds=1)),
    )
    interrupt = threading.Event()
    core = SimpleNamespace(_interrupt=interrupt, last_turn_result={"reason": "complete"})
    checkpoints = []
    service = SimpleNamespace(
        core=core,
        current_task=None,
        checkpoint=lambda kind, state: checkpoints.append((kind, state)),
    )

    class Orchestrator:
        calls = 0

        def remaining_model_calls(self, _budget):
            return 6 - self.calls

        def usage(self):
            return {"model_calls": self.calls}

    orchestrator = Orchestrator()
    started = []

    def run_writer(_svc, _orchestrator, _prepared, writer, _prompt, **kwargs):
        started.append(writer.id)
        orchestrator.calls += 1
        interrupt.set()
        return AgentResult(
            kwargs["job_id"], writer.id, writer.name, "implementer",
            "done", [], 0, 0, 1,
        )

    monkeypatch.setattr(server_mod, "writer_prompt_for_job", lambda _value, job: job.goal)
    monkeypatch.setattr(server_mod, "_install_writer_route", lambda _core, writer: writer.id)
    monkeypatch.setattr(server_mod, "_restore_writer_route", lambda _core, _snapshot: None)
    monkeypatch.setattr(server_mod, "_run_team_writer", run_writer)
    monkeypatch.setattr(
        server_mod,
        "_team_checkpoint_state",
        lambda value, state, _task, **_kwargs: {
            "state": state,
            "completed_writer_job_ids": sorted(value.completed_writer_job_ids),
        },
    )

    with pytest.raises(InterruptedError, match="before the next coding job"):
        server_mod._run_prepared_writers(
            service, orchestrator, prepared, first_persisted_user_text="request",
        )

    assert started == ["backend"]
    assert prepared.completed_writer_job_ids == {"backend-job"}
    assert checkpoints[-1][1]["completed_writer_job_ids"] == ["backend-job"]


def test_each_coding_job_installs_its_own_tool_ceiling(monkeypatch):
    policy_calls = []

    class Registry:
        def mcp_agent_policy_snapshot(self):
            return ({"old": True}, "read_only", "dispatcher")

        def set_mcp_agent_policy(self, policy, *, access_ceiling, role):
            policy_calls.append((policy, access_ceiling, role))

    core = SimpleNamespace(
        client=object(),
        provider="remote",
        host="https://solo.example",
        model="solo",
        config={"remote_account_label": "Solo"},
        context_limit=32_000,
        _context_source="reported",
        _context_requested=32_000,
        _context_limit_for="solo",
        evaluation_read_only=False,
        tool_registry=Registry(),
        _emit_info=lambda: None,
    )
    backend = SimpleNamespace(
        name="Backend", model="backend-model", role="implementer",
        access_ceiling="workspace_write", mcp_policy={"filesystem": True},
        route={"provider": "remote", "account_label": "Backend endpoint"},
    )
    ui = SimpleNamespace(
        name="UI", model="ui-model", role="implementer",
        access_ceiling="computer_control", mcp_policy={"computer": True},
        route={"provider": "remote", "account_label": "UI endpoint"},
    )
    monkeypatch.setattr(
        server_mod,
        "client_for_profile",
        lambda writer: SimpleNamespace(host=f"https://{writer.name.lower()}.example"),
    )

    first_snapshot = server_mod._install_writer_route(core, backend)
    assert core.model == "backend-model"
    server_mod._restore_writer_route(core, first_snapshot)
    second_snapshot = server_mod._install_writer_route(core, ui)
    assert core.model == "ui-model"
    server_mod._restore_writer_route(core, second_snapshot)

    assert ({"filesystem": True}, "workspace_write", "implementer") in policy_calls
    assert ({"computer": True}, "computer_control", "implementer") in policy_calls


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


def test_just_chat_has_no_tools_or_project_context_even_if_provider_requests_one(tmp_path):
    from ollama_code.ollama import ToolCall

    (tmp_path / "AGENTS.md").write_text("workspace-secret-instruction")
    responses = [
        ChatResponse(
            tool_calls=[ToolCall("write_file", {"path": "should-not-exist", "content": "no"})],
            done=True,
        ),
        ChatResponse(content_parts=["A conversational answer."], done=True),
    ]
    core = _core(tmp_path, responses)
    events = []
    core.on_event(events.append)

    core.run_turn("What does this concept mean?", allow_tools=False)

    assert core.client.seen_tools == [[], []]
    assert all(
        "workspace-secret-instruction" not in str(messages)
        for messages in core.client.seen_messages
    )
    assert all("Extension capabilities" not in str(messages) for messages in core.client.seen_messages)
    assert not (tmp_path / "should-not-exist").exists()
    assert not any(event["type"] == "tool_call_proposed" for event in events)
    assert any("Just Chat blocked" in event.get("text", "") for event in events)
    assert core.messages[-1]["content"] == "A conversational answer."


def test_just_chat_images_reach_the_model_but_not_the_saved_transcript(tmp_path):
    encoded = "cHJpdmF0ZS1pbWFnZS1ieXRlcw=="
    core = _core(tmp_path, [ChatResponse(content_parts=["I can see it."], done=True)])

    core.run_turn(
        "Describe the attached image.",
        allow_tools=False,
        attachments=[{
            "name": "photo.png",
            "mime_type": "image/png",
            "data": encoded,
        }],
    )

    request = core.client.seen_messages[0][-1]
    assert request["attachments"][0]["data"] == encoded
    assert core.client.seen_tools == [[]]
    assert encoded not in core.session.path.read_text(encoding="utf-8")


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
    assert [event["type"] for event in events] == ["error", "turn_done"]
    assert events[-1]["reason"] == "error"


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


def test_approx_tokens_counts_image_attachments(tmp_path):
    # Attachments stay in the conversation and are re-sent every turn, so
    # leaving them out let a chat sit near the window with the meter reading
    # almost empty and compaction never firing.
    core = _core(tmp_path, [])
    core.messages = [{
        "role": "user",
        "content": "what is in this screenshot?",
        "attachments": [{"mime_type": "image/png", "data": "z" * 40_000}],
    }]
    assert core.approx_tokens() > core_module.IMAGE_TOKENS_BASE


def test_image_attachments_can_never_exhaust_the_budget(tmp_path):
    # Charging encoded length as tokens overstated a screenshot by orders of
    # magnitude, which put every image-bearing session over budget and made
    # compaction destroy the very image it was accounting for. The charge is
    # bounded so an attachment can never be the reason a session compacts.
    core = _core(tmp_path, [])
    # The largest single image the chat endpoint accepts, base64-encoded.
    core.messages = [{
        "role": "user",
        "content": "",
        "attachments": [{"mime_type": "image/png", "data": "z" * (15 * 1024 * 1024 * 4 // 3)}],
    }]
    assert core.approx_tokens() <= core_module.IMAGE_TOKENS_MAX
    # And the full advertised batch still leaves a normal window usable.
    core.messages = [{
        "role": "user",
        "content": "",
        "attachments": [
            {"mime_type": "image/png", "data": "z" * (2 * 1024 * 1024)} for _ in range(10)
        ],
    }]
    assert core.approx_tokens() <= 10 * core_module.IMAGE_TOKENS_MAX


def test_ws_frame_cap_admits_the_largest_advertised_message(tmp_path):
    # The transport cap has to clear the limits the chat endpoint advertises,
    # or an oversized image is a 1009 socket close instead of the friendly
    # validation error, and the validators are unreachable.
    from ollama_code import server as server_module

    base64_expansion = server_module.MAX_CHAT_IMAGE_TOTAL_BYTES * 4 // 3
    assert server_module.MAX_WS_MESSAGE_BYTES > base64_expansion


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

    def fake_post(url, json=None, stream=None, timeout=None, allow_redirects=None):
        seen["url"] = url
        seen["payload"] = json
        seen["allow_redirects"] = allow_redirects
        return FakeResponse(lines=[
            '{"message":{"content":"hi"},"done":true,"done_reason":"stop"}'
        ])

    monkeypatch.setattr(ollama_mod.requests, "post", fake_post)
    client = ollama_mod.OllamaClient("http://localhost:11434")

    client.chat_stream("m", [{"role": "user", "content": "hi"}], options={"num_ctx": 49_152})

    assert seen["url"] == "http://localhost:11434/api/chat"
    assert seen["payload"]["options"] == {"num_ctx": 49_152}
    assert seen["allow_redirects"] is False


def test_chat_stream_maps_explicit_images_to_ollamas_native_shape(monkeypatch):
    from ollama_code import ollama as ollama_mod

    seen = {}

    def fake_post(url, json=None, stream=None, timeout=None, allow_redirects=None):
        seen["payload"] = json
        return FakeResponse(lines=[
            '{"message":{"content":"described"},"done":true,"done_reason":"stop"}'
        ])

    monkeypatch.setattr(ollama_mod.requests, "post", fake_post)
    client = ollama_mod.OllamaClient("http://localhost:11434")
    client.chat_stream("vision-model", [{
        "role": "user",
        "content": "Describe it.",
        "attachments": [{
            "name": "photo.png",
            "mime_type": "image/png",
            "data": "cG5n",
        }],
    }])

    message = seen["payload"]["messages"][0]
    assert message["images"] == ["cG5n"]
    assert "attachments" not in message


def test_the_window_is_pinned_so_the_first_turn_is_already_budgeted(tmp_path):
    """Ollama defaults to a 4096-token window and a turn spends most of that
    before the conversation starts: the tool schemas alone are around 1,500
    tokens, plus the system prompt and the room held back for a reply. What is
    left cannot hold one file read.

    This reverses the earlier rule that nothing was ever requested. That rule was
    right about the risk — a guessed `num_ctx` can evict a working runner — and
    wrong about the cost of doing nothing, which was an agent running in a window
    chosen for chat. The number is not a guess: it is the model's own trained
    ceiling, clamped by a cap this machine is willing to pay KV cache for, and a
    window that turns out not to fit is backed off from a measurement rather than
    predicted (see the spill test below).
    """
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.client.loaded_window = 0        # nothing resident on the first turn
    core.client.trained_window = 262_144

    core.run_turn("hi")

    assert core.context_limit == 32_768, "the cap, not the trained maximum"
    assert core.client.seen_options == [{"num_ctx": 32_768}]
    assert core._context_source == "pinned", "chosen by us, so labelled as chosen"


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


def _remote_core(tmp_path, base_url="https://endpoint.example/v1", **config):
    """A core pointed at a hosted endpoint, with no network involved."""
    core = AgentCore(cwd=str(tmp_path), config={
        "provider": "remote",
        "remote_base_url": base_url,
        "remote_model": "hosted-model",
        "remote_api_key": "k",
        **config,
    })
    core.model = "hosted-model"
    return core


def _json_response(payload, status=200):
    class Response:
        status_code = status

        def json(self):
            return payload

    return Response()


def test_a_window_reported_by_the_endpoint_is_used(tmp_path, monkeypatch):
    """vLLM states `max_model_len` in the model listing the picker already
    fetches. Discarding every field except the id is why a hosted account had a
    dead meter and no compaction."""
    seen: list[str] = []

    def fake_get(url, **kwargs):
        seen.append(url)
        return _json_response({"data": [{"id": "hosted-model", "max_model_len": 32_768}]})

    monkeypatch.setattr("ollama_code.remote.requests.get", fake_get)
    core = _remote_core(tmp_path)

    core.client.discover_windows()
    core.refresh_context_limit()

    assert core.context_limit == 32_768
    assert core._context_source == "reported"
    assert core.config["model_windows"] == {
        "https://endpoint.example/v1|hosted-model": 32_768
    }, "a reported window is an observation, so it is remembered"
    assert seen == ["https://endpoint.example/v1/models"], "no runtime probe needed"


def test_tgi_info_supplies_the_window_when_the_model_list_does_not(tmp_path, monkeypatch):
    """A Hugging Face Inference Endpoint lists a bare id and puts the real
    number on TGI's own /info route."""
    seen: list[str] = []

    def fake_get(url, **kwargs):
        seen.append(url)
        if url.endswith("/models"):
            return _json_response({"data": [{"id": "hosted-model"}]})
        if url.endswith("/info"):
            return _json_response({"max_total_tokens": 32_768, "max_input_length": 30_000})
        return _json_response({}, status=404)

    monkeypatch.setattr("ollama_code.remote.requests.get", fake_get)
    core = _remote_core(tmp_path)

    core.client.discover_windows()
    core.refresh_context_limit()

    assert core.context_limit == 32_768, "max_total_tokens is prompt + generation"
    assert core._context_source == "reported"
    assert seen == [
        "https://endpoint.example/v1/models",
        "https://endpoint.example/info",
    ], "the /v1 suffix belongs to the OpenAI surface, not to /info"


def test_llama_cpp_props_supplies_the_window(tmp_path, monkeypatch):
    def fake_get(url, **kwargs):
        if url.endswith("/models"):
            return _json_response({"data": [{"id": "hosted-model"}]})
        if url.endswith("/info"):
            return _json_response({}, status=404)
        if url.endswith("/props"):
            return _json_response({"default_generation_settings": {"n_ctx": 16_384}})
        return _json_response({}, status=404)

    monkeypatch.setattr("ollama_code.remote.requests.get", fake_get)
    core = _remote_core(tmp_path)

    core.client.discover_windows()
    core.refresh_context_limit()

    assert core.context_limit == 16_384, "the per-slot window, not the server total"


def test_a_user_window_is_clamped_to_what_the_endpoint_reports(tmp_path, monkeypatch):
    """The protection local models have always had, finally applied remotely: a
    figure larger than the deployment can serve fails every request past the real
    window, and compacts far too late to help."""
    monkeypatch.setattr(
        "ollama_code.remote.requests.get",
        lambda url, **kw: _json_response(
            {"data": [{"id": "hosted-model", "max_model_len": 32_768}]}
        ),
    )
    core = _remote_core(tmp_path, context_window=1_000_000)

    core.client.discover_windows()
    core.refresh_context_limit()

    assert core.context_limit == 32_768


def test_a_published_window_is_labelled_and_never_remembered(tmp_path, monkeypatch):
    """A vendor's documented figure is an assumption: nothing was observed, and a
    model renamed behind the same id would change it silently. It may be
    budgeted against, but writing it to model_windows would let the next session
    read it back as `remembered` — a guess laundered into a measurement."""
    monkeypatch.setattr(
        "ollama_code.remote.requests.get",
        lambda url, **kw: _json_response({}, status=404),
    )
    core = _remote_core(tmp_path, published_context_window=200_000)

    core.client.discover_windows()
    core.refresh_context_limit()

    assert core.context_limit == 200_000
    assert core._context_source == "published"
    assert core.config["model_windows"] == {}


def test_the_endpoint_is_probed_once_not_per_turn(tmp_path, monkeypatch):
    """refresh_context_limit runs at both ends of every turn. If discovery were
    wired into it rather than beside it, a hosted session would pay three HTTP
    timeouts per message."""
    calls: list[str] = []

    def fake_get(url, **kwargs):
        calls.append(url)
        return _json_response({"data": [{"id": "hosted-model", "context_length": 32_768}]})

    monkeypatch.setattr("ollama_code.remote.requests.get", fake_get)
    core = _remote_core(tmp_path)
    core.client.discover_windows()
    after_discovery = len(calls)

    for _ in range(3):
        core.refresh_context_limit()
    core.client.discover_windows()  # idempotent

    assert len(calls) == after_discovery == 1


def test_context_window_keys_are_found_however_they_are_nested(tmp_path):
    """Gateways nest this differently and rename it every other quarter, so the
    walk looks for the keys wherever they are instead of following fixed paths."""
    from ollama_code.remote import parse_context_length

    assert parse_context_length({"context_length": 32_768}) == 32_768
    assert parse_context_length({"model_info": {"max_input_tokens": 128_000}}) == 128_000
    assert parse_context_length({"top_provider": {"context_length": 200_000}}) == 200_000
    assert parse_context_length({"max_model_len": "32768"}) == 32_768
    # An output cap is not a context window: reading it as one would understate a
    # 128k model as an 8k one and compact away most of a working conversation.
    assert parse_context_length({"max_tokens": 8_192}) == 0
    assert parse_context_length({"context_length": True}) == 0
    assert parse_context_length({"context_length": 32}) == 0, "a unit mix-up"
    assert parse_context_length({"context_length": 10_000_000}) == 0, "not a window"
    assert parse_context_length({"a": {"b": {"c": {"d": {"n_ctx": 4_096}}}}}) == 0, "bounded"


def test_a_provider_that_serves_no_model_listing_is_not_asked_for_one(tmp_path, monkeypatch):
    """Kimi Code documents chat completions and nothing else. Asking anyway got a
    401, which the caller reported as a rejected key — and then model switching
    failed for a key that works perfectly well for chat."""
    calls: list[str] = []
    monkeypatch.setattr(
        "ollama_code.remote.requests.get",
        lambda url, **kw: calls.append(url) or _json_response({}, status=401),
    )
    core = _remote_core(tmp_path)
    core.client.lists_models = False

    listed = core.client.list_models()

    assert [m["name"] for m in listed] == ["hosted-model"]
    assert calls == [], "no request was made at all"


def test_anthropic_output_cap_matches_the_room_reserved_for_it(tmp_path):
    """Anthropic will use its whole max_tokens, so reserving less than it is
    allowed to send makes a full reply twice the size the budget planned for."""
    core = _remote_core(tmp_path, base_url="https://api.anthropic.com/v1")
    core.config["published_context_window"] = 200_000
    core.refresh_context_limit()

    options = core.chat_options()

    assert core.context_limit == 200_000
    assert options == {"max_tokens": core._reply_room()}
    assert options["max_tokens"] == 8_192, "the cap Anthropic is given, not 4096"
    assert "num_ctx" not in options, "meaningless in an OpenAI-style body"


def test_a_pinned_window_that_spills_to_the_cpu_is_backed_off(tmp_path):
    """Asking for a large window costs KV cache, and past a point Ollama keeps
    the model loaded by leaving layers on the CPU — silently, and several times
    slower. Predicting that from GGUF metadata does not work: a hybrid
    attention/SSM model publishes no head_count_kv, and does not pay per-token KV
    on every layer when it does. So it is measured after the fact."""
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.client.trained_window = 262_144
    core.client.loaded_window = 32_768
    core.client.resident_size = 20_000_000_000
    core.client.resident_size_vram = 12_000_000_000  # 60% on the GPU
    events: list[dict] = []
    core.on_event(events.append)

    core.run_turn("hi")

    key = f"{core.host}|test-model"
    assert core.config["model_window_caps"][key] == 16_384, "halved, and remembered"
    assert core.context_limit == 16_384, "and applied straight away"
    notes = [e for e in events if e["type"] == "note" and "GPU" in e.get("text", "")]
    assert len(notes) == 1 and "16,384" in notes[0]["text"]


def test_a_window_that_fits_is_left_alone(tmp_path):
    """The other half: a model fully resident on the GPU must not be nudged
    downwards every turn."""
    core = _core(tmp_path, [ChatResponse(content_parts=["answer"], done=True)])
    core.client.trained_window = 262_144
    core.client.loaded_window = 32_768
    core.client.resident_size = 20_000_000_000
    core.client.resident_size_vram = 20_000_000_000

    core.run_turn("hi")

    assert core.config["model_window_caps"] == {}
    assert core.context_limit == 32_768


def test_a_measured_cap_survives_into_the_next_session(tmp_path):
    """A machine that could not hold 32k yesterday cannot hold it today, so the
    reduced ceiling has to outlive the process that measured it — otherwise every
    launch spills once before backing off again."""
    core = _core(tmp_path, [])
    core.remember_window_cap("test-model", 16_384)

    revived = AgentCore(cwd=str(tmp_path), config=dict(core.config))
    revived.model = "test-model"
    revived.client = FakeClient([])
    revived.client.trained_window = 262_144
    revived.refresh_context_limit()

    assert revived.context_limit == 16_384
    assert revived.chat_options() == {"num_ctx": 16_384}


def test_remote_reasoning_state_is_preserved_for_the_next_request(tmp_path):
    core = _core(tmp_path, [
        ChatResponse(
            content_parts=["answer"],
            thinking_parts=["provider-required state"],
            done=True,
        ),
    ])
    core.provider = "remote"

    core.run_turn("hi")

    assistant = next(
        message for message in reversed(core.messages)
        if message.get("role") == "assistant"
    )
    assert assistant["reasoning_content"] == "provider-required state"
    assert core.approx_tokens() >= len("provider-required state") // 4


def test_a_known_ceiling_is_pinned_before_anything_is_resident(tmp_path):
    """A pin is not a guess, so it does not have to wait for the model to load.

    This is the other half of the rule below: with a ceiling published by the
    GGUF there is something real to ask for, and asking early is what stops the
    meter being blank and compaction being off for the whole first turn.
    """
    core = _core(tmp_path, [])
    core.client.trained_window = 262_144
    core.client.loaded_window = 0

    core.refresh_context_limit()

    assert core.context_limit == 32_768
    assert core.chat_options() == {"num_ctx": 32_768}
    assert core._context_source == "pinned"


def test_an_unknown_window_is_left_unknown(tmp_path, monkeypatch):
    """A model that is not loaded, or an Ollama that did not answer, must not
    turn into a confident number the GUI then meters against.

    With no ceiling from `/api/show` and nothing resident on `/api/ps`, there is
    nothing to pin to and nothing to measure — so the honest answer is still no
    answer, and compaction stays off rather than budgeting against a number
    somebody made up.
    """
    core = _core(tmp_path, [])
    monkeypatch.setattr(core.client, "context_length", lambda name: 0)
    core.client.trained_window = 0
    core.client.loaded_window = 0

    core.refresh_context_limit()

    assert core.context_limit == 0
    assert core.chat_options() is None
    assert core._context_source == "unknown"


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

    assert core.context_limit == 32_768, "treated as not configured at all"
    # It still asks for a window — just never the nonsensical one. `num_ctx: 32`
    # would truncate every request and point at nothing.
    assert core.chat_options() == {"num_ctx": 32_768}
    assert core._context_source != "configured"


def test_a_window_written_in_thousands_is_refused_over_http(client):
    response = client.post("/api/config", json={"context_window": 32})

    assert response.status_code == 422
    assert "at least" in response.json()["detail"]
    # 0 stays legal — it is how you ask Ollama to size the window.
    assert client.post("/api/config", json={"context_window": 0}).status_code == 200


def test_an_unusable_iteration_limit_falls_back_to_the_default(tmp_path):
    """0 must not mean `range(0)`, and a negative must not mean `range(-1)`.

    A real config carried `max_iterations: 5` for a week after a test run
    clobbered it, and nothing in the app could say so — hence both the clamp and
    the ceiling.
    """
    from ollama_code.config import DEFAULTS, MAX_ITERATIONS_CEILING, iteration_limit

    default = DEFAULTS["max_iterations"]
    for unusable in (0, -1, -40, None, "", "abc", {}, [], float("inf"), float("nan")):
        assert iteration_limit(unusable) == default, unusable
    assert iteration_limit(2) == 2, "a deliberately small limit is honoured"
    assert iteration_limit("7") == 7, "a hand-edited string number still works"
    assert iteration_limit(10_000) == MAX_ITERATIONS_CEILING, "a hang is not a feature"

    core = AgentCore(cwd=str(tmp_path), config={"model": "m", "max_iterations": -1})
    assert core.max_iterations == default


def test_a_hand_edited_iteration_limit_cannot_take_the_agent_down(tmp_path):
    """The bug that mattered: a non-numeric value raised inside the constructor,
    so the agent did not start and the app reported only that it could not reach
    the backend."""
    from ollama_code.config import DEFAULTS, load_config, save_config

    for bad in ("nonsense", float("inf"), {}, None):
        core = AgentCore(cwd=str(tmp_path), config={"model": "m", "max_iterations": bad})
        assert core.max_iterations == DEFAULTS["max_iterations"]

    save_config({"max_iterations": "nonsense"})
    assert load_config()["max_iterations"] == DEFAULTS["max_iterations"]


def test_the_iteration_limit_is_writable_over_http(client):
    """Reported since forever, settable only by hand-editing a file the app never
    shows — which is why a clobbered value survived so long."""
    service = client.app.state.service

    assert client.post("/api/config", json={"max_iterations": 7}).status_code == 200
    assert service.core.max_iterations == 7
    assert service.core.config["max_iterations"] == 7
    assert client.get("/api/config").json()["session_info"]["max_iterations"] == 7

    for refused in (0, -1, 5_000):
        response = client.post("/api/config", json={"max_iterations": refused})
        assert response.status_code == 422, refused
        assert "between 1 and" in response.json()["detail"]
    assert service.core.max_iterations == 7, "a refused value must not be applied"


def test_a_hand_edited_window_cannot_take_the_agent_down(tmp_path):
    core = _core(tmp_path, [])
    core.client.loaded_window = 16_384
    # `1e999` is valid JSON and parses to float('inf'); int(inf) raises
    # OverflowError, which would kill the service before the user could reach
    # the setting to correct it.
    for bad in ("sixty-four thousand", None, -1, {}, float("inf"), float("nan")):
        core.config["context_window"] = bad
        core.refresh_context_limit()  # must not raise
        # Garbage is treated as "not configured", which now means the window is
        # pinned from the model's own ceiling rather than left at whatever Ollama
        # happened to load. The point of the test is that none of these values
        # reaches the runtime as a window.
        assert core.context_limit == 32_768
        assert core._context_source == "pinned"


def test_compaction_leaves_room_for_the_schemas_and_the_reply(tmp_path):
    from ollama_code.core import (
        ESTIMATE_OPTIMISM,
        RESERVED_REPLY_TOKENS,
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
    request_overhead = (
        core.tool_registry.schema_tokens() + core._extension_prompt_tokens()
    )
    budget = int(
        (core.context_limit - request_overhead - RESERVED_REPLY_TOKENS)
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
    # A model whose ceiling *is* 8k, so the pin cannot raise the window and the
    # turn really does have to out-read it.
    core.client.trained_window = 8_192
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

    # Both calls, not just the second: the window is pinned from the model's
    # ceiling before the first request, so nothing is budgeted against zero.
    assert client.seen_limits == [32_768, 32_768]


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
    from ollama_code.core import AgentCore

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
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.model = "qwen3:8b"

    # No published ceiling, so there is nothing to pin against and a remembered
    # measurement is the only number there can be — which is exactly the case
    # this test is about.
    class Resident:
        def loaded_context_length(self, _model): return 8192
        def context_length(self, _model): return 0

    class Evicted:
        def loaded_context_length(self, _model): return 0
        def context_length(self, _model): return 0

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
    reinstate exactly the over-reporting effective_context_length prevents.

    A pinned window is a request, not an observation, so it may be budgeted
    against but must never be recorded as one. Otherwise the next session reads
    it back as `remembered`, which claims something was measured that never was.
    """
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.model = "qwen3:8b"

    class NeverLoaded:
        def loaded_context_length(self, _model): return 0
        def context_length(self, _model): return 262144

    core.client = NeverLoaded()
    core.refresh_context_limit()
    assert core.config["model_windows"] == {}, "nothing was measured"
    assert core.context_limit == 32_768, "pinned from the ceiling"
    assert core._context_source == "pinned", "and never reported as measured"


def test_corrupt_remembered_windows_are_dropped_not_trusted(tmp_path, monkeypatch):
    from ollama_code import config as config_mod

    path = tmp_path / "config.json"
    path.write_text(json.dumps({
        "host": "http://localhost:11434",
        "model_windows": {"good": 8192, "negative": -1, "text": "lots", "zero": 0},
    }))
    monkeypatch.setattr(config_mod, "CONFIG_PATH", path)
    # Only the usable entry survives; it is also re-keyed onto the host, which
    # is what the pre-host-scoping migration does.
    assert config_mod.load_config()["model_windows"] == {
        "http://localhost:11434|good": 8192
    }

    path.write_text(json.dumps({"model_windows": "not a mapping"}))
    assert config_mod.load_config()["model_windows"] == {}


def test_one_agent_does_not_leak_its_windows_into_another(tmp_path, monkeypatch):
    """DEFAULTS holds a real dict and configs are built by shallow-copying it,
    so mutating that mapping in place would share one session's measurements
    with every other core in the process."""
    from ollama_code.config import DEFAULTS
    from ollama_code.core import AgentCore


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
    from ollama_code.core import AgentCore

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
    from ollama_code.core import AgentCore


    # Ceiling unknown on purpose: with one published, each host would pin its own
    # window and the question of whose measurement got reused could not arise.
    class Serving:
        def __init__(self, window): self.window = window
        def loaded_context_length(self, _m): return self.window
        def context_length(self, _m): return 0

    class Evicted:
        def loaded_context_length(self, _m): return 0
        def context_length(self, _m): return 0

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


def test_a_new_model_does_not_inherit_the_previous_models_window(tmp_path, monkeypatch):
    """The never-downgrade rule is scoped to the model, not the process.

    Without that, picking a different model in the header kept the previous
    one's number: a 4K model reads ~12% at ~96% of its real window and budgets
    compaction against a window that does not exist.
    """
    from ollama_code.core import AgentCore


    class Ollama:
        def __init__(self): self.resident = {"model-a": 32768}
        def loaded_context_length(self, model): return self.resident.get(model, 0)
        # A publishes no ceiling, so its window can only be measured; B publishes
        # a 4K one. The distinction is the test: B must read as the small model it
        # is, not inherit the number measured for A.
        def context_length(self, model): return 4096 if model == "model-b" else 0

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})
    core.client = Ollama()

    core.model = "model-a"
    core.refresh_context_limit()
    assert core.context_limit == 32768

    core.model = "model-b"
    core.refresh_context_limit()
    assert core.context_limit == 4096, "model B inherited model A's window"

    # The guard it must not have broken: an evicted model keeps what was
    # measured for it, so compaction does not quietly switch off.
    core.model = "model-a"
    core.client.resident = {}
    core.refresh_context_limit()
    assert core.context_limit == 32768, "an evicted model lost its own window"


def test_a_hosted_account_can_finally_have_a_window(tmp_path, monkeypatch):
    """A hosted endpoint advertises no window, so before this the meter was
    dead and auto-compaction never engaged for any account."""
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})

    core.use_remote("https://api.anthropic.com/v1", api_key="k", model="claude-sonnet-4-5")
    assert core.context_limit == 0, "no window set yet"

    core.use_remote(
        "https://api.anthropic.com/v1", model="claude-sonnet-4-5",
        context_window_tokens=200_000,
    )
    assert core.context_limit == 200_000
    assert core.session_info()["context_limit"] == 200_000


def test_a_window_below_the_floor_is_refused_not_quietly_honoured(tmp_path, monkeypatch):
    """Below the floor it cannot hold the system prompt and the tool schemas,
    so honouring it would truncate every request with nothing to point at."""
    import pytest as _pytest

    from ollama_code.config import MINIMUM_CONTEXT_WINDOW
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama"})

    with _pytest.raises(ValueError, match=str(MINIMUM_CONTEXT_WINDOW)):
        core.apply_context_window(500)

    core.apply_context_window(0)          # clearing is always allowed
    assert core.config["context_window"] == 0
    core.apply_context_window(None)       # "not specified" leaves it alone
    assert core.config["context_window"] == 0
    core.apply_context_window(8192)
    assert core.config["context_window"] == 8192


def test_a_configured_window_lets_compaction_engage_on_a_hosted_account(tmp_path, monkeypatch):
    from ollama_code.core import AgentCore

    core = AgentCore(cwd=str(tmp_path), config={"provider": "ollama", "auto_compact": True})
    core.use_remote("https://api.openai.com/v1", api_key="k", model="gpt-5")

    # No window: the budget check bails out before looking at anything.
    core.messages = [core.system_message()] + [
        {"role": "user", "content": "x" * 40_000} for _ in range(20)
    ]
    assert core.context_limit == 0
    assert core._over_budget() is False

    core.use_remote("https://api.openai.com/v1", context_window_tokens=8192)
    assert core.context_limit == 8192
    assert core._over_budget() is True, "a window was set; compaction must see it"


def test_windows_measured_before_host_scoping_are_kept_not_discarded(tmp_path, monkeypatch):
    """Re-key rather than drop: those were real measurements against the host
    in this same config, and discarding them blanks the meter until the model
    happens to be resident again."""
    import json as _json

    from ollama_code import config as config_mod

    path = tmp_path / "config.json"
    path.write_text(_json.dumps({
        "host": "http://192.168.50.99:11434",
        "model_windows": {
            "qwen3:8b": 8192,                                  # old bare key
            "http://192.168.50.99:11434|already-scoped": 4096,  # current shape
        },
    }))
    monkeypatch.setattr(config_mod, "CONFIG_PATH", path)

    windows = config_mod.load_config()["model_windows"]
    assert windows["http://192.168.50.99:11434|qwen3:8b"] == 8192
    assert windows["http://192.168.50.99:11434|already-scoped"] == 4096
    assert "qwen3:8b" not in windows, "the bare key should have been migrated"
