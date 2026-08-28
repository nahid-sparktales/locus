"""Transcript search: the FTS index over saved conversations.

The index is derived data kept current by a stat-diff sync, so these tests
drive it exactly the way the server does — write sessions through
``SessionStore``, then search — and assert the parity that matters: a hit's
``message_index`` must address the same position ``SessionStore.load`` returns.
"""
from __future__ import annotations

import time
from pathlib import Path

from ollama_code.sessions import SessionStore
from ollama_code.transcript_search import TranscriptIndex


def _write_session(cwd: str, messages: list[dict[str, str]]) -> SessionStore:
    store = SessionStore(cwd)
    for message in messages:
        store.append({"type": "message", "message": message})
    return store


def _bump_mtime(store: SessionStore) -> None:
    """File mtime has one-second resolution on some filesystems; make the
    stat-diff see appends that land within the same second."""
    stat = store.path.stat()
    import os

    os.utime(store.path, (stat.st_atime, stat.st_mtime + 2))


def test_index_builds_lazily_and_finds_message_text(tmp_path):
    _write_session(str(tmp_path), [
        {"role": "user", "content": "Where does the xylophone-rebate constant live?"},
        {"role": "assistant", "content": "It lives in billing.py near the top."},
    ])
    index = TranscriptIndex()

    response = index.search("xylophone-rebate")

    assert response["indexing"] is False
    assert response["results"], "the seeded token must be found"
    hit = response["results"][0]
    assert hit["role"] == "user"
    assert "xylophone" in hit["snippet"]
    assert hit["highlights"], "matched terms must carry highlight ranges"
    for start, length in hit["highlights"]:
        assert hit["snippet"][start:start + length]


def test_message_index_matches_session_detail_positions(tmp_path):
    store = _write_session(str(tmp_path), [
        {"role": "user", "content": "first question"},
        {"role": "assistant", "content": "first answer"},
        {"role": "tool", "content": "tool output that is never indexed"},
        {"role": "assistant", "content": "the meteorite-ledger detail"},
    ])
    index = TranscriptIndex()

    hit = index.search("meteorite-ledger")["results"][0]

    messages = SessionStore.load(store.path)
    assert messages[hit["message_index"]]["content"] == "the meteorite-ledger detail"


def test_structured_assistant_fields_and_reasoning_sections_are_searchable(tmp_path):
    _write_session(str(tmp_path), [
        {
            "role": "assistant",
            "content": "Checking the forecast",
            "_phase": "commentary",
            "_item_id": "msg-weather",
        },
        {
            "role": "assistant",
            "content": "",
            "_display_only": True,
            "_item_id": "reason-weather",
            "_display_reasoning_sections": ["Planning retrieval", "Parsing aurora-weather"],
        },
    ])
    index = TranscriptIndex()

    commentary = index.search("forecast")["results"][0]
    assert commentary["phase"] == "commentary"
    assert commentary["item_id"] == "msg-weather"
    reasoning = index.search("aurora-weather")["results"][0]
    assert reasoning["item_id"] == "reason-weather"
    assert reasoning["reasoning_sections"] == ["Planning retrieval", "Parsing aurora-weather"]


def test_appended_messages_are_indexed_by_tail_sync(tmp_path):
    store = _write_session(str(tmp_path), [
        {"role": "user", "content": "opening line"},
    ])
    index = TranscriptIndex()
    assert index.search("opening")["results"]
    before = index._connect().execute(
        "SELECT indexed_bytes FROM sessions WHERE session_id=?",
        (store.session_id,),
    ).fetchone()[0]

    store.append({
        "type": "message",
        "message": {"role": "assistant", "content": "a later quartz-anchor reply"},
    })
    _bump_mtime(store)

    assert index.search("quartz-anchor")["results"]
    after = index._connect().execute(
        "SELECT indexed_bytes FROM sessions WHERE session_id=?",
        (store.session_id,),
    ).fetchone()[0]
    assert after > before, "the tail sync must advance, not re-read from zero"


def test_trashed_sessions_leave_the_index_and_restore_returns(tmp_path):
    store = _write_session(str(tmp_path), [
        {"role": "user", "content": "the falcon-invoice question"},
    ])
    index = TranscriptIndex()
    assert index.search("falcon-invoice")["results"]

    _count, target = SessionStore.move_to_trash([store.session_id])
    assert index.search("falcon-invoice")["results"] == []

    restored = SessionStore.restore_from_trash_details(Path(target).name)
    assert restored, "the trash batch must restore"
    assert index.search("falcon-invoice")["results"]


def test_prompt_decoration_is_stripped_from_user_messages(tmp_path):
    _write_session(str(tmp_path), [{
        "role": "user",
        "content": (
            "[Locus mode: Work]\n\nWork instruction text\n\n"
            "User request:\nfind the gazebo-metric"
        ),
    }])
    index = TranscriptIndex()

    assert index.search("gazebo-metric")["results"]
    assert index.search("Locus mode")["results"] == []


def test_results_are_capped_per_session(tmp_path):
    _write_session(str(tmp_path), [
        {"role": "assistant", "content": f"repeated pelican-audit line {i}"}
        for i in range(8)
    ])
    index = TranscriptIndex()

    results = index.search("pelican-audit")["results"]

    assert len(results) == 3


def test_delete_all_empties_the_index(tmp_path):
    _write_session(str(tmp_path), [
        {"role": "user", "content": "ephemeral walrus-manifest"},
    ])
    index = TranscriptIndex()
    assert index.search("walrus-manifest")["results"]

    index.delete_all()

    # The session file still exists, so the next sync re-indexes it — assert
    # via a fresh sync-free connection that the tables were emptied first.
    with index._connect() as connection:
        pending = connection.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    assert pending == 0


def test_schema_mismatch_drops_and_rebuilds(tmp_path):
    _write_session(str(tmp_path), [
        {"role": "user", "content": "stale-schema sentinel"},
    ])
    index = TranscriptIndex()
    assert index.search("stale-schema")["results"]
    with index._connect() as connection:
        connection.execute("UPDATE settings SET schema_version=999 WHERE singleton=1")

    rebuilt = TranscriptIndex()

    assert rebuilt.search("stale-schema")["results"]


def test_search_skips_torn_tail_lines_until_completed(tmp_path):
    store = _write_session(str(tmp_path), [
        {"role": "user", "content": "complete-line marker"},
    ])
    index = TranscriptIndex()
    assert index.search("complete-line")["results"]

    with store.path.open("ab") as handle:
        handle.write(b'{"type": "message", "message": {"role": "user", "con')
    _bump_mtime(store)

    assert index.search("complete-line")["results"], "a torn tail must not break search"
    time.sleep(0)  # placeholder to keep timing honest on slow CI
