"""Loss-aware compaction with a durable, separately preserved task snapshot."""
from __future__ import annotations

import json
from typing import Any


def protected_context(core: Any) -> str:
    from .sessions import SessionStore
    records = SessionStore.authoritative_inputs(core.session.path)
    inputs = [m["content"] for m in records]
    for message in core.messages[1:]:
        if (message.get("role") == "user" and not message.get("_locus_context")
                and not message.get("_compaction_summary")):
            text = message.get("content")
            if isinstance(text, str) and text and text not in inputs:
                inputs.append(text)
    if core.provider == "chatgpt" and core.chatgpt_parity_active(core._turn_allows_tools):
        from .sessions import strip_prompt_decoration
        inputs = [strip_prompt_decoration(text) for text in inputs]
    sections = ["Current task context. Preserve the user's constraints; later corrections supersede earlier instructions."]
    if inputs:
        sections.append("User requests and corrections (verbatim):\n" + "\n\n".join(inputs))
    if core.tool_ctx.plan_document:
        sections.append("Saved plan:\n" + json.dumps(core.tool_ctx.plan_document, ensure_ascii=False))
    runtime = getattr(core, "goal_runtime", None)
    if runtime is not None:
        sections.append("Persistent goal:\n" + json.dumps(runtime.snapshot(), ensure_ascii=False))
    capsule = getattr(core, "capsule_runtime", None)
    if capsule is not None:
        sections.append("Capsule progress:\n" + json.dumps(capsule.context(), ensure_ascii=False))
    failures = SessionStore.unresolved_failures(core.session.path)
    if failures:
        sections.append("Unresolved tool failures (inspect before claiming completion):\n" + json.dumps(failures, ensure_ascii=False))
    sections.append("Full tool results and original conversation remain in the local session: " + str(core.session.path))
    return "\n\n".join(sections)


def compact(core: Any) -> dict[str, Any]:
    from .core import COMPACT_TRANSCRIPT_CAP_CHARS, SUMMARY_ALLOWANCE_TOKENS
    history = [m for m in core.messages[1:] if m.get("role") in {"user", "assistant", "tool"}]
    if len(history) < 2:
        return {"command": "compact", "text": "Nothing to compact yet."}
    original = list(core.messages)
    try:
        snapshot = protected_context(core)
        system = core.system_message()
        available = core.context_limit or 128000
        overhead = token_estimate(str(system.get("content", ""))) + core._tool_schema_tokens() + core._reply_room()
        # Never shorten authoritative instructions just to make compaction succeed.
        if token_estimate(snapshot) + overhead + SUMMARY_ALLOWANCE_TOKENS >= available:
            raise ValueError("Essential task instructions exceed this model's context. Choose a larger context or explicitly narrow the task.")
        user_positions = [i for i, m in enumerate(history) if m.get("role") == "user" and not m.get("_locus_context")]
        tail_start = user_positions[-2] if len(user_positions) > 2 else len(history)
        tail = history[tail_start:]
        older = history[:tail_start]
        # A recent tail is optional; if too large summarize it with every other
        # message, preserving tool pairings in serialized complete records.
        if token_estimate(json.dumps(tail)) + token_estimate(snapshot) + overhead + SUMMARY_ALLOWANCE_TOKENS >= available:
            older, tail = history, []
        cap = min(COMPACT_TRANSCRIPT_CAP_CHARS, max(3000, 3 * (available - SUMMARY_ALLOWANCE_TOKENS - 1500)))
        transcript = "\n".join(json.dumps(m, ensure_ascii=False) for m in older)
        summaries = []
        chunks = bounded_sections(transcript, cap)
        chunk_count = len(chunks)
        allowance = getattr(core, "_compaction_call_limit", None) if core._accepting_steers else None
        if allowance is not None and chunk_count >= allowance:
            raise ValueError("Compaction and execution need more than the remaining model-call allowance. Context is preserved.")
        for section in chunks:
            if core._interrupt.is_set():
                raise InterruptedError("Compaction interrupted; prior context retained.")
            request = [{"role": "system", "content": "Summarize this consecutive section of agent history. Preserve decisions, failed and passed checks, source paths, unresolved blockers and tool evidence. User constraints are preserved separately. Never claim missing work was completed."},
                       {"role": "user", "content": section}]
            response = summarize_section(core, request)
            core.total_prompt_tokens += response.prompt_eval_count
            core.total_completion_tokens += response.eval_count
            core._compaction_calls_pending = getattr(core, "_compaction_calls_pending", 0) + response.provider_fields.get("locus_model_calls", 1)
            core._compaction_prompt_pending = getattr(core, "_compaction_prompt_pending", 0) + response.prompt_eval_count
            core._compaction_completion_pending = getattr(core, "_compaction_completion_pending", 0) + response.eval_count
            core._emit({"type": "compaction_usage", "model_calls": response.provider_fields.get("locus_model_calls", 1), "included_in_turn": core._accepting_steers,
                        "prompt_tokens": response.prompt_eval_count, "completion_tokens": response.eval_count})
            if getattr(core, "capsule_runtime", None) is not None:
                core._emit({"type": "model_usage", "model_calls": core._compaction_calls_pending,
                            "prompt_tokens": core._compaction_prompt_pending,
                            "completion_tokens": core._compaction_completion_pending})
            summary = response.content.strip()
            if not summary or response.done_reason in {"length", "interrupted", "error", "incomplete"}:
                raise ValueError("Compaction did not produce a complete summary; prior context retained.")
            summaries.append(summary)
        summary = "\n\n".join(summaries)
        candidate = [system, {"role": "user", "content": snapshot, "_locus_context": True},
                     {"role": "user", "content": "Summary of earlier exploration:\n" + summary,
                      "_locus_context": True, "_compaction_summary": True}, *tail]
        if token_estimate(json.dumps(candidate)) + core._tool_schema_tokens() + core._reply_room() >= available:
            raise ValueError("The preserved context still exceeds the model window; prior context retained.")
        core.session.append_strict({"type": "compacted_context", "messages": candidate[1:],
                                    "plan": core.tool_ctx.plan_document})
        core.messages = candidate
        core._measured_prompt_tokens = 0
        core._clear_chatgpt_thread()
        core._emit_info()
        return {"command": "compact", "text": "Conversation compacted; task instructions and evidence references preserved.",
                "data": {"summary": summary}}
    except Exception as exc:
        core.messages = original
        return {"command": "compact", "error": str(exc), "text": str(exc)}


def runtime_context(core: Any) -> str:
    """Dynamic input shared by native/classical routes; never a session fingerprint."""
    if core.identity_mode:
        return ""
    runtime, capsule = getattr(core, "goal_runtime", None), getattr(core, "capsule_runtime", None)
    if runtime is None and capsule is None:
        return protected_context(core) if core.provider == "chatgpt" and core._turn_allows_tools else ""
    from .sessions import SessionStore
    inputs = SessionStore.authoritative_inputs(core.session.path)
    state = {"requests_and_corrections": [m["content"] for m in inputs],
             "goal": runtime.snapshot() if runtime is not None else None,
             "capsule": capsule.context() if capsule is not None else None,
             "unresolved_failures": SessionStore.unresolved_failures(core.session.path)}
    if runtime is not None:
        from .task_state import TaskStateStore
        store = TaskStateStore(runtime.store.run_store)
        record = store.get("goal:" + runtime.goal_id)
        if record:
            record["inputs"] = inputs
            store.save(record, expected_revision=record["revision"])
    return "Current durable task state. Later user corrections supersede earlier instructions.\n" + json.dumps(state, ensure_ascii=False)


def summarize_section(core: Any, messages: list[dict]) -> Any:
    """Use the selected route, including the native route, with ordinary metering."""
    if core.provider != "chatgpt":
        reservation = core.goal_runtime.reserve() if core.goal_runtime is not None else None
        response = core.client.chat_stream(core.model, messages, options=core.chat_options(),
                                           should_stop=core._interrupt.is_set)
        if reservation:
            core.goal_runtime.settle(reservation, response)
        return response
    from .codex_app_server import CodexThreadOptions
    from .ollama import ChatResponse
    manager = core.codex_manager
    if manager is None:
        raise ValueError("The selected native account is unavailable for compaction.")
    thread = manager.start_thread(model=core.model, cwd=core.cwd, base_instructions=messages[0]["content"],
                                  tools=[], options=CodexThreadOptions(include_environment_context=False))
    parts, usage, seen = [], {"calls": 0, "input": 0, "output": 0}, set()
    incomplete = False

    def observe(event: dict) -> None:
        nonlocal incomplete
        method, params = event.get("method"), event.get("params") or {}
        if method == "item/agentMessage/delta":
            parts.append(str(params.get("delta") or ""))
        elif method == "thread/tokenUsage/updated":
            tokens = params.get("tokenUsage") or {}
            total = tokens.get("total") or {}
            key = (total.get("inputTokens"), total.get("outputTokens"))
            if any(key) and key in seen:
                return
            seen.add(key)
            last = tokens.get("last") or total
            usage["calls"] += 1
            usage["input"] += max(int(last.get("inputTokens") or 0), 0)
            usage["output"] += max(int(last.get("outputTokens") or 0), 0)
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            incomplete = turn.get("status") not in {None, "completed"}
    options = dict(thread_id=thread, text=messages[1]["content"], model=core.model,
                   tool_handler=None, event_handler=observe, should_interrupt=core._interrupt.is_set)
    try:
        result = (core.goal_runtime.run_native(manager.run_turn, **options)
                  if core.goal_runtime is not None else manager.run_turn(**options))
        incomplete = incomplete or result.get("status") not in {None, "completed"} or core._interrupt.is_set()
    except Exception:
        incomplete = True
    return ChatResponse(content_parts=parts, prompt_eval_count=usage["input"], eval_count=usage["output"],
                        done_reason="interrupted" if incomplete else "stop",
                        provider_fields={"locus_model_calls": max(usage["calls"], 1)})


def token_estimate(text: str) -> int:
    # Conservative local estimate: includes UTF-8 byte cost for non-ASCII text.
    return (len(text.encode("utf-8")) + 2) // 3


def bounded_sections(text: str, byte_limit: int) -> list[str]:
    data, sections, offset = text.encode("utf-8"), [], 0
    while offset < len(data):
        end = min(offset + byte_limit, len(data))
        while end < len(data) and data[end] & 0xC0 == 0x80:
            end -= 1
        sections.append(data[offset:end].decode("utf-8"))
        offset = end
    return sections
