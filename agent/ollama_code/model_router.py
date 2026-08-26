"""Transparent scorecards for opt-in solo-message model routing.

The router deliberately receives task tags rather than prompt text.  It reuses
the orchestration routing samples, so evaluations and observed reliability from
team agents can improve the corresponding solo model route without creating a
second learning store.
"""
from __future__ import annotations

from typing import Any

DEFAULT_WEIGHTS = {
    "quality": 0.32,
    "reliability": 0.16,
    "privacy": 0.14,
    "latency": 0.14,
    "cost": 0.12,
    "efficiency": 0.12,
}


class ModelRouterError(ValueError):
    """A router request is malformed or has no eligible route."""


def decide_model_route(run_store: Any, body: dict[str, Any]) -> dict[str, Any]:
    raw_candidates = body.get("candidates")
    if not isinstance(raw_candidates, list) or not 1 <= len(raw_candidates) <= 100:
        raise ModelRouterError("model router needs between 1 and 100 candidates")
    tags = _bounded_strings(body.get("tags"), limit=24, width=40)
    weights = _weights(body.get("weights"))
    try:
        scorecards = [
            _scorecard(run_store, candidate, tags, weights)
            for candidate in raw_candidates
            if isinstance(candidate, dict)
        ]
    except (TypeError, ValueError, OverflowError) as exc:
        raise ModelRouterError("model router candidate metadata is malformed") from exc
    if not scorecards:
        raise ModelRouterError("model router has no eligible candidates")
    # With little evidence, a small stability bonus prevents the router from
    # moving merely because two unknown routes tie at the neutral prior.
    scorecards.sort(
        key=lambda item: (
            -float(item["selection_score"]),
            not bool(item["current"]),
            str(item["name"]).lower(),
        )
    )
    selected = scorecards[0]
    for item in scorecards:
        item["selected"] = item["route_id"] == selected["route_id"]
        item.pop("selection_score", None)
    return {
        "selected_id": selected["route_id"],
        "limited_data": bool(selected["limited_data"]),
        "reason": _reason(selected),
        "tags": tags,
        "candidates": scorecards,
    }


def _scorecard(
    run_store: Any,
    candidate: dict[str, Any],
    tags: list[str],
    weights: dict[str, float],
) -> dict[str, Any]:
    route_id = str(candidate.get("id") or "").strip()[:512]
    name = str(candidate.get("name") or route_id).strip()[:256]
    if not route_id:
        raise ModelRouterError("every model router candidate needs an id")
    sample_ids = _bounded_strings(
        candidate.get("sample_ids"), limit=32, width=512, lowercase=False,
    )
    if route_id not in sample_ids:
        sample_ids.insert(0, route_id)
    samples: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    if run_store is not None:
        for sample_id in sample_ids:
            for sample in run_store.routing_samples(sample_id, tags, limit=50):
                identity = (
                    sample.get("occurred_at"), sample_id, sample.get("latency_ms"),
                    sample.get("quality"), sample.get("reliable"),
                )
                if identity not in seen:
                    seen.add(identity)
                    samples.append(sample)
    samples.sort(key=lambda item: float(item.get("occurred_at") or 0), reverse=True)
    samples = samples[:50]

    evaluations = [
        sample for sample in samples
        if sample.get("evaluation") and sample.get("quality") is not None
    ]
    observed_quality = _weighted_average([
        (float(sample["quality"]), index) for index, sample in enumerate(evaluations)
    ]) if evaluations else 50.0
    # Five tagged evaluations are needed before quality loses its neutral
    # prior. A single unusually easy benchmark must not seize all traffic.
    quality = (
        observed_quality * min(len(evaluations), 5)
        + 50.0 * max(5 - len(evaluations), 0)
    ) / 5
    reliability = _weighted_average([
        (100.0 if sample.get("reliable") else 0.0, index)
        for index, sample in enumerate(samples)
    ]) if samples else 50.0
    latency_values = [
        (max(0.0, 100.0 - min(float(sample.get("latency_ms") or 0) / 600, 100.0)), index)
        for index, sample in enumerate(samples)
        if int(sample.get("latency_ms") or 0) > 0
    ]
    latency = _weighted_average(latency_values) if latency_values else 50.0

    local = bool(candidate.get("local"))
    metering = str(candidate.get("metering") or ("self_hosted" if local else "metered"))
    observed_costs = [
        (max(0.0, 100.0 - float(sample.get("estimated_cost") or 0) * 100), index)
        for index, sample in enumerate(samples)
        if float(sample.get("estimated_cost") or 0) > 0
    ]
    if local:
        cost = 100.0
    elif metering == "subscription":
        cost = 85.0
    else:
        cost = _weighted_average(observed_costs) if observed_costs else 50.0
    privacy = 100.0 if local else 40.0
    efficiency = _efficiency_score(candidate, local=local)
    components = {
        "quality": round(quality, 2),
        "reliability": round(reliability, 2),
        "privacy": round(privacy, 2),
        "latency": round(latency, 2),
        "cost": round(cost, 2),
        "efficiency": round(efficiency, 2),
    }
    score = sum(components[name] * weights[name] for name in components)
    limited = len(evaluations) < 5
    stability_bonus = 2.0 if limited and bool(candidate.get("current")) else 0.0
    return {
        "route_id": route_id,
        "name": name,
        "model": str(candidate.get("model") or "")[:256],
        "provider": str(candidate.get("provider") or "")[:64],
        "local": local,
        "current": bool(candidate.get("current")),
        "selected": False,
        "score": round(score, 2),
        "selection_score": round(score + stability_bonus, 2),
        "components": components,
        "weights": weights,
        "sample_count": len(samples),
        "evaluation_count": len(evaluations),
        "limited_data": limited,
    }


def _efficiency_score(candidate: dict[str, Any], *, local: bool) -> float:
    if not local:
        # No claim about a provider's hardware or energy mix without telemetry.
        return 50.0
    memory_bytes = max(int(candidate.get("memory_bytes") or 0), 0)
    if memory_bytes <= 0:
        return 50.0
    gib = memory_bytes / (1024 ** 3)
    # Download size is an explainable footprint proxy, not an energy reading.
    return max(20.0, 100.0 - min(gib * 1.5, 80.0))


def _reason(selected: dict[str, Any]) -> str:
    components = selected["components"]
    leaders = sorted(components, key=lambda key: components[key], reverse=True)[:2]
    evidence = (
        "limited evidence; the current route receives a small stability preference"
        if selected["limited_data"] else
        f"{selected['sample_count']} tagged samples"
    )
    return (
        f"Highest eligible scorecard total, led by {leaders[0]} and {leaders[1]} "
        f"({evidence})."
    )


def _weights(value: Any) -> dict[str, float]:
    raw = value if isinstance(value, dict) else {}
    weights = {
        name: max(_finite_number(raw.get(name), default), 0.0)
        for name, default in DEFAULT_WEIGHTS.items()
    }
    total = sum(weights.values())
    if total <= 0:
        raise ModelRouterError("model router weights need a positive value")
    return {name: round(number / total, 6) for name, number in weights.items()}


def _finite_number(value: Any, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if number == number and abs(number) != float("inf") else default


def _weighted_average(values: list[tuple[float, int]]) -> float:
    if not values:
        return 50.0
    weighted = 0.0
    total = 0.0
    for value, index in values:
        weight = 0.95 ** index
        weighted += max(0.0, min(value, 100.0)) * weight
        total += weight
    return weighted / total if total else 50.0


def _bounded_strings(
    value: Any, *, limit: int, width: int, lowercase: bool = True,
) -> list[str]:
    if not isinstance(value, list):
        return []
    output: list[str] = []
    seen: set[str] = set()
    for raw in value:
        item = str(raw).strip()[:width]
        if lowercase:
            item = item.lower()
        if item and item not in seen:
            seen.add(item)
            output.append(item)
        if len(output) >= limit:
            break
    return output


__all__ = ["DEFAULT_WEIGHTS", "ModelRouterError", "decide_model_route"]
