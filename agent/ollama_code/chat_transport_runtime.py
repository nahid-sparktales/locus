"""Request-neutral primitives shared by chat transports and turn execution."""

import asyncio

from fastapi import WebSocket, WebSocketDisconnect

from .chat_service import ChatService


def command_error(service: ChatService, operation: str, message: str) -> None:
    """Report a rejected client command without ending the active turn."""
    service.queue_event(
        {
            "type": "command_error",
            "operation": operation,
            "message": message,
        }
    )


async def event_pump(service: ChatService, websocket: WebSocket) -> None:
    """Forward service events while preserving terminal turn ordering."""
    try:
        while True:
            event = await service.queue.get()
            if event.get("type") in {"turn_done", "slash_result"}:
                future = service.turn_future
                if future is not None and not future.done():
                    await asyncio.shield(future)
            await websocket.send_json(event)
    except (WebSocketDisconnect, RuntimeError):
        pass
