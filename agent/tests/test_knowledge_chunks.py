import copy
import hashlib

import pytest

from ollama_code.knowledge_chunks import (
    CHUNKER_VERSION,
    MAX_CHUNK_CHARS,
    MAX_CONTEXT_CHARS,
    MAX_PARENT_CHARS,
    extracted_chunks,
    text_chunks,
)


def assert_exact_slices(content, chunks):
    assert "".join(chunk["content"] for chunk in chunks) == content
    for chunk in chunks:
        assert chunk["content"] == content[chunk["char_start"]:chunk["char_end"]]
        assert chunk["parent_content"] == content[chunk["parent_char_start"]:chunk["parent_char_end"]]
        assert chunk["content_hash"] == hashlib.sha256(chunk["content"].encode()).hexdigest()
        assert 0 < len(chunk["content"]) <= MAX_CHUNK_CHARS
        assert len(chunk["parent_content"]) <= MAX_PARENT_CHARS
        assert len(chunk["context"]) <= MAX_CONTEXT_CHARS
        assert chunk["parent_char_start"] <= chunk["char_start"] < chunk["char_end"] <= chunk["parent_char_end"]


def test_markdown_heading_hierarchy_is_context_not_evidence():
    source = "# Manual\nIntroduction.\n\n## Setup\nUse uv.\n\n### Linux\nRun make.\n\n## Usage\nStart it.\n"
    chunks = text_chunks(source, path="docs/guide.md")
    assert_exact_slices(source, chunks)
    assert [chunk["context"] for chunk in chunks] == [
        "docs/guide.md | heading: Manual",
        "docs/guide.md | heading: Manual > Setup",
        "docs/guide.md | heading: Manual > Setup > Linux",
        "docs/guide.md | heading: Manual > Usage",
    ]
    assert [(c["line_start"], c["line_end"]) for c in chunks] == [(1, 3), (4, 6), (7, 9), (10, 11)]
    assert all("docs/guide.md" not in chunk["content"] for chunk in chunks)


def test_markdown_fences_do_not_create_fake_headings():
    source = "# Real\n```python\n# Not a heading\n```\n~~~~\n## Also code\n~~~~\n## Next\nDone\n"
    chunks = text_chunks(source, path="README.MD")
    assert_exact_slices(source, chunks)
    assert len(chunks) == 2
    assert chunks[0]["line_end"] == 7
    assert chunks[1]["context"] == "README.MD | heading: Real > Next"


def test_setext_headings_and_indented_code():
    source = "Intro\n=====\nText.\n\n    # Code\n\nInstall\n-------\nReady\n"
    chunks = text_chunks(source, path="readme.markdown")
    assert_exact_slices(source, chunks)
    assert [chunk["context"] for chunk in chunks] == [
        "readme.markdown | heading: Intro", "readme.markdown | heading: Intro > Install",
    ]
    assert chunks[1]["line_start"] == 7


def test_python_decorators_class_methods_and_nested_function_boundaries():
    source = (
        "import os\n\n@decorate\nclass Service:\n    value = 1\n\n"
        "    @cache\n    async def run(self):\n        def inner():\n"
        "            return 1\n        return inner()\n\n"
        "def other():\n    return 2\n"
    )
    chunks = text_chunks(source, path="service.py")
    assert_exact_slices(source, chunks)
    run = next(c for c in chunks if c["context"] == "service.py | symbol: Service.run")
    assert run["line_start"] == 7
    assert run["content"].startswith("    @cache\n")
    inner = next(c for c in chunks if c["context"].endswith("Service.run.inner"))
    assert (inner["line_start"], inner["line_end"]) == (9, 10)
    service = next(c for c in chunks if c["context"] == "service.py | symbol: Service")
    assert service["line_start"] == 3
    assert not any("def other" in c["content"] and "inner" in c["content"] for c in chunks)


def test_huge_function_keeps_symbol_context_with_bounded_parents():
    source = "def huge():\n" + "    value = '" + "a" * 30_000 + "'\n    return value\n"
    chunks = text_chunks(source, path="large.py")
    assert_exact_slices(source, chunks)
    assert len({c["parent_key"] for c in chunks}) > 1
    assert all(c["context"] == "large.py | symbol: huge" for c in chunks)
    same_line = [c for c in chunks if c["line_start"] == c["line_end"] == 2]
    assert len(same_line) > 5


def test_syntax_error_falls_back_without_losing_source_or_inventing_symbols():
    source = "def broken(:\n" + "value\n" * 2_000
    chunks = text_chunks(source, path="broken.py")
    assert_exact_slices(source, chunks)
    assert all(c["context"] == "broken.py" for c in chunks)


@pytest.mark.parametrize("newline", ["\n", "\r\n", "\r"])
def test_text_newlines_unicode_and_line_citations_are_preserved(newline):
    lines = [f"{i}: café 😀 " + "word " * 28 for i in range(100)]
    source = newline.join(lines) + newline
    chunks = text_chunks(source, path="notes.txt")
    assert_exact_slices(source, chunks)
    for chunk in chunks:
        expected = newline.join(lines[chunk["line_start"] - 1:chunk["line_end"]]) + newline
        assert chunk["content"] == expected
        assert not (chunk["content"].endswith("\r") and newline == "\r\n")


def test_huge_single_line_has_no_loss_or_overlap():
    source = " " * 7_000 + "é😀" * 30_000
    chunks = text_chunks(source, path="one-line.txt")
    assert_exact_slices(source, chunks)
    assert all(c["line_start"] == c["line_end"] == 1 for c in chunks)
    assert all(c["parent_line_start"] == c["parent_line_end"] == 1 for c in chunks)


def test_parent_identity_is_deterministic_and_binds_path_range_and_content():
    source = "line\n" * 2_000
    chunks = text_chunks(source, path="a.txt")
    assert CHUNKER_VERSION
    assert chunks == text_chunks(source, path="a.txt")
    assert chunks[0]["parent_key"] == chunks[1]["parent_key"]
    assert chunks[0]["parent_key"] != text_chunks(source, path="b.txt")[0]["parent_key"]
    assert chunks[0]["parent_key"] != text_chunks("changed\n" + source, path="a.txt")[0]["parent_key"]
    assert len({c["parent_key"] for c in chunks}) == 2


def test_extracted_pdf_keeps_exact_page_ocr_locator_and_segment_offsets():
    locator = {"kind": "pdf", "page": 4, "page_index": 3, "bounds": [0.1, 0.2, 0.3, 0.4]}
    source = "Résumé 😀 " * 2_000
    segments = [{"text": source, "locator": locator, "method": "ocr"}]
    original = copy.deepcopy(segments)
    chunks = extracted_chunks(segments, path="manual.pdf")
    assert_exact_slices(source, chunks)
    assert segments == original
    assert all(c["locator"] == locator and c["parent_locator"] == locator for c in chunks)
    assert all(c["line_start"] == c["line_end"] == c["parent_line_start"] == c["parent_line_end"] == 0 for c in chunks)
    assert all(c["segment_index"] == 0 and c["method"] == "ocr" for c in chunks)
    assert all(c["context"] == "manual.pdf | page: 4" for c in chunks)
    chunks[0]["locator"]["bounds"][0] = 99
    assert segments == original
    assert chunks[1]["locator"] == locator
    assert chunks[0]["parent_locator"] == locator


def test_docx_sheet_and_repeated_segments_keep_distinct_citations():
    segments = [
        {"text": "same words", "locator": {"kind": "paragraph", "paragraph_start": 8, "paragraph_end": 9, "heading": "Terms"}},
        {"text": "same words", "locator": {"kind": "sheet", "sheet": "Budget", "cell_range": "B2:D2"}},
        {"text": "same words", "locator": {"kind": "sheet", "sheet": "Budget", "cell_range": "B2:D2"}},
    ]
    chunks = extracted_chunks(segments, path="export")
    assert len({c["parent_key"] for c in chunks}) == 3
    assert chunks[0]["context"] == "export | heading: Terms | paragraph: 8"
    assert chunks[1]["context"] == "export | sheet: Budget | cells: B2:D2"
    for index, chunk in enumerate(chunks):
        assert chunk["locator"] == segments[index]["locator"]
        assert chunk["segment_index"] == index
        assert chunk["char_start"] == 0
        assert chunk["char_end"] == len(segments[index]["text"])


def test_missing_document_citation_is_rejected():
    with pytest.raises(ValueError, match="source locator"):
        extracted_chunks([{"text": "no citation", "locator": {}}], path="file.pdf")


def test_empty_content_and_bounded_context():
    assert text_chunks(" \n\t", path="empty.md") == []
    assert extracted_chunks([], path="empty.pdf") == []
    chunks = text_chunks("# " + "heading " * 5_000, path="x" * 2_000 + ".md")
    assert all(len(c["context"]) <= MAX_CONTEXT_CHARS for c in chunks)
    assert all(len(c["content"]) <= MAX_CHUNK_CHARS for c in chunks)
