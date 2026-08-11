from __future__ import annotations

import json

import pytest
from opentelemetry.sdk.trace.export import SpanExportResult

from ollama_code.runstore import RunStore
from ollama_code.telemetry import TelemetryError, build_otlp_payload, send_otlp


def _store(tmp_path):
    store = RunStore(tmp_path / "runs.sqlite3")
    store.start_run("run", team_name="Team")
    store.append_event("run", {
        "type": "agent_job_started", "job_id": "writer",
        "agent_id": "agent", "provider": "local",
        "model": "model", "goal": "private content", "authorization": "secret",
    })
    store.set_state("run", "completed")
    return store


def test_otlp_payload_uses_ordered_spans_and_omits_content_by_default(tmp_path):
    payload = build_otlp_payload(_store(tmp_path), "run")
    encoded = json.dumps(payload)
    assert "locus.agent_job_started" in encoded
    assert "gen_ai.provider.name" in encoded
    assert "private content" not in encoded
    assert "secret" not in encoded
    assert payload["traceparent"].startswith("00-")
    spans = payload["spans"]
    root = next(span for span in spans if span["name"] == "locus.team.run")
    job = next(span for span in spans if span["name"] == "locus.agent.job")
    attempt = next(span for span in spans if span["name"] == "locus.agent.attempt")
    started = next(span for span in spans if span["name"] == "locus.agent_job_started")
    assert job["parent_span_id"] == root["span_id"]
    assert attempt["parent_span_id"] == job["span_id"]
    assert started["parent_span_id"] == attempt["span_id"]

    content = json.dumps(build_otlp_payload(_store(tmp_path / "content"), "run", include_content=True))
    assert "private content" in content
    assert "secret" not in content


def test_otlp_export_normalizes_endpoint_and_passes_plaintext_header_only_to_exporter(
    tmp_path, monkeypatch
):
    store = _store(tmp_path)
    with pytest.raises(TelemetryError, match="HTTPS"):
        send_otlp(store, "run", "http://collector.example/v1/traces")
    with pytest.raises(TelemetryError, match="must not contain credentials"):
        send_otlp(store, "run", "https://secret@collector.example")

    seen = {}

    def export(exporter, spans):
        seen.update(
            endpoint=exporter._endpoint,
            headers=dict(exporter._headers),
            spans=list(spans),
            session=exporter._session,
        )
        return SpanExportResult.SUCCESS

    monkeypatch.setattr(
        "ollama_code.telemetry._SingleAttemptOTLPSpanExporter.export", export,
    )
    result = send_otlp(
        store, "run", "https://collector.example/otlp",
        authorization="Bearer transient",
    )
    assert result["ok"]
    assert result["endpoint"] == "https://collector.example/otlp/v1/traces"
    assert seen["endpoint"] == result["endpoint"]
    assert seen["headers"]["Authorization"] == "Bearer transient"
    assert seen["session"].__class__.__name__ == "_NoRedirectSession"
    assert "transient" not in json.dumps(result)
    assert store.run("run")["export_state"] == "exported"


def test_otlp_export_retries_three_times_without_persisting_error_text(tmp_path, monkeypatch):
    store = _store(tmp_path)
    attempts = []

    def fail(_exporter, _spans):
        attempts.append(1)
        return SpanExportResult.FAILURE

    monkeypatch.setattr("ollama_code.telemetry._SingleAttemptOTLPSpanExporter.export", fail)
    monkeypatch.setattr("ollama_code.telemetry.time.sleep", lambda _delay: None)
    with pytest.raises(TelemetryError, match="after 3 attempts"):
        send_otlp(store, "run", "https://collector.example")
    assert len(attempts) == 3
    run = store.run("run")
    assert run["export_state"] == "failed"
    assert run["export_attempts"] == 3
