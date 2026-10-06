"""Loss-aware compaction with a durable, separately preserved task snapshot."""
from __future__ import annotations

import json
import uuid
from typing import Any


def protected_context(core: Any, *, checkpoint: dict | None = None) -> str:
    from .sessions import SessionStore
    records = SessionStore.authoritative_inputs(core.session.path)
    saved = SessionStore.context_checkpoint(core.session.path)
    checkpoint = checkpoint if checkpoint is not None else (saved or {}).get("checkpoint")
    inputs = [m["content"] for m in records] if checkpoint is None else []
    for message in (core.messages[1:] if checkpoint is None else []):
        if (message.get("role") == "user" and not message.get("_locus_context")
                and not message.get("_compaction_summary")):
            text = message.get("content")
            if isinstance(text, str) and text and text not in inputs:
                inputs.append(text)
    if core.provider in {"chatgpt", "claude_plan"} and core.chatgpt_parity_active(core._turn_allows_tools):
        from .sessions import strip_prompt_decoration
        inputs = [strip_prompt_decoration(text) for text in inputs]
    sections = ["Current task context. Preserve the user's constraints; later corrections supersede earlier instructions."]
    if checkpoint is not None:
        sections.append("Unfinished-work checkpoint (pending memories are not approved facts):\n" + json.dumps(checkpoint, ensure_ascii=False))
        inputs = [m["content"] for m in records]
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
    from . import context_cleanup
    if core.identity_mode:
        return {"command": "compact", "error": "identity_mode",
                "text": "Identity chat context cannot be saved or cleaned."}
    history = [m for m in core.messages[1:] if m.get("role") in {"user", "assistant", "tool"}
               and not m.get("_locus_context")]
    if len(history) < 2:
        return {"command": "compact", "text": "Nothing to clean yet."}
    attempt_id = uuid.uuid4().hex
    operation = None
    committed = False
    outcomes = []
    try:
        operation = context_cleanup.prepare(core)
        checkpoint = dict(operation["checkpoint"])
        # Existing task/goal stores remain authoritative. The checkpoint holds
        # references and a concise working summary, never invented completion.
        runtime, capsule = getattr(core, "goal_runtime", None), getattr(core, "capsule_runtime", None)
        checkpoint["task_state"] = {
            "goal": runtime.snapshot() if runtime is not None else None,
            "capsule": capsule.context() if capsule is not None else None,
            "plan": core.tool_ctx.plan_document,
        }
        system = core.system_message()
        available = core.context_limit or 128000
        user_positions = [i for i, m in enumerate(history) if m.get("role") == "user"]
        tail = history[user_positions[-2]:] if len(user_positions) > 2 else []
        active_text = {item["content"] for item in checkpoint["active_constraints"]}
        if any(m.get("role") == "user" and m.get("content") not in active_text for m in tail):
            # Replaying the original turn would restore a retired instruction.
            # Its still-active spans and evidence are already in the checkpoint.
            tail = []

        def replacement():
            # This packet already covers frozen input; do not replay those
            # same requests a second time through protected_context.
            from .sessions import SessionStore
            snapshot = "Current task checkpoint. Later corrections supersede earlier instructions. Pending or unresolved memories are not approved facts.\n" + json.dumps(checkpoint, ensure_ascii=False)
            failures = SessionStore.unresolved_failures(core.session.path)
            if failures:
                snapshot += "\nUnresolved tool failures:\n" + json.dumps(failures, ensure_ascii=False)
            snapshot += "\nFull source transcript: " + str(core.session.path)
            messages = [system, {"role": "user", "content": snapshot, "_locus_context": True},
                {"role": "user", "content": "Summary of earlier exploration:\n" + operation["summary"],
                 "_locus_context": True, "_compaction_summary": True}]
            overhead = core._tool_schema_tokens() + core._reply_room()
            if token_estimate(json.dumps(messages, ensure_ascii=False)) + overhead >= available:
                raise ValueError("Essential checkpoint exceeds this model's context; prior context retained. Choose a larger context or narrow the task.")
            if token_estimate(json.dumps([*messages, *tail], ensure_ascii=False)) + overhead < available:
                messages.extend(tail)
            return messages

        replacement()  # Do not write memories for an already impossible cleanup.
        outcomes = context_cleanup.save(core, operation)
        checkpoint["memory_outcomes"] = outcomes
        checkpoint["unresolved_memories"] = [{"content": item["content"], "status": outcome["status"],
            "reason": outcome.get("reason", "Awaiting memory review; do not treat as approved knowledge.")}
            for item, outcome in zip(operation["candidates"], outcomes, strict=True) if outcome.get("status") in {"pending", "unresolved"}]
        candidate = replacement()
        generation = context_cleanup.commit(core, operation, candidate, checkpoint, outcomes)
        committed = True
        counts = {"saved": sum(r.get("status") in {"approved", "already_saved"} for r in outcomes),
                  "pending": sum(r.get("status") == "pending" for r in outcomes),
                  "skipped": sum(r.get("status") in {"suppressed", "policy_disabled", "unresolved"} for r in outcomes)}
        data = {"summary": operation["summary"], "cleanup_operation_id": operation["operation_id"],
                "context_generation": generation, "checkpoint_status": "saved", "counts": counts,
                "outcomes": outcomes}
        # Observability is best effort after the durable commit; it cannot undo
        # committed context or report a failed cleanup after a successful fsync.
        try:
            core._emit({"type": "context_cleanup", **data, "summary": None})
            core._emit_info()
        except Exception:
            pass
        return {"command": "compact", "text": f"Chat context cleaned; {counts['saved']} memories saved, {counts['pending']} pending; unfinished work preserved.", "data": data}
    except Exception as exc:
        if committed:
            raise
        data = {"cleanup_operation_id": operation["operation_id"] if operation else attempt_id,
                "checkpoint_status": "not_committed", "outcomes": outcomes}
        if outcomes:
            data["counts"] = {"saved": sum(r.get("status") in {"approved", "already_saved"} for r in outcomes),
                "pending": sum(r.get("status") == "pending" for r in outcomes),
                "skipped": sum(r.get("status") in {"suppressed", "policy_disabled", "unresolved"} for r in outcomes)}
        try:
            core._emit({"type": "context_cleanup", "error": str(exc), **data})
        except Exception:
            pass
        return {"command": "compact", "error": str(exc),
                "text": "Cleanup failed — chat context retained. " + str(exc), "data": data}


def runtime_context(core: Any) -> str:
    """Dynamic input shared by native/classical routes; never a session fingerprint."""
    if core.identity_mode:
        return ""
    runtime, capsule = getattr(core, "goal_runtime", None), getattr(core, "capsule_runtime", None)
    if runtime is None and capsule is None:
        return protected_context(core) if core.provider in {"chatgpt", "claude_plan"} and core._turn_allows_tools else ""
    from .sessions import SessionStore
    inputs = SessionStore.authoritative_inputs(core.session.path)
    checkpoint = (SessionStore.context_checkpoint(core.session.path) or {}).get("checkpoint")
    state = {"checkpoint": checkpoint, "requests_and_corrections": [m["content"] for m in inputs],
             "goal": runtime.snapshot() if runtime is not None else None,
             "capsule": capsule.context() if capsule is not None else None,
             "unresolved_failures": SessionStore.unresolved_failures(core.session.path)}
    if runtime is not None:
        from .task_state import TaskStateStore
        store = TaskStateStore(runtime.store.run_store)
        record = store.get("goal:" + runtime.goal_id)
        if record:
            record["inputs"] = [{"role": "user", "content": item["content"]}
                                for item in (checkpoint or {}).get("active_constraints", [])] + inputs
            store.save(record, expected_revision=record["revision"])
    return "Current durable task state. Later user corrections supersede earlier instructions.\n" + json.dumps(state, ensure_ascii=False)


def retrieval_query(core: Any, query: str) -> str:
    """Include unfinished work in the next permitted search, never start a round."""
    from .sessions import SessionStore
    session = getattr(core, "session", None)
    if getattr(core, "identity_mode", False) or not getattr(session, "path", None):
        return query
    checkpoint = (SessionStore.context_checkpoint(session.path) or {}).get("checkpoint") or {}
    hints = [checkpoint.get("objective", ""), *checkpoint.get("unfinished_work", []),
             *checkpoint.get("next_steps", [])]
    # A continuation has no useful search terms of its own. For a substantive
    # new question preserve its focused query; the model also receives the
    # checkpoint and can spend the existing refinement if evidence is missing.
    if query.strip().casefold().rstrip(".!?") in {"continue", "resume", "go on", "next", "carry on", "keep going", "proceed"}:
        return next((value.strip()[:2000] for value in hints if isinstance(value, str) and value.strip()), query)
    return query


def summarize_section(core: Any, messages: list[dict]) -> Any:
    """Use the selected route, including the native route, with ordinary metering."""
    if core.provider not in {"chatgpt", "claude_plan"}:
        from .task_usage_ledger import reserve_core, settle_core
        task_call = reserve_core(core, stage="compaction", messages=messages)
        reservation = core.goal_runtime.reserve() if core.goal_runtime is not None else None
        from .model_usage import tracked_chat
        response = tracked_chat(core, core.client, core.model, messages, purpose="compaction", options=core.chat_options(),
                                           should_stop=core._should_stop_stream)
        settle_core(task_call, response)
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
                   tool_handler=None, event_handler=observe, should_interrupt=core._should_stop_stream)
    try:
        from .model_usage import tracked_native
        from .task_usage_ledger import native_accounted
        def execute_native(**kwargs):
            return (core.goal_runtime.run_native(manager.run_turn, **kwargs)
                    if core.goal_runtime is not None else manager.run_turn(**kwargs))
        result = native_accounted(core, lambda **kwargs: tracked_native(core, execute_native, purpose="compaction", **kwargs), options, stage="compaction")
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
