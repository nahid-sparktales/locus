"""Validation and timezone-aware recurrence calculations for scheduled tasks."""
from __future__ import annotations

import math
from datetime import UTC, date, datetime, timedelta
from datetime import time as wall_time
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MIN_INTERVAL_SECONDS = 15 * 60
MAX_INTERVAL_SECONDS = 365 * 24 * 60 * 60
SCHEDULE_MODES = {"ask", "work", "plan", "build"}
SCHEDULE_RUNNERS = {"solo", "solo_swarm", "team"}
SCHEDULE_ENVIRONMENTS = {"local", "worktree"}
SCHEDULE_PROVIDERS = {"ollama", "remote", "chatgpt"}
INTERVAL_UNITS = {
    "minutes": 60,
    "hours": 60 * 60,
    "days": 24 * 60 * 60,
    "weeks": 7 * 24 * 60 * 60,
}


class ScheduleValidationError(ValueError):
    pass


def timezone(value: str) -> ZoneInfo:
    name = (value or "").strip()
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ScheduleValidationError("timezone is not recognized") from exc


def normalize_rule(value: Any, *, now: float) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ScheduleValidationError("rule must be an object")
    kind = str(value.get("kind") or "").strip().lower()
    if kind == "once":
        at = _finite_timestamp(value.get("at"), "one-time run date")
        return {"kind": kind, "at": at}
    if kind in {"daily", "weekdays", "weekly"}:
        hour = _bounded_int(value.get("hour"), "hour", 0, 23)
        minute = _bounded_int(value.get("minute"), "minute", 0, 59)
        result: dict[str, Any] = {"kind": kind, "hour": hour, "minute": minute}
        if kind == "weekly":
            result["weekday"] = _bounded_int(value.get("weekday"), "weekday", 0, 6)
        return result
    if kind == "interval":
        every = _bounded_int(value.get("every"), "interval", 1, 100_000)
        unit = str(value.get("unit") or "").strip().lower()
        if unit not in INTERVAL_UNITS:
            raise ScheduleValidationError("interval unit must be minutes, hours, days, or weeks")
        seconds = every * INTERVAL_UNITS[unit]
        if seconds < MIN_INTERVAL_SECONDS:
            raise ScheduleValidationError("custom intervals must be at least 15 minutes")
        if seconds > MAX_INTERVAL_SECONDS:
            raise ScheduleValidationError("custom intervals cannot exceed one year")
        anchor = _finite_timestamp(value.get("anchor", now), "interval start date")
        return {"kind": kind, "every": every, "unit": unit, "anchor": anchor}
    raise ScheduleValidationError(
        "rule kind must be once, daily, weekdays, weekly, or interval"
    )


def normalize_schedule(value: Any, *, now: float) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ScheduleValidationError("schedule must be an object")
    name = " ".join(str(value.get("name") or "").split())[:120]
    prompt = str(value.get("prompt") or "").strip()[:240_000]
    workspace_root = str(value.get("workspace_root") or "").strip()[:4_000]
    if not name:
        raise ScheduleValidationError("name is required")
    if not prompt:
        raise ScheduleValidationError("prompt is required")
    if not workspace_root:
        raise ScheduleValidationError("workspace_root is required")
    mode = str(value.get("mode") or "work").strip().lower()
    if mode not in SCHEDULE_MODES:
        raise ScheduleValidationError("mode must be ask, work, plan, or build")
    environment = str(value.get("execution_environment") or "local").strip().lower()
    if environment not in SCHEDULE_ENVIRONMENTS:
        raise ScheduleValidationError("execution_environment must be local or worktree")
    runner = str(value.get("runner") or "solo").strip().lower()
    if runner not in SCHEDULE_RUNNERS:
        raise ScheduleValidationError("runner must be solo, solo_swarm, or team")
    team_id = str(value.get("team_id") or "").strip()[:160]
    team_name = " ".join(str(value.get("team_name") or "").split())[:120]
    if runner == "team" and not team_id:
        raise ScheduleValidationError("team_id is required for a team schedule")
    provider = str(value.get("provider") or "ollama").strip().lower()
    if provider not in SCHEDULE_PROVIDERS:
        raise ScheduleValidationError("provider must be ollama, remote, or chatgpt")
    provider_account_id = str(value.get("provider_account_id") or "").strip()[:160]
    if provider != "ollama" and not provider_account_id:
        raise ScheduleValidationError("provider_account_id is required for hosted schedules")
    model = str(value.get("model") or "").strip()[:500]
    if not model:
        raise ScheduleValidationError("model is required")
    timezone_name = str(value.get("timezone") or "UTC").strip()
    zone = timezone(timezone_name)
    rule = normalize_rule(value.get("rule"), now=now)
    enabled = value.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ScheduleValidationError("enabled must be a boolean")
    next_run = next_occurrence(rule, zone, after=now)
    if enabled and next_run is None:
        raise ScheduleValidationError("the next scheduled time must be in the future")
    return {
        "name": name,
        "prompt": prompt,
        "workspace_root": workspace_root,
        "mode": mode,
        "execution_environment": environment,
        "runner": runner,
        "team_id": team_id,
        "team_name": team_name,
        "provider": provider,
        "provider_account_id": provider_account_id,
        "model": model,
        "timezone": timezone_name,
        "rule": rule,
        "enabled": enabled,
        "next_run_at": next_run,
    }


def next_occurrence(rule: dict[str, Any], zone: ZoneInfo, *, after: float) -> float | None:
    """Return the first occurrence strictly after ``after``."""
    kind = str(rule.get("kind") or "")
    if kind == "once":
        at = float(rule["at"])
        return at if at > after + 1e-6 else None
    if kind == "interval":
        anchor = float(rule["anchor"])
        step = int(rule["every"]) * INTERVAL_UNITS[str(rule["unit"])]
        if anchor > after + 1e-6:
            return anchor
        count = math.floor((after - anchor) / step) + 1
        return anchor + count * step
    local_day = datetime.fromtimestamp(after, zone).date()
    for offset in range(0, 371):
        candidate_day = local_day + timedelta(days=offset)
        if not _matches_calendar_day(rule, candidate_day):
            continue
        candidate = _resolved_wall_timestamp(
            candidate_day, int(rule["hour"]), int(rule["minute"]), zone
        )
        if candidate > after + 1e-6:
            return candidate
    raise ScheduleValidationError("could not calculate the next calendar occurrence")


def latest_due_occurrence(
    rule: dict[str, Any], zone: ZoneInfo, *, earliest: float, now: float
) -> float | None:
    """Return the newest due occurrence, collapsing any older missed cadence."""
    if earliest > now + 1e-6:
        return None
    kind = str(rule.get("kind") or "")
    if kind == "once":
        at = float(rule["at"])
        return at if earliest - 1e-6 <= at <= now + 1e-6 else None
    if kind == "interval":
        anchor = float(rule["anchor"])
        step = int(rule["every"]) * INTERVAL_UNITS[str(rule["unit"])]
        if now < anchor:
            return None
        value = anchor + math.floor((now - anchor) / step) * step
        return value if value >= earliest - 1e-6 else None
    local_day = datetime.fromtimestamp(now, zone).date()
    for offset in range(0, 371):
        candidate_day = local_day - timedelta(days=offset)
        if not _matches_calendar_day(rule, candidate_day):
            continue
        candidate = _resolved_wall_timestamp(
            candidate_day, int(rule["hour"]), int(rule["minute"]), zone
        )
        if earliest - 1e-6 <= candidate <= now + 1e-6:
            return candidate
    return None


def _matches_calendar_day(rule: dict[str, Any], value: date) -> bool:
    kind = str(rule.get("kind") or "")
    if kind == "daily":
        return True
    if kind == "weekdays":
        return value.weekday() < 5
    if kind == "weekly":
        return value.weekday() == int(rule["weekday"])
    return False


def _resolved_wall_timestamp(day: date, hour: int, minute: int, zone: ZoneInfo) -> float:
    """Resolve a wall time, moving a nonexistent DST time to the next valid minute.

    ``fold=0`` intentionally chooses the first occurrence of an ambiguous fall-back
    time, so a weekly or daily task can never execute twice for one wall-clock slot.
    """
    desired = datetime.combine(day, wall_time(hour=hour, minute=minute))
    for offset in range(0, 181):
        naive = desired + timedelta(minutes=offset)
        candidate = naive.replace(tzinfo=zone, fold=0)
        round_trip = candidate.astimezone(UTC).astimezone(zone).replace(tzinfo=None)
        if round_trip == naive:
            return candidate.timestamp()
    raise ScheduleValidationError("could not resolve the scheduled wall-clock time")


def _finite_timestamp(value: Any, label: str) -> float:
    if isinstance(value, bool):
        raise ScheduleValidationError(f"{label} must be a timestamp")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ScheduleValidationError(f"{label} must be a timestamp") from exc
    if not math.isfinite(result) or result <= 0:
        raise ScheduleValidationError(f"{label} must be a positive timestamp")
    return result


def _bounded_int(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ScheduleValidationError(f"{label} must be an integer")
    if not minimum <= value <= maximum:
        raise ScheduleValidationError(f"{label} must be between {minimum} and {maximum}")
    return value
