"""WS interrupt verification: stop a long generation mid-stream.

Manual smoke test against a real model. Starts its own server:
    agent/.venv/bin/python tests/live/ws_interrupt.py --model qwen3.6:27b
"""
import asyncio
import json
import sys
import time
from pathlib import Path

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _server import live_server, parse_args  # noqa: E402


async def run(ws_url: str) -> None:
    async with websockets.connect(ws_url) as ws:

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


def main() -> None:
    args = parse_args(__doc__ or "")
    with live_server(args.model) as (_base, ws_url, _workdir):
        asyncio.run(run(ws_url))


main()
