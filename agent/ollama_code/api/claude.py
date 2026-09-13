"""Secret-free Claude subscription account endpoints."""
from typing import Any

from fastapi import APIRouter, Body, HTTPException, Query

from ..capabilities import enabled
from ..codex_app_server import CodexAppServerError
from .providers import ServiceDependency


def manager_for(service, account_id):
    if not enabled("claude_plan_v1"):
        raise HTTPException(404, "Claude plan support is not enabled in this release.")
    try:
        return service.claude_for(account_id)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error


def account_payload(service, account_id):
    manager = manager_for(service, account_id)
    if not manager.available:
        return {"status": "runtime_unavailable", "runtime_available": False,
                "message": "Install Claude plan support to sign in."}
    try:
        raw = manager.account()
    except CodexAppServerError as error:
        return {"status": "runtime_unavailable", "runtime_available": True, "message": str(error)}
    identity = raw.get("account") or {}
    signing = bool(getattr(manager, "_login", None) and manager._login[1].poll() is None)
    return {"status": "signed_in" if identity else "signing_in" if signing else "signed_out",
            "runtime_available": True, "runtime_version": raw.get("runtimeVersion"),
            "email": identity.get("email"), "plan_type": identity.get("planType"),
            "message": "" if identity else "Sign in with a Claude subscription."}


def account(service: ServiceDependency, account_id: str = Query(...)):
    return account_payload(service, account_id)


def login_start(service: ServiceDependency, body: dict[str, Any] = Body(...)):
    manager = manager_for(service, body.get("account_id"))
    try:
        result = manager.start_login()
    except CodexAppServerError as error:
        raise HTTPException(409, str(error)) from error
    return {"status": "signing_in", "login_id": result["loginId"], "auth_url": result["authUrl"]}


def login_cancel(service: ServiceDependency, body: dict[str, Any] = Body(...)):
    manager = manager_for(service, body.get("account_id"))
    try:
        manager.cancel_login(body.get("login_id"))
    except CodexAppServerError as error:
        raise HTTPException(409, str(error)) from error
    return account_payload(service, body["account_id"])


def logout(service: ServiceDependency, body: dict[str, Any] = Body(...)):
    manager = manager_for(service, body.get("account_id"))
    try:
        manager.logout()
    except CodexAppServerError as error:
        raise HTTPException(409, str(error)) from error
    return account_payload(service, body["account_id"])


def models(service: ServiceDependency, account_id: str = Query(...)):
    state = account_payload(service, account_id)
    if state["status"] != "signed_in":
        return {**state, "models": []}
    try:
        rows = manager_for(service, account_id).models()
    except CodexAppServerError as error:
        raise HTTPException(503, str(error)) from error
    return {"status": "signed_in", "models": [
        {"id": row["model"], "display_name": row.get("displayName") or row["model"],
         "description": row.get("description", ""), "is_default": bool(row.get("isDefault")),
         "supported_reasoning_efforts": row.get("supportedReasoningEfforts", [])} for row in rows]}


def usage(service: ServiceDependency, account_id: str = Query(...)):
    state = account_payload(service, account_id)
    raw = manager_for(service, account_id).usage()
    window = None
    if raw.get("utilization") is not None:
        window = {"usedPercent": min(100, max(0, round(raw["utilization"] * 100))),
                  "resetsAt": raw.get("resets_at"), "windowDurationMins": None}
    return {"status": state["status"], "plan_type": state.get("plan_type"),
            "rate_limits": {"rateLimits": {"primary": window}}, "activity": {},
            "limit_status": raw.get("status"), "observed_at": raw.get("observed_at"),
            "message": "Usage has not been reported yet." if not raw else ""}


def select_claude(service, body):
    if any(key in body for key in ("api_key", "base_url", "remote_base_url", "token", "authorization")):
        raise HTTPException(422, "Claude plan accounts reject API credentials and endpoint overrides.")
    account_id = body.get("account_id")
    manager = manager_for(service, account_id)
    try:
        service.core.use_claude_plan(account_id=account_id, model=str(body.get("model") or "default"),
            account_label=str(body.get("account_label") or "Claude plan"), manager=manager,
            reasoning_effort=str(body.get("reasoning_effort") or ""))
    except (ValueError, CodexAppServerError) as error:
        raise HTTPException(409, str(error)) from error
    return service.core.provider_state()


def register_routes(router: APIRouter):
    for path, handler in (("account", account), ("models", models), ("usage", usage)):
        router.add_api_route("/api/claude/" + path, handler, methods=["GET"])
    for path, handler in (("login/start", login_start), ("login/cancel", login_cancel), ("logout", logout)):
        router.add_api_route("/api/claude/" + path, handler, methods=["POST"])
