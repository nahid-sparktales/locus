"""Markdown is an editable scoped source, not a bypass around memory lifecycle."""
import multiprocessing
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace

import pytest
from locus_memory import MemoryEngine, StaticKeyProvider
from locus_memory.errors import MemoryEngineError, NotFound
from locus_memory.models import (
    AccessContext,
    Actor,
    CandidateProposal,
    Correction,
    ForgetTarget,
    Lifecycle,
    Operation,
    PartitionRef,
    RememberRequest,
    Scope,
    ScopeGrants,
    SourceRef,
)

from ollama_code import memory_markdown as markdown


@pytest.fixture
def store(tmp_path):
    engine = MemoryEngine(tmp_path / "app" / "memory-engine", StaticKeyProvider({"test": b"m" * 32}))
    access = AccessContext("test-user", PartitionRef("locus", "default"), Actor.USER,
        grants=ScopeGrants(projects=frozenset({"project-one"}), agents=frozenset({"reviewer"})),
        operations=frozenset({Operation.READ, Operation.WRITE, Operation.PROPOSE, Operation.APPROVE, Operation.FORGET}))
    yield engine, access, tmp_path / "app" / "memories"
    engine.close()


def _remember(store, content="Use violet for releases.", scope=None, **kwargs):
    engine, access, _ = store
    return engine.remember(access, RememberRequest(content=content, title="Release preference",
        scope=scope or Scope.of(project="project-one"), **kwargs)).record


def _workspace(store):
    return store[2] / "workspaces" / "project-one" / "MEMORY.md"


def test_bootstrap_preserves_database_and_produces_editable_files(store):
    item = _remember(store)
    engine, access, root = store
    status = markdown.reconcile(engine, access)
    assert status["storage_root"] == str(root) and status["encrypted"] is False
    assert status["lifecycle_index_encrypted"] is True
    assert item.id in _workspace(store).read_text()
    assert engine.get(access, item.id).revision == item.revision
    assert (root / "USER.md").exists()
    assert (root / "PENDING.md").exists()
    assert len(list((root / "agents").glob("*/MEMORY.md"))) == 1
    assert _workspace(store).stat().st_mode & 0o777 == 0o600
    assert markdown.reconcile(engine, access)["updated"] == 0


def test_external_edit_changes_engine_and_recall_then_database_edit_changes_file(store):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    path.write_text(path.read_text().replace("Use violet for releases.", "Use turquoise for releases.") + "\n")
    assert markdown.reconcile(engine, access)["updated"] == 1
    edited = engine.get(access, item.id)
    assert edited.content == "Use turquoise for releases."
    assert engine.search(access, "turquoise").hits[0].record.id == item.id
    engine.correct(access, item.id, Correction(content="Use amber for releases."), expected_revision=edited.revision)
    markdown.reconcile(engine, access)
    assert "Use amber for releases." in path.read_text()
    assert "turquoise" not in path.read_text()


def test_appended_markdown_is_saved_in_its_document_scope(store):
    engine, access, root = store
    markdown.reconcile(engine, access)
    path = root / "USER.md"
    path.write_text(path.read_text() + "\nI prefer concise answers.\n")
    assert markdown.reconcile(engine, access)["created"] == 1
    saved = engine.list(access)
    assert len(saved) == 1 and saved[0].scope.is_global
    assert saved[0].content == "I prefer concise answers."
    assert saved[0].kind.value == "preference"
    assert markdown.reconcile(engine, access)["created"] == 0


def test_remove_block_forgets_and_restored_old_file_cannot_resurrect(store):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    original = path.read_text()
    path.write_text(markdown._MARKER.sub("", original))
    assert markdown.reconcile(engine, access)["deleted"] == 1
    with pytest.raises(NotFound):
        engine.get(access, item.id)
    path.write_text(original)
    with pytest.raises(MemoryEngineError):
        markdown.reconcile(engine, access)
    assert engine.search(access, "violet").hits == ()
    assert path.read_text() == original


def test_database_forget_removes_unchanged_markdown_and_never_reimports(store):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    engine.forget(access, ForgetTarget("memory", item.id))
    markdown.reconcile(engine, access)
    assert item.id not in _workspace(store).read_text()
    assert engine.list(access) == []


def test_superseded_duplicate_leaves_document_without_forgetting_history(store):
    first = _remember(store)
    second = _remember(store, "Use violet for releases.")
    engine, access, _ = store
    markdown.reconcile(engine, access)
    original = _workspace(store).read_text()
    engine.supersede(access, second.id, first.id, expected_revision=second.revision)
    markdown.reconcile(engine, access)
    assert first.id in _workspace(store).read_text()
    assert second.id not in _workspace(store).read_text()
    assert engine.get(access, second.id).lifecycle == Lifecycle.SUPERSEDED
    _workspace(store).write_text(original)
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    assert engine.get(access, second.id).lifecycle == Lifecycle.SUPERSEDED


def test_pending_edits_and_additions_stay_unapproved_and_cannot_be_moved(store):
    engine, access, _ = store
    item = engine.propose(access, CandidateProposal(content="Violet is a useful release label.",
        title="Suggested label", scope=Scope.of(project="project-one"),
        sources=(SourceRef("document", "test-proposal", actor=Actor.USER),))).record
    markdown.reconcile(engine, access)
    pending = _workspace(store).with_name("PENDING.md")
    pending.write_text(pending.read_text().replace("Violet is a useful", "Turquoise is a useful") + "\nUse short release notes.\n")
    markdown.reconcile(engine, access)
    assert engine.get(access, item.id).lifecycle == Lifecycle.CANDIDATE
    assert engine.search(access, "Turquoise").hits == ()
    assert len(engine.list(access, lifecycles=(Lifecycle.CANDIDATE,))) == 2
    block = markdown._MARKER.search(pending.read_text())[0]
    _workspace(store).write_text(_workspace(store).read_text() + "\n" + block + "\n")
    with pytest.raises(markdown.MarkdownMemoryError, match="scope or review"):
        markdown.reconcile(engine, access)
    assert engine.get(access, item.id).lifecycle == Lifecycle.CANDIDATE


@pytest.mark.parametrize("bad", ["<<<<<<< local\nconflict\n=======\nother\n>>>>>>> remote\n",
    '<!-- locus-memory {"id":"broken"} -->\n', "\x00",
    '<!-- locus-memory {"id":"broken","kind":{}} -->\n## Invalid\ntext\n<!-- /locus-memory -->'])
def test_malformed_file_preserved_and_no_edits_applied(store, bad):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    value = path.read_text() + bad
    path.write_text(value)
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    assert path.read_text() == value
    assert engine.get(access, item.id).content == item.content


def test_simultaneous_database_and_file_edits_fail_closed(store):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    value = path.read_text().replace("Use violet for releases.", "Use turquoise for releases.")
    path.write_text(value)
    engine.correct(access, item.id, Correction(content="Use amber for releases."), expected_revision=item.revision)
    with pytest.raises(markdown.MarkdownMemoryError, match="Both"):
        markdown.reconcile(engine, access)
    assert engine.get(access, item.id).content == "Use amber for releases."
    assert path.read_text() == value


def test_selected_scopes_do_not_export_or_import_personal_or_other_projects(store):
    engine, access, root = store
    _remember(store, "Personal cobalt preference.", Scope.global_())
    broad = replace(access, grants=replace(access.grants, projects=frozenset({"project-one", "project-two"})))
    engine.remember(broad, RememberRequest(content="Other project chartreuse.", scope=Scope.of(project="project-two")))
    _remember(store)
    markdown.reconcile(engine, access, scopes=("workspace",))
    assert not (root / "USER.md").exists()
    assert not (root / "workspaces" / "project-two").exists()
    assert not (root / "agents").exists()
    value = _workspace(store).read_text()
    assert "cobalt" not in value and "chartreuse" not in value
    assert "violet" in value


def test_missing_known_file_fails_closed_and_is_not_recreated(store):
    _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    path.unlink()
    with pytest.raises(markdown.MarkdownMemoryError, match="missing"):
        markdown.reconcile(engine, access)
    assert not path.exists()


def test_unreadable_symlink_is_never_followed(store, tmp_path):
    _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    external = tmp_path / "outside.md"
    external.write_text("External contents")
    path.unlink()
    path.symlink_to(external)
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    assert external.read_text() == "External contents"


def test_interrupted_projection_retries_without_duplicate_or_lost_edit(store, monkeypatch):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    path.write_text(path.read_text().replace("Use violet for releases.", "Use turquoise for releases.") + "\n")
    original = markdown._atomic_write
    def failed(*args, **kwargs):
        raise OSError("interrupted write")
    monkeypatch.setattr(markdown, "_atomic_write", failed)
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    assert engine.get(access, item.id).content == "Use turquoise for releases."
    monkeypatch.setattr(markdown, "_atomic_write", original)
    markdown.reconcile(engine, access)
    assert len(engine.list(access)) == 1
    assert markdown.reconcile(engine, access)["updated"] == 0


def test_threads_reconcile_one_added_note_once(store):
    engine, access, root = store
    markdown.reconcile(engine, access)
    user = root / "USER.md"
    user.write_text(user.read_text() + "\nI prefer concise answers.\n")
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda _: markdown.reconcile(engine, access), range(3)))
    assert len(engine.list(access)) == 1
    assert user.read_text().count("<!-- locus-memory ") == 1


def test_storage_lock_is_reentrant(store):
    engine, access, root = store
    with markdown.storage_lock(root):
        markdown.reconcile(engine, access)


def test_unchanged_reconcile_does_not_rewrite_files_or_baselines(store, monkeypatch):
    _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    monkeypatch.setattr(markdown, "_save_state", lambda *args: pytest.fail("unchanged baseline was rewritten"))
    monkeypatch.setattr(markdown, "_atomic_write", lambda *args: pytest.fail("unchanged file was rewritten"))
    assert markdown.reconcile(engine, access)["updated"] == 0


def test_bootstrap_interrupted_before_first_file_can_retry(store, monkeypatch):
    item = _remember(store)
    engine, access, _ = store
    original = markdown._atomic_write
    monkeypatch.setattr(markdown, "_atomic_write", lambda *args: (_ for _ in ()).throw(OSError("disk unavailable")))
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    monkeypatch.setattr(markdown, "_atomic_write", original)
    markdown.reconcile(engine, access)
    assert item.id in _workspace(store).read_text()
    assert len(engine.list(access)) == 1


def test_completed_file_write_with_unfinished_baseline_recovers(store, monkeypatch):
    _remember(store)
    engine, access, _ = store
    original = markdown._save_state
    def interrupted(partition, key, state):
        if "pending" not in state:
            raise OSError("process ended after atomic file replacement")
        return original(partition, key, state)
    monkeypatch.setattr(markdown, "_save_state", interrupted)
    with pytest.raises(markdown.MarkdownMemoryError):
        markdown.reconcile(engine, access)
    monkeypatch.setattr(markdown, "_save_state", original)
    markdown.reconcile(engine, access)
    assert len(engine.list(access)) == 1


def test_file_change_during_projection_is_preserved_and_blocks_recall(store, monkeypatch):
    item = _remember(store)
    engine, access, _ = store
    markdown.reconcile(engine, access)
    path = _workspace(store)
    path.write_text(path.read_text().replace("Use violet for releases.", "Use turquoise for releases.") + "\n")
    original = markdown._atomic_write
    def editor_race(target, output, expected):
        if target == path:
            target.write_text(target.read_text() + "\nEditor added another sentence.\n")
        return original(target, output, expected)
    monkeypatch.setattr(markdown, "_atomic_write", editor_race)
    with pytest.raises(markdown.MarkdownMemoryError, match="changed during"):
        markdown.reconcile(engine, access)
    assert "Editor added another sentence." in path.read_text()
    assert engine.get(access, item.id).content == "Use turquoise for releases."
    monkeypatch.setattr(markdown, "_atomic_write", original)
    with pytest.raises(markdown.MarkdownMemoryError, match="unfinished"):
        markdown.reconcile(engine, access)


def test_fresh_database_can_import_shared_approved_file_with_stable_ids(store, tmp_path):
    item = _remember(store)
    engine, access, root = store
    markdown.reconcile(engine, access)
    other = MemoryEngine(tmp_path / "other-device" / "memory-engine", StaticKeyProvider({"other": b"n" * 32}))
    try:
        markdown.reconcile(other, access, root=root)
        imported = other.get(access, item.id)
        assert imported.content == item.content and imported.scope == item.scope
    finally:
        other.close()


def _process_reconcile(engine_root, access):
    engine = MemoryEngine(engine_root, StaticKeyProvider({"test": b"m" * 32}))
    try:
        markdown.reconcile(engine, access)
    finally:
        engine.close()


def test_processes_reconcile_one_added_note_once(store):
    engine, access, root = store
    markdown.reconcile(engine, access)
    path = root / "USER.md"
    path.write_text(path.read_text() + "\nI prefer concise answers.\n")
    context = multiprocessing.get_context("spawn")
    processes = [context.Process(target=_process_reconcile, args=(str(engine.root), access)) for _ in range(2)]
    for process in processes:
        process.start()
    for process in processes:
        process.join(timeout=20)
        assert process.exitcode == 0
    assert len(engine.list(access)) == 1
