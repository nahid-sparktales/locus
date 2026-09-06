import asyncio

import pytest
from fastapi import Request
from fastapi.testclient import TestClient

from ollama_code import server
from ollama_code.api.dependencies import get_service
from ollama_code.http_limits import RequestBodyLimitMiddleware


def _run(chunks, *, headers=(), limit=8, route_limits=None, method="POST", path="/"):
    calls = []
    sent = []
    incoming = iter(chunks)

    async def route(scope, receive, send):
        calls.append(await receive())

    async def receive():
        return next(incoming)

    async def send(message):
        sent.append(message)

    asyncio.run(RequestBodyLimitMiddleware(route, max_bytes=limit, route_limits=route_limits)(
        {"type": "http", "headers": list(headers), "method": method, "path": path},
        receive,
        send,
    ))
    return calls, sent


def test_chunked_body_limit_rejects_before_route_or_final_chunk():
    calls, sent = _run([
        {"type": "http.request", "body": b"12345", "more_body": True},
        {"type": "http.request", "body": b"6789", "more_body": True},
    ])
    assert not calls
    assert sent[0]["status"] == 413


def test_declared_small_length_does_not_bypass_received_byte_limit():
    calls, sent = _run([
        {"type": "http.request", "body": b"123456789", "more_body": False},
    ], headers=[(b"content-length", b"1")])
    assert not calls
    assert sent[0]["status"] == 413


@pytest.mark.parametrize("value", [b"-1", b"+8", b"1.0", b"", b"eight"])
def test_invalid_length_is_rejected_without_reading_the_body(value):
    calls, sent = _run([], headers=[(b"content-length", value)])
    assert not calls
    assert sent[0]["status"] == 400


def test_duplicate_lengths_are_rejected_without_reading_the_body():
    calls, sent = _run([], headers=[(b"content-length", b"1"), (b"content-length", b"1")])
    assert not calls
    assert sent[0]["status"] == 400


def test_unbounded_decimal_header_is_rejected_without_large_integer_conversion():
    calls, sent = _run([], headers=[(b"content-length", b"9" * 5000)])
    assert not calls
    assert sent[0]["status"] == 413


def test_exact_limit_is_replayed_unchanged_to_the_route():
    calls, sent = _run([
        {"type": "http.request", "body": b"1234", "more_body": True},
        {"type": "http.request", "body": b"5678", "more_body": False},
    ])
    assert calls == [{"type": "http.request", "body": b"12345678", "more_body": False}]
    assert not sent


def test_disconnect_does_not_invoke_the_route():
    calls, sent = _run([
        {"type": "http.request", "body": b"1234", "more_body": True},
        {"type": "http.disconnect"},
    ])
    assert not calls
    assert not sent


@pytest.mark.parametrize("headers", [[], [(b"content-length", b"10")]])
def test_upload_override_accepts_larger_declared_and_chunked_bodies(headers):
    calls, sent = _run([
        {"type": "http.request", "body": b"12345", "more_body": True},
        {"type": "http.request", "body": b"67890", "more_body": False},
    ], headers=headers, route_limits={("POST", "/upload"): 10}, path="/upload")
    assert calls == [{"type": "http.request", "body": b"1234567890", "more_body": False}]
    assert not sent


@pytest.mark.parametrize("method,path", [("PUT", "/upload"), ("POST", "/upload/other")])
def test_upload_override_does_not_raise_limits_for_other_methods_or_paths(method, path):
    calls, sent = _run([
        {"type": "http.request", "body": b"123456789", "more_body": False},
    ], route_limits={("POST", "/upload"): 10}, method=method, path=path)
    assert not calls
    assert sent[0]["status"] == 413


def test_upload_override_rejects_chunked_overflow_before_route_or_final_chunk():
    calls, sent = _run([
        {"type": "http.request", "body": b"12345", "more_body": True},
        {"type": "http.request", "body": b"678901", "more_body": True},
    ], route_limits={("POST", "/upload"): 10}, path="/upload")
    assert not calls
    assert sent[0]["status"] == 413


def test_upload_override_rejects_declared_overflow_before_reading_body():
    calls, sent = _run(
        [], headers=[(b"content-length", b"11")],
        route_limits={("POST", "/upload"): 10}, path="/upload",
    )
    assert not calls
    assert sent[0]["status"] == 413


def test_application_preserves_document_upload_limit_without_raising_other_routes(monkeypatch):
    monkeypatch.setattr(server, "MAX_HTTP_BODY_BYTES", 4)
    monkeypatch.setattr(server, "MAX_SOURCE_BYTES", 8)
    application = server.create_app(auth_token="test-token")
    application.dependency_overrides[get_service] = lambda: object()

    with TestClient(application) as client:
        headers = {"x-locus-token": "test-token"}
        # Missing filename reaches route validation, proving the body passed
        # middleware under the upload exception without starting a real job.
        assert client.post(
            "/api/document-jobs/upload", content=b"12345678", headers=headers
        ).status_code == 422
        assert client.post(
            "/api/document-jobs/upload", content=b"123456789", headers=headers
        ).status_code == 413
        assert client.put(
            "/api/document-jobs/upload", content=b"12345", headers=headers
        ).status_code == 413
        assert client.post(
            "/body-limit-probe", content=b"12345", headers=headers
        ).status_code == 413


def test_application_authentication_precedes_body_reading():
    application = server.create_app(auth_token="test-token")
    calls = []

    @application.post("/body-limit-probe")
    async def probe(request: Request):
        calls.append(await request.body())
        return {"size": len(calls[-1])}

    def unreadable():
        raise AssertionError("an unauthenticated body must not be consumed")
        yield b""

    with TestClient(application) as client:
        assert client.post("/body-limit-probe", content=unreadable()).status_code == 401
        response = client.post(
            "/body-limit-probe", content=iter([b"hello", b" world"]),
            headers={"x-locus-token": "test-token"},
        )
        assert response.json() == {"size": 11}
    assert calls == [b"hello world"]
