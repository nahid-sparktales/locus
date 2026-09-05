import asyncio

import pytest
from fastapi import Request
from fastapi.testclient import TestClient

from ollama_code import server
from ollama_code.http_limits import RequestBodyLimitMiddleware


def _run(chunks, *, headers=(), limit=8):
    calls = []
    sent = []
    incoming = iter(chunks)

    async def route(scope, receive, send):
        calls.append(await receive())

    async def receive():
        return next(incoming)

    async def send(message):
        sent.append(message)

    asyncio.run(RequestBodyLimitMiddleware(route, max_bytes=limit)(
        {"type": "http", "headers": list(headers)}, receive, send
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
