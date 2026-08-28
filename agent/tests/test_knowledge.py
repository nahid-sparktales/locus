from __future__ import annotations

import pytest

from ollama_code.knowledge import KnowledgeError, KnowledgeStore, workspace_database
from ollama_code.knowledge_runtime import knowledge_store
from ollama_code.tools import ToolContext, execute_tool


def test_explicit_workspace_knowledge_does_not_require_request_service(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    store = knowledge_store(None, str(workspace))

    assert store.root == workspace.resolve()


def test_workspace_knowledge_indexes_searches_and_cites_lines(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "alpha.py").write_text(
        "def frobnicate(value):\n    # unique semantic marker\n    return value + 1\n",
        encoding="utf-8",
    )
    store = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")
    result = store.reindex()
    assert result["document_count"] == 1
    matches = store.search("frobnicate")
    assert matches[0]["path"] == "alpha.py"
    assert matches[0]["line_start"] == 1
    assert "frobnicate" in matches[0]["snippet"]


def test_workspace_knowledge_excludes_secret_files_and_ignored_builds(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    (workspace / "build").mkdir(parents=True)
    (workspace / ".env").write_text("API_KEY=secret")
    (workspace / "server.pem").write_text("secret")
    (workspace / "build" / "generated.py").write_text("generated_marker = True")
    (workspace / "safe.md").write_text("public marker")
    store = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")
    store.reindex()
    assert store.settings()["document_count"] == 1
    assert store.search("secret") == []
    assert store.search("public")[0]["path"] == "safe.md"


def test_changed_file_update_and_delete_are_incremental(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    file = workspace / "note.txt"
    file.write_text("first marker")
    store = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")
    store.reindex()
    file.write_text("second marker")
    store.reindex(changed_paths=["note.txt"])
    assert store.search("second")[0]["path"] == "note.txt"
    assert store.search("first") == []
    file.unlink()
    store.reindex(changed_paths=["note.txt"])
    assert store.settings()["document_count"] == 0


def test_memories_require_explicit_save_and_are_workspace_scoped(tmp_path) -> None:
    one = tmp_path / "one"
    two = tmp_path / "two"
    one.mkdir()
    two.mkdir()
    first = KnowledgeStore(str(one), tmp_path / "first.sqlite3")
    second = KnowledgeStore(str(two), tmp_path / "second.sqlite3")
    memory = first.save_memory({"title": "Convention", "content": "Use tabs", "tags": ["style"]})
    assert first.search("Use tabs")[0]["kind"] == "memory"
    assert second.list_memories() == []
    assert first.delete_memory(memory["id"])
    assert first.list_memories() == []


def test_knowledge_tool_is_safe_and_formats_untrusted_evidence(tmp_path, monkeypatch) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "guide.md").write_text("release trains use canary builds")
    # The tool uses the canonical per-workspace database path.
    path = workspace_database(str(workspace))
    path.parent.mkdir(parents=True, exist_ok=True)
    KnowledgeStore(str(workspace), path).reindex()
    output = execute_tool(
        "search_workspace_knowledge", {"query": "canary"}, ToolContext(cwd=str(workspace))
    )
    assert "untrusted evidence" in output
    assert "guide.md:1-1" in output


def test_embedding_host_must_remain_local(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    store = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")

    with pytest.raises(KnowledgeError, match="only to local Ollama"):
        store.configure(embedding_model="embed", ollama_host="https://example.com")
    assert store.configure(
        embedding_model="embed", ollama_host="http://127.0.0.1:11434"
    )["embedding_model"] == "embed"


def test_configured_exclusions_are_workspace_scoped_globs(tmp_path) -> None:
    workspace = tmp_path / "workspace"
    generated = workspace / "Generated"
    generated.mkdir(parents=True)
    (generated / "secretish.txt").write_text("exclude marker")
    (workspace / "keep.txt").write_text("keep marker")
    store = KnowledgeStore(str(workspace), tmp_path / "knowledge.sqlite3")
    configured = store.configure(exclusions=["Generated/**"])

    store.reindex()

    assert configured["exclusions"] == ["Generated/**"]
    assert store.search("exclude") == []
    assert store.search("keep")[0]["path"] == "keep.txt"
