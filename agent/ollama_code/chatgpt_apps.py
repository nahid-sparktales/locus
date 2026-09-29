"""Supported Codex app discovery; never calls the experimental plugin install API."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .codex_app_server import CodexAppServerError

APP_ID = re.compile(r"^[A-Za-z0-9_-]{1,200}$")


def selected_apps(home: Path) -> list[str]:
    try:
        value = json.loads((home / "locus-apps.json").read_text())
        return sorted({v for v in value if isinstance(v, str) and APP_ID.fullmatch(v)})[:100] if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


def app_policy(ids: list[str]) -> dict[str, Any]:
    return {"_default": {"enabled": False}, **{identifier: {
        "enabled": True, "default_tools_approval_mode": "prompt", "approvals_reviewer": "user",
    } for identifier in ids if APP_ID.fullmatch(identifier)}}


def public_url(value: Any, *, install: bool = False) -> str | None:
    if not isinstance(value, str) or len(value) > 4096:
        return None
    try:
        url = urlparse(value)
        if url.scheme != "https" or not url.hostname or url.username or url.password:
            return None
        if install and (url.hostname != "chatgpt.com" or url.port not in (None, 443)):
            return None
        return value
    except ValueError:
        return None


def catalog(manager: Any, *, refresh: bool = False) -> dict[str, Any]:
    selected = selected_apps(manager.codex_home)
    if not manager.available:
        return {"apps": [], "status": "runtime_unavailable", "message": "Install the ChatGPT component in Settings → Runtime."}
    account = manager.account().get("account") or {}
    if account.get("type") != "chatgpt":
        return {"apps": [], "status": "signed_out", "message": "Sign in to this ChatGPT account in Manage Accounts."}
    result: dict[str, dict[str, Any]] = {}
    cursor = None
    seen = set()
    for _ in range(40):
        page = manager.request("app/list", {"cursor": cursor, "limit": 50, "forceRefetch": refresh})
        for app in page.get("data") or []:
            if not isinstance(app, dict) or not isinstance(app.get("id"), str) or not APP_ID.fullmatch(app["id"]):
                continue
            identifier = app["id"]
            result[identifier] = {
                "id": identifier, "name": str(app.get("name") or identifier)[:200],
                "description": str(app.get("description") or "")[:4000],
                "logo_url": public_url(app.get("logoUrl")),
                "install_url": public_url(app.get("installUrl"), install=True),
                "accessible": app.get("isAccessible") is True,
                "enabled": identifier in selected,
                "runtime_enabled": app.get("isEnabled") is True,
                "callable": None,
            }
        cursor = page.get("nextCursor")
        if not cursor:
            break
        if cursor in seen:
            raise CodexAppServerError("ChatGPT repeated an app catalog page. Try refreshing.")
        seen.add(cursor)
    else:
        raise CodexAppServerError("ChatGPT app catalog exceeded the supported page limit.")
    runtime_note = ""
    try:
        snapshot = manager.request("app/installed", {"forceRefresh": refresh})
        for state in snapshot.get("apps") or []:
            if isinstance(state, dict) and state.get("id") in result:
                result[state["id"]]["callable"] = state.get("callable") is True
    except CodexAppServerError:
        # Older bundled helpers still support app/list. Do not invent a ready state.
        runtime_note = "This ChatGPT runtime cannot report app readiness. Update the ChatGPT component if an app cannot run."
    return {"apps": sorted(result.values(), key=lambda a: a["name"].casefold()),
            "status": "ready", "message": runtime_note}


def set_enabled(manager: Any, identifier: str, enabled: bool) -> dict[str, Any]:
    if not APP_ID.fullmatch(identifier):
        raise ValueError("Invalid ChatGPT app ID")
    if enabled:
        available = catalog(manager)
        if not any(a["id"] == identifier and a["accessible"] for a in available["apps"]):
            raise ValueError("Connect this app with your ChatGPT account first.")
    ids = set(selected_apps(manager.codex_home))
    ids.add(identifier) if enabled else ids.discard(identifier)
    if len(ids) > 100:
        raise ValueError("Enable at most 100 ChatGPT apps per account.")
    # Update the running helper through documented config RPCs, then persist
    # Locus's selection separately from helper credentials/config rewrites.
    manager.request("config/batchWrite", {"edits": [
        {"keyPath": "features.apps", "value": True, "mergeStrategy": "upsert"},
        {"keyPath": "apps", "value": app_policy(sorted(ids)), "mergeStrategy": "replace"},
    ]})
    manager.codex_home.mkdir(parents=True, exist_ok=True)
    path = manager.codex_home / "locus-apps.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(sorted(ids)))
    temporary.chmod(0o600)
    temporary.replace(path)
    return {"ok": True}


def approval_answers(params: dict[str, Any], approved: bool) -> dict[str, Any]:
    """Only approve the one-time choices supplied by the helper; never remember."""
    answers = {}
    for question in (params.get("questions") or [])[:3]:
        if not isinstance(question, dict) or not isinstance(question.get("id"), str):
            continue
        if not question["id"].startswith("mcp_tool_call_approval_"):
            approved_for_question = False
        else:
            approved_for_question = approved
        choices = [option.get("label") for option in question.get("options") or [] if isinstance(option, dict)]
        positive = next((label for label in choices if label in {"Accept", "Approve", "Allow", "Allow once"}), None)
        negative = next((label for label in choices if label in {"Decline", "Deny", "Cancel"}), None)
        answers[question["id"]] = {"answers": [positive if approved_for_question and positive else negative or "Decline"]}
    return {"answers": answers}
