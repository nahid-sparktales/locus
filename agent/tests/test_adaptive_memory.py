"""Prepared memory stays scoped, bounded, receipt-bound and separate from active turns."""
import json
import time
from dataclasses import FrozenInstanceError, replace
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from locus_memory.models import Correction, ForgetTarget, RememberRequest, Scope

from ollama_code.memory_adapter import MemoryAdapter
from ollama_code.memory_canonical import CanonicalMemoryVault
from ollama_code.memory_policy import MemoryPolicy


@pytest.fixture
def memory(isolated_app_dir, tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    policy = MemoryPolicy.parse({})
    core = SimpleNamespace(
        workspace_root=str(workspace), cwd=str(workspace), agent_id="primary", agent_mode="work",
        provider="ollama", identity_mode=False, agent_configuration=SimpleNamespace(memory_policy=policy),
        tool_ctx=SimpleNamespace(memory_run_id="run-one"), session=SimpleNamespace(session_id="session-one"),
        _memory_turn_id="turn-one", _output_run_id="run-one", memory_context="", continuity_context="",
        reset_system_message=Mock(), chatgpt_parity_active=lambda _allow: False,
    )
    adapter = MemoryAdapter(app_dir=isolated_app_dir, edition="locus", mode="enabled")
    yield adapter, core, policy
    adapter.close()


def remember(memory, content="Release project uses violet deployments.", *, scope="workspace", agent_id="primary"):
    adapter, core, _ = memory
    access = adapter.access(core, "user", agent_id=agent_id)
    selected = Scope() if scope == "personal" else (
        Scope.of(agent=agent_id) if scope == "agent" else Scope.of(project=next(iter(access.grants.projects))))
    return adapter.engine.remember(access, RememberRequest(content=content, title="Release project", scope=selected)).record


def prepare(memory, query="release project", **kwargs):
    adapter, core, policy = memory
    return adapter.prepare_retrieval(core, query, policy, agent_id=core.agent_id,
                                     just_chat=core.agent_mode == "ask", **kwargs)


def install(memory, prepared):
    adapter, core, policy = memory
    return adapter.install_retrieval(core, prepared, policy, agent_id=core.agent_id,
                                     just_chat=core.agent_mode == "ask")


def test_preparation_does_not_change_active_core_or_pending_packet(memory):
    adapter, core, _ = memory
    record = remember(memory)
    first = prepare(memory)
    assert first.available and first.item_count == 1
    assert core.memory_context == "" and adapter._pending == {}
    with pytest.raises(FrozenInstanceError):
        first.available = False
    install(memory, first)
    before, pending = vars(core).copy(), adapter._pending.copy()
    second = prepare(memory)
    assert vars(core) == before and adapter._pending == pending
    assert record.id in second._packet.text


def test_install_exact_packet_and_submission_receipt_and_content_free_details(memory):
    adapter, core, _ = memory
    record = remember(memory)
    prepared = prepare(memory)
    text = install(memory, prepared)
    assert text == core.memory_context == prepared._packet.text
    details = adapter.retrieval_details(core)
    assert details["items"][0]["id"] == record.id
    assert details["items"][0]["revision"] == record.revision
    assert details["receipt_id"] == prepared.receipt_id
    assert details["byte_count"] == len(text.encode())
    assert "violet" not in json.dumps(details)
    submission = adapter.begin_submission(core)
    assert submission["metadata"]["context_receipt_id"] == prepared.receipt_id
    assert submission["metadata"]["state"] == "selected"
    adapter.finish_submission(submission, state="submitted")


@pytest.mark.parametrize("change", ["turn", "session", "run", "workspace", "agent", "policy", "ask"])
def test_late_prepared_results_do_not_replace_current_context(memory, change):
    _, core, policy = memory
    remember(memory)
    old = prepare(memory)
    if change == "turn":
        core._memory_turn_id = "turn-two"
    elif change == "session":
        core.session.session_id = "session-two"
    elif change == "run":
        core.tool_ctx.memory_run_id = "run-two"
    elif change == "workspace":
        core.workspace_root += "-other"
    elif change == "agent":
        core.agent_id = "reviewer"
    elif change == "ask":
        core.agent_mode = "ask"
    else:
        core.agent_configuration.memory_policy = replace(policy, recall_enabled=False)
    core.memory_context = "newer turn's context"
    assert install(memory, old) == ""
    assert core.memory_context == "newer turn's context"


def test_personal_switch_and_ask_workspace_boundary(memory):
    adapter, core, policy = memory
    private = remember(memory, "Release project private personal fact.", scope="personal")
    workspace = remember(memory, "Release project uses workspace deployment.")
    agent = remember(memory, "Release project agent review preference.", scope="agent")
    other = remember(memory, "Release project another agent secret.", scope="agent", agent_id="other")
    restricted = replace(policy, scopes=("workspace", "agent"))
    core.agent_configuration.memory_policy = restricted
    selected = adapter.prepare_retrieval(core, "release project", restricted, agent_id="primary")
    ids = {item.record_id for item in selected._packet.items}
    assert {workspace.id, agent.id} <= ids
    assert not {private.id, other.id} & ids
    core.agent_mode = "ask"
    selected = adapter.prepare_retrieval(core, "release project", restricted, agent_id="primary", just_chat=True)
    assert {item.record_id for item in selected._packet.items} == {agent.id}


@pytest.mark.parametrize("blocked", ["disabled", "shadow", "identity", "native", "policy"])
def test_unavailable_paths_do_not_read_or_install(memory, monkeypatch, blocked):
    adapter, core, policy = memory
    if blocked in {"disabled", "shadow"}:
        adapter.mode = blocked
    elif blocked == "identity":
        core.identity_mode = True
    elif blocked == "native":
        core.chatgpt_parity_active = lambda _allow: True
        policy = replace(policy, native_codex_enabled=False)
    else:
        policy = replace(policy, recall_enabled=False)
    core.agent_configuration.memory_policy = policy
    touched = Mock(side_effect=AssertionError("must not open memory"))
    monkeypatch.setattr(adapter, "_prepare_memory", touched)
    result = adapter.prepare_retrieval(core, "release project", policy, agent_id="primary")
    assert not result.available and result.diagnostics
    touched.assert_not_called()


def test_deadline_and_cancellation_are_public_package_inputs(memory, monkeypatch):
    adapter, core, policy = memory
    remember(memory)
    build = adapter.engine.build_context
    calls = []
    def inspect(access, request, *, cancel):
        calls.append((request, cancel))
        return build(access, request, cancel=cancel)
    monkeypatch.setattr(adapter.engine, "build_context", inspect)
    result = prepare(memory, deadline=time.monotonic() + 2, should_stop=lambda: False)
    assert result.available and 0 < calls[0][0].deadline_ms <= 2000
    assert calls[0][0].token_allowance == policy.max_automatic_tokens
    assert not calls[0][1].cancelled
    assert not prepare(memory, deadline=time.monotonic() - 1).available
    assert not prepare(memory, should_stop=lambda: True).available
    assert len(calls) == 1 and core.memory_context == ""


def test_cancellation_during_compilation_discards_result(memory, monkeypatch):
    adapter, _, _ = memory
    remember(memory)
    stopped = False
    build = adapter.engine.build_context
    def complete_late(*args, **kwargs):
        nonlocal stopped
        packet = build(*args, **kwargs)
        stopped = True
        return packet
    monkeypatch.setattr(adapter.engine, "build_context", complete_late)
    assert not prepare(memory, should_stop=lambda: stopped).available
    assert adapter._pending == {}


def test_utf8_budget_recompiles_instead_of_truncating(memory, monkeypatch):
    adapter, core, policy = memory
    remember(memory, "Release project release project " + "界" * 240)
    remember(memory, "Release project compact deployment fact.")
    full = prepare(memory, max_bytes=12000)
    limit = full.byte_count - 100
    calls = []
    build = adapter.engine.build_context
    def inspect(access, request, **kwargs):
        calls.append(request.token_allowance)
        return build(access, request, **kwargs)
    monkeypatch.setattr(adapter.engine, "build_context", inspect)
    bounded = prepare(memory, max_bytes=limit)
    assert bounded.available and bounded.byte_count <= limit
    assert len(calls) >= 2 and calls[-1] < calls[0] == policy.max_automatic_tokens
    text = install(memory, bounded)
    assert text == bounded._packet.text if bounded.item_count else text == ""
    assert len(core.memory_context.encode()) <= limit


def test_markdown_edit_between_prepare_and_install_revalidates_receipt(memory):
    adapter, core, _ = memory
    record = remember(memory, scope="personal")
    prepared = prepare(memory)
    path = adapter.app_dir / "memories" / "USER.md"
    path.write_text(path.read_text().replace("violet", "turquoise"))
    assert "turquoise" in install(memory, prepared)
    details = adapter.retrieval_details(core)
    assert details["items"][0]["revision"] > record.revision
    assert details["receipt_id"] != prepared.receipt_id
    assert adapter.begin_submission(core)["metadata"]["context_receipt_id"] == details["receipt_id"]


def test_forgotten_prepared_memory_is_not_installed(memory):
    adapter, core, _ = memory
    record = remember(memory)
    prepared = prepare(memory)
    adapter.engine.forget(adapter.access(core, "user"), ForgetTarget("memory", record.id))
    assert install(memory, prepared) == "" and core.memory_context == ""
    assert adapter.begin_submission(core)["metadata"]["state"] == "skipped"


def test_revalidation_growth_drops_over_budget_packet_without_truncation(memory):
    adapter, core, _ = memory
    record = remember(memory)
    full = prepare(memory)
    bounded = prepare(memory, max_bytes=full.byte_count + 20)
    assert install(memory, bounded)
    adapter.engine.correct(adapter.access(core, "user"), record.id,
                           Correction(content="Release project " + "界" * 300), expected_revision=record.revision)
    details = adapter.retrieval_details(core)
    assert core.memory_context == "" and not details["available"]
    assert adapter.begin_submission(core)["metadata"]["state"] == "skipped"


def test_native_opt_out_after_install_removes_layer(memory):
    adapter, core, policy = memory
    remember(memory)
    assert install(memory, prepare(memory))
    core.chatgpt_parity_active = lambda _allow: True
    core.agent_configuration.memory_policy = replace(policy, native_codex_enabled=False)
    assert adapter.retrieval_details(core)["items"] == []
    assert core.memory_context == ""


def test_malformed_markdown_fails_closed_and_keeps_source(memory):
    adapter, core, _ = memory
    remember(memory, scope="personal")
    prepared = prepare(memory)
    path = adapter.app_dir / "memories" / "USER.md"
    malformed = path.read_text().replace("<!-- locus-memory", "<!-- broken-memory", 1)
    path.write_text(malformed)
    assert install(memory, prepared) == "" and core.memory_context == ""
    assert path.read_text() == malformed


def test_explicit_search_uses_real_search_policy_through_submission(memory):
    adapter, core, policy = memory
    remember(memory)
    policy = replace(policy, recall_enabled=False, search_enabled=True)
    core.agent_configuration.memory_policy = policy
    assert not adapter.prepare_retrieval(core, "release project", policy, agent_id="primary").available
    selected = adapter.prepare_retrieval(core, "release project", policy, agent_id="primary", automatic=False)
    assert selected.available and selected.item_count
    # A manual packet cannot be adopted as automatic recall.
    assert adapter.install_retrieval(core, selected, policy, agent_id="primary") == ""
    assert adapter.install_retrieval(core, selected, policy, agent_id="primary", automatic=False)
    assert adapter.retrieval_details(core)["available"]
    assert adapter.begin_submission(core)["metadata"]["state"] == "selected"
    core.agent_configuration.memory_policy = replace(policy, search_enabled=False)
    assert not adapter.retrieval_details(core)["available"] and core.memory_context == ""


@pytest.mark.parametrize("settings", [{"search_enabled": False}, {"max_automatic_tokens": 0},
                                     {"max_automatic_memories": 0}])
def test_explicit_search_respects_search_and_budget_switches(memory, settings):
    adapter, core, policy = memory
    policy = replace(policy, **settings)
    core.agent_configuration.memory_policy = policy
    assert not adapter.prepare_retrieval(core, "release project", policy, agent_id="primary", automatic=False).available


def test_empty_selection_has_receipt_but_no_layer_and_no_false_delivery(memory):
    adapter, core, _ = memory
    prepared = prepare(memory)
    assert prepared.available and prepared.item_count == prepared.byte_count == 0
    assert install(memory, prepared) == ""
    details = adapter.retrieval_details(core)
    assert details["available"] and details["items"] == [] and details["byte_count"] == 0
    assert details["receipt_id"] == prepared.receipt_id
    assert adapter.begin_submission(core)["metadata"]["state"] == "skipped"
    remember(memory)
    # Revalidation may discover new memories, but they were never injected.
    assert adapter.retrieval_details(core)["items"] == []
    assert core.memory_context == ""
    assert adapter.begin_submission(core)["metadata"]["state"] == "skipped"


def test_changed_source_between_prepare_and_install_is_omitted(memory):
    adapter, core, _ = memory
    from pathlib import Path
    source = Path(core.workspace_root) / "release.txt"
    source.write_text("violet deployment")
    with CanonicalMemoryVault(adapter.app_dir, workspace=core.workspace_root) as vault:
        vault.save({"title": "Release project", "content": "Release project uses violet deployments.",
                    "scope": "workspace", "kind": "fact", "source_paths": ["release.txt"]})
    prepared = prepare(memory)
    assert prepared.item_count == 1
    source.write_text("turquoise deployment")
    assert install(memory, prepared) == ""
    assert adapter.retrieval_details(core)["items"] == []


def test_packet_text_tampering_cannot_be_installed(memory):
    adapter, core, _ = memory
    remember(memory)
    prepared = prepare(memory)
    tampered = replace(prepared, _packet=replace(prepared._packet, text="invented unreceipted content"))
    installed = install(memory, tampered)
    assert "invented unreceipted content" not in installed
    assert "invented unreceipted content" not in core.memory_context


def test_cancellation_after_selection_does_not_replace_current_context(memory):
    _, core, _ = memory
    remember(memory)
    stopped = False
    prepared = prepare(memory, should_stop=lambda: stopped)
    stopped = True
    core.memory_context = "current context"
    assert install(memory, prepared) == ""
    assert core.memory_context == "current context"


@pytest.mark.parametrize("empty", [False, True])
def test_metadata_snapshot_never_revalidates_or_mutates_selected_packet(memory, monkeypatch, empty):
    adapter, core, _ = memory
    if not empty:
        remember(memory)
    prepared = prepare(memory)
    install(memory, prepared)
    before, pending = vars(core).copy(), adapter._pending.copy()
    no_call = Mock(side_effect=AssertionError("snapshot must not revalidate or synchronize"))
    monkeypatch.setattr(adapter, "revalidate_before_use", no_call)
    monkeypatch.setattr(adapter.engine, "revalidate_context", no_call)
    details = adapter.retrieval_details(core, revalidate=False)
    assert details["receipt_id"] == prepared.receipt_id
    assert vars(core) == before and adapter._pending == pending
    no_call.assert_not_called()


def test_explicit_search_layer_cannot_carry_into_next_turn(memory):
    adapter, core, policy = memory
    remember(memory)
    policy = replace(policy, recall_enabled=False)
    core.agent_configuration.memory_policy = policy
    prepared = adapter.prepare_retrieval(core, "release project", policy, agent_id="primary", automatic=False)
    assert adapter.install_retrieval(core, prepared, policy, agent_id="primary", automatic=False)
    core._memory_turn_id = "turn-two"
    assert not adapter.retrieval_details(core)["available"]
    assert core.memory_context == ""


def test_output_run_initialization_does_not_invalidate_same_memory_turn(memory):
    adapter, core, _ = memory
    remember(memory)
    core._output_run_id = ""
    prepared = prepare(memory)
    assert install(memory, prepared)
    core._output_run_id = core.tool_ctx.memory_run_id
    assert adapter.retrieval_details(core)["available"]


@pytest.mark.parametrize("requested", [("personal",), ("workspace",), ("agent",)])
def test_requested_scope_narrowing_survives_install_and_final_revalidation(memory, requested):
    adapter, core, policy = memory
    records = {scope: remember(memory, f"Release project {scope} fact.", scope=scope)
               for scope in ("personal", "workspace", "agent")}
    prepared = prepare(memory, automatic=False, scopes=requested)
    assert {item.record_id for item in prepared._packet.items} == {records[requested[0]].id}
    assert adapter.install_retrieval(core, prepared, policy, agent_id="primary", automatic=False)
    # A changed record forces the final engine check; access must stay narrowed.
    current = records[requested[0]]
    adapter.engine.correct(adapter.access(core, "user"), current.id,
        Correction(content=f"Release project {requested[0]} updated fact."), expected_revision=current.revision)
    details = adapter.retrieval_details(core)
    assert {item["id"] for item in details["items"]} == {current.id}
    handle = adapter.begin_submission(core)
    assert handle["metadata"]["state"] == "selected"
    assert bool(handle["access"].grants.projects) == (requested == ("workspace",))
    assert bool(handle["access"].grants.agents) == (requested == ("agent",))


@pytest.mark.parametrize("requested", [(), ("unknown",), "personal"])
def test_empty_or_invalid_requested_scopes_never_fall_back_to_all(memory, requested):
    remember(memory)
    assert not prepare(memory, scopes=requested).available


def test_requested_scope_cannot_widen_disabled_personal_policy(memory):
    adapter, core, policy = memory
    remember(memory, scope="personal")
    policy = replace(policy, scopes=("workspace",))
    core.agent_configuration.memory_policy = policy
    prepared = adapter.prepare_retrieval(core, "release project", policy, agent_id="primary", scopes=("personal",))
    assert not prepared.available
