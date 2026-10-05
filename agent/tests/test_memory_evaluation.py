from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pytest

from ollama_code.memory_evaluation import CampaignBudget, CampaignBudgetExceeded, run_paired_memory_campaign


def test_unknown_price_never_admits_request():
    budget = CampaignBudget()
    with pytest.raises(CampaignBudgetExceeded, match="unknown pricing"):
        budget.reserve(input_bound=10, max_output_tokens=10, price_micros_per_token=None)
    assert budget.snapshot()["reserved_tokens"] == 0


def test_concurrent_budget_reservations_do_not_overspend():
    budget = CampaignBudget(max_tokens=100, max_cost_micros=100)
    def reserve(_):
        try:
            return budget.reserve(input_bound=20, max_output_tokens=10, price_micros_per_token=1)
        except CampaignBudgetExceeded:
            return None
    with ThreadPoolExecutor(max_workers=8) as pool:
        accepted = [r for r in pool.map(reserve, range(12)) if r]
    assert len(accepted) == 3
    for receipt in accepted:
        budget.settle(receipt, tokens=None, cost_micros=None)
    assert budget.tokens == budget.cost_micros == 90


def test_provider_bounds_violation_stops_campaign():
    budget = CampaignBudget()
    reserved = budget.reserve(input_bound=5, max_output_tokens=5, price_micros_per_token=0)
    with pytest.raises(CampaignBudgetExceeded, match="exceeded"):
        budget.settle(reserved, tokens=11, cost_micros=0)
    with pytest.raises(CampaignBudgetExceeded):
        budget.reserve(input_bound=1, max_output_tokens=1, price_micros_per_token=0)


def test_pairs_share_snapshots_and_grade_artifact_not_success_claim():
    seen = []
    def call(**request):
        seen.append(request)
        return {"content": '{"success": true}', "prompt_tokens": 10, "output_tokens": 5}
    case = {"id": "fixture", "prompt": "Set ready true", "memory": "approved ready is true",
            "expected": {"ready": True}}
    report = run_paired_memory_campaign(call, model="fake", cases=[case], price_micros_per_token=0)
    assert report["complete"]
    assert len({r["fixture_sha256"] for r in report["results"]}) == 1
    assert all(not r["passed"] and not r["learning_enabled"] for r in report["results"])
    assert all(r["expected_artifact"] == {"ready": True} and r["actual_artifact"] == {"success": True}
               for r in report["results"])
    assert len(seen[0]["messages"]) == 2
    assert len(seen[1]["messages"]) == 3
    assert report["budget"]["tokens"] == 30


def test_incomplete_campaign_has_no_false_quality_claim():
    def forbidden(**request):
        raise AssertionError("budget must refuse before call")
    report = run_paired_memory_campaign(forbidden, model="billable", price_micros_per_token=None)
    assert not report["complete"]
    assert not report["results"]
    assert report["incomplete_reason"] == "unknown pricing; model skipped"


def test_native_campaign_cannot_dispatch_without_output_cap():
    from types import SimpleNamespace
    from ollama_code.model_usage import tracked_native
    from ollama_code.usage_ledger import UsageLimitError
    with pytest.raises(UsageLimitError, match="cannot enforce"):
        tracked_native(SimpleNamespace(provider="chatgpt"), lambda **_: pytest.fail("dispatched"),
                       context={"task_id": "memory-campaign:fixture", "provider": "chatgpt"})


def test_actual_tracked_boundary_refuses_unknown_billable_price(tmp_path):
    from types import SimpleNamespace
    from ollama_code.model_usage import tracked_chat
    from ollama_code.runstore import RunStore
    from ollama_code.usage_ledger import UsageLedger, UsageLimitError
    runs = RunStore(tmp_path / "campaign.sqlite3")
    owner = "memory-campaign:fixture"
    UsageLedger(runs).set_limits(owner, {"max_tokens": 250000, "max_estimated_usd": 10})
    client = SimpleNamespace(chat_stream=lambda *_, **__: pytest.fail("unpriced request dispatched"))
    with pytest.raises(UsageLimitError, match="pricing"):
        tracked_chat(None, client, "unknown-billable", [{"role": "user", "content": "synthetic"}], runs=runs,
                     context={"task_id": owner, "run_id": "one", "session_id": "session", "provider": "remote",
                              "model": "unknown-billable", "route": "https://example.invalid/v1"})
    refusal = UsageLedger(runs).refusals(owner)[0]
    assert refusal["category"] == "unknown_pricing"
    assert refusal["run_id"] == "one"
    assert UsageLedger(runs).summary(task_id=owner)["invocations"] == 0
