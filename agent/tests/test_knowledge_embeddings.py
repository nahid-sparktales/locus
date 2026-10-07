"""Durable embedding queues and generation-bound publication on real SQLite stores."""
from __future__ import annotations

import hashlib
import math
import threading
import time

import pytest

from ollama_code import document_library, knowledge
from ollama_code import knowledge_embeddings as embeddings
from ollama_code.knowledge import KnowledgeStore

_schedule = embeddings.schedule_embeddings


@pytest.fixture(autouse=True)
def manual_scheduling(monkeypatch):
    embeddings.stop_embedding_jobs()
    registrations = []
    monkeypatch.setattr(embeddings, "schedule_embeddings", registrations.append)
    yield registrations
    embeddings.stop_embedding_jobs()


@pytest.fixture
def store(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    result = KnowledgeStore(str(root))
    result.configure(embedding_model="local-embed", documents_enabled=True)
    return result


def _seed(store, count=3, *, format="text"):
    path = "notes.md" if format == "text" else "report.pdf"
    raw = b"source fixture"
    (store.root / path).write_bytes(raw)
    with store._connect() as connection:
        connection.execute("""INSERT INTO documents(path,content_hash,size,mtime,indexed_at,format)
            VALUES(?,?,?,?,?,?)""", (path, hashlib.sha256(raw).hexdigest(), len(raw), 1, 1, format))
        for index in range(count):
            text = f"Item {index} is a source fact."
            connection.execute("""INSERT INTO chunks(path,line_start,line_end,content,content_hash,search_content)
                VALUES(?,1,1,?,?,?)""", (path, text, hashlib.sha256(text.encode()).hexdigest(), "Project heading\n" + text))
    return path


def _fake_vectors(model, host, inputs):
    return [[1.0, .5] for _ in inputs]


def test_drains_more_than_2000_using_bounded_contextual_batches(store, monkeypatch):
    _seed(store, 2005)
    calls = []

    def embed(model, host, inputs):
        calls.append(inputs)
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    assert embeddings.drain_embeddings(store) == 2005
    assert len(calls) == math.ceil(2005 / embeddings.BATCH_SIZE)
    assert all(0 < len(batch) <= embeddings.BATCH_SIZE for batch in calls)
    assert all(text.startswith("Project heading\n") for batch in calls for text in batch)
    assert embeddings.embedding_status(store) == {
        "embedding_pending": 0, "embedding_complete": 2005, "embedding_error": None,
    }


def test_bounded_run_resumes_from_persistent_null_rows_after_reopen(store, monkeypatch):
    _seed(store, 70)
    monkeypatch.setattr(knowledge, "embed_texts", _fake_vectors)
    assert embeddings.drain_embeddings(store, max_batches=1) == embeddings.BATCH_SIZE
    reopened = KnowledgeStore(str(store.root))
    assert embeddings.embedding_status(reopened)["embedding_pending"] == 70 - embeddings.BATCH_SIZE
    assert embeddings.drain_embeddings(reopened) == 70 - embeddings.BATCH_SIZE
    assert embeddings.embedding_status(reopened)["embedding_pending"] == 0


@pytest.mark.parametrize("change", ["model", "host", "generation", "content", "context", "document"])
def test_results_cannot_publish_over_changed_configuration_or_source(store, monkeypatch, change):
    _seed(store)

    def mutate(model, host, inputs):
        if change == "model":
            store.configure(embedding_model="other-embed")
        elif change == "host":
            store.configure(ollama_host="http://127.0.0.1:11435")
        else:
            with store._connect() as connection:
                if change == "generation":
                    connection.execute("UPDATE settings SET vector_generation=vector_generation+1")
                elif change == "content":
                    connection.execute("UPDATE chunks SET content='changed fact',content_hash='new-hash'")
                elif change == "context":
                    connection.execute("UPDATE chunks SET search_content='Changed project heading'")
                elif change == "document":
                    connection.execute("UPDATE documents SET content_hash='new-document-hash'")
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", mutate)
    assert embeddings.drain_embeddings(store, max_batches=1) == 0
    assert embeddings.embedding_status(store)["embedding_pending"] == 3
    monkeypatch.setattr(knowledge, "embed_texts", _fake_vectors)
    assert embeddings.drain_embeddings(store) == 3


@pytest.mark.parametrize("format", ["text", "pdf"])
def test_disabling_during_network_call_prevents_publication(store, monkeypatch, format):
    _seed(store, format=format)

    def disable(model, host, inputs):
        store.configure(**({"enabled": False} if format == "text" else {"documents_enabled": False}))
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", disable)
    assert embeddings.drain_embeddings(store) == 0
    with store._connect() as connection:
        assert connection.execute("SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL").fetchone()[0] == 0


def test_exclusions_do_not_starve_later_allowed_rows(store, monkeypatch):
    _seed(store, 40)
    store.configure(exclusions=["notes.md"])
    with store._connect() as connection:
        connection.execute("INSERT INTO documents(path,content_hash,size,mtime,indexed_at,format) VALUES('allowed.md','ok',1,1,1,'text')")
        connection.execute("""INSERT INTO chunks(path,line_start,line_end,content,content_hash,search_content)
            VALUES('allowed.md',1,1,'allowed fact','ok','allowed contextual fact')""")
    received = []

    def embed(model, host, inputs):
        received.extend(inputs)
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    assert embeddings.drain_embeddings(store) == 1
    assert received == ["allowed contextual fact"]
    assert embeddings.embedding_status(store) == {
        "embedding_pending": 0, "embedding_complete": 1, "embedding_error": None,
    }


def test_failure_keeps_queue_and_reports_content_free_error(store, monkeypatch):
    _seed(store)

    def fail(*_):
        raise RuntimeError("private source content must not enter diagnostics")

    monkeypatch.setattr(knowledge, "embed_texts", fail)
    with pytest.raises(RuntimeError):
        embeddings.drain_embeddings(store)
    status = embeddings.embedding_status(store)
    assert status["embedding_pending"] == 3
    assert "RuntimeError" in status["embedding_error"] and "private source" not in status["embedding_error"]
    monkeypatch.setattr(knowledge, "embed_texts", _fake_vectors)
    assert embeddings.drain_embeddings(store) == 3
    assert embeddings.embedding_status(store)["embedding_error"] is None


@pytest.mark.parametrize("raw", [[[float("nan")]], [[0.0]], [[1.0], [1.0, 2.0]], [[float("inf")]]])
def test_invalid_vectors_are_not_stored(store, monkeypatch, raw):
    _seed(store, len(raw))
    monkeypatch.setattr(knowledge, "embed_texts", lambda *_: raw)
    with pytest.raises(ValueError):
        embeddings.drain_embeddings(store)
    assert embeddings.embedding_status(store)["embedding_complete"] == 0


def test_startup_registers_saved_backlog_without_opening_chats(store, manual_scheduling):
    _seed(store)
    manual_scheduling.clear()
    embeddings.restore_embedding_jobs()
    assert [item.path for item in manual_scheduling] == [store.path]
    assert embeddings.embedding_status(manual_scheduling[0])["embedding_pending"] == 3


def test_background_shutdown_discards_inflight_results_and_work_can_resume(store, monkeypatch):
    _seed(store)
    started, release = threading.Event(), threading.Event()

    def blocking(model, host, inputs):
        started.set()
        assert release.wait(3)
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", blocking)
    _schedule(store)
    assert started.wait(3)
    timer = threading.Timer(.05, release.set)
    timer.start()
    embeddings.stop_embedding_jobs()
    timer.join()
    assert embeddings.embedding_status(store)["embedding_pending"] == 3
    monkeypatch.setattr(knowledge, "embed_texts", _fake_vectors)
    _schedule(store)
    deadline = time.monotonic() + 3
    while embeddings.embedding_status(store)["embedding_pending"] and time.monotonic() < deadline:
        time.sleep(.01)
    assert embeddings.embedding_status(store)["embedding_pending"] == 0


def test_background_worker_yields_large_backlog_to_other_workspaces(store, tmp_path, monkeypatch):
    _seed(store, embeddings.BATCH_SIZE * 5)
    root = tmp_path / "second-workspace"
    root.mkdir()
    other = KnowledgeStore(str(root))
    other.configure(embedding_model="second-model")
    _seed(other, 1)
    calls = []

    def embed(model, host, inputs):
        calls.append(model)
        return _fake_vectors(model, host, inputs)

    monkeypatch.setattr(knowledge, "embed_texts", embed)
    coordinator = embeddings._Coordinator()
    try:
        # Queue both before waking the worker, so service order is deterministic.
        with coordinator._mutex:
            coordinator._stores[str(store.path)] = (store, 0)
            coordinator._stores[str(other.path)] = (other, 0)
        coordinator._wake.set()
        deadline = time.monotonic() + 3
        while embeddings.embedding_status(store)["embedding_pending"] and time.monotonic() < deadline:
            time.sleep(.01)
        assert embeddings.embedding_status(store)["embedding_pending"] == 0
        assert embeddings.embedding_status(other)["embedding_pending"] == 0
        assert calls == ["local-embed"] * 4 + ["second-model", "local-embed"]
    finally:
        coordinator._stop.set()
        coordinator._wake.set()
        coordinator._thread.join(timeout=3)


def test_locks_bound_workspaces_and_global_profile_slots(store, tmp_path):
    stores = [store]
    for name in ("second", "third"):
        root = tmp_path / name
        root.mkdir()
        stores.append(KnowledgeStore(str(root)))
    first, second = embeddings._locks(stores[0]), embeddings._locks(stores[1])
    try:
        assert first and second
        assert embeddings._locks(stores[0]) is None
        assert embeddings._locks(stores[2]) is None
    finally:
        for handle in (first or []) + (second or []):
            handle.close()
    released = embeddings._locks(stores[2])
    assert released
    for handle in released:
        handle.close()


@pytest.mark.parametrize("persistent", [True, False])
def test_document_publication_schedules_only_persistent_indexed_content(store, monkeypatch, manual_scheduling, persistent):
    class ManualCoordinator:
        def register(self, _store):
            pass

    monkeypatch.setattr(document_library, "_coordinator", lambda: ManualCoordinator())
    (store.root / "report.csv").write_text("account,amount\nNorth,42\n")
    library = document_library.DocumentStore(str(store.root), start_worker=False)
    job = library.submit("report.csv", persistent=persistent)
    manual_scheduling.clear()
    library._execute(job["id"])
    assert library.job(job["id"])["state"] == "ready"
    assert bool(manual_scheduling) is persistent
    assert bool(embeddings.embedding_status(store)["embedding_pending"]) is persistent
