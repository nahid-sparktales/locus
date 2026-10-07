"""Explicit, ephemeral profile-art requests through the existing image service.

No prompt or output enters the conversation, workspace, memory or plugin data.
The native app approves/saves decoded pixels only after Use this character.
"""
from __future__ import annotations

import asyncio
import base64
import tempfile
import threading
import uuid
from typing import Any

from fastapi import APIRouter, Body, HTTPException, Request

from ..capabilities import enabled as capability_enabled
from ..image_generation import ImageProviderError, ImageToolError
from ..tools import ToolContext
from .dependencies import get_service
from .disconnect import watch_disconnect

# In-flight cancellation handles only: no agent identity or persistent store.
_pending: dict[tuple[int, str], threading.Event] = {}
PREVIEW_TIMEOUT_SECONDS = 300


def _key(service: Any, body: dict[str, Any]) -> tuple[int, str]:
    try:
        request_id = str(uuid.UUID(str(body.get("request_id", ""))))
    except (ValueError, AttributeError):
        raise HTTPException(422, "A valid image request id is required.") from None
    return id(service.image_generation), request_id


async def generate_portrait(request: Request, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, str]:
    if not capability_enabled("image_generation_v1"):
        raise HTTPException(404, "Image generation is unavailable in this runtime.")
    service = get_service(request)
    key = _key(service, body)
    prompt, account_id = body.get("prompt"), body.get("account_id")
    if not isinstance(prompt, str) or not isinstance(account_id, str):
        raise HTTPException(422, "A description and selected image account are required.")
    if any(owner == key[0] for owner, _ in _pending):
        raise HTTPException(409, "An image preview is already being generated. Cancel or wait for it first.")
    stopped = threading.Event()
    _pending[key] = stopped

    def perform() -> bytes:
        # Managed helper image generation receives an empty, temporary folder,
        # never the user's active project's files or an invented conversation.
        with tempfile.TemporaryDirectory(prefix="locus-character-") as root:
            return service.image_generation.portrait_preview(
                prompt, account_id, ToolContext(cwd=root, should_stop=stopped.is_set)
            )

    disconnect = asyncio.create_task(watch_disconnect(request, stopped))
    task = asyncio.create_task(asyncio.to_thread(perform))
    try:
        deadline = asyncio.get_running_loop().time() + PREVIEW_TIMEOUT_SECONDS
        while True:
            if stopped.is_set():
                raise HTTPException(499, "Image generation cancelled. The provider may already have charged for work started.")
            if task.done():
                break
            if asyncio.get_running_loop().time() >= deadline:
                stopped.set()
                raise HTTPException(504, "Image generation timed out. No automatic retry was made.")
            await asyncio.wait({task}, timeout=0.1)
        data = await task
        return {"png_base64": base64.b64encode(data).decode("ascii")}
    except ImageToolError as error:
        raise HTTPException(422, str(error)) from None
    except ImageProviderError as error:
        raise HTTPException(499 if str(error) == "interrupted" else 502, str(error)) from None
    finally:
        stopped.set()
        disconnect.cancel()
        # The existing provider client observes stop while awaiting headers and
        # closes late responses. Consume its result without delaying the UI.
        def finish(done: asyncio.Task) -> None:
            if not done.cancelled():
                done.exception()
            _pending.pop(key, None)
        if task.done():
            finish(task)
        else:
            task.add_done_callback(finish)
        await asyncio.gather(disconnect, return_exceptions=True)


async def cancel_portrait(request: Request, body: dict[str, Any] = Body(default_factory=dict)) -> dict[str, bool]:
    service = get_service(request)
    key = _key(service, body)
    event = _pending.get(key)
    if event is not None:
        event.set()
    return {"ok": True}


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/images/portrait", generate_portrait, methods=["POST"])
    router.add_api_route("/api/images/portrait/cancel", cancel_portrait, methods=["POST"])
