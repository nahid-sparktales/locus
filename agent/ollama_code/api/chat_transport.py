"""Authenticated WebSocket transports for chat and Codex workers."""

import asyncio
import os
import threading
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..chat_service import ChatService
from ..chat_transport_runtime import command_error, event_pump
from ..codex_app_server import (
    CodexAppServerError,
    CodexBrokerClient,
    CodexProtocolMismatch,
)
from .dependencies import service_from_app

MessageHandler = Callable[[ChatService, dict[str, Any]], Awaitable[None]]


def _allowed_origins(websocket: WebSocket) -> set[str]:
    return set(getattr(websocket.app.state, "allowed_origins", set()))


def _message_handler(websocket: WebSocket) -> MessageHandler:
    handler = getattr(websocket.app.state, "chat_message_handler", None)
    if not callable(handler):
        raise RuntimeError("chat message handling is not ready")
    return handler


async def ws_codex_broker(ws: WebSocket) -> None:
    """Authenticated duplex broker for isolated team worker processes."""
    origin = ws.headers.get("origin")
    if origin:
        await ws.close(code=1008, reason="browser connections are not allowed")
        return
    token = str(getattr(ws.app.state, "auth_token", "") or "")
    if not token or ws.headers.get("x-locus-token") != token:
        await ws.close(code=1008, reason="internal broker authentication failed")
        return
    await ws.accept()
    svc = service_from_app(ws.app)
    # A worker must never cause another helper to launch behind the broker.
    if isinstance(svc.codex, CodexBrokerClient):
        await ws.send_json({"type": "error", "message": "nested ChatGPT brokers are forbidden"})
        await ws.close(code=1008)
        return
    try:
        request = await ws.receive_json()
        operation = str(request.get("op") or "")
        if operation == "account":
            result = await asyncio.to_thread(
                svc.codex.account, refresh=bool(request.get("refresh"))
            )
            await ws.send_json({"type": "result", "result": result})
        elif operation == "models":
            await ws.send_json(
                {
                    "type": "result",
                    "result": await asyncio.to_thread(svc.codex.models),
                }
            )
        elif operation == "usage":
            await ws.send_json(
                {
                    "type": "result",
                    "result": await asyncio.to_thread(svc.codex.usage),
                }
            )
        elif operation == "thread_start":
            result = await asyncio.to_thread(
                svc.codex.start_thread,
                model=str(request.get("model") or ""),
                cwd=str(request.get("cwd") or svc.core.cwd),
                base_instructions=str(request.get("base_instructions") or ""),
                tools=request.get("tools") if isinstance(request.get("tools"), list) else [],
                ephemeral=bool(request.get("ephemeral")),
            )
            await ws.send_json({"type": "result", "result": result})
        elif operation == "thread_resume":
            result = await asyncio.to_thread(
                svc.codex.resume_thread,
                str(request.get("thread_id") or ""),
                model=str(request.get("model") or ""),
                cwd=str(request.get("cwd") or svc.core.cwd),
            )
            await ws.send_json({"type": "result", "result": result})
        elif operation == "complete":
            result = await asyncio.to_thread(
                svc.codex.complete,
                model=str(request.get("model") or ""),
                cwd=str(request.get("cwd") or svc.core.cwd),
                base_instructions=str(request.get("base_instructions") or ""),
                prompt=str(request.get("prompt") or ""),
                output_schema=(
                    request.get("output_schema")
                    if isinstance(request.get("output_schema"), dict)
                    else None
                ),
                timeout=float(request.get("timeout") or 300),
            )
            await ws.send_json({"type": "result", "result": result})
        elif operation == "turn_run":
            loop = asyncio.get_running_loop()
            inbound: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
            interrupted = threading.Event()

            async def receive_worker_results() -> None:
                while True:
                    message = await ws.receive_json()
                    if message.get("type") == "interrupt":
                        interrupted.set()
                    else:
                        await inbound.put(message)

            receiver = asyncio.create_task(receive_worker_results())

            def send_from_helper(message: dict[str, Any]) -> None:
                future = asyncio.run_coroutine_threadsafe(ws.send_json(message), loop)
                future.result(timeout=30)

            def forward_event(event: dict[str, Any]) -> None:
                send_from_helper({"type": "event", "event": event})

            def run_tool(name: str, arguments: dict[str, Any], call_id: str) -> str:
                send_from_helper(
                    {
                        "type": "tool_call",
                        "tool": name,
                        "arguments": arguments,
                        "call_id": call_id,
                    }
                )
                future = asyncio.run_coroutine_threadsafe(inbound.get(), loop)
                reply = future.result(timeout=1_800)
                if reply.get("type") != "tool_result" or reply.get("call_id") != call_id:
                    raise CodexProtocolMismatch("worker returned an invalid dynamic tool result")
                return str(reply.get("result") or "")

            try:
                turn = await asyncio.to_thread(
                    svc.codex.run_turn,
                    thread_id=str(request.get("thread_id") or ""),
                    text=str(request.get("text") or ""),
                    input_items=(
                        request.get("input_items")
                        if isinstance(request.get("input_items"), list)
                        else None
                    ),
                    model=str(request.get("model") or ""),
                    effort=str(request.get("effort") or ""),
                    output_schema=(
                        request.get("output_schema")
                        if isinstance(request.get("output_schema"), dict)
                        else None
                    ),
                    tool_handler=run_tool,
                    event_handler=forward_event,
                    should_interrupt=interrupted.is_set,
                    timeout=float(request.get("timeout") or 1_800),
                )
                await ws.send_json({"type": "completed", "turn": turn})
            finally:
                receiver.cancel()
        else:
            await ws.send_json({"type": "error", "message": "unknown broker operation"})
    except (CodexAppServerError, CodexProtocolMismatch, ValueError, RuntimeError) as error:
        try:
            await ws.send_json({"type": "error", "message": str(error)})
        except RuntimeError:
            pass
    except WebSocketDisconnect:
        return


async def ws_chat(ws: WebSocket) -> None:
    # Same-origin rule as the HTTP routes: a browser page must never be able
    # to open the agent socket. WebSocket handshakes always carry Origin when
    # they come from a page.
    origin = ws.headers.get("origin")
    if origin and origin not in _allowed_origins(ws):
        await ws.close(code=1008, reason="cross-origin connections are not allowed")
        return
    token = str(getattr(ws.app.state, "auth_token", "") or "")
    if token and ws.headers.get("x-locus-token") != token:
        await ws.close(code=1008, reason="local agent authentication failed")
        return
    await ws.accept()
    svc = service_from_app(ws.app)
    message_handler = _message_handler(ws)
    previous_ws = svc.ws
    previous_pump = svc.event_pump
    # Publish the replacement before closing the old socket. Its finally block
    # can now tell it is stale and cannot interrupt the replacement's turn.
    svc.ws = ws
    svc.event_pump = None
    if previous_pump is not None:
        previous_pump.cancel()
    if previous_ws is not None and previous_ws is not ws:  # single-client app: replace
        try:
            await previous_ws.close()
        except Exception:  # noqa: BLE001
            pass
    svc.loop = asyncio.get_running_loop()
    await ws.send_json(
        {
            "type": "session_info",
            **svc.core.session_info(),
            "worker_id": svc.worker_id,
            "process_id": os.getpid(),
        }
    )
    for run in svc.recoverable_runs:
        await ws.send_json(
            {
                "type": "orchestration_recovery_available",
                "run": run,
            }
        )
    svc.recoverable_runs = []
    for run_id, plan in list(svc.pending_dispatch_plans.items()):
        await ws.send_json(
            {
                "type": "dispatch_plan_ready",
                "run_id": run_id,
                "state": "waiting_dispatch_approval",
                "plan": plan,
            }
        )
    pump = asyncio.create_task(event_pump(svc, ws))
    svc.event_pump = pump
    try:
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict):
                await message_handler(svc, msg)
            else:
                command_error(svc, "invalid", "WebSocket messages must be JSON objects")
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - e.g. invalid JSON from client
        pass
    finally:
        pump.cancel()
        if svc.event_pump is pump:
            svc.event_pump = None
        if svc.ws is ws:  # a newer connection may already have replaced us
            svc.ws = None
            svc.core.interrupt()
            svc.interrupt_parallel_writers()
            svc.deny_all_pending()
            svc.cancel_all_computer_actions()
            svc.cancel_all_simulator_actions()
            svc.cancel_all_browser_actions()
            svc.cancel_all_notes_actions()
            svc.cancel_all_wallet_actions()
            svc.cancel_dispatch_decisions()
            svc.cancel_all_mcp_inputs()


def register_routes(router: APIRouter) -> None:
    router.add_api_websocket_route("/ws/internal/codex", ws_codex_broker)
    router.add_api_websocket_route("/ws/chat", ws_chat)
