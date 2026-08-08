from __future__ import annotations

import json

import pytest

from ollama_code.runstore import RunStore
from ollama_code.telemetry import TelemetryError, build_otlp_payload, send_otlp


def _store(tmp_path):
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run", team_name="Team")
    store.append_event("run", {
        "type": "agent_job_started", "agent_id": "agent", "provider": "local",
        "model": "model", "goal": "private content", "authorization": "secret",
    })
    return store


def test_otlp_payload_uses_ordered_spans_and_omits_content_by_default(tmp_path):
    payload = build_otlp_payload(_store(tmp_path), "run")
    encoded = json.dumps(payload)
    assert "locus.agent_job_started" in encoded
    assert "gen_ai.provider.name" in encoded
    assert "private content" not in encoded
    assert "secret" not in encoded


def test_otlp_export_requires_tls_remotely_and_never_follows_redirects(tmp_path, monkeypatch):
    store = _store(tmp_path)
    with pytest.raises(TelemetryError, match="HTTPS"):
        send_otlp(store, "run", "http://collector.example/v1/traces")

    seen = {}

    class Response:
        status_code = 200

    def post(url, **kwargs):
        seen.update(url=url, **kwargs)
        return Response()

    monkeypatch.setattr("ollama_code.telemetry.requests.post", post)
    result = send_otlp(
        store, "run", "https://collector.example/v1/traces",
        authorization="Bearer transient",
    )
    assert result["ok"]
    assert seen["allow_redirects"] is False
    assert seen["headers"]["Authorization"] == "Bearer transient"
