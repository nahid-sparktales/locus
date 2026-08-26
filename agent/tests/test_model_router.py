from __future__ import annotations

from ollama_code.model_router import decide_model_route
from ollama_code.runstore import RunStore


def _candidate(route_id: str, *, local: bool, current: bool = False) -> dict:
    return {
        "id": route_id,
        "name": route_id,
        "model": route_id,
        "provider": "ollama" if local else "codex",
        "local": local,
        "current": current,
        "metering": "self_hosted" if local else "metered",
        "memory_bytes": 8 * 1024**3 if local else 0,
        "sample_ids": [route_id],
    }


def test_limited_data_prefers_the_current_route_on_an_otherwise_equal_score(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    result = decide_model_route(store, {
        "tags": ["general"],
        "candidates": [
            _candidate("model-route:ollama:a", local=True),
            _candidate("model-route:ollama:b", local=True, current=True),
        ],
    })

    assert result["selected_id"] == "model-route:ollama:b"
    assert result["limited_data"] is True
    assert all(card["score"] == result["candidates"][0]["score"] for card in result["candidates"])


def test_tagged_evaluations_can_move_quality_routing_away_from_the_current_model(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    for _ in range(5):
        store.record_routing_sample(
            "model-route:ollama:strong",
            tags=["coding"], quality=95, reliable=True, latency_ms=2_000,
            estimated_cost=0, local=True, evaluation=True,
        )
        store.record_routing_sample(
            "model-route:ollama:current",
            tags=["coding"], quality=35, reliable=True, latency_ms=2_000,
            estimated_cost=0, local=True, evaluation=True,
        )
    result = decide_model_route(store, {
        "tags": ["coding"],
        "weights": {"quality": 1, "reliability": 0, "privacy": 0,
                    "latency": 0, "cost": 0, "efficiency": 0},
        "candidates": [
            _candidate("model-route:ollama:current", local=True, current=True),
            _candidate("model-route:ollama:strong", local=True),
        ],
    })

    assert result["selected_id"] == "model-route:ollama:strong"
    assert result["limited_data"] is False
    assert result["candidates"][0]["components"]["quality"] == 95


def test_privacy_policy_selects_local_and_hosted_efficiency_stays_neutral(tmp_path) -> None:
    store = RunStore(tmp_path / "runs.sqlite3")
    result = decide_model_route(store, {
        "tags": ["research"],
        "weights": {"quality": 0, "reliability": 0, "privacy": 1,
                    "latency": 0, "cost": 0, "efficiency": 0},
        "candidates": [
            _candidate("model-route:account:hosted", local=False, current=True),
            _candidate("model-route:ollama:local", local=True),
        ],
    })

    assert result["selected_id"] == "model-route:ollama:local"
    hosted = next(card for card in result["candidates"] if not card["local"])
    assert hosted["components"]["efficiency"] == 50
