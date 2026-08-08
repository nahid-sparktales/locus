"""Opt-in OpenTelemetry/HTTP export for sanitized orchestration traces."""
from __future__ import annotations

import hashlib
import ipaddress
from typing import Any
from urllib.parse import urlparse

import requests

from .runstore import RunStore


class TelemetryError(RuntimeError):
    pass


def _attribute(key: str, value: Any) -> dict[str, Any]:
    if isinstance(value, bool):
        encoded = {"boolValue": value}
    elif isinstance(value, int):
        encoded = {"intValue": str(value)}
    elif isinstance(value, float):
        encoded = {"doubleValue": value}
    else:
        encoded = {"stringValue": str(value)[:16_000]}
    return {"key": key, "value": encoded}


def build_otlp_payload(store: RunStore, run_id: str, *, include_content: bool = False) -> dict[str, Any]:
    exported = store.export(run_id, include_content=include_content)
    run = exported["run"]
    trace_id = hashlib.sha256(run_id.encode()).hexdigest()[:32]
    spans = []
    for event in run.get("events") or []:
        event_id = str(event.get("event_id") or f"{run_id}:{event.get('seq')}")
        occurred = int(float(event.get("occurred_at") or 0) * 1_000_000_000)
        attributes = [
            _attribute("gen_ai.operation.name", str(event.get("type") or "agent.event")),
            _attribute("gen_ai.agent.id", str(event.get("agent_id") or "")),
            _attribute("locus.run.id", run_id),
            _attribute("locus.run.seq", int(event.get("seq") or 0)),
            _attribute("locus.schema.version", int(event.get("schema_version") or 1)),
        ]
        if event.get("provider"):
            attributes.append(_attribute("gen_ai.provider.name", event["provider"]))
        if event.get("model"):
            attributes.append(_attribute("gen_ai.request.model", event["model"]))
        if event.get("job_id"):
            attributes.append(_attribute("locus.job.id", event["job_id"]))
        if include_content:
            attributes.append(_attribute("locus.event.payload", event))
        spans.append({
            "traceId": trace_id,
            "spanId": hashlib.sha256(event_id.encode()).hexdigest()[:16],
            "name": f"locus.{event.get('type') or 'event'}",
            "kind": 1,
            "startTimeUnixNano": str(occurred),
            "endTimeUnixNano": str(max(occurred, occurred + 1)),
            "attributes": attributes,
            "status": {"code": 2 if "error" in str(event.get("type") or "") else 1},
        })
    return {
        "resourceSpans": [{
            "resource": {"attributes": [
                _attribute("service.name", "locus"),
                _attribute("locus.run.team", str(run.get("team_name") or "")),
            ]},
            "scopeSpans": [{
                "scope": {"name": "io.sparktales.locus.orchestration", "version": "1"},
                "spans": spans,
            }],
        }],
    }


def send_otlp(
    store: RunStore,
    run_id: str,
    endpoint: str,
    *,
    authorization: str = "",
    include_content: bool = False,
) -> dict[str, Any]:
    parsed = urlparse(endpoint.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise TelemetryError("OTLP endpoint must be an absolute HTTP URL")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    if parsed.scheme != "https" and not loopback:
        raise TelemetryError("remote OTLP endpoints must use HTTPS")
    headers = {"Content-Type": "application/json"}
    if authorization.strip():
        headers["Authorization"] = authorization.strip()
    try:
        response = requests.post(
            endpoint, json=build_otlp_payload(store, run_id, include_content=include_content),
            headers=headers, timeout=20, allow_redirects=False,
        )
    except requests.RequestException as exc:
        raise TelemetryError(f"OTLP export failed: {exc}") from exc
    if 300 <= response.status_code < 400:
        raise TelemetryError("OTLP endpoint redirects are not followed")
    if not 200 <= response.status_code < 300:
        raise TelemetryError(f"OTLP endpoint returned HTTP {response.status_code}")
    return {"ok": True, "run_id": run_id, "status_code": response.status_code}


__all__ = ["TelemetryError", "build_otlp_payload", "send_otlp"]
