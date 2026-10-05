"""Memory identity survives idle saved-agent boundaries without primary fallback."""
import uuid
from types import SimpleNamespace

import pytest

from ollama_code.agent_config import AgentConfiguration
from ollama_code.agent_profile_runtime import trusted_memory_agent
from ollama_code.runtime_store import PrivateStore
from ollama_code.sessions import SessionMeta


@pytest.fixture
def identity_host(tmp_path, monkeypatch):
    root = tmp_path / "runtime"
    monkeypatch.setenv("LOCUS_RUNTIME_PROFILE_ROOT", str(root))
    metadata = {}
    monkeypatch.setattr(SessionMeta, "get", lambda _: metadata)
    core = SimpleNamespace(agent_id="primary", agent_configuration=AgentConfiguration.parse({}),
        session=SimpleNamespace(session_id="session-one"), tool_ctx=SimpleNamespace(memory_run_id=""))
    profile = {"id": str(uuid.uuid4()), "name": "Reviewer", "model": "fixture",
        "role": "reviewer", "access_ceiling": "read_only", "timeout_seconds": 120,
        "token_limit": 8192, "behavior": {"memory_policy": {"scopes": ["agent"],
        "native_codex_enabled": True, "proposals_enabled": False}}}
    return core, metadata, root, profile


def save(root, profile):
    PrivateStore(root).set("agent-profiles", {profile["id"]: {"profile": profile}})


def test_idle_saved_agent_uses_saved_current_grants(identity_host):
    core, metadata, root, profile = identity_host
    metadata["agent_profile_id"] = profile["id"]
    save(root, profile)
    # Output IDs remain on completed cores and cannot establish live identity.
    core._output_run_id = "finished-run"
    agent_id, configuration = trusted_memory_agent(core)
    assert agent_id == profile["id"]
    assert configuration.memory_policy.scopes == ("agent",)
    assert configuration.memory_policy.native_codex_enabled
    assert not configuration.memory_policy.proposals_enabled
    assert not configuration.capability_policy.workspace_write
    profile["behavior"]["memory_policy"]["scopes"] = []
    save(root, profile)
    assert trusted_memory_agent(core)[1].memory_policy.scopes == ()


@pytest.mark.parametrize("marker", ["profile", "run"])
def test_active_host_identity_is_authoritative(identity_host, marker):
    core, metadata, _, profile = identity_host
    metadata["agent_profile_id"] = profile["id"]
    core.agent_id = "admitted-helper"
    if marker == "profile":
        core._memory_profile_active = True
    else:
        core.tool_ctx.memory_run_id = "live-run"
    assert trusted_memory_agent(core) == ("admitted-helper", core.agent_configuration)


@pytest.mark.parametrize("binding", ["", "invalid", 42])
def test_invalid_bindings_do_not_use_primary(identity_host, binding):
    core, metadata, _, _ = identity_host
    metadata["agent_profile_id"] = binding
    with pytest.raises(ValueError, match="saved memory agent"):
        trusted_memory_agent(core)


def test_missing_store_is_not_recreated(identity_host):
    core, metadata, root, profile = identity_host
    metadata["agent_world_profile_id"] = profile["id"]
    with pytest.raises(ValueError, match="saved memory agent"):
        trusted_memory_agent(core)
    assert not root.exists()


@pytest.mark.parametrize("mutation", ["removed", "foreign", "policy", "mode", "symlink"])
def test_untrusted_saved_profiles_fail_closed(identity_host, mutation):
    core, metadata, root, profile = identity_host
    metadata["agent_profile_id"] = profile["id"]
    save(root, profile)
    path = root / "runtime-secrets.json"
    if mutation == "removed":
        PrivateStore(root).set("agent-profiles", {})
    elif mutation == "foreign":
        PrivateStore(root).set("agent-profiles", {profile["id"]: {"profile": {**profile, "id": str(uuid.uuid4())}}})
    elif mutation == "policy":
        profile["behavior"]["memory_policy"]["recall_enabled"] = "false"
        save(root, profile)
    elif mutation == "mode":
        path.chmod(0o644)
    else:
        target = root / "other.json"
        path.rename(target)
        path.symlink_to(target)
    with pytest.raises(ValueError, match="saved memory agent"):
        trusted_memory_agent(core)


def test_unbound_primary_is_unchanged(identity_host):
    core, _, root, _ = identity_host
    assert trusted_memory_agent(core) == ("primary", core.agent_configuration)
    assert not root.exists()
