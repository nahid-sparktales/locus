import json

import pytest

from ollama_code.core import AgentCore
from ollama_code.ollama import ToolCall
from ollama_code.sessions import SessionMeta, SessionStore
from ollama_code.tools import ToolContext, execute_tool


def saved_chat(workspace, text, **metadata):
    session = SessionStore(str(workspace))
    session.append({"type": "message", "message": {"role": "user", "content": text}})
    SessionMeta.update(session.session_id, **metadata)
    return session


def read_tool(name, arguments, context=None):
    result = execute_tool(name, arguments, context or ToolContext())
    assert not result.startswith("Error:"), result
    return json.loads(result)


def test_search_and_read_find_archived_other_agent_chat_across_workspaces(tmp_path):
    first = saved_chat(tmp_path / "one", "Please generate an image of an amber lighthouse", title="Illustration", archived=True,
                       agent_profile_id="artist", agent_name="Artist")
    first.append({"type": "message", "message": {"role": "assistant", "content": "Created amber-lighthouse.png using the image tool."}})
    second = saved_chat(tmp_path / "two", "Can you inspect this calendar?", title="Calendar")
    context = ToolContext(cwd=str(tmp_path / "two"), memory_session_id=second.session_id)
    search = read_tool("search_locus_chats", {"query": "lighthouse"}, context)
    assert search["untrusted_context"] is True
    assert search["indexing"] is False
    assert {hit["session_id"] for hit in search["results"]} == {first.session_id}
    hit = search["results"][0]
    read = read_tool("read_locus_chat", {"session_id": hit["session_id"], "start_message": hit["message_index"]}, context)
    assert "lighthouse" in read["messages"][0]["content"]
    assert read["archived"] is True
    assert read["workspace"] == str(tmp_path / "one")
    assert read["agent_name"] == "Artist"
    assert context.memory_session_id == second.session_id
    chats = read_tool("list_locus_chats", {}, context)
    assert {item["id"] for item in chats["chats"]} == {first.session_id, second.session_id}
    active = read_tool("list_locus_chats", {"include_archived": False}, context)
    assert [item["id"] for item in active["chats"]] == [second.session_id]


def test_long_message_is_bounded_and_continues_without_losing_text(tmp_path):
    content = "lighthouse " * 6000
    session = saved_chat(tmp_path, content)
    session.append({"type": "message", "message": {"role": "tool", "name": "image_tool", "content": "tool evidence"}})
    session.append({"type": "message", "message": {"role": "assistant", "content": "Finished."}})
    next_message, next_offset, chunks = 0, 0, []
    while next_message is not None:
        page = read_tool("read_locus_chat", {"session_id": session.session_id,
            "start_message": next_message, "content_offset": next_offset})
        assert sum(len(item["content"]) for item in page["messages"]) <= 24_000
        chunks.extend(item["content"] for item in page["messages"] if item["message_index"] == 0)
        next_message, next_offset = page["next_message"], page["next_content_offset"]
    assert "".join(chunks) == content
    assert read_tool("read_locus_chat", {"session_id": session.session_id,
        "start_message": 1, "include_tool_results": True})["messages"][0]["content"] == "tool evidence"


def test_list_pagination_includes_every_chat_once(tmp_path):
    sessions = [saved_chat(tmp_path, f"Question {i}", title=f"Chat {i}") for i in range(3)]
    first = read_tool("list_locus_chats", {"limit": 2})
    last = read_tool("list_locus_chats", {"limit": 2, "offset": first["next_offset"]})
    assert first["total"] == 3
    assert last["next_offset"] is None
    assert {row["id"] for row in first["chats"] + last["chats"]} == {session.session_id for session in sessions}


def test_private_identity_and_trashed_chats_are_not_disclosed(tmp_path):
    private = saved_chat(tmp_path, "vault sentinel", identity_mode=True)
    visible = saved_chat(tmp_path, "visible sentinel")
    assert {row["id"] for row in read_tool("list_locus_chats", {})["chats"]} == {visible.session_id}
    assert {hit["session_id"] for hit in read_tool("search_locus_chats", {"query": "sentinel"})["results"]} == {visible.session_id}
    assert "Identity Vault" in execute_tool("read_locus_chat", {"session_id": private.session_id}, ToolContext())
    SessionStore.move_to_trash([visible.session_id])
    assert read_tool("search_locus_chats", {"query": "sentinel"})["results"] == []
    assert "not found" in execute_tool("read_locus_chat", {"session_id": visible.session_id}, ToolContext())


@pytest.mark.parametrize("name,args", [
    ("search_locus_chats", {"query": ""}), ("list_locus_chats", {"offset": -1}),
    ("list_locus_chats", {"limit": True}), ("list_locus_chats", {"include_archived": "yes"}),
    ("read_locus_chat", {"session_id": "../../secret"}),
])
def test_bad_arguments_are_rejected(name, args):
    assert execute_tool(name, args, ToolContext()).startswith("Error:")


def test_history_schemas_and_execution_respect_policy_and_capability(tmp_path, monkeypatch):
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    try:
        assert "search_locus_chats" not in {s["function"]["name"] for s in core.tool_registry.schemas()}
        core.companion_context = core.tool_registry.companion_context = True
        core.configure_agent({}, mode="ask")
        for schemas in (core.tool_registry.schemas(), core.tool_registry.parity_schemas()):
            assert {"list_locus_chats", "search_locus_chats", "read_locus_chat"} <= {s["function"]["name"] for s in schemas}
        core.configure_agent({"memory_policy": {"cross_chat_context_enabled": False}}, mode="ask")
        for schemas in (core.tool_registry.schemas(), core.tool_registry.parity_schemas()):
            assert "search_locus_chats" not in {s["function"]["name"] for s in schemas}
        assert "disabled" in execute_tool("list_locus_chats", {}, core.tool_ctx)
        core.configure_agent({}, mode="ask")
        monkeypatch.setenv("LOCUS_CAPABILITY_TRANSCRIPT_SEARCH", "0")
        assert "search_locus_chats" not in {s["function"]["name"] for s in core.tool_registry.schemas()}
        assert "disabled" in execute_tool("list_locus_chats", {}, core.tool_ctx)
    finally:
        core.mcp.close()


def test_companion_discovers_read_only_connectors_and_blocks_native_mutations(tmp_path):
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    try:
        core.companion_context = core.tool_registry.companion_context = True
        core.configure_agent({}, mode="ask")
        registry = core.tool_registry
        registry.browser_enabled = registry.notes_enabled = registry.calendar_enabled = registry.board_enabled = True
        registry._mcp_by_qualified = {
            "mcp_fixture_read": {"server_id": "fixture", "name": "read", "description": "Find a fixture",
                                 "annotations": {"readOnlyHint": True, "destructiveHint": False}},
            "mcp_fixture_write": {"server_id": "fixture", "name": "write", "description": "Update a fixture",
                                  "annotations": {"readOnlyHint": False}},
        }
        discovery = registry.execute("search_extension_tools", {"query": "fixture"}, core.tool_ctx)
        assert "mcp_fixture_read" in discovery
        assert "mcp_fixture_write" not in discovery
        names = {item["function"]["name"] for item in registry.schemas()}
        assert {"mcp_fixture_read", "notes_read", "calendar_list", "board_read", "browser_tabs"} <= names
        assert not names & {"mcp_fixture_write", "notes_update", "board_create_card", "calendar_create"}
        assert "read-only" in core._run_tool_call(ToolCall("notes_update", {"text": "replace"}), None)
        assert "cannot change" in core._run_tool_call(ToolCall("browser_tabs", {"action": "close"}), None)
        tabs = next(item for item in registry.schemas() if item["function"]["name"] == "browser_tabs")
        assert tabs["function"]["parameters"]["properties"]["action"]["enum"] == ["list"]
        registry.set_user_capability_policy({"mcp": False, "workspace_read": False})
        names = {item["function"]["name"] for item in registry.schemas()}
        assert not names & {"mcp_fixture_read", "search_extension_tools", "read_file"}
        assert "search_locus_chats" in names
    finally:
        core.mcp.close()
