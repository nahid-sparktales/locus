"""WS interrupt verification: stop a long generation mid-stream.
Run with the server up: .venv/bin/python tests/ws_interrupt.py"""
import asyncio
import json
import time

import websockets


async def main() -> None:
    async with websockets.connect("ws://localhost:8791/ws/chat") as ws:

        async def recv(timeout=90):
            return json.loads(await asyncio.wait_for(ws.recv(), timeout))

        while True:  # wait for session_info
            m = await recv(15)
            if m.get("type") == "session_info":
                break

        await ws.send(json.dumps({
            "type": "user_message",
            "text": "tell me a very long story about a dragon, at least 3000 words. "
                    "Do not use any tools — reply directly in chat only.",
        }))

        n_tokens = 0
        start = time.time()
        while n_tokens < 25:
            m = await recv(90)
            if m.get("type") == "token":
                n_tokens += 1
            elif m.get("type") == "permission_request":
                await ws.send(json.dumps({
                    "type": "permission_decision",
                    "request_id": m["request_id"],
                    "decision": "always",
                }))
            elif m.get("type") == "turn_done":
                raise AssertionError("turn finished before we could interrupt")

        interrupt_at = time.time()
        await ws.send(json.dumps({"type": "interrupt"}))

        while True:
            m = await recv(30)
            if m.get("type") == "permission_request":
                await ws.send(json.dumps({
                    "type": "permission_decision",
                    "request_id": m["request_id"],
                    "decision": "deny",
                }))
            elif m.get("type") == "turn_done":
                latency = time.time() - interrupt_at
                print(f"TURN_DONE reason={m.get('reason')} tokens_before_interrupt={n_tokens} "
                      f"latency_after_interrupt={latency:.1f}s total={time.time() - start:.1f}s")
                assert m.get("reason") == "interrupted", m
                print("WS INTERRUPT PASSED")
                return


asyncio.run(main())
