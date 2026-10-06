"""Deterministic passages with separate retrieval context and exact source ranges.

No generated summaries are evidence. ``content`` and ``parent_content`` are
unaltered source slices; ``context`` is only a bounded retrieval label. Text
line ranges are inclusive and one-based. Character ranges are half-open Python
string offsets (not byte or UTF-16 offsets). For extracted documents those
offsets are relative to ``segment_index``; their original locator is retained
and line numbers are zero because binary documents have no source-code lines.
"""
from __future__ import annotations

import ast
import bisect
import copy
import hashlib
import json
import re
from collections.abc import Iterable, Iterator
from pathlib import PurePath
from typing import Any

CHUNKER_VERSION = "locus-contextual-1"
MAX_CHUNK_CHARS = 2_400
MAX_PARENT_CHARS = 6_000
MAX_CONTEXT_CHARS = 512

_NEWLINE = re.compile(r"\r\n|\r|\n")
_BLANK_LINE = re.compile(r"(?:\r\n|\r(?!\n)|(?<!\r)\n)[ \t]*(?:\r\n|\r(?!\n)|(?<!\r)\n)")
_ATX = re.compile(r" {0,3}(#{1,6})(?:[ \t]+(.*?)|[ \t]*)$")
_SETEXT = re.compile(r" {0,3}(=+|-+)[ \t]*$")
_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})(.*)$")


def _line_starts(content: str) -> list[int]:
    return [0, *(match.end() for match in _NEWLINE.finditer(content))]


def _line_range(starts: list[int], start: int, end: int) -> tuple[int, int]:
    return bisect.bisect_right(starts, start), bisect.bisect_right(starts, end - 1)


def _context(path: str, label: str) -> str:
    # Labels are metadata, never copied into the quoted source passage.
    source = " ".join(str(path).split())[:256]
    detail = " ".join(label.split())
    return (f"{source} | {detail}" if detail else source)[:MAX_CONTEXT_CHARS]


def _windows(content: str, start: int, end: int, limit: int,
             line_starts: list[int]) -> Iterator[tuple[int, int]]:
    """Prefer paragraphs and whole lines, but always cap even a single long line."""
    while start < end:
        stop = min(start + limit, end)
        if stop < end:
            # Do not cut the two characters of a CRLF across separate chunks.
            if content[stop - 1:stop + 1] == "\r\n":
                stop -= 1
            preferred = start + limit * 3 // 4
            paragraphs = _BLANK_LINE.finditer(content, start, stop)
            paragraph_end = 0
            for match in paragraphs:
                if match.end() >= preferred:
                    paragraph_end = match.end()
            line_end = line_starts[bisect.bisect_right(line_starts, stop) - 1]
            stop = paragraph_end or (line_end if line_end > start else stop)
        yield start, stop
        start = stop


def _markdown_regions(content: str, starts: list[int]) -> list[tuple[int, int, str]]:
    headings: list[tuple[int, str]] = []
    boundaries: list[tuple[int, str]] = [(0, "")]
    fence_char = ""
    fence_size = 0
    previous_plain = False
    previous_text = ""
    for number, start in enumerate(starts):
        stop = starts[number + 1] if number + 1 < len(starts) else len(content)
        line = content[start:stop].rstrip("\r\n")
        fence = _FENCE.fullmatch(line)
        if fence_char:
            if (fence and fence.group(1)[0] == fence_char
                    and len(fence.group(1)) >= fence_size and not fence.group(2).strip()):
                fence_char = ""
            previous_plain = False
            continue
        if fence:
            fence_char, fence_size = fence.group(1)[0], len(fence.group(1))
            previous_plain = False
            continue
        heading = _ATX.fullmatch(line)
        setext = _SETEXT.fullmatch(line) if previous_plain else None
        if heading:
            level = len(heading.group(1))
            title = re.sub(r"[ \t]+#+[ \t]*$", "", heading.group(2) or "").strip()
            heading_start = start
        elif setext:
            level = 1 if setext.group(1)[0] == "=" else 2
            title = previous_text.strip()
            heading_start = starts[number - 1]
        else:
            previous_plain = bool(line.strip()) and not line.startswith(("    ", "\t", ">", "- ", "* ", "+ "))
            previous_text = line
            continue
        while headings and headings[-1][0] >= level:
            headings.pop()
        headings.append((level, title))
        label = "heading: " + " > ".join(title for _, title in headings if title)
        if boundaries[-1][0] == heading_start:
            boundaries[-1] = (heading_start, label)
        else:
            boundaries.append((heading_start, label))
        previous_plain = False
    return [(start, boundaries[i + 1][0] if i + 1 < len(boundaries) else len(content), label)
            for i, (start, label) in enumerate(boundaries)]


def _python_regions(content: str, starts: list[int]) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(content)
    except (SyntaxError, ValueError, RecursionError):
        return [(0, len(content), "")]
    # Sweep nested symbol ranges rather than flattening whole classes into one
    # unbounded passage. Decorators belong to their definitions.
    spans: list[tuple[int, int, tuple[str, ...]]] = []
    stack: list[tuple[ast.AST, tuple[str, ...]]] = [(tree, ())]
    while stack:
        node, symbols = stack.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            symbols = (*symbols, node.name)
            first = min([node.lineno, *(item.lineno for item in node.decorator_list)])
            last = node.end_lineno or node.lineno
            start = starts[first - 1]
            end = starts[last] if last < len(starts) else len(content)
            spans.append((start, end, symbols))
        stack.extend((child, symbols) for child in ast.iter_child_nodes(node))
    events: dict[int, list[tuple[bool, int]]] = {0: [], len(content): []}
    for index, (start, end, _) in enumerate(spans):
        events.setdefault(start, []).append((True, index))
        events.setdefault(end, []).append((False, index))
    regions: list[tuple[int, int, str]] = []
    active: set[int] = set()
    positions = sorted(events)
    for i, start in enumerate(positions[:-1]):
        for opening, index in events[start]:
            if opening:
                active.add(index)
            else:
                active.discard(index)
        symbol = max(active, key=lambda item: (len(spans[item][2]), spans[item][0]), default=None)
        label = "symbol: " + ".".join(spans[symbol][2]) if symbol is not None else ""
        regions.append((start, positions[i + 1], label))
    return regions


def _chunks(content: str, *, path: str, regions: list[tuple[int, int, str]],
            segment_index: int | None = None, locator: dict[str, Any] | None = None,
            method: str = "") -> list[dict[str, Any]]:
    if not content.strip():
        return []
    starts = _line_starts(content)
    output: list[dict[str, Any]] = []
    for region_start, region_end, label in regions:
        for parent_start, parent_end in _windows(content, region_start, region_end, MAX_PARENT_CHARS, starts):
            parent = content[parent_start:parent_end]
            identity = json.dumps([CHUNKER_VERSION, str(path), segment_index, locator,
                                   parent_start, parent_end, parent], sort_keys=True, ensure_ascii=False)
            parent_key = hashlib.sha256(identity.encode("utf-8")).hexdigest()
            parent_lines = _line_range(starts, parent_start, parent_end) if locator is None else (0, 0)
            for start, end in _windows(content, parent_start, parent_end, MAX_CHUNK_CHARS, starts):
                passage = content[start:end]
                lines = _line_range(starts, start, end) if locator is None else (0, 0)
                item = {
                    "content": passage,
                    "content_hash": hashlib.sha256(passage.encode("utf-8")).hexdigest(),
                    "context": _context(path, label),
                    "line_start": lines[0], "line_end": lines[1],
                    "char_start": start, "char_end": end,
                    "parent_key": parent_key, "parent_content": parent,
                    "parent_line_start": parent_lines[0], "parent_line_end": parent_lines[1],
                    "parent_char_start": parent_start, "parent_char_end": parent_end,
                }
                if locator is not None:
                    item.update(locator=copy.deepcopy(locator), parent_locator=copy.deepcopy(locator),
                                segment_index=segment_index, method=method)
                output.append(item)
    return output


def text_chunks(content: str, *, path: str) -> list[dict[str, Any]]:
    """Split Markdown by headings, Python by AST symbols, and other text by lines."""
    if not content.strip():
        return []
    starts = _line_starts(content)
    suffix = PurePath(path).suffix.lower()
    if suffix in {".md", ".markdown"}:
        regions = _markdown_regions(content, starts)
    elif suffix in {".py", ".pyi"}:
        regions = _python_regions(content, starts)
    else:
        regions = [(0, len(content), "")]
    return _chunks(content, path=path, regions=regions)


def _locator_label(locator: dict[str, Any]) -> str:
    labels: list[str] = []
    for key, name in (("heading", "heading"), ("page", "page"), ("sheet", "sheet"),
                      ("cell_range", "cells"), ("paragraph_start", "paragraph")):
        if locator.get(key) is not None:
            labels.append(f"{name}: {locator[key]}")
    return " | ".join(labels)


def extracted_chunks(segments: Iterable[dict[str, Any]], *, path: str) -> list[dict[str, Any]]:
    """Split within extracted segments without inventing finer source locators.

    A page, OCR box, paragraph, or sheet range remains exactly as supplied by
    the extractor. Character offsets refine the *extracted segment*, not the
    original PDF/Office file. Identical segments remain distinguishable by index.
    """
    output: list[dict[str, Any]] = []
    for index, segment in enumerate(segments):
        content, locator = segment["text"], segment["locator"]
        if not isinstance(content, str) or not isinstance(locator, dict) or not locator:
            raise ValueError("Extracted segments require text and a nonempty source locator")
        output.extend(_chunks(content, path=path,
                              regions=[(0, len(content), _locator_label(locator))],
                              segment_index=index, locator=locator,
                              method=str(segment.get("method") or "")))
    return output
