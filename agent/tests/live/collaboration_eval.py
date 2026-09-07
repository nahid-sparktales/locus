"""Opt-in model-backed collaboration probes in disposable fixture checkouts.

Pass a configured model and its Locus-managed account home explicitly. The
App Server owns authentication; this harness never reads credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--provider", choices=["chatgpt", "ollama"], default="chatgpt")
    parser.add_argument("--managed-home", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--case", choices=["simple", "explicit_one", "independent_edit", "parallel_review"]
    )
    args = parser.parse_args()
    if args.provider == "chatgpt" and (not args.managed_home or not args.helper):
        parser.error("ChatGPT probes require --managed-home and --helper")
    target = Path(tempfile.mkdtemp(prefix="locus-collaboration-eval-"))
    os.environ["OLLAMA_CODE_HOME"] = str(target / "agent-home")
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from ollama_code.codex_app_server import CodexAppServerManager
    from ollama_code.collaboration_bridge import CollaborationBridge
    from ollama_code.core import AgentCore

    manager = (CodexAppServerManager(helper_path=str(args.helper), codex_home=args.managed_home)
               if args.provider == "chatgpt" else None)
    cases = [
        ("simple", "What is 2 + 2? Reply with only the number.", "work", False),
        (
            "explicit_one",
            "Use exactly one research helper to inspect alpha.txt while you independently inspect beta.txt. Report both identifiers and file evidence.",
            "plan",
            True,
        ),
        (
            "independent_edit",
            "Use one coding helper to fix add() in calculator.py and test the fix, while you independently inspect beta.txt. Review and integrate the helper's frozen result, validate the combined checkout, and report the identifier and test result. This is a disposable fixture.",
            "work",
            True,
        ),
        (
            "parallel_review",
            "Audit the independent parser.py, cache.py, and calculator.py components. For each, inspect implementation and contracts, identify correctness and data-loss bugs, and propose concrete fixes and regression tests. Evaluate negative, empty, duplicate, and limit-boundary cases. Work efficiently and preserve fixture files.",
            "work",
            True,
        ),
    ]
    report = {
        "model": args.model,
        "provider": args.provider,
        "policy_version": "balanced-v2",
        "fixture_root": str(target),
        "cases": [],
    }
    try:
        for name, prompt, mode, expected_helper in cases:
            if args.case and args.case != name:
                continue
            cwd = target / name
            cwd.mkdir()
            (cwd / "alpha.txt").write_text("Alpha component identifier: A-137.\n")
            (cwd / "beta.txt").write_text("Beta component identifier: B-251.\n")
            (cwd / "calculator.py").write_text("def add(a, b):\n    return a - b\n")
            (
                cwd / "parser.py"
            ).write_text('''"""Parse comma separated integer IDs. Empty fields must be rejected; preserve duplicates."""
def parse_ids(text):
    return list(set(int(part) for part in text.split(',') if part))
def parse_limit(text, maximum=100):
    """A limit must be between zero and maximum, inclusive."""
    limit = int(text)
    if limit >= maximum:
        raise ValueError('Too large')
    return limit
''')
            (
                cwd / "cache.py"
            ).write_text('''"""A bounded cache. Missing reads must not evict values; updates preserve capacity."""
class Cache:
    def __init__(self, capacity=2):
        self.capacity = capacity
        self.data = {}
    def get(self, key):
        return self.data.pop(key, None)
    def put(self, key, value):
        if len(self.data) >= self.capacity:
            self.data.pop(next(iter(self.data)))
        self.data[key] = value
''')
            (cwd / "test_calculator.py").write_text(
                "from calculator import add\nassert add(2, 3) == 5\nassert add(-2, 3) == 1\n"
            )
            for command in (
                ["git", "init", "-q"],
                ["git", "add", "."],
                [
                    "git",
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@localhost",
                    "commit",
                    "-qm",
                    "fixture",
                ],
            ):
                subprocess.run(command, cwd=cwd, check=True, capture_output=True)
            events = []
            core = AgentCore(
                cwd=str(cwd),
                model=args.model,
                config={
                    "provider": args.provider,
                    "chatgpt_model": args.model,
                    "chatgpt_native_mode": mode == "plan",
                    "max_iterations": 24,
                    "permission_mode": "accept_edits",
                },
            )
            core.codex_manager = manager
            core.configure_agent(None, mode=mode)
            svc = SimpleNamespace(
                core=core,
                codex=manager,
                run_store=None,
                emit=events.append,
                decide=lambda *_: "once",
                _execute_background_service=lambda _: "Error: unavailable in fixture",
                pending_context_deliveries=lambda: [],
                mark_question_delivery_applied=lambda _: False,
                question_before_finalize=lambda: False,
            )
            bridge = CollaborationBridge(svc, name)
            core.on_event(events.append)
            core.tool_ctx.delegate_read_only = bridge.execute
            core.tool_ctx.collaboration = bridge.call
            core.tool_registry.set_solo_swarm_enabled(True)
            core.tool_registry.set_collaboration_enabled(True)
            core.tool_action_lock = bridge.lock
            core.context_delivery_source = bridge.deliveries
            core.context_delivery_applied = bridge.applied
            core.before_finalize = bridge.before_finalize
            core.reset_system_message()
            exposed = (
                core.tool_registry.parity_schemas(mode == "plan")
                if core.chatgpt_parity_active(True)
                else core.tool_registry.schemas()
            )
            timer = threading.Timer(240, core.interrupt)
            started = time.monotonic()
            try:
                timer.start()
                core.run_turn(prompt, svc.decide, model_call_limit=20)
                launches = len([e for e in events if e.get("type") == "agent_job_started"])
                validation = None
                final = next(
                    (
                        str(m.get("content") or "")
                        for m in reversed(core.messages)
                        if m.get("role") == "assistant" and m.get("content")
                    ),
                    "",
                )
                helper_reads = sum(
                    e.get("type") == "tool_result"
                    and bool(e.get("agent_id"))
                    and e.get("tool") in {"read_file", "grep", "glob"}
                    for e in events
                )
                integrations = sum(e.get("type") == "agent_worktree_integrated" for e in events)
                if name == "simple":
                    validation = final.strip() == "4"
                if name == "explicit_one":
                    validation = helper_reads > 0 and "A-137" in final and "B-251" in final
                if name == "independent_edit":
                    validation = (
                        subprocess.run(
                            [sys.executable, "test_calculator.py"], cwd=cwd, capture_output=True
                        ).returncode
                        == 0
                        and integrations > 0
                    )
                item = {
                    "case": name,
                    "mode": mode,
                    "exposed_tools": [s["function"]["name"] for s in exposed],
                    "launches": launches,
                    "helpers_created": sum(e.get("type") == "agent_spawned" for e in events),
                    "helper_reads": helper_reads,
                    "integrations": integrations,
                    "expected_helper": expected_helper,
                    "reason": core.last_turn_result.get("reason"),
                    "parent_usage": core.last_turn_result,
                    "helper_usage": bridge.usage,
                    "validation": validation,
                    "seconds": round(time.monotonic() - started, 2),
                    "passed": (launches > 0) == expected_helper
                    and core.last_turn_result.get("reason") == "complete"
                    and validation is not False,
                    "errors": [
                        str(e.get("message") or "")[:500]
                        for e in events
                        if e.get("type") == "error"
                    ],
                }
                report["cases"].append(item)
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, indent=2))
                print(
                    json.dumps(
                        {
                            k: item[k]
                            for k in ("case", "launches", "passed", "reason", "seconds", "errors")
                        }
                    ),
                    flush=True,
                )
            finally:
                timer.cancel()
                bridge.close()
                core.close()
    finally:
        if manager:
            manager.close()
    return 0 if all(c["passed"] for c in report["cases"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
