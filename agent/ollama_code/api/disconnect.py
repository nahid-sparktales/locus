"""Cooperative cancellation for workers owned by parsed-body HTTP requests."""

import threading

from fastapi import Request


async def watch_disconnect(request: Request, stopped: threading.Event) -> None:
    """Wait after body parsing; callers cancel/await this task on completion.

    Unlike Request.is_disconnected's immediately cancelled receive, a blocking
    receive can pass through the production BaseHTTPMiddleware wrappers. The
    route must already have consumed its body and have no other receive reader.
    """
    try:
        while (await request.receive())["type"] != "http.disconnect":
            pass
    finally:
        # A broken receive stream also revokes the worker rather than leaving
        # it running after the request can no longer be monitored.
        stopped.set()
