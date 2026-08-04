"""WS end-to-end verification: agentic turn with permission flow over WebSocket.

Manual smoke test against a real model. Starts its own server:
    agent/.venv/bin/python tests/live/ws_verify.py --model qwen3.6:27b
"""
import asyncio
import json
import sys
import time
from collections import Counter
from pathlib import Path

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _server import live_server, parse_args  # noqa: E402


async def run(ws_url: str, target: Path) -> None:
    events: list[dict] = []

    async with websockets.connect(ws_url) as ws:

        async def recv_until(pred, timeout=240):
            deadline = time.time() + timeout
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting; events so far: "
                                       f"{Counter(e.get('type') for e in events)}")
                msg = json.loads(await asyncio.wait_for(ws.recv(), remaining))
                events.append(msg)
                if msg.get("type") == "permission_request":
                    await ws.send(json.dumps({
                        "type": "permission_decision",
                        "request_id": msg["request_id"],
                        "decision": "always",
                    }))
                    print(f"  >> answered permission_request for {msg.get('tool')} with 'always'")
                if pred(msg):
                    return msg

        await recv_until(lambda m: m.get("type") == "session_info", 15)
        print("SESSION_INFO OK")

        await ws.send(json.dumps({
            "type": "user_message",
            "text": f"create a file {target} that prints hello from gui, "
                    "then run it with python3",
        }))
        done = await recv_until(lambda m: m.get("type") == "turn_done", 240)
        print("TURN_DONE:", done.get("reason"))

        counts = Counter(e.get("type") for e in events)
        print("EVENT COUNTS:", dict(counts))
        ran = False
        for e in events:
            t = e.get("type")
            if t in ("tool_call_proposed", "tool_result", "turn_done", "error", "slash_result"):
                extra = e.get("summary") or str(e.get("result", ""))[:70] or e.get("reason") or e.get("message")
                print(f"  {t} | {e.get('tool', '')} | {extra}")
                if t == "tool_result" and "hello from gui" in str(e.get("result", "")):
                    ran = True
        assert counts.get("token", 0) > 0, "no token events streamed"
        assert counts.get("tool_call_proposed", 0) >= 2, "expected >=2 tool calls"
        assert counts.get("tool_result", 0) >= 2, "expected >=2 tool results"
        assert done.get("reason") == "complete", done
        assert target.exists(), f"{target} was not created"
        assert ran, "the script output never appeared in a tool_result (was it executed?)"
        print("WS VERIFY PASSED")


def main() -> None:
    args = parse_args(__doc__ or "")
    with live_server(args.model) as (_base, ws_url, workdir):
        # Inside the server's own throwaway cwd, not a shared /tmp path.
        asyncio.run(run(ws_url, workdir / "hello.py"))


main()
