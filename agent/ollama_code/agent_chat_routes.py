"""Credential-free model snapshots for one saved-agent conversation turn."""

import uuid
from typing import Any


def validate_agent_chat_route(value: Any, metadata: dict[str, Any]) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) - {"profile_id", "provider", "provider_account_id", "model"}:
        raise ValueError("The agent chat model selection is malformed.")
    try:
        profile_id = str(uuid.UUID(value.get("profile_id")))
        owners = [str(uuid.UUID(metadata[key])) for key in ("agent_profile_id", "agent_world_profile_id")
                  if metadata.get(key)]
    except (ValueError, TypeError, AttributeError) as exc:
        raise ValueError("The agent chat model selection has an invalid owner.") from exc
    if not owners or any(owner != profile_id for owner in owners):
        raise ValueError("The model selection belongs to a different saved agent.")
    if metadata.get("agent_primary"):
        raise ValueError("Automation tasks keep their configured model.")
    provider = value.get("provider")
    model = value.get("model")
    if not isinstance(provider, str) or provider not in {"ollama", "remote", "chatgpt", "claude_plan"} or not isinstance(model, str) \
            or not model.strip() or len(model) > 512:
        raise ValueError("The agent chat model selection needs an exact provider and model.")
    result = {"profile_id": profile_id, "provider": provider, "model": model.strip()}
    account_id = value.get("provider_account_id")
    if provider == "ollama":
        if account_id not in (None, ""):
            raise ValueError("Local model selections cannot use a provider account.")
    else:
        try:
            uuid.UUID(account_id)
        except (ValueError, TypeError, AttributeError) as exc:
            raise ValueError("The model selection needs its exact provider account.") from exc
        result["provider_account_id"] = account_id
    return result
