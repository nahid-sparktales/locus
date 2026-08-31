"""Validation, deterministic filtering, and webhook authentication for events."""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import re
import time
from fnmatch import fnmatchcase
from typing import Any

CONNECTION_KINDS = {"gmail", "telegram", "webhook"}
TRIGGER_MODES = {"ask", "work", "plan", "grill", "build"}
DELIVERY_STATES = {"pending", "claiming", "queued", "failed"}
MAX_EVENT_BYTES = 256 * 1024
MAX_PENDING_PER_TRIGGER = 1_000
MAX_FILTER_VALUES = 100
MAX_TEXT = 120_000
_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}")
_BLOCKED_KEY = re.compile(
    r"(?:authorization|cookie|credential|password|secret|signature|token|api[_-]?key)$",
    re.IGNORECASE,
)


class EventTriggerValidationError(ValueError):
    pass


def valid_identifier(value: Any, label: str) -> str:
    text = str(value or "").strip()
    if not _IDENTIFIER.fullmatch(text):
        raise EventTriggerValidationError(f"{label} is invalid")
    return text


def normalize_connection(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventTriggerValidationError("connection must be an object")
    kind = str(value.get("kind") or "").strip().lower()
    if kind not in CONNECTION_KINDS:
        raise EventTriggerValidationError("connection kind must be gmail, telegram, or webhook")
    display_name = " ".join(str(value.get("display_name") or "").split())[:120]
    if not display_name:
        raise EventTriggerValidationError("connection display_name is required")
    public_config = value.get("public_config") or {}
    cursor = value.get("cursor") or {}
    if not isinstance(public_config, dict) or not isinstance(cursor, dict):
        raise EventTriggerValidationError("connection config and cursor must be objects")
    public_config = _bounded_object(public_config, "public_config", 32_000)
    cursor = _bounded_object(cursor, "cursor", 32_000)
    enabled = value.get("enabled", True)
    if not isinstance(enabled, bool):
        raise EventTriggerValidationError("connection enabled must be a boolean")
    return {
        "kind": kind,
        "display_name": display_name,
        "public_config": public_config,
        "cursor": cursor,
        "enabled": enabled,
    }


def normalize_trigger(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventTriggerValidationError("trigger must be an object")
    name = " ".join(str(value.get("name") or "").split())[:120]
    connection_id = valid_identifier(value.get("connection_id"), "connection_id")
    target_session_id = valid_identifier(value.get("target_session_id"), "target_session_id")
    instruction = str(value.get("instruction") or "").strip()[:240_000]
    if not name:
        raise EventTriggerValidationError("trigger name is required")
    if not instruction:
        raise EventTriggerValidationError("trigger instruction is required")
    mode = str(value.get("mode") or "work").strip().lower()
    if mode not in TRIGGER_MODES:
        raise EventTriggerValidationError("mode must be ask, work, plan, grill, or build")
    filters = value.get("filters") or {}
    if not isinstance(filters, dict):
        raise EventTriggerValidationError("filters must be an object")
    normalized_filters = normalize_filters(filters)
    action_ids = value.get("action_connection_ids")
    if action_ids is None:
        action_ids = [connection_id]
    if not isinstance(action_ids, list):
        raise EventTriggerValidationError("action_connection_ids must be a list")
    normalized_action_ids = list(dict.fromkeys(
        valid_identifier(item, "action connection id") for item in action_ids[:32]
    ))
    enabled = value.get("enabled", True)
    if not isinstance(enabled, bool):
        raise EventTriggerValidationError("trigger enabled must be a boolean")
    return {
        "name": name,
        "connection_id": connection_id,
        "target_session_id": target_session_id,
        "instruction": instruction,
        "mode": mode,
        "filters": normalized_filters,
        "action_connection_ids": normalized_action_ids,
        "enabled": enabled,
    }


def normalize_filters(value: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in (
        "senders", "recipients", "labels", "subject_contains", "chat_ids",
        "sender_ids", "command_prefixes", "message_types", "event_names",
    ):
        if key not in value:
            continue
        raw = value[key]
        if not isinstance(raw, list):
            raise EventTriggerValidationError(f"filter {key} must be a list")
        items = [str(item).strip()[:500] for item in raw[:MAX_FILTER_VALUES]]
        result[key] = [item for item in items if item]
    if "has_attachments" in value:
        if not isinstance(value["has_attachments"], bool):
            raise EventTriggerValidationError("filter has_attachments must be a boolean")
        result["has_attachments"] = value["has_attachments"]
    predicates = value.get("predicates")
    if predicates is not None:
        if not isinstance(predicates, list):
            raise EventTriggerValidationError("filter predicates must be a list")
        clean: list[dict[str, Any]] = []
        for raw in predicates[:32]:
            if not isinstance(raw, dict):
                raise EventTriggerValidationError("each predicate must be an object")
            path = str(raw.get("path") or "").strip()
            operation = str(raw.get("op") or "equals").strip().lower()
            if not path or len(path) > 500 or any(not part for part in path.split(".")):
                raise EventTriggerValidationError("predicate path is invalid")
            if operation not in {"exists", "equals", "contains"}:
                raise EventTriggerValidationError("predicate op must be exists, equals, or contains")
            item: dict[str, Any] = {"path": path, "op": operation}
            if operation != "exists":
                item["value"] = _clean_json(raw.get("value"), depth=0)
            clean.append(item)
        result["predicates"] = clean
    unknown = set(value) - set(result)
    if unknown:
        raise EventTriggerValidationError(f"unknown filter field: {sorted(unknown)[0]}")
    return result


def validate_filters_for_source(source: str, filters: dict[str, Any]) -> None:
    """Reject filters that cannot be evaluated for a connector's event shape."""
    allowed = {
        "gmail": {
            "senders", "recipients", "labels", "subject_contains", "has_attachments",
        },
        "telegram": {
            "chat_ids", "sender_ids", "command_prefixes", "message_types",
        },
        "webhook": {"event_names", "predicates"},
    }.get(source)
    if allowed is None:
        raise EventTriggerValidationError("event source is invalid")
    incompatible = set(filters) - allowed
    if incompatible:
        raise EventTriggerValidationError(
            f"filter {sorted(incompatible)[0]} is not valid for {source}"
        )
    if source == "telegram" and not any(filters.get(key) for key in allowed):
        raise EventTriggerValidationError(
            "Telegram triggers require an allowed chat, sender, command prefix, or message type"
        )
    if source == "webhook" and not filters.get("event_names"):
        raise EventTriggerValidationError("webhook triggers require at least one event name")


def normalize_event(value: Any, *, source: str = "") -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventTriggerValidationError("event must be an object")
    normalized_source = str(source or value.get("source") or "").strip().lower()
    if normalized_source not in CONNECTION_KINDS:
        raise EventTriggerValidationError("event source is invalid")
    source_event_id = valid_identifier(value.get("source_event_id"), "source_event_id")
    occurred_at = _finite_timestamp(value.get("occurred_at", time.time()))
    attachments = value.get("attachments") or []
    if not isinstance(attachments, list):
        raise EventTriggerValidationError("attachments must be a list")
    event = {
        "source": normalized_source,
        "source_event_id": source_event_id,
        "event_type": str(value.get("event_type") or "message")[:120],
        "occurred_at": occurred_at,
        "actor": _bounded_object(value.get("actor") or {}, "actor", 16_000),
        "subject": str(value.get("subject") or "")[:4_000],
        "text": str(value.get("text") or "")[:MAX_TEXT],
        "recipients": _string_list(value.get("recipients"), 100),
        "labels": _string_list(value.get("labels"), 100),
        "attachments": [
            _bounded_object(item, "attachment", 8_000)
            for item in attachments[:100] if isinstance(item, dict)
        ],
        "data": _clean_json(value.get("data") or {}, depth=0),
    }
    encoded = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) > MAX_EVENT_BYTES:
        raise EventTriggerValidationError("event exceeds the 256 KB limit")
    return event


def matches_trigger(filters: dict[str, Any], event: dict[str, Any]) -> bool:
    actor = event.get("actor") if isinstance(event.get("actor"), dict) else {}
    sender = str(actor.get("email") or actor.get("username") or actor.get("id") or "")
    checks = (
        ("senders", [sender], True),
        ("recipients", event.get("recipients") or [], True),
        ("labels", event.get("labels") or [], True),
        ("subject_contains", [str(event.get("subject") or "")], False),
        ("chat_ids", [str(event.get("data", {}).get("chat_id") or "")], True),
        ("sender_ids", [str(actor.get("id") or "")], True),
        ("message_types", [str(event.get("event_type") or "")], True),
        ("event_names", [str(event.get("event_type") or "")], True),
    )
    for key, candidates, glob in checks:
        expected = filters.get(key)
        if expected and not _any_match(expected, candidates, glob=glob):
            return False
    command_prefixes = filters.get("command_prefixes") or []
    text = str(event.get("text") or "").casefold()
    if command_prefixes and not any(
        text.startswith(str(prefix).casefold()) for prefix in command_prefixes
    ):
        return False
    if "has_attachments" in filters:
        if bool(event.get("attachments")) != bool(filters["has_attachments"]):
            return False
    for predicate in filters.get("predicates") or []:
        exists, actual = _resolve_path(event.get("data"), str(predicate["path"]))
        operation = predicate["op"]
        if operation == "exists" and not exists:
            return False
        if operation == "equals" and (not exists or actual != predicate.get("value")):
            return False
        if operation == "contains" and (
            not exists or str(predicate.get("value", "")).casefold() not in str(actual).casefold()
        ):
            return False
    return True


def verify_webhook_signature(
    secret: str, timestamp: str, signature: str, body: bytes,
    *, now: float | None = None, tolerance_seconds: int = 300,
) -> bool:
    try:
        sent_at = float(timestamp)
    except (TypeError, ValueError):
        return False
    current = time.time() if now is None else float(now)
    if not math.isfinite(sent_at) or abs(current - sent_at) > tolerance_seconds:
        return False
    supplied = signature.removeprefix("v1=").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", supplied):
        return False
    expected = hmac.new(
        secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, supplied)


def _any_match(expected: list[str], candidates: list[Any], *, glob: bool) -> bool:
    for wanted in expected:
        needle = wanted.casefold()
        for candidate in candidates:
            haystack = str(candidate).casefold()
            if (fnmatchcase(haystack, needle) if glob else needle in haystack):
                return True
    return False


def _resolve_path(value: Any, path: str) -> tuple[bool, Any]:
    current = value
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            return False, None
        current = current[part]
    return True, current


def _string_list(value: Any, limit: int) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise EventTriggerValidationError("event list field is invalid")
    return [str(item)[:4_000] for item in value[:limit]]


def _finite_timestamp(value: Any) -> float:
    if isinstance(value, bool):
        raise EventTriggerValidationError("occurred_at must be a timestamp")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise EventTriggerValidationError("occurred_at must be a timestamp") from exc
    if not math.isfinite(result) or result <= 0:
        raise EventTriggerValidationError("occurred_at must be a positive timestamp")
    return result


def _bounded_object(value: Any, label: str, limit: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventTriggerValidationError(f"{label} must be an object")
    cleaned = _clean_json(value, depth=0)
    if not isinstance(cleaned, dict):
        raise EventTriggerValidationError(f"{label} must be an object")
    if len(json.dumps(cleaned, ensure_ascii=False).encode()) > limit:
        raise EventTriggerValidationError(f"{label} is too large")
    return cleaned


def _clean_json(value: Any, *, depth: int) -> Any:
    if depth > 10:
        return "[truncated]"
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for raw_key, item in list(value.items())[:256]:
            key = str(raw_key)[:128]
            result[key] = "[redacted]" if _BLOCKED_KEY.search(key) else _clean_json(
                item, depth=depth + 1
            )
        return result
    if isinstance(value, (list, tuple)):
        return [_clean_json(item, depth=depth + 1) for item in list(value)[:512]]
    if isinstance(value, str):
        return value[:MAX_TEXT]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)[:4_000]


__all__ = [
    "CONNECTION_KINDS", "DELIVERY_STATES", "EventTriggerValidationError",
    "MAX_EVENT_BYTES", "MAX_PENDING_PER_TRIGGER", "matches_trigger",
    "normalize_connection", "normalize_event", "normalize_filters",
    "normalize_trigger", "valid_identifier", "validate_filters_for_source",
    "verify_webhook_signature",
]
