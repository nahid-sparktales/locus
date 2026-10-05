"""Stage-2 memory adapter: rollout modes, trusted scope, isolation and fencing.

Real turns run through ``server._run_user_turn`` with a scripted model client, so
the prompt a model would receive is what is asserted. The canonical store stays
the legacy vault (``MemoryVault``); the engine only ever holds a derived copy.
"""
from __future__ import annotations

import logging
import uuid

import pytest
from locus_memory import MemoryEngine
from locus_memory.compat.legacy_vault import (
    LegacyMemoryVault,
    legacy_agent_hash,
    legacy_workspace_hash,
)
from locus_memory.context import CONTEXT_WRAPPER_OPEN
from locus_memory.errors import AccessDenied, MemoryEngineError, MigrationError, OwnershipFenced
from locus_memory.migrations.state import OwnershipControl
from locus_memory.models import (
    Actor,
    CandidateProposal,
    Lifecycle,
    Operation,
    PartitionRef,
    RememberRequest,
    ScopeGrants,
    SourceRef,
)

from ollama_code import memory_adapter as adapter_module
from ollama_code import paths, server
from ollama_code.agent_config import AgentConfiguration
from ollama_code.agent_profile_runtime import parse_solo_profile
from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.memory import MemoryVault
from ollama_code.memory_adapter import (
    ARCHIVE_ENV,
    ENGINE_DIR,
    LEGACY_RESULTS_HEADER,
    MODE_ENV,
    LocusKeyProvider,
    MemoryAdapter,
    assert_single_memory_layer,
    project_id,
)
from ollama_code.ollama import ChatResponse

CANARY = "zebra-canary-7731"
DEPLOY = "How do we deploy with make release?"
NO_SNAPSHOTS = {"memory_policy": {"cross_chat_context_enabled": False}}
LAYER = "<locus-memory-reference>"
ENGINE_LAYER = CONTEXT_WRAPPER_OPEN


def test_evaluation_cannot_restore_learning_or_memory_off_context(services, monkeypatch):
    service = services("enabled", archive=True)
    core, adapter = service.core, service.memory_adapter
    core.memory_evaluation_disabled = True
    core.memory_comparison_arm = False
    core.configure_agent({"memory_policy": {"recall_enabled": True, "search_enabled": True,
        "proposals_enabled": True}}, memory_context="old packet", continuity_context="old snapshot")
    policy = core.agent_configuration.memory_policy
    assert not policy.recall_enabled and not policy.search_enabled and not policy.proposals_enabled
    assert not policy.cross_chat_context_enabled
    assert core.memory_context == core.continuity_context == ""
    archived, maintenance = [], []
    monkeypatch.setattr(adapter, "archive_text", lambda *args, **kwargs: archived.append(kwargs))
    monkeypatch.setattr(adapter, "session_boundary", lambda *args, **kwargs: maintenance.append(kwargs))
    adapter.on_committed_message(core, {"role": "assistant", "content": "Evaluation result"})
    adapter.on_session_boundary(core)
    assert archived == []
    assert maintenance == [{"active": False}]


class _Client:
    """Scripted model: records every request and answers briefly."""

    host = "http://127.0.0.1:9"  # read by Solo route snapshots; never contacted
    timeout = 5

    def __init__(self) -> None:
        self.seen: list[list[dict]] = []

    def chat_stream(self, model, messages, tools=None, on_token=None, should_stop=None,
                    on_thinking=None, think=False, options=None):
        self.seen.append([dict(message) for message in messages])
        return ChatResponse(content_parts=["Noted."], prompt_eval_count=4, eval_count=1, done=True)

    def context_length(self, name):
        return 262_144

    def loaded_context_length(self, name):
        return 0

    def resident_state(self, name):
        return {"context_length": 0, "size": 0, "size_vram": 0}

    def list_models(self):
        return [{"name": "test-model"}]


@pytest.fixture(autouse=True)
def legacy_profile(isolated_app_dir):
    """These rollout tests exercise upgrades; new profiles use the package directly."""
    LegacyMemoryVault(isolated_app_dir / "memory" / "memory.sqlite3",
                      key=LocusKeyProvider(isolated_app_dir).legacy_key())


@pytest.fixture
def workspace(tmp_path):
    path = tmp_path / "ws"
    path.mkdir()
    return path


@pytest.fixture
def services(workspace, monkeypatch):
    """Build ChatServices whose adapter reads the given rollout mode at construction."""
    built: list[ChatService] = []

    def make(mode: str, *, archive: bool = False, cwd=None) -> ChatService:
        if mode == "disabled":
            monkeypatch.delenv(MODE_ENV, raising=False)
        else:
            monkeypatch.setenv(MODE_ENV, mode)
        if archive:
            monkeypatch.setenv(ARCHIVE_ENV, "1")
        else:
            monkeypatch.delenv(ARCHIVE_ENV, raising=False)
        core = AgentCore(cwd=str(cwd or workspace),
                         config={"model": "test-model", "max_iterations": 3, "auto_compact": False})
        core.mcp.close()
        core.model = "test-model"
        core.client = _Client()
        service = ChatService(core)
        built.append(service)
        return service

    yield make
    for service in built:
        service.close_codex()
        service.memory_adapter.close()
        service.core.close()


def _remember(content: str, scope: str = "workspace", *, workspace=None, agent_id: str = "primary",
              kind: str = "fact", title: str = "") -> dict:
    """Write through the canonical legacy vault, exactly as the /api/memory routes do."""
    return MemoryVault().save(
        {"title": title or content[:40], "content": content, "scope": scope, "kind": kind},
        workspace=str(workspace or ""), agent_id=agent_id,
    )


def _turn(service: ChatService, text: str, *, just_chat: bool = False,
          agent_config: dict | None = None) -> str:
    """Return the complete provider request; memory is lower-priority reference data."""
    server._run_user_turn(service, text, just_chat, agent_config=agent_config or NO_SNAPSHOTS,
                          solo_swarm_enabled=False)
    return "\n".join(str(message.get("content") or "") for message in service.core.client.seen[0])


def _spy_packets(service: ChatService) -> list:
    engine = service.memory_adapter.engine
    original = engine.build_context
    packets = []

    def spy(access, request, **kwargs):
        packet = original(access, request, **kwargs)
        packets.append(packet)
        return packet

    engine.build_context = spy
    return packets


def _engine_files():
    return [path for path in paths.APP_DIR.rglob("*") if ENGINE_DIR in path.parts]


def _derived(adapter: MemoryAdapter, record_id: str):
    """(record, tombstoned?) for one id in the derived copy, regardless of scope or grants."""
    ctx = adapter.engine.partition_context(adapter.partition)
    with ctx.partition.db.read() as conn:
        return (ctx.records.get(conn, record_id),
                ctx.services.forgetting.tombstone_generation(conn, "memory", record_id) is not None)


def _spy_imports(monkeypatch) -> list:
    """Record each LegacyImporter's access context and report."""
    imports = []
    original = adapter_module.LegacyImporter.run

    def run(importer):
        report = original(importer)
        imports.append((importer.access, report))
        return report

    monkeypatch.setattr(adapter_module.LegacyImporter, "run", run)
    return imports


def test_disabled_mode_opens_nothing_and_keeps_the_stage1_prompt(services, workspace):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    stage1 = services("disabled")
    stage1.core.memory_adapter = None  # the seam without any adapter is the Stage-1 code path
    expected = _turn(stage1, DEPLOY)

    service = services("disabled")
    prompt = _turn(service, DEPLOY)

    assert prompt == expected
    assert LEGACY_RESULTS_HEADER in prompt and "We deploy with make release" in prompt
    assert ENGINE_LAYER not in prompt
    assert service.memory_adapter.mode == "disabled" and service.memory_adapter._engine is None
    assert _engine_files() == []


def test_shadow_mode_never_changes_the_prompt_and_writes_only_ciphertext(services, workspace, caplog):
    _remember(f"Deploy token phrase {CANARY} goes through make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    expected = _turn(services("disabled"), DEPLOY)
    assert CANARY in expected  # the legacy layer really carries the canary into the prompt

    caplog.set_level(logging.INFO, logger="ollama_code.memory_adapter")
    shadow = services("shadow")
    assert _turn(shadow, DEPLOY) == expected

    comparison = shadow.memory_adapter.last_shadow
    assert comparison["legacy_items"] >= 1 and comparison["engine_items"] >= 1 and comparison["overlap"] >= 1
    assert comparison["legacy_token_kind"] == "estimated"
    counters = shadow.memory_adapter.engine.metrics.snapshot()["counters"]
    assert counters["adapter.shadow.compared"]["value"] == 1
    assert any(path.name == "memory.sqlite3" for path in _engine_files())
    for path in paths.APP_DIR.rglob("*"):
        if path.is_file():
            assert CANARY.encode() not in path.read_bytes(), f"plaintext memory in {path}"
    assert "memory engine shadow:" in caplog.text and CANARY not in caplog.text


def test_enabled_mode_injects_one_engine_layer_within_the_policy_budget(services, workspace):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    service = services("enabled")
    packets = _spy_packets(service)
    prompt = _turn(service, DEPLOY, agent_config={
        "memory_policy": {"cross_chat_context_enabled": False, "max_automatic_tokens": 300}})

    assert prompt.count(LAYER) == 1
    assert prompt.count(ENGINE_LAYER) == 1
    assert LEGACY_RESULTS_HEADER not in prompt
    assert "We deploy with make release" in prompt and "Prefer concise answers" in prompt
    assert packets and all(p.token_allowance == 300 and p.token_count <= 300 for p in packets)
    with pytest.raises(AssertionError):
        assert_single_memory_layer(packets[0].text + "\n" + LEGACY_RESULTS_HEADER)


def test_enabled_mode_with_nothing_recalled_injects_no_layer(services):
    legacy = _turn(services("disabled"), "Summarize the weather")
    assert "No approved memory matched that query." in legacy  # the D41 behaviour being replaced

    prompt = _turn(services("enabled"), "Summarize the weather")
    assert LAYER not in prompt and ENGINE_LAYER not in prompt


def test_revalidation_drops_memory_deleted_between_recall_and_use(services, workspace, monkeypatch):
    doomed = _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    service = services("enabled")
    packets = _spy_packets(service)
    from ollama_code import reusable_check_runtime

    def delete_after_recall(*_args, **_kwargs):
        # Runs after recall and before the model call, like a REST delete would.
        assert MemoryVault().delete(doomed["id"])

    monkeypatch.setattr(reusable_check_runtime, "bind_run_checks", delete_after_recall)
    prompt = _turn(service, DEPLOY)

    assert doomed["id"] in {item.record_id for item in packets[0].items}
    assert "We deploy with make release" not in prompt and doomed["id"] not in prompt
    assert "Prefer concise answers" in prompt and prompt.count(ENGINE_LAYER) == 1
    counters = service.memory_adapter.engine.metrics.snapshot()["counters"]
    assert counters["adapter.revalidate.changed"]["value"] == 1


def test_records_the_legacy_store_marks_stale_or_superseded_are_never_injected(services, workspace):
    """Feedback and approve-replace change these flags without a legacy revision bump.

    The package importer carries them into the derived copy; the adapter excludes nothing itself.
    """
    flagged = _remember("We deploy with make release from main", workspace=workspace, title="Deploy")
    kept = _remember("Deploy announcements go to the release channel", workspace=workspace, title="Announce")
    service = services("enabled")
    adapter = service.memory_adapter
    core, configuration = service.core, AgentConfiguration.parse(None)
    first = server._automatic_memory_context(core, "deploy", configuration, just_chat=False)
    assert "make release from main" in first and "release channel" in first
    requests = []
    build = adapter.engine.build_context

    def spy(access, request, **kwargs):
        requests.append(request)
        return build(access, request, **kwargs)

    adapter.engine.build_context = spy

    MemoryVault().feedback(flagged["id"], "incorrect", workspace=str(workspace))
    second = server._automatic_memory_context(core, "deploy", configuration, just_chat=False)
    assert "make release from main" not in second and "release channel" in second
    assert _derived(adapter, flagged["id"])[0].lifecycle is Lifecycle.STALE

    # Between recall and use: a newer memory supersedes the one already in the packet.
    core.memory_context = second
    candidate = MemoryVault().save({"title": "Announce", "content": "Deploy announcements go to the ops channel",
                                    "scope": "workspace", "status": "candidate"}, workspace=str(workspace))
    MemoryVault().approve(candidate["id"], workspace=str(workspace), resolution="replace")
    server._revalidate_memory_context(core)
    assert kept["id"] not in core.memory_context and "release channel" not in core.memory_context
    assert "ops channel" in core.memory_context  # the replacement, recompiled for the same request
    assert core.memory_context.count(ENGINE_LAYER) == 1
    superseded = _derived(adapter, kept["id"])[0]
    assert superseded.lifecycle is Lifecycle.SUPERSEDED and superseded.links.superseded_by == candidate["id"]
    assert requests and all(request.exclude_ids == () for request in requests)


def test_a_legacy_deletion_outside_every_grant_reaches_the_derived_copy(services, workspace, tmp_path,
                                                                        monkeypatch):
    """The import access carries no grants; the importer scopes each deletion to its record."""
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    gone = [_remember("Elsewhere deploy note", workspace=elsewhere, title="Elsewhere"),
            _remember("Ghost agent deploy note", scope="agent", agent_id="ghost-agent", title="Ghost")]
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    configuration = AgentConfiguration.parse(None)
    first = services("enabled")
    assert "make release" in server._automatic_memory_context(first.core, DEPLOY, configuration, just_chat=False)
    assert all(_derived(first.memory_adapter, record["id"])[0] is not None for record in gone)
    first.memory_adapter.close()

    for record in gone:  # deleted while no adapter runs; the next process never sees these targets
        assert MemoryVault().delete(record["id"])
    imports = _spy_imports(monkeypatch)
    second = services("enabled")
    recalled = server._automatic_memory_context(second.core, DEPLOY, configuration, just_chat=False)

    assert "We deploy with make release" in recalled
    [(access, report)] = imports
    assert access.actor is Actor.HOST and access.operations == {Operation.ADMIN}
    assert access.grants == ScopeGrants()
    assert report["deletion_propagation"] == {"propagated": 2, "failed": 0, "failed_by_code": {}}
    assert all(_derived(second.memory_adapter, record["id"]) == (None, True) for record in gone)


def test_enabled_recall_fails_closed_until_a_legacy_deletion_is_propagated(services, workspace, monkeypatch):
    doomed = _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Deploy announcements go to the release channel", workspace=workspace, title="Announce")
    service = services("enabled")
    adapter, core, configuration = service.memory_adapter, service.core, AgentConfiguration.parse(None)
    assert "make release" in server._automatic_memory_context(core, DEPLOY, configuration, just_chat=False)
    forgetting = adapter.engine.partition_context(adapter.partition).services.forgetting
    forget = forgetting.forget

    def denied(*_args, **_kwargs):
        raise AccessDenied("simulated")

    MemoryVault().delete(doomed["id"])
    monkeypatch.setattr(forgetting, "forget", denied)
    assert server._automatic_memory_context(core, DEPLOY, configuration, just_chat=False) == ""
    counters = adapter.engine.metrics.snapshot()["counters"]
    assert counters["adapter.sync.incomplete"]["value"] == 1
    assert counters["adapter.recall.failed"]["value"] == 1

    monkeypatch.setattr(forgetting, "forget", forget)  # the next turn retries the import
    retried = server._automatic_memory_context(core, "release channel", configuration, just_chat=False)
    assert "make release" not in retried and "release channel" in retried


def test_the_import_mapping_never_flips_between_agents(services, monkeypatch):
    """Agent records are not re-scoped back and forth as different agents recall."""
    _remember("Primary agent deploy note", scope="agent", agent_id="primary", title="Primary")
    _remember("Reviewer agent deploy note", scope="agent", agent_id="reviewer-1", title="Reviewer")
    imports = _spy_imports(monkeypatch)
    service = services("enabled")
    core, configuration = service.core, AgentConfiguration.parse(None)
    recalled = {}
    for turn, agent_id in enumerate(("primary", "reviewer-1", "primary")):
        _remember(f"Personal note {turn}", scope="personal")  # a legacy change, so the importer runs
        recalled[agent_id] = server._automatic_memory_context(core, "agent deploy note", configuration, just_chat=False,
                                                              agent_id=agent_id)

    assert len(imports) == 3
    assert [report.get("updated", 0) for _access, report in imports] == [0, 0, 0]
    assert "Reviewer agent deploy note" in recalled["reviewer-1"]
    assert "Primary agent deploy note" not in recalled["reviewer-1"]
    assert "Primary agent deploy note" in recalled["primary"]


def test_enabled_mode_caps_items_at_max_automatic_memories(services, workspace):
    for step in range(3):
        _remember(f"Deploy step {step}: make release target {step}", workspace=workspace, title=f"Step {step}")
    service = services("enabled")
    packets = _spy_packets(service)
    prompt = _turn(service, DEPLOY, agent_config={
        "memory_policy": {"cross_chat_context_enabled": False, "max_automatic_memories": 1}})

    assert prompt.count(ENGINE_LAYER) == 1
    assert sum(f"Deploy step {step}:" in prompt for step in range(3)) == 1
    assert len(packets[0].items) == 1
    assert any(omission.reason == "max_items" for omission in packets[0].omissions)


def test_enabled_mode_serves_nothing_once_the_legacy_vault_is_gone(services, workspace):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    service = services("enabled")
    core, configuration = service.core, AgentConfiguration.parse(None)
    core.memory_context = server._automatic_memory_context(core, DEPLOY, configuration, just_chat=False)
    assert "make release" in core.memory_context

    for path in (paths.APP_DIR / "memory").glob("memory.sqlite3*"):
        path.unlink()  # the user wiped the canonical store; the derived copy must not outlive it
    server._revalidate_memory_context(core)
    assert core.memory_context == ""
    assert server._automatic_memory_context(core, DEPLOY, configuration, just_chat=False) == ""


def test_ask_mode_never_sees_workspace_memory(services, workspace):
    _remember("Workspace deploy secret uses make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise deploy answers", scope="personal", kind="preference", title="Style")
    service = services("enabled")
    adapter, core = service.memory_adapter, service.core

    prompt = _turn(service, DEPLOY, just_chat=True)

    assert "Workspace deploy secret" not in prompt
    assert "Prefer concise deploy answers" in prompt
    for purpose in ("recall", "tool"):
        ask = adapter.access(core, purpose, just_chat=True)
        assert not ask.grants.projects
        assert not any(target.startswith("workspace:") for target in ask.grants.legacy_targets)
    # The record is in the derived copy; only the trusted grants keep it out of Ask mode.
    work = adapter.access(core, "recall")
    assert any("Workspace deploy secret" in record.content for record in adapter.engine.list(work))


def test_policy_scopes_bound_what_the_engine_may_inject(services, workspace):
    _remember("Workspace deploy uses make release", workspace=workspace, title="Deploy")
    _remember("Personal deploy preference: be brief", scope="personal", kind="preference", title="Style")
    _remember("Agent deploy note for reviews", scope="agent", agent_id="primary", title="Agent")
    prompt = _turn(services("enabled"), DEPLOY, agent_config={
        "memory_policy": {"cross_chat_context_enabled": False, "scopes": ["workspace"]}})

    assert "Workspace deploy uses make release" in prompt
    assert "Personal deploy preference" not in prompt and "Agent deploy note" not in prompt


def test_identity_mode_disables_the_adapter_entirely(services, workspace, monkeypatch):
    _remember("We deploy with make release", workspace=workspace)
    service = services("enabled", archive=True)
    core = service.core
    core.enable_identity_mode()
    monkeypatch.setattr(core, "run_turn", lambda *args, **kwargs: None)
    server._run_user_turn(service, "Draft my resume", False)

    configuration = AgentConfiguration.parse(None)
    assert server._automatic_memory_context(core, DEPLOY, configuration, just_chat=False) == ""
    assert server._automatic_continuity_context(core, DEPLOY, configuration, just_chat=False) == ""
    core._add_message({"role": "user", "content": "private identity source text"})
    server._revalidate_memory_context(core)
    core.set_cwd(str(workspace))
    assert service.memory_adapter._engine is None
    assert _engine_files() == []


def test_two_chat_services_with_different_app_dirs_share_no_engine_cache_or_key(tmp_path, monkeypatch):
    monkeypatch.setenv(MODE_ENV, "enabled")
    built = []
    for name in ("alpha", "beta"):
        monkeypatch.setattr(paths, "APP_DIR", tmp_path / f"home-{name}")
        cwd = tmp_path / f"ws-{name}"
        cwd.mkdir()
        _remember(f"The {name} deploy uses make release", scope="personal", title=name.title())
        core = AgentCore(cwd=str(cwd), config={"model": "test-model"})
        core.mcp.close()
        built.append(ChatService(core))
    try:
        configuration = AgentConfiguration.parse(None)
        alpha, beta = (server._automatic_memory_context(service.core, DEPLOY, configuration, just_chat=False)
                       for service in built)
        assert "alpha deploy" in alpha and "beta" not in alpha.lower()
        assert "beta deploy" in beta and "alpha" not in beta.lower()

        first, second = (service.memory_adapter for service in built)
        assert first is not second and first.engine is not second.engine
        assert first.engine.metrics is not second.engine.metrics
        assert first.root == tmp_path / "home-alpha" / ENGINE_DIR
        assert second.root == tmp_path / "home-beta" / ENGINE_DIR
        assert first._keys.get_key("locus-v1") != second._keys.get_key("locus-v1")
        shared = [value for value in vars(adapter_module).values()
                  if isinstance(value, (MemoryEngine, MemoryAdapter, OwnershipControl))]
        assert shared == []
    finally:
        for service in built:
            service.close_codex()
            service.memory_adapter.close()
            service.core.close()


@pytest.mark.parametrize("mode", ["disabled", "enabled"])
def test_profile_turns_recall_with_the_profile_agent_id(services, monkeypatch, mode):
    profile = parse_solo_profile({
        "id": str(uuid.uuid4()), "name": "Reviewer", "model": "test-model", "role": "reviewer",
        "instructions": "Review the change.", "access_ceiling": "read_only",
        "timeout_seconds": 120, "token_limit": 8_192,
    }, "test-model")
    _remember("Reviewer checklist lives in docs/review.md", scope="agent", agent_id=profile.id,
              title="Checklist")
    _remember("Primary private review checklist shortcut", scope="agent", agent_id="primary",
              title="Shortcut")
    service = services(mode)
    seen = []

    def run_turn(*_args, **_kwargs):
        seen.append(service.core.memory_context)
        service.core.last_turn_result = {"type": "turn_done", "reason": "complete", "duration_ms": 0}

    monkeypatch.setattr(service.core, "run_turn", run_turn)
    server._run_profile_turn(service, "Where is the review checklist?", False, [], profile, "work", "")

    assert "Reviewer checklist lives in docs/review.md" in seen[0]
    assert "Primary private review checklist shortcut" not in seen[0]
    if mode == "enabled":
        grants = service.memory_adapter.access(service.core, "recall", agent_id=profile.id).grants
        assert grants.agents == {profile.id}


def test_canonical_writes_through_the_adapter_are_fenced_while_legacy_is_authoritative(services):
    service = services("enabled")
    adapter, core = service.memory_adapter, service.core
    state = adapter.ownership_state()
    assert state["state"] == "legacy_authoritative" and state["permitted_writers"] == ["legacy"]

    with pytest.raises(OwnershipFenced):
        adapter.engine.remember(adapter.access(core, "user"), RememberRequest(content="Do not write me"))
    with pytest.raises(OwnershipFenced):
        adapter.engine.propose(adapter.access(core, "tool"), CandidateProposal(
            content="Nor me", sources=(SourceRef("user_action", "turn-1"),)))
    assert adapter.engine.list(adapter.access(core, "recall"), lifecycles=None) == []


def test_archive_is_opt_in_and_skips_reasoning_synthetic_and_injected_text(services):
    off = services("enabled")
    _turn(off, "Remember the blue deployment window")
    assert off.memory_adapter.engine.search_history(off.memory_adapter.access(off.core), "blue").hits == ()

    on = services("enabled", archive=True)
    _turn(on, "Remember the green deployment window")
    adapter, core = on.memory_adapter, on.core
    core._add_message({"role": "user", "content": "runtime green context", "_locus_context": True})
    core._add_message({"role": "assistant", "content": "<think>green reasoning</think> fine"})
    core._add_message({"role": "user", "content": f"{LAYER}\n{ENGINE_LAYER}\ngreen recalled memory"})
    core._add_message({"role": "user", "content": f"Quoted: {ENGINE_LAYER}\ngreen echoed block\n</memory-context>"})
    core._add_message({"role": "user", "content": "unsaved green draft"}, persist=False)

    texts = [hit.message.text for hit in adapter.engine.search_history(adapter.access(core), "green").hits]
    assert any("green deployment window" in text for text in texts)
    for excluded in ("runtime green context", "green reasoning", "green recalled memory", "green echoed block",
                     "unsaved green draft"):
        assert not any(excluded in text for text in texts)


def test_session_boundaries_run_bounded_maintenance_and_scope_changes_invalidate(services, tmp_path):
    service = services("enabled")
    adapter, core = service.memory_adapter, service.core
    adapter.schedule = lambda task: task()  # the host normally schedules this off-thread
    core.new_session()
    assert adapter._engine is None and _engine_files() == []  # nothing opened just to maintain

    _turn(service, "Open the engine for this test")
    engine = adapter.engine
    calls = []
    maintain, invalidate = engine.maintain, engine.invalidate

    def spy_maintain(access):
        calls.append(("maintain", access.actor, access.operations))
        return maintain(access)

    def spy_invalidate(access, reason):
        calls.append(("invalidate", reason))
        return invalidate(access, reason)

    engine.maintain, engine.invalidate = spy_maintain, spy_invalidate
    core.new_session()
    core.new_session()
    assert calls == [("maintain", Actor.HOST, frozenset({Operation.MAINTAIN}))]

    other = tmp_path / "other"
    other.mkdir()
    core.set_cwd(str(other))
    assert calls[-1] == ("invalidate", "workspace_changed")


@pytest.mark.parametrize("mode", ["disabled", "shadow", "enabled"])
@pytest.mark.parametrize("boundary", ["new_session", "set_cwd"])
def test_session_and_scope_boundaries_clear_memory_already_in_the_prompt(
    services, workspace, tmp_path, mode, boundary,
):
    _remember("Deploy with make release; private workspace canary", workspace=workspace)
    service = services(mode)
    core = service.core
    assert "private workspace canary" in _turn(service, DEPLOY)
    core.continuity_context = "Private previous-session handoff canary"
    core.reset_system_message()
    assert "Private previous-session handoff canary" not in core.messages[0]["content"]
    assert "Private previous-session handoff canary" in core._memory_reference_input()

    if boundary == "set_cwd":
        other = tmp_path / "other-workspace"
        other.mkdir()
        core.set_cwd(str(other))
    else:
        core.new_session()

    service.memory_adapter.revalidate_before_use(core)
    assert core.memory_context == core.continuity_context == ""
    assert id(core) not in service.memory_adapter._pending
    assert "private workspace canary" not in core.messages[0]["content"]
    assert "Private previous-session handoff canary" not in core.messages[0]["content"]


def test_access_contexts_come_from_trusted_host_state(services, workspace):
    service = services("enabled")
    adapter, core = service.memory_adapter, service.core
    digest = legacy_workspace_hash(str(workspace))

    recall = adapter.access(core, "recall", agent_id="reviewer-1")
    assert recall.partition == PartitionRef("locus", "default")
    assert recall.actor is Actor.USER and recall.operations == frozenset({Operation.READ})
    assert recall.grants.projects == {project_id(digest)} == {"ws-" + digest[:32]}
    assert recall.grants.agents == {"reviewer-1"}
    assert recall.grants.legacy_targets == {"workspace:" + digest, "agent:" + legacy_agent_hash("reviewer-1")}
    assert adapter.access(core, "tool").actor is Actor.AGENT
    assert Operation.WRITE in adapter.access(core, "user").operations
    assert adapter.access(core, "recall", scopes=("personal",)).grants == ScopeGrants()


def test_unknown_mode_values_fail_safe_to_disabled(tmp_path):
    LegacyMemoryVault(tmp_path / "memory" / "memory.sqlite3",
                      key=LocusKeyProvider(tmp_path).legacy_key())
    adapter = MemoryAdapter.from_environment(app_dir=tmp_path, edition="Locus",
                                             environ={MODE_ENV: "on", ARCHIVE_ENV: "1"})
    assert adapter.mode == "disabled" and adapter.archive is False
    with pytest.raises(MemoryEngineError):
        _ = adapter.engine
    assert not (tmp_path / ENGINE_DIR).exists()


def test_enabled_recall_fails_closed_when_the_derived_copy_cannot_sync(services, workspace, monkeypatch):
    doomed = _remember("We deploy with make release", workspace=workspace, title="Deploy")
    service = services("enabled")
    configuration = AgentConfiguration.parse(None)
    assert "We deploy with make release" in server._automatic_memory_context(
        service.core, DEPLOY, configuration, just_chat=False)

    MemoryVault().delete(doomed["id"])

    def broken(_importer):
        raise MigrationError("simulated import failure")

    monkeypatch.setattr(adapter_module.LegacyImporter, "run", broken)
    assert server._automatic_memory_context(service.core, DEPLOY, configuration, just_chat=False) == ""
    counters = service.memory_adapter.engine.metrics.snapshot()["counters"]
    assert counters["adapter.recall.failed"]["value"] == 1


def test_an_approved_memory_quoting_the_legacy_header_never_fails_a_turn(services, workspace):
    # A model-proposed memory that echoes search_memory output, approved by the user: its text is
    # data inside the engine packet, not a second memory layer.
    proposed = MemoryVault().save(
        {"title": "Recall notes", "content": "Copied from chat: " + LEGACY_RESULTS_HEADER + " prefer tabs",
         "scope": "personal", "kind": "preference"}, workspace=str(workspace), default_status="candidate")
    assert MemoryVault().approve(proposed["id"], workspace=str(workspace))["status"] == "approved"
    _remember("Indentation notes", scope="personal", kind="preference", title=LEGACY_RESULTS_HEADER)
    service = services("enabled")
    for text in ("Which indentation do I prefer?", "what is the weather in Paris"):
        service.core.client.seen.clear()
        prompt = _turn(service, text)  # recall and the pre-call revalidation both run
        assert prompt.count(ENGINE_LAYER) == 1 and prompt.count(LAYER) == 1
        assert "prefer tabs" in prompt
    counters = service.memory_adapter.engine.metrics.snapshot()["counters"]
    assert "adapter.layer_violation" not in counters
    ask = _turn(services("enabled"), "hello", just_chat=True)
    assert ask.count(ENGINE_LAYER) == 1


def test_a_genuine_double_layer_is_detected_but_never_fails_the_turn(services, workspace, monkeypatch):
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    service = services("enabled")
    packets = _spy_packets(service)
    prompt = _turn(service, DEPLOY)
    packet = packets[0].text
    assert prompt.count(ENGINE_LAYER) == 1
    assert_single_memory_layer(packet)
    with pytest.raises(AssertionError):
        assert_single_memory_layer(LEGACY_RESULTS_HEADER + "\n- legacy item\n\n" + packet)
    with pytest.raises(AssertionError):
        assert_single_memory_layer(packet + "\n" + packet)

    # Should the invariant ever trip, the turn still runs - with no engine memory at all.
    def tripped(_text):
        raise AssertionError("memory was injected twice (engine packet and legacy layer)")

    monkeypatch.setattr(adapter_module, "assert_single_memory_layer", tripped)
    service.core.client.seen.clear()
    prompt = _turn(service, DEPLOY)
    assert ENGINE_LAYER not in prompt and LEGACY_RESULTS_HEADER not in prompt
    counters = service.memory_adapter.engine.metrics.snapshot()["counters"]
    assert counters["adapter.layer_violation"]["value"] >= 1


def test_after_cutover_the_adapter_stops_importing_from_the_legacy_vault(services, workspace, monkeypatch):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    service = services("enabled")
    adapter = service.memory_adapter
    imports = _spy_imports(monkeypatch)
    _turn(service, DEPLOY)
    assert imports, "legacy-authoritative: the derived copy is synced from the legacy vault"
    control = adapter._control
    pid = adapter.partition.partition_id
    for target in ("shadow_prepared", "validated", "cutover_in_progress", "package_authoritative"):
        current = control.get(pid, "memories")
        control.transition(pid, "memories", target, expected_generation=current.generation, reason="test")
    imports.clear()
    # Simulate an obsolete, unfenced binary. Host MemoryVault now routes writes
    # to the package, so it cannot stand in for this stale legacy writer.
    LegacyMemoryVault(adapter.legacy_db, key=adapter._keys.legacy_key()).save(
        {"title": "Late", "content": "A legacy write after cutover must not be imported", "scope": "workspace"},
        workspace=str(workspace),
    )
    service.core.client.seen.clear()
    prompt = _turn(service, DEPLOY)
    assert imports == []  # the package is canonical; nothing flows back in from legacy
    assert "must not be imported" not in prompt
    assert "We deploy with make release" in prompt  # the package store still serves memory


def _set_package_owner(adapter, *, retired=False):
    _ = adapter.engine
    control = adapter._control
    targets = ["shadow_prepared", "validated", "cutover_in_progress", "package_authoritative"]
    if retired:
        targets.append("legacy_retired")
    for target in targets:
        current = control.get(adapter.partition.partition_id, "memories")
        control.transition(adapter.partition.partition_id, "memories", target,
                           expected_generation=current.generation, reason="test")


@pytest.mark.parametrize("mode", ["disabled", "shadow"])
@pytest.mark.parametrize("retired", [False, True])
def test_package_ownership_overrides_rollout_switch(services, workspace, mode, retired):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    original = services("enabled")
    _turn(original, DEPLOY)
    _set_package_owner(original.memory_adapter, retired=retired)
    restarted = services(mode)
    assert restarted.memory_adapter.mode == "enabled"
    prompt = _turn(restarted, DEPLOY)
    assert "We deploy with make release" in prompt
    assert ENGINE_LAYER in prompt and LEGACY_RESULTS_HEADER not in prompt
    assert restarted.memory_adapter.last_shadow is None


def test_revalidation_keeps_packet_live_across_later_model_calls(services, workspace):
    doomed = _remember("We deploy with make release", workspace=workspace, title="Deploy")
    service = services("enabled")
    core = service.core
    core.memory_context = server._automatic_memory_context(
        core, DEPLOY, core.agent_configuration, just_chat=False)
    server._revalidate_memory_context(core)
    assert "We deploy with make release" in core.memory_context
    MemoryVault().delete(doomed["id"])
    server._revalidate_memory_context(core)
    assert "We deploy with make release" not in core.memory_context


def test_disabled_service_holds_offline_migration_lease_until_core_close(services):
    from ollama_code.memory import MemoryError
    from ollama_code.memory_ownership import profile_lease

    service = services("disabled")
    with pytest.raises(MemoryError, match="in use"):
        with profile_lease(paths.APP_DIR, exclusive=True):
            pass
    service.core.close()
    with profile_lease(paths.APP_DIR, exclusive=True):
        pass
    assert service.memory_adapter._engine is None


def test_standalone_core_uses_engine_and_releases_its_lease(services, workspace, monkeypatch):
    from ollama_code.memory_ownership import profile_lease

    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    monkeypatch.setenv(MODE_ENV, "enabled")
    core = AgentCore(cwd=str(workspace), config={"model": "test-model"})
    try:
        result = server._automatic_memory_context(core, DEPLOY, core.agent_configuration, just_chat=False)
        assert ENGINE_LAYER in result and "We deploy with make release" in result
        assert core.memory_adapter.mode == "enabled"
    finally:
        core.close()
    with profile_lease(paths.APP_DIR, exclusive=True):
        pass


def test_helper_recalls_root_project_memories_through_its_own_adapter(services, workspace, tmp_path):
    import threading

    from ollama_code.collaboration import WorkerSpec
    from ollama_code.collaboration_bridge import AgentWorkerRuntime

    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Only the helper uses the review checklist", scope="agent", agent_id="helper-one", title="Review")
    service = services("enabled")
    checkout = tmp_path / "helper-checkout"
    checkout.mkdir()
    runtime = AgentWorkerRuntime(service, WorkerSpec(
        "helper-one", "root", "run-helper", str(checkout), "research", {}, {}, "Helper", None,
    ), threading.RLock())
    runtime.core.client = _Client()
    try:
        runtime.run(DEPLOY, max_calls=2, should_stop=lambda: False,
                    drain_messages=lambda: [], on_usage=lambda _: None)
        prompt = "\n".join(str(message.get("content") or "") for message in runtime.core.client.seen[0])
        assert "We deploy with make release" in prompt and ENGINE_LAYER in prompt
        assert runtime.core.memory_adapter is not service.memory_adapter
        assert runtime.core.workspace_root == str(workspace)
    finally:
        runtime.close()
    assert runtime.core.memory_adapter._closed


def test_team_recall_happens_after_scheduler_admission(services, workspace, monkeypatch):
    from contextlib import contextmanager

    from ollama_code import orchestration

    doomed = _remember("We deploy with make release", workspace=workspace, title="Deploy")
    _remember("Prefer concise answers", scope="personal", kind="preference", title="Style")
    service = services("enabled")
    profile = parse_solo_profile({
        "id": "reviewer", "name": "Reviewer", "model": "test-model", "role": "reviewer",
        "instructions": "Review the change.", "access_ceiling": "read_only",
        "timeout_seconds": 120, "token_limit": 8_192,
        "behavior": NO_SNAPSHOTS,
    }, "test-model")
    runner = orchestration.TeamOrchestrator(lambda _: None, lambda: False)
    runner.memory_context_provider = lambda selected: server._team_memory_context(service.core, DEPLOY, selected)
    client = _Client()
    monkeypatch.setattr(orchestration, "_client", lambda _: client)

    @contextmanager
    def admission(*_args):
        MemoryVault().delete(doomed["id"])
        yield

    monkeypatch.setattr(runner, "_scheduler_slot", admission)
    runner._raw_call("team-run", profile, [
        {"role": "system", "content": profile.system_prompt("Review.")},
        {"role": "user", "content": DEPLOY},
    ], orchestration.OrchestrationBudget())
    prompt = "\n".join(str(message.get("content") or "") for message in client.seen[0])
    assert "We deploy with make release" not in prompt
    assert "Prefer concise answers" in prompt and prompt.count(ENGINE_LAYER) == 1
    assert service.memory_adapter._pending == {}


def test_missing_key_for_package_only_data_never_creates_replacement(services):
    from locus_memory.errors import VaultLocked

    from ollama_code.memory_adapter import LocusKeyProvider

    service = services("enabled")
    adapter = service.memory_adapter
    _set_package_owner(adapter)
    adapter.engine.remember(adapter.access(service.core, "user"), RememberRequest(
        content="A package-only memory", kind=adapter_module.MemoryKind.PREFERENCE,
    ))
    adapter.close()
    key_file = paths.APP_DIR / "memory" / "master.key"
    key_file.unlink()
    with pytest.raises(VaultLocked):
        LocusKeyProvider(paths.APP_DIR).legacy_key()
    assert not key_file.exists()


def test_enabled_recall_resumes_legacy_sync_after_ownership_rollback(services, workspace):
    _remember("We deploy with make release", workspace=workspace, title="Deploy")
    original = services("enabled")
    _turn(original, DEPLOY)
    adapter = original.memory_adapter
    _set_package_owner(adapter)
    for target in ("rollback_in_progress", "legacy_authoritative"):
        current = adapter._control.get(adapter.partition.partition_id, "memories")
        adapter._control.transition(adapter.partition.partition_id, "memories", target,
                                    expected_generation=current.generation, reason="test rollback")
    _remember("After rollback deploy with make release hotfix", workspace=workspace, title="Rollback")
    restarted = services("enabled")
    prompt = _turn(restarted, DEPLOY)
    assert ENGINE_LAYER in prompt and "After rollback deploy with make release hotfix" in prompt
