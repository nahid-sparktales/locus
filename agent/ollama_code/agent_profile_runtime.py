"""Temporary profile boundaries for a conversation whose provider is already configured."""
from __future__ import annotations

import os
import sys
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .agent_config import AgentConfiguration
from .orchestration import AgentProfile


def trusted_memory_agent(core: Any) -> tuple[str, AgentConfiguration]:
    """Resolve memory identity from admitted host state, never a request body.

    A live profile boundary owns the current core identity. Once that boundary
    restores the core, an idle saved-agent chat must reload its controller-owned
    profile instead of inheriting the primary agent's namespace or grants.
    """
    configuration = getattr(core, "agent_configuration", None)
    agent_id = getattr(core, "agent_id", None)
    if (not isinstance(configuration, AgentConfiguration) or not isinstance(agent_id, str)
            or not agent_id.strip() or len(agent_id) > 256
            or any(ord(char) < 32 for char in agent_id)):
        raise ValueError("The current memory agent is unavailable.")
    if (getattr(core, "_memory_profile_active", False)
            or getattr(getattr(core, "tool_ctx", None), "memory_run_id", "")):
        return agent_id, configuration

    from .sessions import SessionMeta

    session_id = getattr(getattr(core, "session", None), "session_id", None)
    metadata = SessionMeta.get(session_id) if session_id else {}
    if not isinstance(metadata, dict):
        raise ValueError("The conversation's memory identity is unavailable.")
    bound = metadata.get("agent_world_profile_id")
    if bound is None:
        bound = metadata.get("agent_profile_id")
    if bound is None:
        return agent_id, configuration
    return saved_memory_agent(bound, read_only=bool(getattr(core, "evaluation_read_only", False)))


def saved_memory_agent(bound: str, *, read_only: bool = False) -> tuple[str, AgentConfiguration]:
    """Read a host-bound saved profile; callers must establish its ownership first."""
    try:
        if not isinstance(bound, str):
            raise ValueError("Invalid profile binding")
        profile_id = str(uuid.UUID(bound))
        root_value = os.environ.get("LOCUS_RUNTIME_PROFILE_ROOT", "").strip()
        if root_value:
            root = Path(root_value).expanduser()
            if not root.is_absolute():
                raise ValueError("Invalid runtime profile root")
        elif sys.platform == "darwin":
            # Matches RuntimeInstallation.root and the signed RuntimeHelper.
            root = Path.home() / "Library/Application Support/Locus/Runtime"
        elif sys.platform.startswith("linux"):
            root = Path.home() / ".local/share/locus-runtime"
        else:
            raise ValueError("The runtime profile store is unavailable")
        # PrivateStore creates directories on construction. Inspection must not
        # create a replacement store when the authenticated store disappeared.
        if not (root / "runtime-secrets.json").is_file():
            raise ValueError("The runtime profile store is unavailable")
        from .runtime_store import PrivateStore

        saved = PrivateStore(root).read()
        profiles = saved.get("agent-profiles") if isinstance(saved, dict) else None
        item = profiles.get(profile_id) if isinstance(profiles, dict) else None
        value = item.get("profile") if isinstance(item, dict) else None
        if not isinstance(value, dict) or str(uuid.UUID(str(value.get("id")))) != profile_id:
            raise ValueError("The bound profile is unavailable")
        model = value.get("model")
        if not isinstance(model, str) or not model.strip():
            raise ValueError("The bound profile is malformed")
        behavior = value.get("behavior")
        if behavior is not None and not isinstance(behavior, dict):
            raise ValueError("The bound profile behavior is malformed")
        memory = (behavior or {}).get("memory_policy")
        if memory is not None:
            if not isinstance(memory, dict):
                raise ValueError("The bound memory policy is malformed")
            switches = ("recall_enabled", "search_enabled", "proposals_enabled",
                        "native_codex_enabled", "cross_chat_context_enabled")
            if any(key in memory and not isinstance(memory[key], bool) for key in switches):
                raise ValueError("The bound memory policy is malformed")
            scopes = memory.get("scopes", [])
            if (not isinstance(scopes, list)
                    or any(scope not in ("personal", "workspace", "agent") for scope in scopes)):
                raise ValueError("The bound memory scopes are malformed")
        profile = parse_solo_profile(value, model)
        # A provider can be offline without changing the saved memory namespace.
        # Bounds still apply, including narrower policy saved since the last turn.
        return profile.id, AgentConfiguration.parse(bounded_profile_configuration(
            profile, read_only=read_only))
    except (ValueError, TypeError, KeyError, AttributeError, OSError) as exc:
        raise ValueError("The conversation's saved memory agent is unavailable.") from exc


def parse_solo_profile(value: Any, model: str) -> AgentProfile:
    # The native account broker configures the worker first. Screen messages
    # cannot supply routes or cause fallback to a different account/model.
    if not isinstance(value, dict):
        raise ValueError("The selected agent profile is malformed.")
    profile = AgentProfile.parse({**value, "route": {}}, require_route=False)
    if profile.model != model:
        raise ValueError("The selected agent's exact model is not configured on this conversation.")
    return profile


def bounded_profile_configuration(profile: AgentProfile, *, read_only: bool = False) -> dict[str, Any]:
    configuration = profile.behavior.structured()
    capabilities = dict(configuration["capability_policy"])
    if read_only or profile.access_ceiling == "read_only":
        capabilities.update(workspace_write=False, shell=False)
    if read_only or profile.access_ceiling != "computer_control":
        capabilities.update(computer_control=False, simulator_control=False)
    configuration["capability_policy"] = capabilities
    runtime = dict(configuration["runtime_policy"])
    for name, ceiling in (
        ("timeout_seconds", profile.timeout_seconds),
        ("max_total_tokens", profile.token_limit),
        ("max_output_tokens", min(profile.token_limit, 128_000)),
    ):
        runtime[name] = min(runtime[name], ceiling) if runtime.get(name) is not None else ceiling
    configuration["runtime_policy"] = runtime
    return configuration


@contextmanager
def solo_profile_boundary(core: Any, profile: AgentProfile):
    """Keep permissions and identity scoped to one complete turn, including errors."""
    previous = {
        "configuration": core.agent_configuration.structured(),
        "mode": core.agent_mode,
        "memory_context": core.memory_context,
        "continuity_context": core.continuity_context,
        "role_contract": core.agent_role_contract,
        "agent_id": core.agent_id,
        "max_iterations": core.max_iterations,
        "mcp": core.tool_registry.mcp_agent_policy_snapshot(),
        "memory_profile_active": getattr(core, "_memory_profile_active", False),
    }
    read_only = bool(getattr(core, "evaluation_read_only", False))
    try:
        core._memory_profile_active = True
        core.tool_registry.set_mcp_agent_policy(
            profile.mcp_policy,
            access_ceiling="read_only" if read_only else profile.access_ceiling,
            role=profile.role,
        )
        yield bounded_profile_configuration(profile, read_only=read_only)
    finally:
        core._memory_profile_active = previous["memory_profile_active"]
        policy, ceiling, role = previous["mcp"]
        core.tool_registry.set_mcp_agent_policy(policy, access_ceiling=ceiling, role=role)
        core.configure_agent(
            previous["configuration"], mode=previous["mode"],
            memory_context=previous["memory_context"],
            continuity_context=previous["continuity_context"],
            role_contract=previous["role_contract"], agent_id=previous["agent_id"],
        )
        core.max_iterations = previous["max_iterations"]
