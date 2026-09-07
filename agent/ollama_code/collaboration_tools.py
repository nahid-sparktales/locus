"""Provider-neutral contracts for session helpers and optional questions."""

from typing import Any


def schema(name: str, description: str, properties: dict[str, Any], required: list[str]):
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


ID = {"type": "string", "description": "Stable helper ID."}
TEXT = {"type": "string"}
COLLABORATION_SCHEMAS = [
    schema(
        "spawn_agent",
        "Start one scoped helper and return immediately. Continue independent work. Editing uses an isolated Git worktree; research cannot mutate. Helpers retain context for followups.",
        {
            "task": TEXT,
            "label": TEXT,
            "mode": {"type": "string", "enum": ["research", "edit"]},
            "tools": {"type": "array", "items": TEXT},
        },
        ["task", "mode"],
    ),
    schema("list_agents", "List this task's helpers and shared usage.", {}, []),
    schema(
        "read_agent",
        "Read bounded status, output, frozen result and validation evidence before integration.",
        {"agent_id": ID},
        ["agent_id"],
    ),
    schema(
        "send_agent_message",
        "Deliver information without starting an idle helper. Active helpers receive it at safe boundaries.",
        {"agent_id": ID, "text": TEXT},
        ["agent_id", "text"],
    ),
    schema(
        "followup_agent",
        "Continue a helper with retained conversation and the current run budget.",
        {"agent_id": ID, "text": TEXT},
        ["agent_id", "text"],
    ),
    schema(
        "interrupt_agent",
        "Interrupt one helper, preserving context and isolated changes.",
        {"agent_id": ID},
        ["agent_id"],
    ),
    schema(
        "resume_agent",
        "Resume an interrupted helper within the remaining shared budget.",
        {"agent_id": ID, "prompt": TEXT},
        ["agent_id"],
    ),
    schema(
        "wait_agents",
        "Wait for the first relevant update without model polling. Use the returned cursor; maximum 60 seconds.",
        {
            "agent_ids": {"type": "array", "items": ID},
            "after_cursor": {"type": "integer", "minimum": 0},
            "timeout_ms": {"type": "integer", "minimum": 0, "maximum": 60000},
        },
        [],
    ),
    schema(
        "integrate_agent",
        "Apply a reviewed frozen coding result to this task's checkout. Conflicts preserve both sides. Validate the combined changes afterward.",
        {"agent_id": ID, "result_id": TEXT},
        ["agent_id", "result_id"],
    ),
]
COLLABORATION_NAMES = {s["function"]["name"] for s in COLLABORATION_SCHEMAS}
ASK_QUESTION_ASYNC_SCHEMA = schema(
    "ask_question_async",
    "Ask 1–3 optional questions and immediately continue independent work. Each requires a frozen recommendation. Skip or 60 unpaused seconds applies recommendations to unanswered questions as assumptions, never approvals. Use ask_user_question for required decisions. Answers arrive later as new context. If no longer relevant, explicitly supersede using action=supersede, request_id and reason.",
    {
        "action": {"type": "string", "enum": ["ask", "supersede"]},
        "request_id": TEXT,
        "reason": TEXT,
        "questions": {
            "type": "array",
            "minItems": 1,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "id": TEXT,
                    "question": TEXT,
                    "header": TEXT,
                    "recommendation": {
                        "type": "string",
                        "description": "Exact recommended option label, or explicit default text for a free-text question.",
                    },
                    "options": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {"label": TEXT, "description": TEXT},
                            "required": ["label"],
                        },
                    },
                },
                "required": ["id", "question", "recommendation"],
            },
        },
    },
    [],
)
