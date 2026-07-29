"""Unit tests for ollama-code internals. Run: .venv/bin/python tests/test_parse.py"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ollama_code.ollama import ChatResponse, process_chunk  # noqa: E402
from ollama_code.permissions import PermissionManager, build_preview  # noqa: E402
from ollama_code.render import ThinkFilter, strip_think  # noqa: E402
from ollama_code.tools import ToolContext, execute_tool  # noqa: E402


def test_content_accumulates() -> None:
    resp = ChatResponse()
    assert process_chunk({"message": {"content": "Hel"}}, resp) == "Hel"
    assert process_chunk({"message": {"content": "lo"}}, resp) == "lo"
    process_chunk({"done": True, "done_reason": "stop", "prompt_eval_count": 3, "eval_count": 2}, resp)
    assert resp.content == "Hello"
    assert resp.done and resp.done_reason == "stop"
    assert resp.prompt_eval_count == 3 and resp.eval_count == 2


def test_tool_calls_in_late_chunk() -> None:
    resp = ChatResponse()
    process_chunk({"message": {"content": ""}}, resp)
    process_chunk(
        {
            "message": {
                "role": "assistant",
                "tool_calls": [
                    {"type": "function", "function": {"name": "bash", "arguments": {"command": "ls"}}}
                ],
            },
            "done": True,
            "done_reason": "stop",
        },
        resp,
    )
    assert len(resp.tool_calls) == 1
    assert resp.tool_calls[0].name == "bash"
    assert resp.tool_calls[0].arguments == {"command": "ls"}


def test_tool_call_arguments_as_json_string() -> None:
    resp = ChatResponse()
    process_chunk(
        {"message": {"tool_calls": [{"function": {"name": "read_file", "arguments": '{"path": "a.txt"}'}}]}},
        resp,
    )
    assert resp.tool_calls[0].arguments == {"path": "a.txt"}


def test_think_filter_streaming() -> None:
    f = ThinkFilter()
    out = ""
    for tok in ["<th", "ink>secret ", "reasoning</th", "ink>", "Hello", " world"]:
        out += f.feed(tok)
    out += f.flush()
    assert out == "Hello world", repr(out)


def test_think_filter_unclosed() -> None:
    f = ThinkFilter()
    out = f.feed("<think>never closes")
    out += f.flush()
    assert out == "", repr(out)


def test_strip_think() -> None:
    assert strip_think("<think>x</think>done") == "done"
    assert strip_think("plain") == "plain"


def test_file_tools() -> None:
    ctx = ToolContext()
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "a.txt"
        r = execute_tool("write_file", {"path": str(p), "content": "one\ntwo\n"}, ctx)
        assert "Wrote" in r, r
        r = execute_tool("read_file", {"path": str(p)}, ctx)
        assert "1\tone" in r and "2\ttwo" in r, r
        r = execute_tool("edit_file", {"path": str(p), "old_string": "two", "new_string": "TWO"}, ctx)
        assert "Edited" in r, r
        assert p.read_text() == "one\nTWO\n"
        r = execute_tool("edit_file", {"path": str(p), "old_string": "missing", "new_string": "x"}, ctx)
        assert "Error" in r
        execute_tool("write_file", {"path": str(p), "content": "dup\ndup\n"}, ctx)
        r = execute_tool("edit_file", {"path": str(p), "old_string": "dup", "new_string": "x"}, ctx)
        assert "must be unique" in r, r
        r = execute_tool("edit_file", {"path": str(p), "old_string": "dup", "new_string": "x", "replace_all": True}, ctx)
        assert "Edited" in r and p.read_text() == "x\nx\n", r
        r = execute_tool("bash", {"command": "echo hi"}, ctx)
        assert "hi" in r
        r = execute_tool("glob", {"pattern": str(Path(d) / "*.txt")}, ctx)
        assert "a.txt" in r
        r = execute_tool("grep", {"pattern": "^x$", "path": d}, ctx)
        assert "a.txt" in r and ":2:" in r, r
        r = execute_tool("list_dir", {"path": d}, ctx)
        assert "a.txt" in r
        r = execute_tool("todo_write", {"todos": [{"content": "task", "status": "pending"}]}, ctx)
        assert "1 task" in r and ctx.todos[0]["status"] == "pending", r
        r = execute_tool("nosuchtool", {}, ctx)
        assert "unknown tool" in r


def test_permissions() -> None:
    pm = PermissionManager()
    assert pm.is_auto_allowed("read_file")  # safe tool
    assert not pm.is_auto_allowed("bash")
    pm.allow_tool("bash")
    assert pm.is_auto_allowed("bash")
    pm.reset()
    assert not pm.is_auto_allowed("bash")
    pm2 = PermissionManager(skip_all=True)
    assert pm2.is_auto_allowed("write_file")
    summary, detail = build_preview("edit_file", {"path": "x", "old_string": "a\nb", "new_string": "a\nc"})
    assert "edit x" in summary and "-b" in detail and "+c" in detail


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"{len(tests)} tests passed")
