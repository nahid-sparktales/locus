from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from locus_memory.models import RememberRequest, Scope

from ollama_code import paths
from ollama_code.agent_config import AgentConfiguration
from ollama_code.api.memory_inspector import (
    memory_submission,
    memory_submissions,
    propose_helper_result,
)
from ollama_code.memory_adapter import LegacyRecall, MemoryAdapter


@pytest.fixture
def host(tmp_path):
    workspace = str(tmp_path / "workspace")
    adapter = MemoryAdapter(app_dir=paths.APP_DIR, edition="locus")
    core = SimpleNamespace(workspace_root=workspace, cwd=workspace, identity_mode=False,
        agent_configuration=AgentConfiguration.parse({}), agent_id="primary", memory_adapter=adapter,
        memory_context="", reset_system_message=lambda: None, session=SimpleNamespace(session_id="session-a"),
        tool_ctx=SimpleNamespace(memory_run_id="run-a"), _memory_turn_id="turn-a")
    run = {"id": "run-a", "session_id": "session-a", "workspace_root": workspace,
           "manifest": {"memory_agent_id": "primary"}, "attempts": []}
    service = SimpleNamespace(core=core, run_store=SimpleNamespace(run=lambda rid: run if rid == "run-a" else None))
    yield service, adapter, run
    adapter.close()


def recall(host, text="violet"):
    service, adapter, _ = host
    core = service.core
    core.memory_context = adapter.recall(core, text, core.agent_configuration.memory_policy,
        just_chat=False, agent_id="primary", legacy=lambda: LegacyRecall(""))
    return adapter.begin_submission(core)


def test_final_packet_reference_explains_scope_and_current_content(host):
    service, adapter, _ = host
    access = adapter.access(service.core, "user")
    project = next(iter(access.grants.projects))
    item = adapter.engine.remember(access, RememberRequest(content="Violet deployment requires review.",
        scope=Scope.of(project=project))).record
    handle = recall(host)
    adapter.finish_submission(handle, state="submitted")
    listing = memory_submissions(service, run_id="run-a", turn_id=None)["submissions"]
    assert len(listing) == 1 and listing[0]["state"] == "submitted"
    detail = memory_submission(handle["submission_id"], service, run_id="run-a", include_content=True)
    row = detail["context"]["items"][0]
    assert row["record_id"] == item.id and row["scope"] == {"project": project}
    assert row["current_revision"] == row["compiled_revision"]
    assert row["current_content"] == item.content
    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"scopes": []}})
    narrowed = memory_submission(handle["submission_id"], service, run_id="run-a", include_content=True)
    assert narrowed["context"]["items"] == []


def test_unconfirmed_call_stays_uncertain_and_wrong_run_is_hidden(host):
    service, adapter, run = host
    adapter.engine.remember(adapter.access(service.core, "user"), RememberRequest(content="Violet preference", kind="preference"))
    handle = recall(host)
    adapter.finish_submission(handle, state="uncertain")
    assert memory_submissions(service, run_id="run-a", turn_id=None)["submissions"][0]["state"] == "uncertain"
    with pytest.raises(HTTPException) as exc:
        memory_submission(handle["submission_id"], service, run_id="other", include_content=True)
    assert exc.value.status_code == 404
    run["workspace_root"] = "/other/project"
    with pytest.raises(HTTPException):
        memory_submissions(service, run_id="run-a", turn_id=None)


def test_empty_context_still_explains_exclusions(host):
    service, adapter, _ = host
    adapter.engine.remember(adapter.access(service.core, "user"), RememberRequest(content="The production cluster is green."))
    handle = recall(host, "Who owns the unrelated payroll processor?")
    detail = memory_submission(handle["submission_id"], service, run_id="run-a", include_content=False)
    assert detail["submission"]["state"] == "skipped"
    assert detail["context"]["items"] == []
    assert detail["context"]["omissions"]


def test_helper_promotions_are_scoped_idempotent_candidates(host):
    service, adapter, run = host
    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"auto_save_enabled": False}})
    run["attempts"] = [{"attempt_id": "attempt-one", "agent_id": "helper-one", "state": "completed",
                        "result": {"output": "Violet deploys require passing the release tests."}}]
    first = propose_helper_result(service, "run-a", "attempt-one")
    second = propose_helper_result(service, "run-a", "attempt-one", agent=True)
    assert first["memory_id"] == second["memory_id"] and first["status"] == "candidate"
    assert first["requires_human_approval"] is True
    assert recall(host)["metadata"]["state"] == "skipped"
    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"proposals_enabled": False}})
    with pytest.raises(HTTPException) as exc:
        propose_helper_result(service, "run-a", "attempt-one", agent=True)
    assert exc.value.status_code == 403


def test_helper_discovery_is_saved_by_default_and_recalled(host):
    service, adapter, run = host
    run["attempts"] = [{"attempt_id": "attempt-one", "agent_id": "helper-one", "state": "completed",
                        "result": {"output": "Violet deploys require passing the release tests."}}]
    first = propose_helper_result(service, "run-a", "attempt-one", agent=True)
    second = propose_helper_result(service, "run-a", "attempt-one", agent=True)
    assert first == second
    assert first["status"] == "approved" and first["requires_human_approval"] is False
    assert recall(host)["metadata"]["state"] == "selected"


def test_private_identity_never_exposes_inspection_or_promotion(host):
    service, _, _ = host
    service.core.identity_mode = True
    with pytest.raises(HTTPException):
        memory_submissions(service, run_id="run-a", turn_id=None)


def test_inspection_reloads_saved_target_policy(host, monkeypatch):
    from locus_memory.policies import MemoryPolicy

    from ollama_code.api import memory_inspector
    service, adapter, run = host
    target = "90420610-299f-4bb8-b878-057409b30d29"
    run["manifest"]["profiles"] = [{"id": target}]
    monkeypatch.setattr(memory_inspector, "saved_memory_agent", lambda _: (
        target, AgentConfiguration.parse({"memory_policy": {"scopes": ["agent"]}})))
    _, scopes = memory_inspector._access(service, adapter, target, MemoryPolicy(), run)
    assert scopes == ("agent",)
    def missing(_):
        raise ValueError("profile removed")
    monkeypatch.setattr(memory_inspector, "saved_memory_agent", missing)
    _, scopes = memory_inspector._access(service, adapter, target, MemoryPolicy(), run)
    assert scopes == ()


def test_uuid_helper_keeps_owning_agent_policy_without_profile_lookup(host, monkeypatch):
    from locus_memory.policies import MemoryPolicy

    from ollama_code.api import memory_inspector
    service, adapter, run = host
    helper = "3da14bbc-86d5-413e-94cf-89294eae7f25"
    run["attempts"] = [{"agent_id": helper, "job_id": helper, "parent_node_id": "root"}]
    service.core.agent_configuration = AgentConfiguration.parse({"memory_policy": {"scopes": ["agent"]}})
    monkeypatch.setattr(memory_inspector, "saved_memory_agent", lambda _: pytest.fail("helper is not a saved profile"))
    _, scopes = memory_inspector._access(service, adapter, helper, MemoryPolicy(), run)
    assert scopes == ("agent",)


def test_helper_promotion_fails_closed_when_bound_agent_is_missing(host, monkeypatch):
    from ollama_code.api import memory_inspector
    service, _, run = host
    run["attempts"] = [{"attempt_id": "attempt-one", "agent_id": "helper-one", "state": "completed",
                        "result": {"output": "A useful helper result"}}]
    def missing(_):
        raise ValueError("profile removed")
    monkeypatch.setattr(memory_inspector, "trusted_memory_agent", missing)
    with pytest.raises(HTTPException) as exc:
        propose_helper_result(service, "run-a", "attempt-one")
    assert exc.value.status_code == 409
