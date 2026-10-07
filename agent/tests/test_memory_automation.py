"""Automatic memory uses trusted settings while retaining package write boundaries."""
from dataclasses import replace
from types import SimpleNamespace

import pytest
from locus_memory.models import Actor

from ollama_code.agent_config import AgentConfiguration
from ollama_code.memory import MemoryError, MemoryVault
from ollama_code.memory_automation import auto_save_candidate, capture_user_memory
from ollama_code.memory_policy import MemoryPolicy


@pytest.fixture
def core(tmp_path):
    workspace = str(tmp_path / "workspace")
    return SimpleNamespace(workspace_root=workspace, cwd=workspace, identity_mode=False,
        memory_evaluation_disabled=False, agent_mode="work", agent_id="primary",
        agent_configuration=AgentConfiguration(memory_policy=MemoryPolicy()),
        session=SimpleNamespace(session_id="chat-one"),
        tool_ctx=SimpleNamespace(memory_run_id="run-one"), chatgpt_parity_active=lambda: False)


def _vault(core, **kwargs):
    return MemoryVault(workspace=core.workspace_root, agent_id=core.agent_id, **kwargs)


def _propose(core, **value):
    vault = _vault(core, actor=Actor.AGENT)
    try:
        return vault.save({"title": "Color", "content": "The favorite color is violet.",
            "scope": "workspace", "status": "candidate", "kind": "fact",
            "source_session_id": "chat-one", "source_run_id": "run-one", **value})
    finally:
        vault.close()


def _save(core, candidate, policy=None, **kwargs):
    return auto_save_candidate(candidate, policy=policy or core.agent_configuration.memory_policy,
        workspace=core.workspace_root, agent_id=core.agent_id, **kwargs)


def test_policy_defaults_and_explicit_disabled_values_roundtrip():
    policy = MemoryPolicy.parse(None)
    assert policy.auto_save_enabled and policy.native_codex_enabled and policy.automatic_recall_enabled
    disabled = MemoryPolicy.parse({"auto_save_enabled": False, "native_codex_enabled": False,
        "recall_enabled": False, "proposals_enabled": False, "scopes": ["personal"],
        "max_automatic_tokens": 50000})
    assert not disabled.auto_save_enabled and not disabled.native_codex_enabled
    assert not disabled.recall_enabled and not disabled.proposals_enabled
    assert disabled.scopes == ("personal",) and disabled.max_automatic_tokens == 4000
    assert MemoryPolicy.parse({**disabled.__dict__, "scopes": list(disabled.scopes)}) == disabled
    assert replace(policy, scopes=()).auto_save_enabled


def test_direct_statement_is_saved_recallable_and_deduplicated(core):
    records = capture_user_memory(core, "I prefer concise answers.")
    assert len(records) == 1 and records[0]["status"] == "approved"
    assert records[0]["source_session_id"] == "chat-one"
    assert records[0]["source_run_id"] == "run-one"
    assert capture_user_memory(core, "I prefer concise answers.") == []
    vault = _vault(core)
    try:
        assert vault.search("concise answers")[0]["id"] == records[0]["id"]
    finally:
        vault.close()


def test_disabled_automatic_save_keeps_candidate_out_of_recall(core):
    core.agent_configuration = replace(core.agent_configuration,
        memory_policy=replace(MemoryPolicy(), auto_save_enabled=False))
    records = capture_user_memory(core, "I prefer concise answers.")
    assert len(records) == 1 and records[0]["status"] == "candidate"
    vault = _vault(core)
    try:
        assert vault.search("concise answers") == []
    finally:
        vault.close()


@pytest.mark.parametrize("change", ["private", "evaluation", "read_only", "helper", "disabled", "empty_scopes", "native_disabled"])
def test_capture_respects_turn_and_memory_settings(core, change):
    policy = MemoryPolicy()
    if change == "private":
        core.identity_mode = True
    elif change == "evaluation":
        core.memory_evaluation_disabled = True
    elif change == "read_only":
        core.evaluation_read_only = True
    elif change == "helper":
        core.agent_role_contract = "Complete the assigned helper task."
    elif change == "disabled":
        policy = replace(policy, proposals_enabled=False)
    elif change == "empty_scopes":
        policy = replace(policy, scopes=())
    else:
        core.chatgpt_parity_active = lambda: True
        policy = replace(policy, native_codex_enabled=False)
    core.agent_configuration = replace(core.agent_configuration, memory_policy=policy)
    assert capture_user_memory(core, "I prefer concise answers.") == []


@pytest.mark.parametrize("text", ["What do I prefer?", "Always use violet?", '"I prefer concise answers."',
    "> I prefer concise answers.", "I prefer concise answers.\nQuoted transcript follows.",
    "Remember this password: hunter2", "Always run `make check`.", "The article says I prefer violet."])
def test_capture_excludes_questions_quoted_content_code_and_secrets(core, text):
    assert capture_user_memory(core, text) == []


def test_ask_capture_uses_only_an_allowed_non_workspace_scope(core):
    core.agent_mode = "ask"
    records = capture_user_memory(core, "I prefer concise answers.")
    assert records[0]["scope"] == "personal"
    core.agent_configuration = replace(core.agent_configuration,
        memory_policy=replace(MemoryPolicy(), scopes=("workspace",)))
    assert capture_user_memory(core, "I prefer violet answers.") == []


def test_host_saves_only_actual_candidate_and_agent_cannot_approve(core):
    candidate = _propose(core)
    vault = _vault(core, actor=Actor.AGENT)
    try:
        with pytest.raises(MemoryError):
            vault.approve(candidate["id"])
    finally:
        vault.close()
    result = _save(core, {"id": candidate["id"], "content": "Forged content", "status": "approved"},
        session_id="chat-one", run_id="run-one")
    assert result["status"] == "approved"
    assert result["content"] == candidate["content"]


def test_scopes_and_source_binding_prevent_saving_other_candidates(core):
    candidate = _propose(core, scope="personal")
    with pytest.raises(MemoryError, match="scope"):
        _save(core, candidate, replace(MemoryPolicy(), scopes=("workspace",)))
    with pytest.raises(MemoryError, match="source"):
        _save(core, candidate, session_id="another-chat")


def test_conflicting_candidate_remains_in_inbox(core):
    vault = _vault(core)
    try:
        vault.save({"title": "Color", "content": "The favorite color is turquoise.", "scope": "workspace"})
    finally:
        vault.close()
    candidate = _propose(core)
    assert _save(core, candidate)["status"] == "candidate"


def test_explicit_false_does_not_approve_model_proposals(core):
    candidate = _propose(core)
    assert _save(core, candidate, replace(MemoryPolicy(), auto_save_enabled=False))["status"] == "candidate"
    assert _save(core, candidate, replace(MemoryPolicy(), proposals_enabled=False))["status"] == "candidate"


def test_forgotten_statement_is_not_saved_again(core):
    saved = capture_user_memory(core, "I prefer concise answers.")[0]
    vault = _vault(core)
    try:
        assert vault.delete(saved["id"])
    finally:
        vault.close()
    assert capture_user_memory(core, "I prefer concise answers.") == []
