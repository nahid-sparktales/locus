"""Codex ``apply_patch`` envelope support for the ChatGPT parity tool suite.

Codex-tuned models edit files through a ``*** Begin Patch`` envelope rather
than Locus's write/edit tools. This module parses that envelope and applies it
with the same matching rules as the vendored ``codex-rs/apply-patch`` crate
(pinned at the App Server version Locus ships), so a patch the model was
trained to emit lands the same way here as it would under native Codex:
context located by decreasing strictness (exact, then trailing-whitespace,
then fully trimmed, then Unicode-punctuation-normalised), one replacement per
``@@`` chunk, and files always written with a trailing newline.

Everything is resolved in memory first and written only when every hunk
matched, so a patch either applies completely or leaves the tree untouched.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover - import cycle guard for typing only
    from .tools import ToolContext

BEGIN_MARKER = "*** Begin Patch"
END_MARKER = "*** End Patch"
ADD_MARKER = "*** Add File: "
DELETE_MARKER = "*** Delete File: "
UPDATE_MARKER = "*** Update File: "
MOVE_MARKER = "*** Move to: "
EOF_MARKER = "*** End of File"
ENVIRONMENT_MARKER = "*** Environment ID: "

MAX_PATCH_CHARS = 2_000_000


class PatchError(ValueError):
    """A malformed envelope or a hunk that does not match the file."""


@dataclass
class _Chunk:
    context: str | None = None
    old_lines: list[str] = field(default_factory=list)
    new_lines: list[str] = field(default_factory=list)
    is_end_of_file: bool = False

    @property
    def is_empty(self) -> bool:
        return not self.old_lines and not self.new_lines


@dataclass
class _AddHunk:
    path: str
    contents: str


@dataclass
class _DeleteHunk:
    path: str


@dataclass
class _UpdateHunk:
    path: str
    move_path: str | None = None
    chunks: list[_Chunk] = field(default_factory=list)


_Hunk = _AddHunk | _DeleteHunk | _UpdateHunk


def _strip_heredoc(text: str) -> str:
    """Unwrap the ``<<'EOF' … EOF`` framing some models emit around a patch."""
    stripped = text.strip()
    for opener in ("<<'EOF'", '<<"EOF"', "<<EOF"):
        if stripped.startswith(opener) and stripped.endswith("EOF"):
            return stripped[len(opener):-len("EOF")].strip()
    return stripped


def parse_patch(text: str) -> list[_Hunk]:
    """Parse an envelope into hunks, mirroring the pinned crate's grammar."""
    if len(text) > MAX_PATCH_CHARS:
        raise PatchError("patch exceeds the size limit")
    lines = _strip_heredoc(text).split("\n")
    if not lines or lines[0].strip() != BEGIN_MARKER:
        raise PatchError(f"patch must start with '{BEGIN_MARKER}'")
    if lines[-1].strip() == "":
        lines = lines[:-1]
    if not lines or lines[-1].strip() != END_MARKER:
        raise PatchError(f"patch must end with '{END_MARKER}'")
    body = lines[1:-1]
    if body and body[0].startswith(ENVIRONMENT_MARKER):
        body = body[1:]

    hunks: list[_Hunk] = []
    index = 0
    while index < len(body):
        line = body[index]
        marker = line.strip()
        if marker.startswith(ADD_MARKER):
            path = marker[len(ADD_MARKER):].strip()
            if not path:
                raise PatchError("Add File hunk is missing a path")
            contents: list[str] = []
            index += 1
            while index < len(body) and not body[index].strip().startswith("*** "):
                content_line = body[index]
                if not content_line.startswith("+"):
                    raise PatchError(
                        f"Add File lines must start with '+', got: {content_line!r}"
                    )
                contents.append(content_line[1:])
                index += 1
            hunks.append(_AddHunk(path=path, contents="\n".join(contents) + "\n"))
            continue
        if marker.startswith(DELETE_MARKER):
            path = marker[len(DELETE_MARKER):].strip()
            if not path:
                raise PatchError("Delete File hunk is missing a path")
            hunks.append(_DeleteHunk(path=path))
            index += 1
            continue
        if marker.startswith(UPDATE_MARKER):
            path = marker[len(UPDATE_MARKER):].strip()
            if not path:
                raise PatchError("Update File hunk is missing a path")
            hunk = _UpdateHunk(path=path)
            index += 1
            if index < len(body) and body[index].strip().startswith(MOVE_MARKER):
                hunk.move_path = body[index].strip()[len(MOVE_MARKER):].strip()
                index += 1
            index = _parse_update_body(body, index, hunk)
            if not hunk.chunks or all(chunk.is_empty for chunk in hunk.chunks):
                raise PatchError(f"Update File hunk for {path} contains no changes")
            hunks.append(hunk)
            continue
        raise PatchError(f"unexpected line in patch: {line!r}")
    if not hunks:
        raise PatchError("patch contains no hunks")
    return hunks


def _parse_update_body(body: list[str], index: int, hunk: _UpdateHunk) -> int:
    """Consume one update hunk's chunk lines; returns the next unread index."""
    chunks = hunk.chunks
    while index < len(body):
        raw = body[index]
        line = raw.rstrip()
        if line.strip().startswith("*** ") and line.strip() != EOF_MARKER:
            return index
        if chunks and chunks[-1].is_end_of_file:
            # After an end-of-file chunk only blank lines or a new @@ chunk
            # may follow, exactly as the pinned parser enforces.
            if not line:
                index += 1
                continue
            if line != "@@" and not line.startswith("@@ "):
                raise PatchError(
                    f"expected a @@ context marker after End of File, got: {raw!r}"
                )
        if line == "@@" or line.startswith("@@ "):
            if chunks and chunks[-1].is_empty:
                raise PatchError(f"unexpected empty chunk before: {raw!r}")
            context = line[3:] if line.startswith("@@ ") else None
            chunks.append(_Chunk(context=context))
            index += 1
            continue
        if line.strip() == EOF_MARKER:
            if not chunks or chunks[-1].is_empty:
                raise PatchError("update hunk does not contain any lines")
            chunks[-1].is_end_of_file = True
            index += 1
            continue
        if raw == "":
            if not chunks:
                chunks.append(_Chunk())
            chunks[-1].old_lines.append("")
            chunks[-1].new_lines.append("")
            index += 1
            continue
        prefix, rest = raw[0], raw[1:]
        if prefix == " ":
            if not chunks:
                chunks.append(_Chunk())
            chunks[-1].old_lines.append(rest)
            chunks[-1].new_lines.append(rest)
        elif prefix == "+":
            if not chunks:
                chunks.append(_Chunk())
            chunks[-1].new_lines.append(rest)
        elif prefix == "-":
            if not chunks:
                chunks.append(_Chunk())
            chunks[-1].old_lines.append(rest)
        else:
            raise PatchError(
                f"unexpected line in update hunk: {raw!r}. Every line should start "
                "with ' ' (context line), '+' (added line), or '-' (removed line)"
            )
        index += 1
    return index


def _normalise(line: str) -> str:
    """ASCII-fold the punctuation the crate's most permissive pass tolerates."""
    table = {
        0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2013: "-", 0x2014: "-",
        0x2015: "-", 0x2212: "-",
        0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'",
        0x201C: '"', 0x201D: '"', 0x201E: '"', 0x201F: '"',
        0x00A0: " ", 0x2002: " ", 0x2003: " ", 0x2004: " ", 0x2005: " ",
        0x2006: " ", 0x2007: " ", 0x2008: " ", 0x2009: " ", 0x200A: " ",
        0x202F: " ", 0x205F: " ", 0x3000: " ",
    }
    return line.strip().translate(table)


def _seek_sequence(
    lines: list[str],
    pattern: list[str],
    start: int,
    eof: bool,
) -> int | None:
    """Find ``pattern`` in ``lines`` with the crate's decreasing strictness."""
    if not pattern:
        return start
    if len(pattern) > len(lines):
        return None
    search_start = len(lines) - len(pattern) if eof else start
    last = len(lines) - len(pattern)
    passes = (
        lambda a, b: a == b,
        lambda a, b: a.rstrip() == b.rstrip(),
        lambda a, b: a.strip() == b.strip(),
        lambda a, b: _normalise(a) == _normalise(b),
    )
    for matches in passes:
        for i in range(search_start, last + 1):
            if all(matches(lines[i + j], pattern[j]) for j in range(len(pattern))):
                return i
    return None


def _compute_replacements(
    original: list[str],
    path: str,
    chunks: list[_Chunk],
) -> list[tuple[int, int, list[str]]]:
    replacements: list[tuple[int, int, list[str]]] = []
    line_index = 0
    for chunk in chunks:
        if chunk.context is not None:
            found = _seek_sequence(original, [chunk.context], line_index, False)
            if found is None:
                raise PatchError(f"Failed to find context '{chunk.context}' in {path}")
            line_index = found + 1
        if not chunk.old_lines:
            # Pure addition: appended at the end, before a final blank line
            # when one exists.
            insertion = len(original) - 1 if original and original[-1] == "" else len(original)
            replacements.append((insertion, 0, list(chunk.new_lines)))
            continue
        pattern = list(chunk.old_lines)
        new_lines = list(chunk.new_lines)
        found = _seek_sequence(original, pattern, line_index, chunk.is_end_of_file)
        if found is None and pattern and pattern[-1] == "":
            # A trailing empty pattern line stands for the file's final
            # newline, which the line list does not carry — retry without it.
            pattern = pattern[:-1]
            if new_lines and new_lines[-1] == "":
                new_lines = new_lines[:-1]
            found = _seek_sequence(original, pattern, line_index, chunk.is_end_of_file)
        if found is None:
            joined = "\n".join(chunk.old_lines)
            raise PatchError(f"Failed to find expected lines in {path}:\n{joined}")
        replacements.append((found, len(pattern), new_lines))
        line_index = found + len(pattern)
    replacements.sort(key=lambda item: item[0])
    return replacements


def updated_contents(contents: str, path: str, chunks: list[_Chunk]) -> str:
    """The file's new text after applying one update hunk's chunks."""
    lines = contents.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    for start, old_len, new_segment in reversed(
        _compute_replacements(lines, path, chunks)
    ):
        lines[start:start + old_len] = new_segment
    if not lines or lines[-1] != "":
        lines.append("")
    return "\n".join(lines)


def apply_patch(text: str, ctx: ToolContext) -> str:
    """Parse and apply one envelope inside the workspace guards.

    Returns the crate's success summary ("A/M/D path" lines) or raises
    ``PatchError`` before anything is written.
    """
    from .tools import MAX_TEXT_FILE_BYTES, _atomic_write_text, _workspace_write_root

    hunks = parse_patch(text)

    def guarded(path_text: str, *, must_exist: bool) -> Path:
        resolved = ctx.resolve(path_text)
        if link := ctx.symlink_component(resolved):
            raise PatchError(f"{path_text} passes through a symlink at {link}")
        if must_exist and not resolved.is_file():
            raise PatchError(f"file not found: {path_text}")
        return resolved

    # Resolve every hunk in memory first; the write phase below starts only
    # after the whole patch is known to apply. Operations keep hunk order so a
    # patch that deletes and re-adds the same path lands the way it reads.
    operations: list[tuple[str, Path, str]] = []
    summary: list[str] = []
    for hunk in hunks:
        if isinstance(hunk, _AddHunk):
            resolved = guarded(hunk.path, must_exist=False)
            if resolved.exists() and not any(
                kind == "delete" and target == resolved for kind, target, _ in operations
            ):
                raise PatchError(f"file already exists: {hunk.path}")
            operations.append(("write", resolved, hunk.contents))
            summary.append(f"A {hunk.path}")
        elif isinstance(hunk, _DeleteHunk):
            operations.append(("delete", guarded(hunk.path, must_exist=True), ""))
            summary.append(f"D {hunk.path}")
        else:
            source = guarded(hunk.path, must_exist=True)
            if source.stat().st_size > MAX_TEXT_FILE_BYTES:
                raise PatchError(f"{hunk.path} is larger than the text-edit limit")
            raw = source.read_bytes()
            if b"\0" in raw[:4096]:
                raise PatchError(f"{hunk.path} looks like a binary file")
            new_text = updated_contents(
                raw.decode("utf-8", errors="replace"), hunk.path, hunk.chunks
            )
            if hunk.move_path:
                destination = guarded(hunk.move_path, must_exist=False)
                operations.append(("write", destination, new_text))
                operations.append(("delete", source, ""))
                summary.append(f"M {hunk.move_path}")
            else:
                operations.append(("write", source, new_text))
                summary.append(f"M {hunk.path}")

    for kind, resolved, contents in operations:
        if kind == "write":
            _atomic_write_text(resolved, contents, _workspace_write_root(ctx, resolved))
        else:
            os.unlink(resolved)
    return "Success. Updated the following files:\n" + "\n".join(summary)


def changed_paths(text: str) -> list[tuple[str, str]]:
    """(marker, path) pairs for a permission preview; parse errors return []."""
    try:
        hunks = parse_patch(text)
    except PatchError:
        return []
    pairs: list[tuple[str, str]] = []
    for hunk in hunks:
        if isinstance(hunk, _AddHunk):
            pairs.append(("A", hunk.path))
        elif isinstance(hunk, _DeleteHunk):
            pairs.append(("D", hunk.path))
        else:
            pairs.append(("M", hunk.move_path or hunk.path))
    return pairs
