"""Temporary profile boundaries for a conversation whose provider is already configured."""
from __future__ import annotations

from contextlib import contextmanager
from typing import Any

from .orchestration import AgentProfile


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
    }
    read_only = bool(getattr(core, "evaluation_read_only", False))
    try:
        core.tool_registry.set_mcp_agent_policy(
            profile.mcp_policy,
            access_ceiling="read_only" if read_only else profile.access_ceiling,
            role=profile.role,
        )
        yield bounded_profile_configuration(profile, read_only=read_only)
    finally:
        policy, ceiling, role = previous["mcp"]
        core.tool_registry.set_mcp_agent_policy(policy, access_ceiling=ceiling, role=role)
        core.configure_agent(
            previous["configuration"], mode=previous["mode"],
            memory_context=previous["memory_context"],
            continuity_context=previous["continuity_context"],
            role_contract=previous["role_contract"], agent_id=previous["agent_id"],
        )
        core.max_iterations = previous["max_iterations"]
