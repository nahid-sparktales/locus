"""Compare companion preflight payloads using an isolated synthetic chat.

Run with the agent environment, for example:
    python agent/benchmarks/companion_send_context.py --messages 10000

Measures backend reconstruction plus JSON serialization, not model latency or
desktop rendering. No real chat history or provider credentials are accessed.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import tempfile
import time
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=10000, choices=range(1, 20001), metavar="1..20000")
    parser.add_argument("--repeats", type=int, default=5, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="locus-send-context-benchmark-") as directory:
        os.environ["OLLAMA_CODE_HOME"] = directory
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        from ollama_code.api.sessions import session_detail, session_execution_context
        from ollama_code.sessions import SessionMeta, SessionStore

        chat = SessionStore(directory, "fixture:model")
        SessionMeta.update(chat.session_id, agent_profile_id="fixture-profile", workspace_root=directory)
        with chat.path.open("a") as handle:
            for index in range(args.messages):
                record = {"type": "message", "message": {
                    "role": "user" if index % 2 == 0 else "assistant",
                    "content": f"Synthetic message {index}: " + "x" * 2000,
                }}
                handle.write(json.dumps(record) + "\n")

        result = {"messages": args.messages, "transcript_bytes": chat.path.stat().st_size, "repeats": args.repeats}
        for name, handler in (("full_detail", session_detail), ("execution_context", session_execution_context)):
            durations = []
            for _ in range(args.repeats):
                started = time.perf_counter()
                payload = json.dumps(handler(chat.session_id)).encode()
                durations.append((time.perf_counter() - started) * 1000)
            result[name] = {"median_ms": round(statistics.median(durations), 3), "payload_bytes": len(payload)}
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
