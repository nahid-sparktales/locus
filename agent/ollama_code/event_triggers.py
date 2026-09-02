"""Validation, deterministic filtering, and webhook authentication for events."""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import re
import time
from decimal import Decimal, InvalidOperation
from fnmatch import fnmatchcase
from typing import Any

CONNECTION_KINDS = {"gmail", "telegram", "webhook", "price_feed"}
TRIGGER_KINDS = {"event", "price"}
TRIGGER_MODES = {"ask", "work", "plan", "grill", "build"}
DELIVERY_STATES = {"pending", "claiming", "queued", "failed"}
MAX_EVENT_BYTES = 256 * 1024
MAX_PENDING_PER_TRIGGER = 1_000
MAX_FILTER_VALUES = 100
MAX_TEXT = 120_000
MIN_PRICE_REPEAT_SECONDS = 15 * 60
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
        raise EventTriggerValidationError(
            "connection kind must be gmail, telegram, webhook, or price_feed"
        )
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
    trigger_kind = str(value.get("trigger_kind") or "event").strip().lower()
    if trigger_kind not in TRIGGER_KINDS:
        raise EventTriggerValidationError("trigger_kind must be event or price")
    filters = value.get("filters") or {}
    if not isinstance(filters, dict):
        raise EventTriggerValidationError("filters must be an object")
    normalized_filters = normalize_filters(filters)
    action_ids = value.get("action_connection_ids")
    if action_ids is None:
        action_ids = [] if trigger_kind == "price" else [connection_id]
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
        "trigger_kind": trigger_kind,
        "filters": normalized_filters,
        "action_connection_ids": normalized_action_ids,
        "enabled": enabled,
    }


def normalize_filters(value: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    list_keys = (
        "senders", "recipients", "labels", "subject_contains", "chat_ids",
        "sender_ids", "command_prefixes", "message_types", "event_names",
    )
    for key in list_keys:
        if key not in value:
            continue
        raw = value[key]
        if not isinstance(raw, list):
            raise EventTriggerValidationError(f"filter {key} must be a list")
        items = [str(item).strip()[:500] for item in raw[:MAX_FILTER_VALUES]]
        clean_items = [item for item in items if item]
        if clean_items:
            result[key] = clean_items
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
        if clean:
            result["predicates"] = clean
    if "price_condition" in value:
        result["price_condition"] = normalize_price_condition(value["price_condition"])
    known_keys = set(list_keys) | {"has_attachments", "predicates", "price_condition"}
    unknown = set(value) - known_keys
    if unknown:
        raise EventTriggerValidationError(f"unknown filter field: {sorted(unknown)[0]}")
    return result


def validate_filters_for_source(
    source: str, filters: dict[str, Any], *, trigger_kind: str = "event"
) -> None:
    """Reject filters that cannot be evaluated for a connector's event shape."""
    allowed = {
        "gmail": {
            "senders", "recipients", "labels", "subject_contains", "has_attachments",
        },
        "telegram": {
            "chat_ids", "sender_ids", "command_prefixes", "message_types",
        },
        "webhook": {"event_names", "predicates", "price_condition"},
        "price_feed": {"price_condition"},
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
    if trigger_kind == "price":
        if source not in {"price_feed", "webhook"}:
            raise EventTriggerValidationError(
                "price triggers require a price feed or signed webhook connection"
            )
        if not filters.get("price_condition"):
            raise EventTriggerValidationError("price triggers require a price condition")
        if source == "webhook" and filters.get("event_names") != ["price.quote"]:
            raise EventTriggerValidationError(
                "webhook price triggers require event_names to contain only price.quote"
            )
        return
    if source == "price_feed":
        raise EventTriggerValidationError("price feed connections require a price trigger")
    if "price_condition" in filters:
        raise EventTriggerValidationError("price_condition is valid only for price triggers")
    if source == "webhook" and not filters.get("event_names"):
        raise EventTriggerValidationError("webhook triggers require at least one event name")


def normalize_price_condition(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EventTriggerValidationError("price_condition must be an object")
    provider_symbol = " ".join(str(value.get("provider_symbol") or "").split())[:120]
    display_symbol = " ".join(
        str(value.get("display_symbol") or provider_symbol).split()
    )[:120]
    asset_class = str(value.get("asset_class") or "").strip().lower()
    quote_currency = str(value.get("quote_currency") or "USD").strip().upper()[:20]
    comparison = str(value.get("comparison") or "").strip().lower()
    lifecycle = str(value.get("lifecycle") or "once").strip().lower()
    if not provider_symbol:
        raise EventTriggerValidationError("price provider_symbol is required")
    if not quote_currency:
        raise EventTriggerValidationError("price quote_currency is required")
    if asset_class not in {"stock", "crypto"}:
        raise EventTriggerValidationError("price asset_class must be stock or crypto")
    if comparison not in {"crosses_above", "crosses_below"}:
        raise EventTriggerValidationError(
            "price comparison must be crosses_above or crosses_below"
        )
    if lifecycle not in {"once", "rearm", "repeat"}:
        raise EventTriggerValidationError("price lifecycle must be once, rearm, or repeat")
    threshold = canonical_decimal(value.get("threshold"), label="price threshold")
    try:
        interval = int(value.get("repeat_interval_seconds") or MIN_PRICE_REPEAT_SECONDS)
    except (TypeError, ValueError) as exc:
        raise EventTriggerValidationError("price repeat interval must be whole seconds") from exc
    if interval < 1:
        raise EventTriggerValidationError("price repeat interval must be positive")
    if lifecycle == "repeat" and interval < MIN_PRICE_REPEAT_SECONDS:
        raise EventTriggerValidationError("repeating price alerts must wait at least 15 minutes")
    if interval > 31_536_000:
        raise EventTriggerValidationError("price repeat interval is too large")
    return {
        "provider_symbol": provider_symbol,
        "display_symbol": display_symbol,
        "asset_class": asset_class,
        "quote_currency": quote_currency,
        "comparison": comparison,
        "threshold": threshold,
        "lifecycle": lifecycle,
        "repeat_interval_seconds": interval,
    }


def canonical_decimal(value: Any, *, label: str = "price") -> str:
    if isinstance(value, bool):
        raise EventTriggerValidationError(f"{label} must be a positive decimal")
    raw = str(value).strip()
    if len(raw) > 128:
        raise EventTriggerValidationError(f"{label} must be a bounded positive decimal")
    try:
        number = Decimal(raw)
    except (InvalidOperation, ValueError) as exc:
        raise EventTriggerValidationError(f"{label} must be a positive decimal") from exc
    if not number.is_finite() or number <= 0:
        raise EventTriggerValidationError(f"{label} must be a positive decimal")
    if abs(number.adjusted()) > 120:
        raise EventTriggerValidationError(f"{label} must be a bounded positive decimal")
    normalized = format(number.normalize(), "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    return normalized


def evaluate_price_event(
    condition: dict[str, Any], state: dict[str, Any], event: dict[str, Any], *,
    now: float, max_quote_age_seconds: float = 300,
) -> tuple[dict[str, Any], bool]:
    """Return updated durable state and whether this quote should create a delivery."""
    if event.get("event_type") != "price.quote":
        return state, False
    data = event.get("data") if isinstance(event.get("data"), dict) else {}
    symbol = str(data.get("provider_symbol") or data.get("instrument_id") or "")
    if symbol.casefold() != str(condition["provider_symbol"]).casefold():
        return state, False
    if str(data.get("asset_class") or "").lower() != condition["asset_class"]:
        return state, False
    if str(data.get("quote_currency") or "").upper() != condition["quote_currency"]:
        return state, False
    try:
        price_text = canonical_decimal(data.get("price"), label="quote price")
        price = Decimal(price_text)
        quote_at = _finite_timestamp(data.get("provider_timestamp", event["occurred_at"]))
    except EventTriggerValidationError:
        return state, False
    if quote_at > now + 300 or now - quote_at > max(1.0, max_quote_age_seconds):
        return state, False
    previous_at = float(state.get("last_quote_at") or 0)
    if quote_at <= previous_at:
        return state, False

    threshold = Decimal(condition["threshold"])
    triggered = (
        price >= threshold
        if condition["comparison"] == "crosses_above"
        else price <= threshold
    )
    side = "triggered" if triggered else "safe"
    previous_side = str(state.get("last_side") or "")
    lifecycle = condition["lifecycle"]
    fired = bool(state.get("fired"))
    should_fire = False
    if lifecycle == "repeat":
        last_fired_at = float(state.get("last_fired_at") or 0)
        should_fire = triggered and (
            not last_fired_at
            or now - last_fired_at >= int(condition["repeat_interval_seconds"])
        )
    elif previous_side:
        should_fire = previous_side == "safe" and triggered
        if lifecycle == "once" and fired:
            should_fire = False

    updated = dict(state)
    updated.update({
        "last_price": price_text,
        "last_quote_at": quote_at,
        "last_side": side,
    })
    if should_fire:
        updated["last_fired_at"] = now
        if lifecycle == "once":
            updated["fired"] = True
    return updated, should_fire


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
    "MAX_EVENT_BYTES", "MAX_PENDING_PER_TRIGGER", "MIN_PRICE_REPEAT_SECONDS",
    "TRIGGER_KINDS", "canonical_decimal", "evaluate_price_event", "matches_trigger",
    "normalize_connection", "normalize_event", "normalize_filters",
    "normalize_price_condition", "normalize_trigger", "valid_identifier",
    "validate_filters_for_source",
    "verify_webhook_signature",
]
