"""Bound HTTP bodies before a route decodes or acts on them."""
from __future__ import annotations

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RequestBodyLimitMiddleware:
    """Enforce the received byte count, including chunked requests.

    Authentication wraps this middleware so rejected callers are never read.
    Buffering is bounded by ``max_bytes`` and happens before route invocation:
    an oversized body cannot partially mutate application state.
    """

    def __init__(self, app: ASGIApp, *, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        lengths = [value for name, value in scope["headers"] if name.lower() == b"content-length"]
        if lengths and (len(lengths) != 1 or not lengths[0].isdigit()):
            await JSONResponse({"detail": "invalid content-length"}, status_code=400)(
                scope, receive, send
            )
            return
        # Bound before int conversion as well: an attacker-controlled decimal
        # header should not reach Python's large-integer parser.
        length = lengths[0].lstrip(b"0") if lengths else b""
        if length and (len(length) > len(str(self.max_bytes)) or int(length) > self.max_bytes):
            await self._too_large(scope, receive, send)
            return

        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            if len(body) + len(chunk) > self.max_bytes:
                await self._too_large(scope, receive, send)
                return
            body.extend(chunk)
            if not message.get("more_body", False):
                break

        delivered = False

        async def replay() -> Message:
            nonlocal delivered
            if delivered:
                return await receive()
            delivered = True
            return {"type": "http.request", "body": bytes(body), "more_body": False}

        await self.app(scope, replay, send)

    @staticmethod
    async def _too_large(scope: Scope, receive: Receive, send: Send) -> None:
        await JSONResponse({"detail": "request body is too large"}, status_code=413)(
            scope, receive, send
        )
