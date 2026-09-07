"""Opt-in live optional-question probe; only disposable fixture data is sent.

Authentication remains owned by the configured App Server account manager.
This harness never opens account credentials or modifies the user's workspace.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--managed-home", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--answer-at-finalization", action="store_true",
                        help="Hold the answer until the model finishes its independent work.")
    args = parser.parse_args()
    fixture = Path(tempfile.mkdtemp(prefix="locus-question-eval-"))
    os.environ["OLLAMA_CODE_HOME"] = str(fixture / "agent-home")
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from ollama_code.chat_service import ChatService
    from ollama_code.codex_app_server import CodexAppServerManager
    from ollama_code.core import AgentCore

    workspace = fixture / "workspace"
    workspace.mkdir()
    (workspace / "alpha.txt").write_text("Alpha identifier: A-137.\n")
    (workspace / "beta.txt").write_text("Beta identifier: B-251.\n")
    core = AgentCore(cwd=str(workspace), model=args.model, config={
        "provider": "chatgpt", "chatgpt_model": args.model,
        "chatgpt_native_mode": False, "max_iterations": 8,
    })
    service = ChatService(core)
    manager = CodexAppServerManager(helper_path=str(args.helper), codex_home=args.managed_home)
    core.codex_manager = manager
    service.ws = object()  # Synthetic authenticated card renderer for this fixture.
    service.active_run_id = "question-eval"
    service.async_questions_enabled = True
    core.configure_agent(None, mode="work")
    core.tool_registry.set_ask_question_async_enabled(True)
    schemas = core.tool_registry.schemas
    core.tool_registry.schemas = lambda: [schema for schema in schemas()
        if schema["function"]["name"] in {"ask_question_async", "read_file"}]
    core.context_delivery_source = service.pending_context_deliveries
    core.context_delivery_applied = service.mark_question_delivery_applied
    core.context_delivery_native_sent = service.mark_question_native_delivery_sent
    core.context_delivery_native_unsent = service.clear_question_native_delivery_attempt
    events, response_acks, sends, timings, continuations = [], [], [], [], []
    pending_submissions = []
    reads_before_answer = []
    answer_timers = []
    service.emit = lambda event: events.append({**event, "observed_at": time.monotonic()})
    core.on_event(service.emit)
    ask = service.ask_user_question_async

    def ask_then_answer(payload):
        started = time.monotonic()
        result = ask(payload)
        request = json.loads(result) if not result.startswith("Error") else {}
        timings.append({"ask_seconds": time.monotonic() - started, "status": request.get("status")})
        if request.get("status") == "pending":
            def submit():
                reads_before_answer.append(len([event for event in events
                    if event.get("type") == "tool_result" and event.get("tool") == "read_file" and event.get("ok")]))
                response_acks.append(service.handle_async_question_response({
                    "request_id": request["request_id"], "response_id": "fixture-answer",
                    "action": "answer", "answers": [{
                        "id": question["id"], "text": "Use Remote. Validation code: R-742.",
                    } for question in request["questions"]],
                }))
            if args.answer_at_finalization:
                pending_submissions.append(submit)
            else:
                timer = threading.Timer(1.5, submit)
                answer_timers.append(timer)
                timer.start()
        return result

    core.tool_ctx.ask_question_async = ask_then_answer
    steer = manager.steer_turn

    def observed_steer(thread_id, text, client_id, expected_turn_id=""):
        entry = {"client_id": client_id, "accepted": False}
        sends.append(entry)
        result = steer(thread_id, text, client_id, expected_turn_id)
        entry["accepted"] = True
        return result

    manager.steer_turn = observed_steer
    request_native = manager.request

    def observed_request(method, params, **kwargs):
        entry = None
        if method == "turn/start" and params.get("clientUserMessageId"):
            states = service.optional_questions.snapshot(core.session.session_id)
            entry = {"client_id": params["clientUserMessageId"], "accepted": False,
                     "delivery_status_before_write": [state.get("delivery_status") for state in states]}
            continuations.append(entry)
        result = request_native(method, params, **kwargs)
        if entry is not None:
            entry["accepted"] = True
        return result

    manager.request = observed_request

    def before_finalize():
        while pending_submissions:
            pending_submissions.pop(0)()
        while not core._interrupt.is_set() and service.question_before_finalize():
            core._interrupt.wait(0.05)

    core.before_finalize = before_finalize
    watchdog = threading.Timer(180, core.interrupt)
    started = time.monotonic()
    try:
        watchdog.start()
        core.run_turn(
            "This is a disposable integration fixture. First call ask_question_async exactly once "
            "with one optional storage question (id storage), options Local and Remote, recommendation Local. "
            "While the card is pending, independently read alpha.txt and beta.txt with read_file; "
            "these reads do not depend on storage. Continue working immediately after the question tool returns. "
            "A fixture answer will arrive as new context. In your final answer report the exact identifier "
            "value written inside each file after 'identifier:', along with "
            "the exact storage choice and validation code supplied by that answer. Do not invent a code. "
            + ("If the answer has not arrived after both reads, finish your independent-work response; "
               "the fixture will then supply the answer and continue your turn. " if args.answer_at_finalization else "") +
            "Do not ask a second question or create/edit files.",
            lambda *_: "once", model_call_limit=8,
        )
        requests = service.optional_questions.snapshot(core.session.session_id)
        final = next((str(item.get("content") or "") for item in reversed(core.messages)
                      if item.get("role") == "assistant" and item.get("content")), "")
        reads = [event for event in events if event.get("type") == "tool_result"
                 and event.get("tool") == "read_file" and event.get("ok")]
        applied = [event for event in events if event.get("type") == "context_delivery_applied"]
        accepted = [ack for ack in response_acks if ack.get("accepted")]
        report = {
            "provider": "chatgpt", "model": args.model, "fixture_root": str(fixture),
            "seconds": round(time.monotonic() - started, 2), "reason": core.last_turn_result.get("reason"),
            "question_count": len(requests), "accepted_count": len(accepted), "applied_count": len(applied),
            "question_states": [{key: request.get(key) for key in ("status", "delivery_status", "remaining_ms")}
                                for request in requests],
            "ask_timings": timings, "native_steer_attempts": sends, "independent_reads": len(reads),
            "answer_at_finalization": args.answer_at_finalization,
            "reads_before_answer": reads_before_answer, "native_continuation_attempts": continuations,
            "final": final, "usage": core.last_turn_result,
            "errors": [str(event.get("message") or event.get("text") or "")[:500]
                       for event in events if event.get("type") == "error"],
        }
        report["wire_passed"] = (report["reason"] == "complete" and len(requests) == len(accepted) == len(applied) == 1
            and requests[0]["status"] == "answered" and requests[0]["delivery_status"] == "applied"
            and len(reads) >= 2 and all(value in final for value in ("R-742", "Remote")))
        report["read_identifiers_reported"] = all(value in final for value in ("A-137", "B-251"))
        if args.answer_at_finalization:
            report["wire_passed"] = (report["wire_passed"] and reads_before_answer == [2]
                and len(continuations) == 1 and continuations[0]["accepted"]
                and continuations[0]["delivery_status_before_write"] == ["accepted"])
        report["passed"] = report["wire_passed"] and report["read_identifiers_reported"]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2))
        print(json.dumps({key: report[key] for key in (
            "passed", "reason", "seconds", "question_count", "accepted_count", "applied_count", "independent_reads", "errors",
        )}), flush=True)
        return 0 if report["passed"] else 1
    finally:
        watchdog.cancel()
        for timer in answer_timers:
            timer.cancel()
            timer.join()
        service.close_question_timer()
        service.close_codex()
        manager.close()
        core.close()


if __name__ == "__main__":
    raise SystemExit(main())
