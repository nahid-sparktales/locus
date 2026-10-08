"""Assigned-model snapshots and initial-failure fallback for saved agents.

Credentials are read only from the controller-owned runtime store. A task's
public snapshot contains account IDs and exact models, never provider secrets.
"""
from __future__ import annotations

import os
import re
import time
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any

from .agent_chat_routes import remember_chat_route, validate_chat_route, validate_model_choices


def profile_model_choices(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 7:
        raise ValueError("An agent can have at most eight assigned models.")
    result = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"route", "model"}:
            raise ValueError("An assigned model needs its provider route and exact model.")
        model, route = item["model"], item["route"]
        if not isinstance(model, str) or not model.strip() or len(model) > 256 \
                or any(ord(char) < 32 for char in model):
            raise ValueError("An assigned model identifier is invalid.")
        if not isinstance(route, dict) or set(route) - {"kind", "accountID"}:
            raise ValueError("Assigned model routes cannot contain provider credentials.")
        if route.get("kind") == "ollama" and route.get("accountID") is None:
            normalized = {"kind": "ollama"}
        elif route.get("kind") == "account":
            try:
                normalized = {"kind": "account", "accountID": str(uuid.UUID(route.get("accountID")))}
            except (ValueError, TypeError, AttributeError) as exc:
                raise ValueError("An assigned model needs its exact account.") from exc
        else:
            raise ValueError("An assigned model route is invalid.")
        choice = {"route": normalized, "model": model.strip()}
        if choice in result:
            raise ValueError("Assigned models must be distinct.")
        result.append(choice)
    return result


def provider_route(provider: dict[str, Any], model: str = "") -> dict[str, str]:
    return validate_chat_route({"provider": provider.get("provider"),
                                "provider_account_id": provider.get("account_id"),
                                "model": model or provider.get("model")})


def normalize_runtime_choices(item: dict[str, Any]) -> dict[str, Any]:
    """Validate the write-only controller envelope before replacing its store."""
    result = deepcopy(item)
    profile = result["profile"]
    extras = profile_model_choices(profile.get("model_choices"))
    if "model_choices" in profile:
        profile["model_choices"] = extras
    choices = result.get("model_choices")
    if choices is None:
        return result
    if not isinstance(choices, list) or not 1 <= len(choices) <= 8:
        raise ValueError("The runtime needs one to eight assigned models.")
    allowed = {(choice["route"].get("accountID"), choice["model"]) for choice in extras}
    seen = set()
    for index, choice in enumerate(choices):
        if not isinstance(choice, dict) or set(choice) - {"model", "provider", "unavailable"}:
            raise ValueError("The runtime model choice is malformed.")
        model = choice.get("model")
        if not isinstance(model, str) or not model.strip() or len(model) > 256:
            raise ValueError("The runtime model choice needs an exact model.")
        if index == 0 and model != profile["model"]:
            raise ValueError("The preferred model must lead the assigned pool.")
        provider = choice.get("provider")
        if provider is None:
            if not isinstance(choice.get("unavailable"), str) or not choice["unavailable"]:
                raise ValueError("An unavailable model needs its reason.")
            continue
        if not isinstance(provider, dict) or provider.get("model") not in (None, model):
            raise ValueError("The assigned provider and model disagree.")
        route = provider_route(provider, model)
        identity = (route.get("provider_account_id"), model)
        if index > 0 and identity not in allowed:
            raise ValueError("The runtime model is not assigned to the agent.")
        if identity in seen:
            raise ValueError("Assigned models must be distinct.")
        seen.add(identity)
        choice["provider"] = {**provider, "model": model}
    if result.get("model_selection", "task") != "task":
        raise ValueError("Unknown agent model-selection policy.")
    return result


def configured_choices(item: dict[str, Any]) -> list[tuple[dict[str, str], dict[str, Any]]]:
    entries = item.get("model_choices")
    if entries is None:
        entries = [{"model": item.get("profile", {}).get("model"), "provider": item.get("provider")}]
    result = []
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("provider"), dict):
            provider = {**entry["provider"], "model": entry["model"]}
            result.append((provider_route(provider), provider))
    return result


def live_task_choices(saved: dict[str, Any], snapshot: Any) -> list[dict[str, Any]]:
    """Resolve frozen identities against current credentials, including revocation."""
    result = []
    for route in validate_model_choices(snapshot):
        key = "account:" + route.get("provider_account_id", "local")
        provider = next((value for name, value in saved.items() if name.lower() == key), None)
        if route["provider"] == "ollama" and provider is None:
            provider = {"provider": "ollama"}
        if not isinstance(provider, dict) or provider.get("provider") != route["provider"]:
            continue
        result.append({**deepcopy(provider), "model": route["model"],
                       **({"account_id": route["provider_account_id"]} if "provider_account_id" in route else {})})
    return result


def frozen_task_choices(saved: dict[str, Any], profile_id: str, snapshot: Any,
                        run_id: str) -> list[dict[str, Any]] | None:
    frozen = saved.get(f"agent-model-task:{run_id}") if run_id else None
    if frozen is None:
        return None
    if not isinstance(frozen, dict) or frozen.get("profile_id") != str(uuid.UUID(profile_id)) \
            or frozen.get("choices") != validate_model_choices(snapshot):
        raise ValueError("The queued task's assigned-model snapshot changed.")
    return live_task_choices(saved, frozen["choices"])


def freeze_saved_task_choices(store: Any, profile_id: str, snapshot: Any,
                              run_id: str = "") -> list[dict[str, Any]]:
    saved = store.read()
    frozen = frozen_task_choices(saved, profile_id, snapshot, run_id)
    if frozen is not None:
        return frozen
    profiles = saved.get("agent-profiles", {})
    item = profiles.get(str(uuid.UUID(profile_id))) if isinstance(profiles, dict) else None
    if not isinstance(item, dict) or not isinstance(item.get("profile"), dict):
        raise ValueError("The saved agent's assigned models are unavailable.")
    requested = validate_model_choices(snapshot)
    assigned = [route for route, _ in configured_choices(item)]
    if any(route not in assigned for route in requested):
        raise ValueError("The task requests a model that is not assigned to this agent.")
    if run_id:
        # Only identities are frozen. Account credentials are always resolved
        # afresh, so revoked accounts cannot survive in a queued task copy.
        store.set(f"agent-model-task:{run_id}", {"profile_id": str(uuid.UUID(profile_id)),
                  "choices": requested, "created_at": time.time()})
    return live_task_choices(saved, requested)


def freeze_task_choices(profile_id: str, snapshot: Any, run_id: str) -> list[dict[str, Any]]:
    root = os.environ.get("LOCUS_RUNTIME_PROFILE_ROOT", "").strip()
    if not root or not Path(root).is_absolute() or not (Path(root) / "runtime-secrets.json").is_file():
        raise ValueError("Reconnect Locus to load the agent's assigned models.")
    from .runtime_store import PrivateStore
    return freeze_saved_task_choices(PrivateStore(Path(root)), profile_id, snapshot, run_id)


def trusted_task_choices(profile_id: str, snapshot: Any, run_id: str = "") -> list[dict[str, Any]]:
    return freeze_task_choices(profile_id, snapshot, run_id)


def clean_task_choices(store: Any, runs: Any, *, now: float | None = None) -> None:
    now = time.time() if now is None else now
    for key, frozen in store.read().items():
        if not key.startswith("agent-model-task:"):
            continue
        run = runs.run(key[len("agent-model-task:"):])
        if run and run.get("state") in {"completed", "failed", "cancelled", "interrupted", "discarded"} \
                or run is None and now - float(frozen.get("created_at", 0)) > 86_400:
            store.set(key, None)


def rank_task_choices(choices: list[dict[str, Any]], text: str, run_store: Any) -> list[dict[str, Any]]:
    """Use the same account/model sample identities as native Solo routing."""
    if len(choices) < 2:
        return choices
    from .model_router import decide_model_route
    tags = task_tags(text)
    candidates = []
    mapping = {}
    for index, choice in enumerate(choices):
        route = provider_route(choice)
        key = model_route_id(route)
        mapping[key] = choice
        candidates.append({"id": key, "name": route["model"], "model": route["model"],
                           "provider": route["provider"], "local": route["provider"] == "ollama",
                           "metering": "subscription" if route["provider"] in {"chatgpt", "claude_plan"}
                           else "self_hosted" if route["provider"] == "ollama" else "metered",
                           "current": index == 0, "sample_ids": [key]})
    decision = decide_model_route(run_store, {"candidates": candidates, "tags": tags})
    return [mapping[item["route_id"]] for item in decision["candidates"]]


def task_tags(text: str) -> list[str]:
    lower = text.lower()
    terms = {"coding": ("code", "function", "class", "api", "compile", "refactor", ".swift", ".py", ".js"),
             "debugging": ("bug", "debug", "crash", "error", "failing", "fix"),
             "testing": ("test", "spec", "verify", "regression"),
             "review": ("review", "audit", "security", "risk"),
             "research": ("research", "compare", "sources", "browse", "latest"),
             "writing": ("write", "rewrite", "draft", "summarize", "explain")}
    tags = [tag for tag, words in terms.items() if any(word in lower for word in words)]
    if len(text) > 12_000:
        tags.append("long_context")
    return tags or ["general"]


def model_route_id(route: dict[str, str]) -> str:
    return f"model-route:{route.get('provider_account_id', 'ollama')}:{route['model'].lower()}"


def record_route_outcome(run_store: Any, provider: dict[str, Any], text: str,
                         *, reliable: bool, latency_ms: int) -> None:
    if run_store is None:
        return
    run_store.record_routing_sample(model_route_id(provider_route(provider)), tags=task_tags(text),
                                   quality=None, reliable=reliable, latency_ms=latency_ms,
                                   estimated_cost=0, local=provider["provider"] == "ollama", evaluation=False)


def initial_provider_failure(error: BaseException | None, *, managed: bool) -> bool:
    from .codex_app_server import CodexAppServerError
    from .ollama import OllamaError
    from .orchestration import ProviderUnavailableError
    if isinstance(error, ProviderUnavailableError):
        return True
    if not isinstance(error, (OllamaError, CodexAppServerError)):
        return False
    text = str(error).lower()
    # Classic providers cannot execute tools independently. A failed first
    # model request before output is safe even when transport acceptance is
    # unknown. Managed helpers can have hosted actions, so uncertain disconnects
    # and timeouts never qualify; only explicit unavailable/quota/auth rejection.
    if not managed and isinstance(error, OllamaError):
        return True
    return bool(re.search(r"rate.?limit|usage.?limit|quota|too many requests|\b(?:401|403|404|429|503)\b|"
                          r"model.{0,80}(?:not found|not available|unavailable|not supported)|"
                          r"(?:runtime|helper).{0,40}unavailable|sign in|not authenticated", text))


def run_with_model_fallback(service: Any, choices: list[dict[str, Any]], text: str,
                            decider: Any, *, core_override: Any = None, apply_route: Any = None,
                            update_session_route: bool = True, **options: Any) -> None:
    """Retry only an initial model failure; keep one durable user/run boundary."""
    core = core_override or service.core
    if not choices:
        core.run_turn(text, decider, **options)
        return
    before_messages = deepcopy(core.messages)
    original_handler = core._event_handler
    original_suppress = core._suppress_turn_done
    progress = False
    pending: list[dict[str, Any]] = []
    attempted = 0
    failed_calls = 0

    def deliver(event):
        if original_handler is not None:
            original_handler(event)

    def observe(event):
        nonlocal progress
        kind = event.get("type")
        if kind in {"tool_call_proposed", "tool_result", "permission_request", "question_request",
                    "assistant_item_start", "assistant_item_delta", "assistant_item_end"} \
                or kind in {"token", "thinking"} and event.get("text") \
                or kind == "message_end" and event.get("content"):
            progress = True
        if kind in {"error", "turn_done"}:
            pending.append(dict(event))
        else:
            deliver(event)

    core.on_event(observe)
    try:
        for index, provider in enumerate(choices):
            pending.clear()
            if (index or core.provider != provider["provider"] or core.model != provider["model"]
                    or str(core.account_id or "").lower() != str(provider.get("account_id") or "").lower()):
                from .api.providers import _apply_provider
                try:
                    if apply_route is not None:
                        apply_route(provider)
                    else:
                        _apply_provider(service, provider)
                        if core.model != provider["model"]:
                            core.set_model(provider["model"])
                except Exception:
                    # Configuration has not admitted any work. Try the next
                    # assigned entry without exposing provider credentials.
                    if index + 1 < len(choices):
                        continue
                    deliver({"type": "error", "message": "The remaining assigned models could not connect."})
                    core.last_turn_result = {"type": "turn_done", "reason": "error", "duration_ms": 0,
                                             "model_calls": failed_calls, "tool_steps": 0,
                                             "prompt_tokens": 0, "completion_tokens": 0,
                                             "provider": core.provider, "model": core.model}
                    if not original_suppress:
                        deliver(dict(core.last_turn_result))
                    return
                core.messages = deepcopy(before_messages)
                # No tools were accepted before this change. Refresh the older
                # Solo executor's immutable provider snapshot before it can run.
                from .solo_swarm import SoloSwarmExecutor, snapshot_route
                swarm = getattr(service, "active_solo_swarm", None)
                if isinstance(swarm, SoloSwarmExecutor):
                    swarm.route = snapshot_route(core, core.codex_manager if core.provider == "claude_plan" else service.codex)
                if update_session_route:
                    remember_chat_route(core, automatic=True)
                core._emit({"type": "note", "text": (f"The first model could not start. Continuing with {core.model}."
                            if attempted else f"Using {core.model} for this task."),
                            "model_fallback": True, "model": core.model, "provider": core.provider})
            core._initial_provider_error = None
            attempt_options = {**options, "persist_user_message": options.get("persist_user_message", True) and attempted == 0}
            if options.get("model_call_limit") is not None:
                attempt_options["model_call_limit"] = max(options["model_call_limit"] - failed_calls, 1)
            core.run_turn(text, decider, **attempt_options)
            attempted += 1
            failed = core.last_turn_result.get("reason") == "error"
            record_route_outcome(getattr(service, "run_store", None), provider, text,
                                 reliable=core.last_turn_result.get("reason") == "complete",
                                 latency_ms=int(core.last_turn_result.get("duration_ms") or 0))
            attempt_calls = max(int(core.last_turn_result.get("model_calls") or 0), 1)
            retry = (failed and not progress and not getattr(core, "_model_fallback_progress", False)
                     and not core._interrupt.is_set()
                     and index + 1 < len(choices)
                     and (options.get("model_call_limit") is None or failed_calls + attempt_calls < options["model_call_limit"])
                     and initial_provider_failure(core._initial_provider_error,
                                                  managed=core.provider in {"chatgpt", "claude_plan"}))
            if not retry:
                core.last_turn_result["model_calls"] = int(core.last_turn_result.get("model_calls") or 0) + failed_calls
                for event in pending:
                    if event.get("type") == "turn_done":
                        event["model_calls"] = core.last_turn_result["model_calls"]
                    deliver(event)
                return
            failed_calls += attempt_calls
    finally:
        core.on_event(original_handler)
        core._initial_provider_error = None
