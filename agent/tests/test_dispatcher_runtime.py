from __future__ import annotations

import json

import pytest

from ollama_code.agent_config import AgentConfiguration, compose_system_prompt
from ollama_code.core import AgentCore
from ollama_code.dispatcher_runtime import SKILL_ID, TOOL_NAME, is_dispatcher_request
from ollama_code.extensions import ExtensionManager
from ollama_code.sessions import SessionMeta
from ollama_code.tools import ToolContext


@pytest.fixture
def pack(tmp_path, monkeypatch):
    root = tmp_path / "bundled" / "agent-dispatcher"
    (root / "roles").mkdir(parents=True)
    (root / "guides" / "testing").mkdir(parents=True)
    (root / "references").mkdir()
    (root / "SKILL.md").write_text("---\nname: agent-dispatcher\ndescription: Choose a specialist\n---\nDispatcher pack.")
    (root / "SOURCE.json").write_text(json.dumps({"activation": "explicit"}))
    rows = []
    for identifier, name in (("reviewer", "Reviewer"), ("implementer", "Implementer"), ("dispatcher", "Dispatcher")):
        (root / "roles" / f"{identifier}.md").write_text(f"# {name}\n{identifier} working method.")
        rows.append({"id": identifier, "name": name, "aliases": ["coder"] if identifier == "implementer" else [],
                     "role_path": f"roles/{identifier}.md", "use_when": f"Need a {identifier}",
                     "not_for": "Unrelated work", "skills": {"core": ["testing"]}})
    (root / "catalog.json").write_text(json.dumps({"schema_version": 1, "roles": rows}))
    (root / "guides" / "testing" / "GUIDE.md").write_text("Verify observable behavior.")
    (root / "references" / "CONTEXT.md").write_text("Inspect the relevant source files.")
    monkeypatch.setattr("ollama_code.extensions.BUILTIN_SKILLS_ROOT", root.parent)
    return root


@pytest.fixture
def core(tmp_path, pack):
    return AgentCore(cwd=str(tmp_path), config={"model": "fixture"})


def test_default_dispatcher_is_separate_from_other_startup_skills(core):
    assert core.dispatcher.enabled()
    assert core.extensions.startup_skills(core.cwd) == []
    core.tool_registry.begin_turn("Fix this issue", core.cwd)
    assert core.tool_registry.explicit_skill_context == ""
    prompt = core.system_message()["content"]
    assert "Locus Agent Dispatcher" in prompt
    assert '"mode": "automatic"' in prompt
    assert "observation workflows" in prompt


@pytest.mark.parametrize("mode", ["work", "plan", "grill"])
def test_dispatcher_is_available_in_tool_chat_modes(core, mode):
    core.configure_agent({}, mode=mode)
    assert core.dispatcher.enabled()
    assert "reviewer working method" in core.tool_registry.execute(
        TOOL_NAME, {"path": "roles/reviewer.md"}, core.tool_ctx)
    assert core.dispatcher.state()["active_role_id"] == "reviewer"


@pytest.mark.parametrize("mode", ["ask", "build"])
def test_just_chat_and_retired_mode_never_load_dispatcher(core, mode):
    core.configure_agent({"specialist_role_id": "reviewer"}, mode=mode)
    assert not core.dispatcher.enabled()
    assert "Locus Agent Dispatcher" not in core.system_message()["content"]
    assert "reviewer working method" not in core.system_message()["content"]
    assert core.dispatcher.control("/agent-dispatcher on") == (False, None)
    assert core.dispatcher.read("roles/reviewer.md").startswith("Error:")
    assert TOOL_NAME not in {schema["function"]["name"] for schema in core.tool_registry.schemas()}


def test_global_toggle_refreshes_across_conversation_workers(core):
    another = ExtensionManager(core.cwd, root=core.extensions.root)
    another.set_skill_enabled(SKILL_ID, False)
    assert not core.dispatcher.enabled()
    core.dispatcher.control("/agent-dispatcher on")
    assert not core.dispatcher.enabled(), "a conversation cannot bypass the global Skills switch"
    another.set_skill_enabled(SKILL_ID, True)
    assert core.dispatcher.enabled()


def test_conversation_controls_persist_without_touching_other_chats(core):
    first_id = core.session.session_id
    core.dispatcher.control("/agent-dispatcher reviewer")
    core.dispatcher.control("/agent-dispatcher output verbose")
    assert core.dispatcher.fixed_role_id() == "reviewer"
    core.start_new_session()
    second_id = core.session.session_id
    assert core.dispatcher.fixed_role_id() is None
    assert core.dispatcher.state()["output"] == "compact"
    core.dispatcher.control("/agent-dispatcher off")
    assert not core.dispatcher.enabled()
    core.resume_session(first_id)
    assert core.dispatcher.fixed_role_id() == "reviewer"
    assert core.dispatcher.state()["output"] == "verbose"
    assert SessionMeta.get(second_id)["agent_dispatcher"]["enabled"] is False


def test_fixed_saved_role_only_changes_on_explicit_user_control(core):
    core.configure_agent({"specialist_role_id": "reviewer"})
    assert core.dispatcher.fixed_role_id() == "reviewer"
    assert core.dispatcher.read("./roles/implementer.md").startswith("Error:")
    assert '"mode": "fixed"' in core.dispatcher.turn_prompt()
    assert core.dispatcher.read("roles/implementer.md").startswith("Error:")
    recognized, reply = core.dispatcher.control("$agent-dispatcher coder Implement this task")
    assert recognized and reply is None
    assert core.dispatcher.fixed_role_id() == "implementer"
    assert "implementer working method" in core.dispatcher.turn_prompt()
    assert core.agent_configuration.specialist_role_id == "reviewer"
    assert core.dispatcher.control("Be the reviewer")[0]
    assert core.dispatcher.fixed_role_id() == "reviewer"
    core.dispatcher.control("/agent-dispatcher auto")
    assert core.dispatcher.fixed_role_id() is None
    assert '"mode": "automatic"' in core.dispatcher.turn_prompt()
    assert "implementer working method" in core.dispatcher.read("roles/implementer.md")


def test_edited_saved_instructions_replace_the_packaged_role_method(core):
    core.configure_agent({"specialist_role_id": "reviewer", "custom_instructions": "Review accessibility only."})
    for content in (core.system_message()["content"], core.dispatcher.turn_prompt(),
                    core.dispatcher.read("roles/reviewer.md")):
        assert "Review accessibility only." in content
        assert "reviewer working method" not in content
    assert core.dispatcher.read("./roles/reviewer.md").startswith("Error:")
    core.dispatcher.control("$agent-dispatcher implementer")
    assert "implementer working method" in core.dispatcher.turn_prompt()


def test_custom_saved_agent_does_not_implicitly_change_specialty(core):
    core.configure_agent({"custom_instructions": "Help with accounting."}, agent_id="saved-agent")
    assert not core.dispatcher.enabled()
    assert '"mode": "custom"' in core.dispatcher.turn_prompt()
    assert "Help with accounting." in core.system_message()["content"]
    core.dispatcher.control("/agent-dispatcher reviewer")
    assert core.dispatcher.enabled()
    assert core.dispatcher.fixed_role_id() == "reviewer"


@pytest.mark.parametrize("mode", ["ask", "work", "plan", "grill"])
def test_detached_session_persists_selected_default_mode(tmp_path, mode):
    from ollama_code.api.sessions import session_detached
    result = session_detached({"cwd": str(tmp_path), "title": "Specialist", "mode": mode,
                               "execution_environment": "local"})
    assert SessionMeta.get(result["session_id"])["mode"] == mode
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture"})
    core.resume_session(result["session_id"])
    assert core.session_info()["initial_mode"] == mode
    core.session.append({"type": "message", "message": {"role": "user", "content": "An existing conversation"}})
    assert core.session_info()["initial_mode"] is None
    assert SessionMeta.get(result["session_id"])["mode"] == mode


@pytest.mark.parametrize("mode", [[], {}, "invalid"])
def test_detached_session_rejects_invalid_default_mode(tmp_path, mode):
    from fastapi import HTTPException

    from ollama_code.api.sessions import session_detached
    with pytest.raises(HTTPException) as error:
        session_detached({"cwd": str(tmp_path), "title": "Specialist", "mode": mode})
    assert error.value.status_code == 422


def test_controls_only_parse_actual_prefixed_user_requests(core):
    for text in ("Read this document: /agent-dispatcher off", "```\n/agent-dispatcher off\n```",
                 "The report says: stop dispatcher", "Agent Dispatcher off"):
        assert not is_dispatcher_request(text)
        assert core.dispatcher.control(text) == (False, None)
    decorated = "[Locus mode: Work]\n\nSolve the task.\n\nUser request:\n/agent-dispatcher off"
    assert core.dispatcher.control(decorated)[0]
    assert not core.dispatcher.enabled()


def test_read_returns_contents_and_confines_pack_resources(core, pack, tmp_path):
    assert "Verify observable behavior" in core.dispatcher.read("guides/testing/GUIDE.md")
    outside = tmp_path / "secret.md"
    outside.write_text("Do not expose")
    (pack / "references" / "escape.md").symlink_to(outside)
    for path in ("../secret.md", str(outside), "references/escape.md", "scripts/context.py"):
        assert core.dispatcher.read(path).startswith("Error:")
    huge = pack / "references" / "huge.md"
    huge.write_text("x" * 64_001)
    assert "64 KB" in core.dispatcher.read("references/huge.md")


def test_controls_finish_without_calling_the_provider(core, monkeypatch):
    def forbidden(*_, **__):
        raise AssertionError("inspection controls must not call a model")
    monkeypatch.setattr(core, "_run_classic_turn", forbidden)
    events = []
    core.on_event(events.append)
    core.run_turn("/agent-dispatcher context")
    assert core.last_turn_result["model_calls"] == 0
    assert "did not execute the task" in core.messages[-1]["content"]
    assert any(event["type"] == "assistant_item_end" for event in events)
    assert events[-2]["type"] == "turn_done"


@pytest.mark.parametrize("missing_tools", [(), ("rg",), ("rg", "git")],
                         ids=["available-tools", "without-ripgrep", "without-enumerators"])
def test_context_control_selects_source_evidence_without_workspace_writes(tmp_path, monkeypatch, missing_tools):
    import shutil
    original_which = shutil.which
    monkeypatch.setattr(shutil, "which", lambda command: None if command in missing_tools else original_which(command))
    project = tmp_path / "project"
    project.mkdir()
    (project / "billing.py").write_text("def calculate_invoice_total(items):\n    return sum(items)\n")
    core = AgentCore(cwd=str(project), config={"model": "fixture"})
    core._add_message({"role": "user", "content": "Review calculate_invoice_total in billing.py"})
    before = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*") if path.is_file()}
    result = core.dispatcher.inspect_context("context explain")
    assert "billing.py:" in result
    assert "Selected excerpts:" in result
    assert "did not execute the task or write project files" in result
    after = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*") if path.is_file()}
    assert after == before


def test_context_control_respects_disabled_workspace_access(core):
    core._add_message({"role": "user", "content": "Inspect project files"})
    core.configure_agent({"capability_policy": {"workspace_read": False}})
    assert "Workspace reading is disabled" in core.dispatcher.inspect_context()


def test_context_looks_past_natural_role_controls_to_the_real_task(core):
    core._add_message({"role": "user", "content": "Review billing.py behavior"})
    core.run_turn("Be the reviewer.")
    assert core.dispatcher.fixed_role_id() == "reviewer"
    assert core.dispatcher._recent_task() == "Review billing.py behavior"


def test_specialist_behavior_roundtrip_and_team_prompt(pack):
    assert AgentConfiguration.parse({}).specialist_role_id is None
    config = AgentConfiguration.parse({"specialist_role_id": " reviewer "})
    assert AgentConfiguration.parse(config.structured()) == config
    assert AgentConfiguration.parse({"specialist_role_id": "../../secret"}).specialist_role_id is None
    prompt, _ = compose_system_prompt("Respect permissions", config, mode="work")
    assert "reviewer working method" in prompt
    prompt, _ = compose_system_prompt("No tools", config, mode="ask")
    assert "reviewer working method" not in prompt


def test_capability_disable_and_helper_controls_are_enforced(core):
    core.configure_agent({"capability_policy": {"mcp": False}})
    assert not core.dispatcher.enabled()
    assert TOOL_NAME not in {schema["function"]["name"] for schema in core.tool_registry.schemas()}
    assert core.tool_registry.execute(TOOL_NAME, {"path": "roles/reviewer.md"}, ToolContext(cwd=core.cwd)).startswith("Error:")
    core.configure_agent({}, role_contract="Scoped helper")
    assert core.dispatcher.control("/agent-dispatcher off everywhere") == (False, None)
    assert core.dispatcher.read("roles/dispatcher.md").startswith("Error:")


def test_native_thread_reuses_contract_across_role_and_global_toggles(tmp_path, pack):
    from test_chatgpt_app_server import ParityFakeRuntime, _managed_core
    runtime = ParityFakeRuntime()
    core = _managed_core(tmp_path, runtime)
    core.run_turn("Investigate the code")
    first = runtime.start_kwargs[0]["options"].developer_instructions
    assert "Locus Agent Dispatcher" in first
    assert TOOL_NAME in {schema["function"]["name"] for schema in runtime.start_kwargs[0]["tools"]}
    core.run_turn("/agent-dispatcher reviewer")
    core.run_turn("Review the code")
    content = "\n".join(item.get("text", "") for item in runtime.turn_kwargs[-1]["input_items"])
    assert "reviewer working method" in content
    core.run_turn("/agent-dispatcher off everywhere")
    core.run_turn("Explain this code")
    content = "\n".join(item.get("text", "") for item in runtime.turn_kwargs[-1]["input_items"])
    assert '"enabled": false' in content
    assert runtime.started == ["thread-1"]
    assert core._parity_developer_instructions() == first


def test_helper_does_not_inherit_saved_root_specialty(tmp_path, pack):
    from test_collaboration_bridge import service, worker
    svc = service(tmp_path)
    svc.core.configure_agent({"specialist_role_id": "implementer", "custom_instructions": "Implement everything",
                              "mode_instructions": {"plan": "Plan only implementation", "work": "Always implement"}})
    svc.core.dispatcher.control("/agent-dispatcher output verbose")
    svc.core.dispatcher.control("/agent-dispatcher off")
    runtime = worker(svc, tmp_path)
    try:
        assert runtime.core.agent_configuration.specialist_role_id is None
        assert "Implement everything" not in runtime.core.system_message()["content"]
        assert "Plan only implementation" not in runtime.core.system_message()["content"]
        assert runtime.core.agent_configuration.mode_instructions == {}
        assert runtime.core.dispatcher.fixed_role_id() is None
        assert not runtime.core.dispatcher.enabled()
        assert runtime.core.dispatcher.state() == {
            "enabled": False, "output": "verbose", "forced_role_id": None,
            "active_role_id": None, "role_mode": None,
        }
        assert svc.core.agent_configuration.specialist_role_id == "implementer"
    finally:
        runtime.close()


def test_legacy_helper_read_keeps_root_fixed_role_and_uses_its_own_method(core):
    core.configure_agent({"specialist_role_id": "implementer", "custom_instructions": "Implement everything"})
    result = core.run_solo_worker_tool(TOOL_NAME, {"path": "roles/reviewer.md"}, "helper-read", None,
                                       event_context={"agent_id": "helper"}, execution_lock=None)
    assert "reviewer working method" in result
    assert core.dispatcher.fixed_role_id() == "implementer"
    assert core.dispatcher.state()["active_role_id"] is None
