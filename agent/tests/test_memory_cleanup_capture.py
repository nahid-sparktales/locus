"""Durable ownership, provenance, and restart-safe cleanup memory writes."""
import hashlib
from dataclasses import replace
from types import SimpleNamespace
from uuid import uuid4

import pytest
from locus_memory import MemoryEngine
from locus_memory.errors import NotFound, VaultLocked
from locus_memory.models import Actor

from ollama_code.agent_config import AgentConfiguration
from ollama_code.memory import MemoryError, MemoryVault
from ollama_code.memory_automation import (
    automatic_memory_scope,
    capture_user_memory,
    cleanup_verification_context,
    prepare_cleanup_candidates,
    save_cleanup_candidates,
)
from ollama_code.memory_policy import MemoryPolicy


@pytest.fixture
def core(tmp_path):
    workspace = tmp_path / "project"
    workspace.mkdir()
    return SimpleNamespace(workspace_root=str(workspace), cwd=str(workspace),
        agent_id=str(uuid4()), _memory_profile_active=True, identity_mode=False,
        agent_mode="work", agent_configuration=AgentConfiguration(memory_policy=MemoryPolicy()),
        session=SimpleNamespace(session_id="chat-one"), tool_ctx=SimpleNamespace(memory_run_id="run-one"),
        chatgpt_parity_active=lambda: False)


def prepare(core, text="I prefer concise answers.", *, category="personal_preference", source=None, **extra):
    return prepare_cleanup_candidates(core, [{"category": category, "content": text,
        "source_ids": ["user-one"], **extra}], "cleanup-one",
        source or [{"source_id": "user-one", "role": "user", "content": text}])


def vault(core):
    return MemoryVault(workspace=core.workspace_root, agent_id=core.agent_id, actor=Actor.USER)


def test_preferences_follow_user_and_project_knowledge_stays_local(core, tmp_path):
    saved = capture_user_memory(core, "I prefer concise answers.", event_id="one")[0]
    project = capture_user_memory(core, "For this project I prefer tabs.", event_id="two")
    # Deterministic capture retains its narrow direct-statement gate.
    assert project == []
    project = capture_user_memory(core, "I prefer tabs in this project.", event_id="three")[0]
    assert saved["scope"] == "personal" and project["scope"] == "workspace"
    other = MemoryVault(workspace=str(tmp_path / "other"), agent_id=core.agent_id)
    try:
        assert saved["id"] in {item["id"] for item in other.search("concise answers")}
        assert project["id"] not in {item["id"] for item in other.list()}
    finally:
        other.close()


def test_no_fallback_when_personal_scope_is_disabled(core):
    core.agent_configuration = replace(core.agent_configuration,
        memory_policy=replace(MemoryPolicy(), scopes=("workspace", "agent")))
    specs = prepare(core)
    assert specs[0]["status"] == "policy_disabled"
    assert save_cleanup_candidates(core, specs, "cleanup-one")[0]["status"] == "policy_disabled"
    with vault(core) as store:
        assert store.list() == []


def test_project_qualifier_in_source_prevents_broadening(core):
    specs = prepare(core, text="I prefer tabs.", source=[{"source_id": "user-one", "role": "user",
        "content": "For this project, I prefer tabs."}])
    assert specs[0]["scope"] == "workspace"


@pytest.mark.parametrize("category,role,text", [
    ("task", "user", "Finish the migration."),
    ("personal_preference", "assistant", "You prefer concise answers."),
    ("personal_preference", "user", "I prefer short replies just this time."),
    ("specialist_lesson", "assistant", "Checking inputs prevents incorrect output."),
])
def test_unsupported_and_temporary_claims_remain_checkpoint_only(core, category, role, text):
    specs = prepare(core, text=text, category=category,
        source=[{"source_id": "user-one", "role": role, "content": text}])
    assert specs[0]["status"] == "unresolved"
    assert save_cleanup_candidates(core, specs, "cleanup-one")[0]["status"] == "unresolved"


def test_model_paraphrase_is_pending_not_falsely_user_stated(core):
    specs = prepare(core, text="The user prefers short replies.",
        source=[{"source_id": "user-one", "role": "user", "content": "I prefer concise answers."}])
    result = save_cleanup_candidates(core, specs, "cleanup-one")[0]
    assert result["status"] == "pending"
    with vault(core) as store:
        access, _ = store._access()
        record = store.engine.get(access, result["memory_id"])
        assert record.basis.value == "model_interpretation"
        assert store.search("short replies") == []


def test_exact_message_provenance_and_retry_preserve_one_record(core):
    specs = prepare(core)
    first = save_cleanup_candidates(core, specs, "cleanup-one")[0]
    second = save_cleanup_candidates(core, specs, "cleanup-one")[0]
    assert first["status"] == "approved" and second["status"] == "already_saved"
    assert first["memory_id"] == second["memory_id"]
    with vault(core) as store:
        access, _ = store._access()
        record = store.engine.get(access, first["memory_id"])
        source = next(source for source in record.sources if source.locator.get("message_id"))
        assert source.locator == {"kind": "session_message", "session_id": "chat-one",
                                  "message_id": "user-one", "role": "user"}
        assert source.fingerprint == hashlib.sha256(b"I prefer concise answers.").hexdigest()
        assert len(store.list()) == 1


def test_crash_after_proposal_reuses_candidate_on_retry(core, monkeypatch):
    import ollama_code.memory_automation as automation

    original = automation.auto_save_candidate
    monkeypatch.setattr(automation, "auto_save_candidate", lambda *_a, **_k: (_ for _ in ()).throw(OSError("disk unavailable")))
    specs = prepare(core)
    with pytest.raises(OSError, match="disk unavailable"):
        save_cleanup_candidates(core, specs, "cleanup-one")
    with vault(core) as store:
        pending = store.list()
        assert len(pending) == 1 and pending[0]["status"] == "candidate"
    monkeypatch.setattr(automation, "auto_save_candidate", original)
    recovered = save_cleanup_candidates(core, specs, "cleanup-one")[0]
    assert recovered["status"] == "approved" and recovered["memory_id"] == pending[0]["id"]


def test_real_approval_failure_blocks_cleanup(core, monkeypatch):
    monkeypatch.setattr(MemoryEngine, "approve", lambda *_a, **_k: (_ for _ in ()).throw(VaultLocked("unavailable key")))
    with pytest.raises(MemoryError, match="unavailable key"):
        save_cleanup_candidates(core, prepare(core), "cleanup-one")


def test_readback_failure_blocks_cleanup(core, monkeypatch):
    monkeypatch.setattr(MemoryEngine, "get", lambda *_a, **_k: (_ for _ in ()).throw(NotFound("unavailable record")))
    with pytest.raises(MemoryError, match="unavailable record"):
        save_cleanup_candidates(core, prepare(core), "cleanup-one")


def test_owner_change_rejects_prepared_operation(core):
    specs = prepare(core)
    core.agent_id = str(uuid4())
    with pytest.raises(MemoryError, match="owner or source changed"):
        save_cleanup_candidates(core, specs, "cleanup-one")


def test_disabled_save_persists_candidate_and_revoked_scope_does_not_reroute(core):
    specs = prepare(core)
    core.agent_configuration = replace(core.agent_configuration,
        memory_policy=replace(MemoryPolicy(), auto_save_enabled=False))
    assert save_cleanup_candidates(core, specs, "cleanup-one")[0]["status"] == "pending"
    core.agent_configuration = replace(core.agent_configuration,
        memory_policy=replace(MemoryPolicy(), scopes=("workspace",)))
    assert save_cleanup_candidates(core, specs, "cleanup-one")[0]["status"] == "policy_disabled"


def test_unknown_sources_never_create_memory(core):
    specs = prepare_cleanup_candidates(core, [{"category": "personal_preference", "content": "I prefer red.",
        "source_ids": ["invented"]}], "cleanup-one", [])
    assert specs[0]["status"] == "unresolved"


def test_general_fact_default_and_explicit_scope_router(core):
    assert automatic_memory_scope("The build uses a compiler.") == "workspace"
    assert automatic_memory_scope("I prefer short replies.", kind="preference") == "personal"
    assert automatic_memory_scope("Use short replies for this task.", kind="preference") is None


def test_verified_lesson_uses_stable_agent_and_rechecks_changed_files(core, tmp_path):
    from ollama_code.core import AgentCore
    from ollama_code.runstore import RunStore
    from ollama_code.task_state import TaskStateStore, TaskVerifier

    live = AgentCore(cwd=core.cwd, model="fixture", skip_permissions=True,
        config={"provider": "ollama", "auto_compact": False})
    try:
        live.configure_agent({}, agent_id=core.agent_id)
        live._memory_profile_active = True
        runs = RunStore(tmp_path / "runs.sqlite3")
        live.usage_store = runs
        runs.start_run("run-one", request="Verify a reusable input check", workspace_root=core.cwd, run_kind="solo")
        tasks = TaskStateStore(runs)
        task_id = "run:run-one"
        path = tmp_path / "project" / "result.txt"
        path.write_text("ready")
        tasks.ensure(task_id, request="Verify a reusable input check", revision=1, workspace=core.cwd,
            execution=core.cwd, agent_id=core.agent_id, session_id=live.session.session_id, include_reusable=False)
        task = TaskVerifier(tasks, task_id, live, "run-one").verify([
            {"id": "ready", "kind": "file_contains", "path": "result.txt", "value": "ready",
             "requirement": "Result is ready"}], lambda *_: True)
        hints = cleanup_verification_context(live)
        assert hints[0]["task_id"] == task_id and hints[0]["receipt_ids"] == task["evidence_ids"]
        live._add_message({"role": "assistant", "content": "Validate inputs before consuming a result.", "_item_id": "user-one"})
        specs = prepare(live, text="Validate inputs before consuming a result.", category="specialist_lesson",
            source=[{"source_id": "user-one", "role": "assistant", "content": "Validate inputs before consuming a result."}],
            task_id=task_id, receipt_ids=task["evidence_ids"])
        saved = save_cleanup_candidates(live, specs, "cleanup-one")[0]
        assert saved["status"] == "approved" and saved["scope"] == "agent"
        live.agent_mode = "ask"
        assert cleanup_verification_context(live) == []
        live.agent_mode = "work"
        policy = live.agent_configuration.capability_policy
        live.agent_configuration = replace(live.agent_configuration,
            capability_policy=replace(policy, workspace_read=False))
        assert cleanup_verification_context(live) == []
        live.agent_configuration = replace(live.agent_configuration, capability_policy=policy)
        other = MemoryVault(workspace=str(tmp_path / "other"), agent_id=core.agent_id)
        try:
            assert saved["memory_id"] in {item["id"] for item in other.list()}
        finally:
            other.close()
        path.write_text("changed")
        assert cleanup_verification_context(live) == []
        with pytest.raises(MemoryError, match="verification changed"):
            save_cleanup_candidates(live, specs, "cleanup-one")
    finally:
        live.close()


def test_pending_duplicate_from_another_chat_is_retained_without_approval(core):
    first = save_cleanup_candidates(core, prepare(core), "cleanup-one", auto_save=False)[0]
    core.session.session_id = "another-chat"
    second = save_cleanup_candidates(core, prepare(core), "cleanup-one")[0]
    assert second["status"] == "pending"
    assert second["memory_id"] == first["memory_id"]


def test_conflicting_preference_is_saved_pending(core):
    save_cleanup_candidates(core, prepare(core, text="I prefer concise answers."), "cleanup-one")
    specs = prepare_cleanup_candidates(core, [{"category": "personal_preference", "content": "I prefer verbose answers.",
        "source_ids": ["different-message"]}], "cleanup-two",
        [{"source_id": "different-message", "role": "user", "content": "I prefer verbose answers."}])
    assert save_cleanup_candidates(core, specs, "cleanup-two")[0]["status"] == "pending"


def test_quoted_user_source_is_not_attested_as_a_direct_preference(core):
    specs = prepare(core, text="I prefer concise answers.", source=[{"source_id": "user-one", "role": "user",
        "content": 'Summarize this quotation: "I prefer concise answers."'}])
    assert specs[0]["basis"] == "model_interpretation"
    assert save_cleanup_candidates(core, specs, "cleanup-one")[0]["status"] == "pending"


@pytest.mark.parametrize("content", ["I prefer tabs in Atlas.", "I prefer tabs in atlas.", "I prefer tabs in the Atlas project."])
def test_ambiguous_named_project_preferences_never_become_personal(core, content):
    assert capture_user_memory(core, content) == []
    assert prepare(core, text=content)[0]["status"] == "unresolved"


def test_current_named_project_routes_to_workspace(core):
    assert automatic_memory_scope("I prefer tabs in Locus.", kind="preference", workspace="/work/Locus") == "workspace"
    core.workspace_root = core.cwd = "/work/Locus"
    assert prepare(core, text="I prefer tabs in Locus.")[0]["scope"] == "workspace"


def test_source_mutation_before_write_fails_and_creates_no_memory(core):
    from ollama_code.sessions import SessionStore

    core.session = SessionStore(core.cwd, model="fixture", provider="ollama")
    core.session.append_strict({"type": "message", "message": {
        "role": "user", "content": "I prefer concise answers.", "_item_id": "user-one"}})
    specs = prepare(core)
    original = core.session.path.read_text()
    core.session.path.write_text(original.replace("I prefer concise answers.", "I prefer verbose answers."))
    with pytest.raises(MemoryError, match="source evidence changed"):
        save_cleanup_candidates(core, specs, "cleanup-one")
    with vault(core) as store:
        assert store.list() == []


def test_capture_without_provider_ids_binds_actual_persisted_source(core):
    from ollama_code.sessions import SessionStore

    core.session = SessionStore(core.cwd, model="fixture", provider="ollama")
    core.session.append_strict({"type": "message", "message": {
        "role": "user", "content": "I prefer concise answers."}})
    source = SessionStore.cleanup_source_records(core.session.path)[0]
    result = capture_user_memory(core, "I prefer concise answers.")[0]
    with vault(core) as store:
        access, _ = store._access()
        record = store.engine.get(access, result["id"])
        assert any(item.locator.get("message_id") == source["source_id"] for item in record.sources)


def test_forgotten_candidate_cannot_resurface_on_prepared_retry(core):
    specs = prepare(core)
    first = save_cleanup_candidates(core, specs, "cleanup-one")[0]
    with vault(core) as store:
        assert store.delete(first["memory_id"])
    with pytest.raises(MemoryError):
        save_cleanup_candidates(core, specs, "cleanup-one")
    # A fresh operation is also blocked by the canonical suppression ledger.
    specs = prepare_cleanup_candidates(core, [{"category": "personal_preference", "content": "I prefer concise answers.",
        "source_ids": ["user-one"]}], "cleanup-new", [{"source_id": "user-one", "role": "user", "content": "I prefer concise answers."}])
    assert save_cleanup_candidates(core, specs, "cleanup-new")[0]["status"] == "suppressed"
    with vault(core) as store:
        assert store.list() == []
