"""Opt-in OpenTelemetry export for sanitized solo and team run traces."""
from __future__ import annotations

import hashlib
import ipaddress
import json
import time
from collections.abc import Sequence
from typing import Any
from urllib.parse import urlparse, urlunparse

import requests
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.common.trace_encoder import encode_spans
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import IdGenerator, ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExporter, SpanExportResult

from .runstore import RunStore


class TelemetryError(RuntimeError):
    pass


def normalize_trace_endpoint(value: str) -> str:
    """Accept an OTLP base URL or the legacy full traces endpoint."""
    parsed = urlparse(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise TelemetryError("OTLP endpoint must be an absolute HTTP URL")
    if parsed.username is not None or parsed.password is not None:
        raise TelemetryError("OTLP endpoint must not contain credentials")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    if parsed.scheme != "https" and not loopback:
        raise TelemetryError("remote OTLP endpoints must use HTTPS")
    path = parsed.path.rstrip("/")
    if not path.endswith("/v1/traces"):
        path = f"{path}/v1/traces" if path else "/v1/traces"
    return urlunparse(parsed._replace(path=path, params="", query="", fragment=""))


def traceparent_for_run(run: dict[str, Any]) -> str:
    """Return the stable W3C context persisted with a run."""
    trace_id = str(run.get("trace_id") or "")
    span_id = str(run.get("root_span_id") or "")
    if len(trace_id) != 32 or len(span_id) != 16:
        raise TelemetryError("run trace identity is missing")
    return f"00-{trace_id}-{span_id}-01"


class _StableIdGenerator(IdGenerator):
    def __init__(self, trace_id: str, span_ids: list[str]) -> None:
        self.trace_id = int(trace_id, 16)
        self.span_ids = [int(value, 16) for value in span_ids]

    def generate_trace_id(self) -> int:
        return self.trace_id

    def generate_span_id(self) -> int:
        if not self.span_ids:
            return int.from_bytes(hashlib.sha256(b"locus-span").digest()[:8], "big")
        return self.span_ids.pop(0)


class _CaptureExporter(SpanExporter):
    def __init__(self) -> None:
        self.spans: list[ReadableSpan] = []

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        self.spans.extend(spans)
        return SpanExportResult.SUCCESS


class _NoRedirectSession(requests.Session):
    def request(self, method: str, url: str, **kwargs: Any) -> requests.Response:
        kwargs["allow_redirects"] = False
        return super().request(method, url, **kwargs)


class _SingleAttemptOTLPSpanExporter(OTLPSpanExporter):
    """Use the official encoder/transport while Locus owns the retry budget."""

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        try:
            data = encode_spans(spans).SerializePartialToString()
            response = self._export(data, self._timeout)
        except requests.RequestException:
            return SpanExportResult.FAILURE
        return (
            SpanExportResult.SUCCESS
            if 200 <= response.status_code < 300
            else SpanExportResult.FAILURE
        )


def _span_id(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def _nanoseconds(value: Any, fallback: float) -> int:
    try:
        return max(int(float(value) * 1_000_000_000), 1)
    except (TypeError, ValueError):
        return max(int(fallback * 1_000_000_000), 1)


def _event_name(event_type: str) -> str:
    aliases = {
        "dispatch_plan": "dispatch",
        "tool_call_proposed": "tool.call",
        "tool_result": "tool.result",
        "permission_request": "permission.wait",
        "mcp_task_started": "mcp.operation",
        "mcp_task_completed": "mcp.operation",
        "task_ready": "worktree.create",
        "task_applied": "worktree.integrate",
        "session_handoff": "worktree.handoff",
    }
    if event_type in aliases:
        return aliases[event_type]
    if "model" in event_type or event_type in {"message_start", "message_end"}:
        return "model.call"
    if "retry" in event_type or event_type == "agent_job_continuing":
        return "retry"
    return event_type or "event"


def _attributes(
    run: dict[str, Any], event: dict[str, Any] | None = None, *, include_content: bool = False
) -> dict[str, Any]:
    values: dict[str, Any] = {
        "locus.run.id": str(run.get("id") or ""),
        "locus.run.kind": str(run.get("run_kind") or "team"),
        "locus.session.id": str(run.get("session_id") or ""),
        "locus.worker.id": str(run.get("worker_id") or ""),
        "locus.execution.environment": str(run.get("execution_environment") or "local"),
        "locus.content.policy": "content" if include_content else "metadata",
    }
    if include_content and run.get("request"):
        values["gen_ai.input.messages"] = str(run["request"])[:16_000]
    if event is not None:
        event_type = str(event.get("type") or "event")
        values.update({
            "gen_ai.operation.name": _event_name(event_type),
            "locus.event.type": event_type,
            "locus.run.seq": int(event.get("seq") or 0),
            "locus.schema.version": int(event.get("schema_version") or 1),
        })
        for source, destination in (
            ("agent_id", "gen_ai.agent.id"),
            ("provider", "gen_ai.provider.name"),
            ("model", "gen_ai.request.model"),
            ("job_id", "locus.job.id"),
            ("attempt_id", "locus.attempt.id"),
            ("tool", "gen_ai.tool.name"),
            ("tool_name", "gen_ai.tool.name"),
        ):
            if event.get(source):
                values[destination] = str(event[source])[:4_000]
        if include_content:
            # This value has already crossed RunStore's credential scrubber.
            values["locus.event.payload"] = json.dumps(
                event, ensure_ascii=False, separators=(",", ":"), default=str
            )[:16_000]
    return {key: value for key, value in values.items() if value != ""}


def build_spans(
    store: RunStore, run_id: str, *, include_content: bool = False
) -> tuple[list[ReadableSpan], str]:
    """Reconstruct a stable hierarchy from the local durable event ledger."""
    exported = store.export(run_id, include_content=include_content)
    run = exported["run"]
    events = list(run.get("events") or [])
    attempts = list(run.get("attempts") or [])
    trace_id = str(run.get("trace_id") or "")
    root_span_id = str(run.get("root_span_id") or "")
    if len(trace_id) != 32 or len(root_span_id) != 16:
        raise TelemetryError("run trace identity is missing")

    job_order = list(dict.fromkeys(
        str(attempt.get("job_id") or "") for attempt in attempts
        if attempt.get("job_id")
    ))
    job_span_ids = [_span_id(f"{run_id}:job:{job_id}") for job_id in job_order]
    attempt_span_ids = [
        _span_id(f"{run_id}:attempt:{attempt.get('attempt_id') or index}")
        for index, attempt in enumerate(attempts)
    ]
    event_ids = [
        _span_id(f"{run_id}:event:{event.get('event_id') or event.get('seq') or index}")
        for index, event in enumerate(events)
    ]
    generator = _StableIdGenerator(
        trace_id, [root_span_id, *job_span_ids, *attempt_span_ids, *event_ids]
    )
    provider = TracerProvider(
        resource=Resource.create({"service.name": "locus", "service.version": "1"}),
        id_generator=generator,
    )
    capture = _CaptureExporter()
    provider.add_span_processor(SimpleSpanProcessor(capture))
    tracer = provider.get_tracer("io.sparktales.locus.runs", "1")
    created = float(run.get("created_at") or time.time())
    ended = float(run.get("completed_at") or run.get("updated_at") or created)
    root = tracer.start_span(
        f"locus.{run.get('run_kind') or 'team'}.run",
        start_time=_nanoseconds(created, created),
        attributes=_attributes(run, include_content=include_content),
    )
    root_context = trace.set_span_in_context(root)

    jobs: dict[str, Any] = {}
    job_attempts: dict[str, list[tuple[float, Any]]] = {}
    job_spans: list[tuple[str, Any, float]] = []
    for job_id in job_order:
        members = [
            attempt for attempt in attempts
            if str(attempt.get("job_id") or "") == job_id
        ]
        first = members[0]
        starts = [float(item.get("started_at") or created) for item in members]
        completions = [
            float(item.get("completed_at") or ended) for item in members
        ]
        job_started = min(starts, default=created)
        job_ended = max(completions, default=ended)
        span = tracer.start_span(
            "locus.agent.job",
            context=root_context,
            start_time=_nanoseconds(job_started, created),
            attributes={
                "locus.run.id": run_id,
                "locus.job.id": job_id,
                "gen_ai.agent.id": str(first.get("agent_id") or ""),
                "gen_ai.request.model": str(first.get("model") or ""),
            },
        )
        jobs[job_id] = span
        job_attempts[job_id] = []
        job_spans.append((job_id, span, job_ended))

    attempts_by_id: dict[str, Any] = {}
    attempt_spans: list[Any] = []
    for attempt in attempts:
        attempt_id = str(attempt.get("attempt_id") or "")
        job_id = str(attempt.get("job_id") or "")
        parent = jobs.get(job_id)
        span = tracer.start_span(
            "locus.agent.attempt",
            context=trace.set_span_in_context(parent) if parent is not None else root_context,
            start_time=_nanoseconds(attempt.get("started_at"), created),
            attributes={
                "locus.run.id": run_id,
                "locus.job.id": job_id,
                "locus.attempt.id": attempt_id,
                "gen_ai.agent.id": str(attempt.get("agent_id") or ""),
                "gen_ai.request.model": str(attempt.get("model") or ""),
            },
        )
        attempt_spans.append(span)
        if attempt_id:
            attempts_by_id[attempt_id] = span
        if job_id:
            job_attempts.setdefault(job_id, []).append(
                (float(attempt.get("started_at") or created), span)
            )

    for event in events:
        event_type = str(event.get("type") or "event")
        occurred = float(event.get("occurred_at") or created)
        job_id = str(event.get("job_id") or "")
        parent = attempts_by_id.get(str(event.get("attempt_id") or ""))
        if parent is None and job_id:
            candidates = [
                item for item in job_attempts.get(job_id, []) if item[0] <= occurred
            ]
            if candidates:
                parent = max(candidates, key=lambda item: item[0])[1]
            else:
                parent = jobs.get(job_id)
        context = trace.set_span_in_context(parent) if parent is not None else root_context
        span = tracer.start_span(
            f"locus.{_event_name(event_type)}",
            context=context,
            start_time=_nanoseconds(occurred, created),
            attributes=_attributes(run, event, include_content=include_content),
        )
        if "error" in event_type or str(event.get("state") or "") == "failed":
            span.set_status(trace.Status(trace.StatusCode.ERROR))
        span.end(end_time=_nanoseconds(occurred + 0.000001, occurred))

    for attempt, span in zip(attempts, attempt_spans, strict=False):
        span.end(end_time=_nanoseconds(attempt.get("completed_at"), ended))
    for _job_id, span, job_ended in job_spans:
        span.end(end_time=_nanoseconds(job_ended, ended))
    if str(run.get("state") or "") == "failed":
        root.set_status(trace.Status(trace.StatusCode.ERROR))
    root.end(end_time=_nanoseconds(ended, created))
    provider.shutdown()
    return capture.spans, traceparent_for_run(run)


def build_otlp_payload(
    store: RunStore, run_id: str, *, include_content: bool = False
) -> dict[str, Any]:
    """Compatibility/debug description; network encoding is owned by the SDK."""
    spans, traceparent = build_spans(store, run_id, include_content=include_content)
    return {
        "traceparent": traceparent,
        "spans": [
            {
                "name": span.name,
                "trace_id": f"{span.context.trace_id:032x}" if span.context else "",
                "span_id": f"{span.context.span_id:016x}" if span.context else "",
                "parent_span_id": (
                    f"{span.parent.span_id:016x}" if span.parent is not None else ""
                ),
                "attributes": dict(span.attributes or {}),
            }
            for span in spans
        ],
    }


def send_otlp(
    store: RunStore,
    run_id: str,
    endpoint: str,
    *,
    authorization: str = "",
    include_content: bool = False,
) -> dict[str, Any]:
    """Export through the official OTLP/HTTP protobuf exporter, with bounded retries."""
    normalized = normalize_trace_endpoint(endpoint)
    record = store.run(run_id)
    if record is None:
        raise TelemetryError(f"run not found: {run_id}")
    if str(record.get("state") or "") not in {
        "completed", "failed", "interrupted", "cancelled", "discarded", "paused",
    }:
        raise TelemetryError("a run can be exported only after it stops")
    spans, traceparent = build_spans(store, run_id, include_content=include_content)
    headers = {"Authorization": authorization.strip()} if authorization.strip() else {}
    exporter = _SingleAttemptOTLPSpanExporter(
        endpoint=normalized,
        headers=headers,
        timeout=20,
        session=_NoRedirectSession(),
    )
    store.mark_export(
        run_id, "exporting",
        content_policy="content" if include_content else "metadata",
    )
    for attempt in range(1, 4):
        try:
            result = exporter.export(spans)
        except Exception:  # exporter detail may contain a credential-bearing URL
            result = SpanExportResult.FAILURE
        if result is SpanExportResult.SUCCESS:
            exporter.shutdown()
            store.mark_export(run_id, "exported", attempts=attempt)
            return {
                "ok": True, "run_id": run_id, "endpoint": normalized,
                "attempts": attempt, "traceparent": traceparent,
            }
        if attempt < 3:
            time.sleep((0.2, 0.5)[attempt - 1])
    exporter.shutdown()
    store.mark_export(run_id, "failed", attempts=3)
    raise TelemetryError("OTLP export failed after 3 attempts")


__all__ = [
    "TelemetryError", "build_otlp_payload", "build_spans", "normalize_trace_endpoint",
    "send_otlp", "traceparent_for_run",
]
