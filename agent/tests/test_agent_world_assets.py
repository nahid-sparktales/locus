"""Offline regression checks for the paid asset generator's recovery boundary."""
from __future__ import annotations

import importlib.util
import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def generator(tmp_path, monkeypatch):
    source = Path(__file__).resolve().parents[2] / "Tools/GenerateAgentWorldAssets.py"
    spec = importlib.util.spec_from_file_location("agent_world_asset_generator", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "ASSETS", {"station": "A workstation"})
    monkeypatch.setenv("MESHY_API_KEY", "msy_offline_fixture_only")
    state = tmp_path / "private"
    state.mkdir()
    output = tmp_path / "package/assets"
    monkeypatch.setattr("sys.argv", [str(source), "--state-dir", str(state), "--output", str(output)])
    calls = []

    def request(url, **kwargs):
        method = url.get_method() if hasattr(url, "get_method") else "GET"
        address = url.full_url if hasattr(url, "full_url") else url
        calls.append((method, address))
        if method == "POST":
            raise TimeoutError("simulated uncertain response")
        if address.endswith("/balance"):
            value = {"balance": 1_000}
        elif address.endswith("/library"):
            value = []
        elif address.endswith("/completed"):
            value = {"status": "SUCCEEDED", "model_urls": {"glb": "https://assets.example/station.glb"}}
        elif address == "https://assets.example/station.glb":
            return io.BytesIO(b"glTFoffline fixture")
        else:
            pytest.fail(f"Unexpected request: {method} {address}")
        return io.BytesIO(json.dumps(value).encode())

    monkeypatch.setattr(module.urllib.request, "urlopen", request)
    monkeypatch.setattr(module.urllib.request, "build_opener", lambda *args: SimpleNamespace(open=request))
    return module, state, output, calls


def test_uncertain_submission_retains_reservation_and_resume_never_posts_again(generator):
    module, state, _, calls = generator
    with pytest.raises(RuntimeError, match="did not complete"):
        module.main()
    saved = json.loads((state / "ledger.json").read_text())
    assert saved["tasks"][0]["status"] == "SUBMITTING"
    assert saved["tasks"][0]["reserved_credits"] == 5
    assert len([call for call in calls if call[0] == "POST"]) == 1
    calls.clear()
    with pytest.raises(SystemExit, match="Uncertain submission"):
        module.main()
    assert all(method == "GET" for method, _ in calls)


def test_completed_generation_recovers_missing_output_without_spending(generator):
    module, state, output, calls = generator
    module.save(state / "ledger.json", {"tasks": [{
        "asset": "station", "stage": "refine", "endpoint": module.TEXT, "id": "completed",
        "status": "SUCCEEDED", "reserved_credits": 10, "consumed_credits": 10,
    }], "assets": {}})
    module.main()
    assert (output / "station.glb").read_bytes() == b"glTFoffline fixture"
    assert all(method == "GET" for method, _ in calls)
    public = json.loads((output.parent / "provenance.json").read_text())
    assert public["reserved_credits"] == 10
    assert "https://assets.example" not in json.dumps(public)
    assert "msy_" not in json.dumps(public)


def test_insufficient_budget_rejects_submission_before_network_post(generator, monkeypatch):
    module, _, _, calls = generator
    monkeypatch.setattr("sys.argv", [*sys.argv, "--max-credits", "4"])
    with pytest.raises(SystemExit, match="Credit ceiling reached"):
        module.main()
    assert all(method == "GET" for method, _ in calls)


def test_invalid_negative_ledger_cannot_reduce_credit_commitments(generator):
    module, state, _, calls = generator
    module.save(state / "ledger.json", {"tasks": [{
        "asset": "station", "stage": "refine", "status": "SUCCEEDED", "reserved_credits": -100,
    }]})
    with pytest.raises(SystemExit, match="Invalid credit ledger"):
        module.main()
    assert all(method == "GET" for method, _ in calls)


def test_api_redirect_cannot_forward_authorization():
    source = Path(__file__).resolve().parents[2] / "Tools/GenerateAgentWorldAssets.py"
    spec = importlib.util.spec_from_file_location("redirect_test_generator", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    request = module.urllib.request.Request(module.API + "/openapi/v1/balance", headers={"Authorization": "Bearer fixture"})
    with pytest.raises(module.urllib.error.HTTPError):
        module.NoAPIRedirects().redirect_request(request, None, 302, "Redirect", {}, "https://other.example/")
