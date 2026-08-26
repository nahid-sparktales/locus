"""Tests for the Codex ``apply_patch`` envelope parser and applier."""
from __future__ import annotations

from pathlib import Path

import pytest

from ollama_code import codex_patch
from ollama_code.codex_patch import PatchError, apply_patch, changed_paths, parse_patch
from ollama_code.tools import ToolContext, execute_tool


def _ctx(tmp_path: Path) -> ToolContext:
    return ToolContext(cwd=str(tmp_path))


def _envelope(*lines: str) -> str:
    return "\n".join(["*** Begin Patch", *lines, "*** End Patch"])


def test_add_update_delete_and_move(tmp_path: Path) -> None:
    (tmp_path / "app.py").write_text("def greet():\n    print(\"Hi\")\n")
    (tmp_path / "obsolete.txt").write_text("gone\n")
    patch = _envelope(
        "*** Add File: hello.txt",
        "+Hello world",
        "*** Update File: app.py",
        "*** Move to: main.py",
        "@@ def greet():",
        '-    print("Hi")',
        '+    print("Hello, world!")',
        "*** Delete File: obsolete.txt",
    )
    result = apply_patch(patch, _ctx(tmp_path))
    assert result.startswith("Success. Updated the following files:")
    assert "A hello.txt" in result
    assert "M main.py" in result
    assert "D obsolete.txt" in result
    assert (tmp_path / "hello.txt").read_text() == "Hello world\n"
    assert not (tmp_path / "app.py").exists()
    assert (tmp_path / "main.py").read_text() == 'def greet():\n    print("Hello, world!")\n'
    assert not (tmp_path / "obsolete.txt").exists()


def test_multi_chunk_update_with_context_anchors(tmp_path: Path) -> None:
    (tmp_path / "code.py").write_text(
        "class A:\n    def one(self):\n        return 1\n\n"
        "class B:\n    def one(self):\n        return 1\n"
    )
    patch = _envelope(
        "*** Update File: code.py",
        "@@ class B:",
        "     def one(self):",
        "-        return 1",
        "+        return 2",
    )
    apply_patch(patch, _ctx(tmp_path))
    text = (tmp_path / "code.py").read_text()
    assert text.count("return 1") == 1
    assert "return 2" in text
    # The chunk after the anchor changed class B, not class A.
    assert text.index("return 2") > text.index("class B")


def test_whitespace_tolerant_matching(tmp_path: Path) -> None:
    (tmp_path / "w.txt").write_text("  alpha   \n  beta\n")
    patch = _envelope(
        "*** Update File: w.txt",
        "@@",
        "-alpha",
        "+gamma",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "w.txt").read_text() == "gamma\n  beta\n"


def test_unicode_punctuation_normalised_match(tmp_path: Path) -> None:
    (tmp_path / "u.txt").write_text("a \u2014 dash\nplain\n")
    patch = _envelope(
        "*** Update File: u.txt",
        "@@",
        "-a - dash",
        "+a plain dash",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "u.txt").read_text() == "a plain dash\nplain\n"


def test_pure_addition_appends_at_end(tmp_path: Path) -> None:
    (tmp_path / "list.txt").write_text("one\ntwo\n")
    patch = _envelope(
        "*** Update File: list.txt",
        "@@",
        "+three",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "list.txt").read_text() == "one\ntwo\nthree\n"


def test_end_of_file_chunk_applies_at_the_end(tmp_path: Path) -> None:
    (tmp_path / "dup.txt").write_text("x\nmiddle\nx\n")
    patch = _envelope(
        "*** Update File: dup.txt",
        "@@",
        "-x",
        "+y",
        "*** End of File",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "dup.txt").read_text() == "x\nmiddle\ny\n"


def test_unmatched_context_fails_and_leaves_files_untouched(tmp_path: Path) -> None:
    (tmp_path / "a.txt").write_text("alpha\n")
    (tmp_path / "b.txt").write_text("beta\n")
    patch = _envelope(
        "*** Update File: a.txt",
        "@@",
        "-alpha",
        "+ALPHA",
        "*** Update File: b.txt",
        "@@",
        "-not present",
        "+never",
    )
    with pytest.raises(PatchError, match="Failed to find expected lines"):
        apply_patch(patch, _ctx(tmp_path))
    # All-or-nothing: the first hunk matched but nothing was written.
    assert (tmp_path / "a.txt").read_text() == "alpha\n"
    assert (tmp_path / "b.txt").read_text() == "beta\n"


def test_delete_then_re_add_same_path(tmp_path: Path) -> None:
    (tmp_path / "swap.txt").write_text("old\n")
    patch = _envelope(
        "*** Delete File: swap.txt",
        "*** Add File: swap.txt",
        "+new",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "swap.txt").read_text() == "new\n"


def test_add_existing_file_is_refused(tmp_path: Path) -> None:
    (tmp_path / "here.txt").write_text("present\n")
    patch = _envelope("*** Add File: here.txt", "+clobber")
    with pytest.raises(PatchError, match="already exists"):
        apply_patch(patch, _ctx(tmp_path))


def test_update_missing_file_is_refused(tmp_path: Path) -> None:
    patch = _envelope("*** Update File: ghost.txt", "@@", "-a", "+b")
    with pytest.raises(PatchError, match="file not found"):
        apply_patch(patch, _ctx(tmp_path))


def test_symlinked_path_is_refused(tmp_path: Path) -> None:
    outside = tmp_path.parent / "outside.txt"
    outside.write_text("secret\n")
    (tmp_path / "link.txt").symlink_to(outside)
    patch = _envelope("*** Update File: link.txt", "@@", "-secret", "+patched")
    with pytest.raises(PatchError, match="symlink"):
        apply_patch(patch, _ctx(tmp_path))
    assert outside.read_text() == "secret\n"


def test_trailing_empty_pattern_line_retries_without_it(tmp_path: Path) -> None:
    (tmp_path / "end.txt").write_text("last line\n")
    patch = _envelope(
        "*** Update File: end.txt",
        "@@",
        "-last line",
        "-",
        "+final line",
        "+",
    )
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "end.txt").read_text() == "final line\n"


def test_heredoc_wrapper_is_unwrapped() -> None:
    wrapped = "<<'EOF'\n" + _envelope("*** Add File: x.txt", "+x") + "\nEOF"
    hunks = parse_patch(wrapped)
    assert len(hunks) == 1


def test_malformed_envelopes_are_rejected() -> None:
    with pytest.raises(PatchError, match="must start"):
        parse_patch("*** Update File: x.txt")
    with pytest.raises(PatchError, match="must end"):
        parse_patch("*** Begin Patch\n*** Add File: x.txt\n+x")
    with pytest.raises(PatchError, match="no hunks"):
        parse_patch("*** Begin Patch\n*** End Patch")
    with pytest.raises(PatchError, match="start with '\\+'"):
        parse_patch(_envelope("*** Add File: x.txt", "not plus"))
    with pytest.raises(PatchError, match="unexpected line in update hunk"):
        parse_patch(_envelope("*** Update File: x.txt", "@@", "?bogus"))
    # The pinned streaming parser rejects a second @@ directly after an empty
    # chunk; mirror that exactly.
    with pytest.raises(PatchError, match="empty chunk"):
        parse_patch(_envelope("*** Update File: x.txt", "@@ one", "@@ two", "-a", "+b"))


def test_changed_paths_preview() -> None:
    patch = _envelope(
        "*** Add File: a.txt",
        "+a",
        "*** Update File: b.txt",
        "*** Move to: c.txt",
        "@@",
        "-b",
        "+c",
        "*** Delete File: d.txt",
    )
    assert changed_paths(patch) == [("A", "a.txt"), ("M", "c.txt"), ("D", "d.txt")]
    assert changed_paths("not a patch") == []


def test_apply_patch_tool_impl_and_error_shape(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ok = execute_tool(
        "apply_patch", {"input": _envelope("*** Add File: t.txt", "+t")}, ctx
    )
    assert ok.startswith("Success.")
    assert (tmp_path / "t.txt").read_text() == "t\n"
    bad = execute_tool("apply_patch", {"input": "nope"}, ctx)
    assert bad.startswith("Error:")
    empty = execute_tool("apply_patch", {}, ctx)
    assert empty.startswith("Error:")


def test_binary_and_oversize_guards(tmp_path: Path) -> None:
    (tmp_path / "bin.dat").write_bytes(b"\0\1\2")
    patch = _envelope("*** Update File: bin.dat", "@@", "-a", "+b")
    with pytest.raises(PatchError, match="binary"):
        apply_patch(patch, _ctx(tmp_path))


def test_patch_size_limit() -> None:
    with pytest.raises(PatchError, match="size limit"):
        parse_patch("x" * (codex_patch.MAX_PATCH_CHARS + 1))


def test_empty_file_update(tmp_path: Path) -> None:
    (tmp_path / "empty.txt").write_text("")
    patch = _envelope("*** Update File: empty.txt", "@@", "+first")
    apply_patch(patch, _ctx(tmp_path))
    assert (tmp_path / "empty.txt").read_text() == "first\n"
