"""Provider selection, model discovery, and ChatGPT account routes."""

import math
import sqlite3
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..chat_service import AgentBusyError, ChatService
from ..codex_app_server import CodexAppServerError
from ..config import context_window
from ..model_router import ModelRouterError, decide_model_route
from ..ollama import OllamaError, effective_context_length
from ..runstore import RunStoreError
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def get_provider(service: ServiceDependency) -> dict[str, Any]:
    return service.core.provider_state()


def model_router_decision(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Score eligible model routes without receiving the user's prompt text."""
    try:
        return decide_model_route(service.run_store, body)
    except (ModelRouterError, RunStoreError, sqlite3.DatabaseError) as exc:
        raise HTTPException(422, str(exc)) from exc


def model_router_sample(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Record the observable outcome of one opt-in routed solo turn."""
    route_id = str(body.get("route_id") or "").strip()[:512]
    if not route_id:
        raise HTTPException(422, "model router sample needs a route_id")
    raw_tags = body.get("tags")
    tags = (
        [str(item).strip().lower()[:40] for item in raw_tags[:24]]
        if isinstance(raw_tags, list)
        else []
    )
    try:
        quality_value = body.get("quality")
        quality = None if quality_value is None else float(quality_value)
        estimated_cost = float(body.get("estimated_cost") or 0)
        if quality is not None and not math.isfinite(quality):
            raise ValueError("model router quality must be finite")
        if not math.isfinite(estimated_cost):
            raise ValueError("model router estimated cost must be finite")
        if quality is not None:
            quality = min(max(quality, 0), 100)
        service.run_store.record_routing_sample(
            route_id,
            tags=[tag for tag in tags if tag],
            quality=quality,
            reliable=bool(body.get("reliable")),
            latency_ms=max(int(body.get("latency_ms") or 0), 0),
            estimated_cost=max(estimated_cost, 0),
            local=bool(body.get("local")),
            evaluation=bool(body.get("evaluation")),
        )
    except (
        TypeError,
        ValueError,
        OverflowError,
        RunStoreError,
        sqlite3.DatabaseError,
    ) as exc:
        raise HTTPException(422, str(exc)) from exc
    return {"ok": True, "route_id": route_id}


def _chatgpt_manager(service: ChatService, home_id: str) -> Any:
    """Return the helper for a requested account, or reject a malformed id."""
    try:
        return service.codex_for(home_id)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error


def chatgpt_account_payload(
    service: ChatService, *, refresh: bool = False, home_id: str = ""
) -> dict[str, Any]:
    """Return the stable, secret-free account shape used by API consumers."""
    manager = _chatgpt_manager(service, home_id)
    if not manager.available:
        return {
            "status": "runtime_unavailable",
            "runtime_available": False,
            "message": "The bundled ChatGPT runtime is unavailable.",
            "email": None,
            "plan_type": None,
        }
    try:
        raw = manager.account(refresh=refresh)
    except CodexAppServerError as error:
        return {
            "status": "runtime_unavailable",
            "runtime_available": False,
            "message": str(error),
            "email": None,
            "plan_type": None,
        }
    account = raw.get("account")
    signed_in = isinstance(account, dict) and account.get("type") == "chatgpt"
    return {
        "status": "signed_in" if signed_in else "signed_out",
        "runtime_available": True,
        "runtime_version": str(raw.get("runtimeVersion") or ""),
        "email": account.get("email") if signed_in else None,
        "plan_type": account.get("planType") if signed_in else None,
        "message": "" if signed_in else "Sign in to use included ChatGPT plan usage.",
    }


def chatgpt_account(
    service: ServiceDependency,
    refresh: bool = Query(default=False),
    account_id: str = Query(default=""),
) -> dict[str, Any]:
    return chatgpt_account_payload(service, refresh=refresh, home_id=account_id)


def chatgpt_login_start(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    manager = _chatgpt_manager(service, str(body.get("account_id") or ""))
    try:
        result = manager.start_login()
    except CodexAppServerError as error:
        raise HTTPException(503, str(error)) from error
    return {
        "status": "signing_in",
        "login_id": str(result.get("loginId") or ""),
        "auth_url": str(result.get("authUrl") or ""),
    }


def chatgpt_login_cancel(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    login_id = str(body.get("login_id") or "").strip()
    if not login_id:
        raise HTTPException(422, "login_id is required")
    home_id = str(body.get("account_id") or "")
    try:
        _chatgpt_manager(service, home_id).cancel_login(login_id)
    except CodexAppServerError as error:
        raise HTTPException(409, str(error)) from error
    return chatgpt_account_payload(service, home_id=home_id)


def chatgpt_logout(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    home_id = str(body.get("account_id") or "")
    manager = _chatgpt_manager(service, home_id)
    try:
        with service.state_mutation():
            manager.logout()
            # Signing out of a secondary account must not interrupt a turn
            # running on the account currently selected by the agent.
            if service.core.provider == "chatgpt" and manager is service.codex:
                service.core.use_ollama()
    except AgentBusyError as error:
        raise _busy_http() from error
    except CodexAppServerError as error:
        raise HTTPException(409, str(error)) from error
    return chatgpt_account_payload(service, home_id=home_id)


def chatgpt_models(
    service: ServiceDependency,
    account_id: str = Query(default=""),
) -> dict[str, Any]:
    account = chatgpt_account_payload(service, home_id=account_id)
    if account["status"] != "signed_in":
        return {"models": [], "status": account["status"], "message": account["message"]}
    try:
        rows = _chatgpt_manager(service, account_id).models()
    except CodexAppServerError as error:
        raise HTTPException(503, str(error)) from error
    return {
        "status": "signed_in",
        "models": [
            {
                "id": str(row.get("model") or row.get("id") or ""),
                "display_name": str(
                    row.get("displayName") or row.get("model") or row.get("id") or ""
                ),
                "description": str(row.get("description") or ""),
                "is_default": bool(row.get("isDefault")),
                "supported_reasoning_efforts": _chatgpt_efforts(row),
                "default_reasoning_effort": str(row.get("defaultReasoningEffort") or ""),
            }
            for row in rows
            if row.get("model") or row.get("id")
        ],
    }


def _chatgpt_efforts(row: dict[str, Any]) -> list[dict[str, str]]:
    """Return supported effort choices while withholding unsupported ultra."""
    raw = row.get("supportedReasoningEfforts")
    if not isinstance(raw, list):
        return []
    efforts: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        effort = str(item.get("effort") or "").strip()
        if not effort or effort == "ultra":
            continue
        efforts.append({"effort": effort, "description": str(item.get("description") or "")})
    return efforts


def chatgpt_usage(
    service: ServiceDependency,
    account_id: str = Query(default=""),
) -> dict[str, Any]:
    account = chatgpt_account_payload(service, home_id=account_id)
    if account["status"] != "signed_in":
        return {
            "status": account["status"],
            "plan_type": account.get("plan_type"),
            "rate_limits": {},
            "activity": {},
            "message": account["message"],
        }
    try:
        raw = _chatgpt_manager(service, account_id).usage()
    except CodexAppServerError as error:
        raise HTTPException(503, str(error)) from error
    return {
        "status": "signed_in",
        "plan_type": account.get("plan_type"),
        "rate_limits": raw.get("rateLimits") or {},
        "activity": raw.get("activity") or {},
        "message": "",
    }


def set_provider(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    """Switch between the local runtime, ChatGPT plan, and hosted endpoints."""
    try:
        with service.state_mutation():
            return _apply_provider(service, body)
    except AgentBusyError as error:
        raise _busy_http() from error


def _apply_provider(service: ChatService, body: dict[str, Any]) -> dict[str, Any]:
    """Apply a provider request after the service has reserved mutable state."""
    provider = str(body.get("provider") or "").strip().lower()
    if provider not in ("ollama", "remote", "chatgpt"):
        raise HTTPException(422, "provider must be 'ollama', 'remote', or 'chatgpt'")

    if provider == "ollama":
        try:
            service.core.use_ollama(
                host=str(body.get("host") or "") or None,
                context_window_tokens=body.get("context_window"),
            )
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        service.resolve_context_limit_soon()
        return service.core.provider_state()

    if provider == "chatgpt":
        forbidden = [key for key in ("api_key", "base_url", "remote_base_url") if key in body]
        if forbidden:
            raise HTTPException(
                422,
                "the ChatGPT provider rejects API-key and base-URL fields",
            )
        account_id = str(body.get("account_id") or "").strip()
        if not account_id:
            raise HTTPException(422, "account_id is required for the ChatGPT provider")
        raw_native = body.get("native_mode")
        raw_search = body.get("web_search")
        raw_effort = body.get("reasoning_effort")
        try:
            manager = service.use_chatgpt_home(str(body.get("codex_home_id") or ""))
            service.core.use_chatgpt(
                account_id=account_id,
                model=str(body.get("model") or ""),
                account_label=str(body.get("account_label") or "ChatGPT plan"),
                manager=manager,
                native_mode=None if raw_native is None else bool(raw_native),
                web_search=None if raw_search is None else bool(raw_search),
                reasoning_effort=None if raw_effort is None else str(raw_effort),
            )
        except (ValueError, CodexAppServerError) as error:
            raise HTTPException(409, str(error)) from error
        return service.core.provider_state()

    base_url = str(body.get("base_url") or body.get("remote_base_url") or "").strip()
    if not base_url:
        raise HTTPException(422, "base_url is required for the remote provider")
    raw_key = body.get("api_key")
    api_key = None if raw_key is None else str(raw_key)
    raw_style = body.get("auth_style")
    raw_label = body.get("account_label")
    raw_lists = body.get("lists_models")
    try:
        service.core.use_remote(
            base_url=base_url,
            api_key=api_key,
            model=str(body.get("model") or ""),
            auth_style=None if raw_style is None else str(raw_style),
            account_label=None if raw_label is None else str(raw_label),
            lists_models=None if raw_lists is None else bool(raw_lists),
            context_window_tokens=body.get("context_window"),
            published_context_window=body.get("published_context_window"),
        )
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    if body.get("verify"):
        try:
            service.core.client.check()
        except OllamaError as error:
            raise HTTPException(502, str(error)) from error
    service.resolve_context_limit_soon()
    return service.core.provider_state()


def models(service: ServiceDependency) -> dict[str, Any]:
    if service.core.provider == "chatgpt":
        try:
            return {
                "models": [
                    {
                        "name": str(item.get("model") or item.get("id") or ""),
                        "size": 0,
                        "parameter_size": "ChatGPT plan",
                        "context_length": 0,
                        "trained_context_length": 0,
                        "vision": (
                            "image" in item.get("inputModalities", [])
                            if isinstance(item.get("inputModalities"), list)
                            else None
                        ),
                    }
                    for item in service.codex.models()
                    if item.get("model") or item.get("id")
                ],
                "current": service.core.model,
            }
        except CodexAppServerError as error:
            raise HTTPException(503, str(error)) from error
    try:
        raw = service.core.client.list_models()
    except OllamaError as error:
        raise HTTPException(502, str(error)) from error
    configured = context_window(service.core.config.get("context_window"))
    is_ollama = service.core.provider != "remote"
    resident: dict[str, int] = {}
    if is_ollama:
        try:
            for entry in service.core.client.running_models():
                window = entry.get("context_length")
                if isinstance(window, int) and window > 0:
                    for key in (entry.get("name"), entry.get("model")):
                        if key:
                            resident[key] = window
        except OllamaError:
            resident = {}
    out: list[dict[str, Any]] = []
    for model in raw:
        name = model.get("name")
        if not name:
            continue
        vision: bool | None = None
        if is_ollama:
            trained = service.core.client.context_length(name)
            model_configured = configured if name == service.core.model else 0
            window = effective_context_length(
                resident.get(name, 0), trained, model_configured
            )
            if window <= 0:
                window = service.core.remembered_model_window(name)
            vision = service.core.client.vision_capability(name)
        else:
            window = int(model.get("context_length") or 0)
            trained = int(model.get("trained_context_length") or 0) or window
            if name == service.core.model:
                window = service.core.context_limit or window
            if window <= 0:
                window = service.core.remembered_model_window(name)
        out.append(
            {
                "name": name,
                "size": model.get("size") or 0,
                "parameter_size": (model.get("details") or {}).get("parameter_size", ""),
                "context_length": window,
                "trained_context_length": trained,
                "vision": vision,
            }
        )
    return {"models": out, "current": service.core.model}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/provider", get_provider, methods=["GET"])
    router.add_api_route(
        "/api/model-router/decision", model_router_decision, methods=["POST"]
    )
    router.add_api_route("/api/model-router/sample", model_router_sample, methods=["POST"])
    router.add_api_route("/api/chatgpt/account", chatgpt_account, methods=["GET"])
    router.add_api_route("/api/chatgpt/login/start", chatgpt_login_start, methods=["POST"])
    router.add_api_route(
        "/api/chatgpt/login/cancel", chatgpt_login_cancel, methods=["POST"]
    )
    router.add_api_route("/api/chatgpt/logout", chatgpt_logout, methods=["POST"])
    router.add_api_route("/api/chatgpt/models", chatgpt_models, methods=["GET"])
    router.add_api_route("/api/chatgpt/usage", chatgpt_usage, methods=["GET"])
    router.add_api_route("/api/provider", set_provider, methods=["POST"])
    router.add_api_route("/api/models", models, methods=["GET"])


__all__ = ["chatgpt_account_payload", "register_routes"]
