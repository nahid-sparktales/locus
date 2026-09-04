"""Validation, rendering, and deterministic simulation for automation workflows.

The workflow format is intentionally small and forward-only.  It is shared by
scheduled and event agents, persisted as an immutable execution snapshot, and
safe to evaluate without loading a model or invoking a connector.
"""
from __future__ import annotations

import copy
import json
import math
import re
from typing import Any

WORKFLOW_VERSION = 1
MAX_WORKFLOW_STEPS = 20
_IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
_CONNECTION_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
_TEMPLATE = re.compile(r"{{\s*([^{}]+?)\s*}}")
_OUTPUT_TYPES = {"string", "number", "boolean"}
_MODES = {"ask", "work", "plan", "grill"}
_OPERATORS = {
    "equals", "not_equals", "greater_than", "greater_than_or_equal",
    "less_than", "less_than_or_equal", "is_true", "is_false", "exists",
}
_TRIGGER_FIELDS: dict[str, str] = {
    "subject": "string",
    "text": "string",
    "sender": "string",
    "recipient": "string",
    "source": "string",
    "event_type": "string",
    "chat_id": "string",
    "message_type": "string",
    "occurred_at": "number",
    "scheduled_at": "number",
}
_MISSING = object()


class WorkflowValidationError(ValueError):
    """The workflow cannot be saved or executed safely."""


def implicit_workflow(instruction: str, mode: str = "work") -> dict[str, Any]:
    """Compile a legacy scalar prompt into the v1 in-memory representation."""
    return {
        "version": WORKFLOW_VERSION,
        "entry_step_id": "agent",
        "steps": [{
            "id": "agent",
            "type": "agent",
            "title": "Run agent",
            "instruction_template": str(instruction or ""),
            "mode": mode if mode in _MODES else "work",
            "outputs": [],
            "allowed_connection_ids": None,
            "next_step_id": None,
        }],
    }


def _clean_text(value: Any, label: str, *, maximum: int, required: bool = True) -> str:
    if not isinstance(value, str):
        raise WorkflowValidationError(f"{label} must be text")
    text = value.strip()
    if required and not text:
        raise WorkflowValidationError(f"{label} is required")
    if len(text) > maximum:
        raise WorkflowValidationError(f"{label} is too long")
    return text


def _identifier(value: Any, label: str) -> str:
    text = _clean_text(value, label, maximum=64)
    if not _IDENTIFIER.fullmatch(text):
        raise WorkflowValidationError(
            f"{label} must start with a letter and use only letters, numbers, _ or -"
        )
    return text


def _next_target(value: Any, label: str) -> str | None:
    if value is None or value == "finish":
        return None
    return _identifier(value, label)


def _connection_identifier(value: Any, label: str) -> str:
    text = _clean_text(value, label, maximum=160)
    if not _CONNECTION_IDENTIFIER.fullmatch(text):
        raise WorkflowValidationError(f"{label} is invalid")
    return text


def _json_scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, bool, int, float))


def _value_type(value: Any) -> str:
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    return "null" if value is None else "object"


def _reference_type(
    reference: str,
    *,
    current_index: int,
    step_indexes: dict[str, int],
    outputs: dict[str, dict[str, str]],
) -> str:
    parts = reference.split(".")
    if parts[0] == "trigger":
        if len(parts) == 2 and parts[1] in _TRIGGER_FIELDS:
            return _TRIGGER_FIELDS[parts[1]]
        if len(parts) >= 3 and parts[1] == "data" and all(parts[2:]):
            leaf = parts[-1].lower()
            if leaf in {"price", "amount", "value", "threshold", "count", "quantity"}:
                return "number"
            if leaf.startswith(("is_", "has_")):
                return "boolean"
            return "any"
        raise WorkflowValidationError(f"unknown template reference: {reference}")
    if len(parts) != 3 or parts[0] != "steps":
        raise WorkflowValidationError(f"unknown template reference: {reference}")
    step_id, field = parts[1], parts[2]
    if step_id not in step_indexes or step_indexes[step_id] >= current_index:
        raise WorkflowValidationError(
            f"reference {reference} must use an earlier Agent step"
        )
    field_type = outputs.get(step_id, {}).get(field)
    if field_type is None:
        raise WorkflowValidationError(f"unknown template reference: {reference}")
    return field_type


def _validate_template(
    template: str,
    *,
    label: str,
    current_index: int,
    step_indexes: dict[str, int],
    outputs: dict[str, dict[str, str]],
) -> None:
    # Stray braces usually mean a misspelled template; reject instead of
    # silently sending it to the model as prose.
    scrubbed = _TEMPLATE.sub("", template)
    if "{{" in scrubbed or "}}" in scrubbed:
        raise WorkflowValidationError(f"{label} contains an invalid template")
    for match in _TEMPLATE.finditer(template):
        _reference_type(
            match.group(1).strip(), current_index=current_index,
            step_indexes=step_indexes, outputs=outputs,
        )


def validate_workflow(
    value: Any,
    *,
    allowed_connection_ids: set[str] | None = None,
) -> dict[str, Any]:
    """Return a canonical v1 workflow or raise a user-facing validation error."""
    if not isinstance(value, dict):
        raise WorkflowValidationError("workflow must be an object")
    if value.get("version") != WORKFLOW_VERSION:
        raise WorkflowValidationError("workflow version must be 1")
    raw_steps = value.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        raise WorkflowValidationError("workflow must contain at least one step")
    if len(raw_steps) > MAX_WORKFLOW_STEPS:
        raise WorkflowValidationError(
            f"workflow cannot contain more than {MAX_WORKFLOW_STEPS} steps"
        )
    if not all(isinstance(item, dict) for item in raw_steps):
        raise WorkflowValidationError("every workflow step must be an object")
    if not any(item.get("type") == "agent" for item in raw_steps):
        raise WorkflowValidationError("workflow must contain at least one Agent step")

    step_ids = [_identifier(item.get("id"), "step id") for item in raw_steps]
    if len(set(step_ids)) != len(step_ids):
        raise WorkflowValidationError("workflow step ids must be unique")
    step_indexes = {step_id: index for index, step_id in enumerate(step_ids)}
    entry = _identifier(value.get("entry_step_id") or step_ids[0], "entry step id")
    if entry != step_ids[0]:
        raise WorkflowValidationError("entry_step_id must identify the first step")

    declared_outputs: dict[str, dict[str, str]] = {}
    for step_id, raw in zip(step_ids, raw_steps, strict=True):
        if raw.get("type") != "agent":
            continue
        fields: dict[str, str] = {}
        raw_outputs = raw.get("outputs", [])
        if not isinstance(raw_outputs, list):
            raise WorkflowValidationError(f"outputs for {step_id} must be an array")
        for item in raw_outputs:
            if not isinstance(item, dict):
                raise WorkflowValidationError(f"every output for {step_id} must be an object")
            name = _identifier(item.get("name"), f"output name in {step_id}")
            kind = str(item.get("type") or "")
            if kind not in _OUTPUT_TYPES:
                raise WorkflowValidationError(
                    f"output {step_id}.{name} must be string, number, or boolean"
                )
            if name in fields:
                raise WorkflowValidationError(f"output names in {step_id} must be unique")
            fields[name] = kind
        declared_outputs[step_id] = fields

    normalized_steps: list[dict[str, Any]] = []
    for index, (step_id, raw) in enumerate(zip(step_ids, raw_steps, strict=True)):
        kind = str(raw.get("type") or "")
        if kind not in {"agent", "condition", "approval"}:
            raise WorkflowValidationError(
                f"step {step_id} type must be agent, condition, or approval"
            )
        title = _clean_text(raw.get("title") or step_id, f"title for {step_id}", maximum=160)
        natural_next = step_ids[index + 1] if index + 1 < len(step_ids) else None

        def checked_target(
            raw_target: Any, label: str, *, default: str | None = None,
            step_index: int = index,
        ) -> str | None:
            target = default if raw_target is _MISSING else _next_target(raw_target, label)
            if target is not None:
                target_index = step_indexes.get(target)
                if target_index is None:
                    raise WorkflowValidationError(f"{label} points to an unknown step")
                if target_index <= step_index:
                    raise WorkflowValidationError(f"{label} must point to a later step")
            return target

        if kind == "agent":
            instruction = _clean_text(
                raw.get("instruction_template"), f"instruction for {step_id}", maximum=120_000
            )
            _validate_template(
                instruction, label=f"instruction for {step_id}", current_index=index,
                step_indexes=step_indexes, outputs=declared_outputs,
            )
            mode = str(raw.get("mode") or "work")
            if mode not in _MODES:
                raise WorkflowValidationError(f"mode for {step_id} is invalid")
            raw_connections = raw.get("allowed_connection_ids")
            if raw_connections is not None and not isinstance(raw_connections, list):
                raise WorkflowValidationError(
                    f"allowed connectors for {step_id} must be an array"
                )
            connections: list[str] | None = None
            if raw_connections is not None:
                connections = []
                for item in raw_connections:
                    connection_id = _connection_identifier(
                        item, f"connector id in {step_id}"
                    )
                    if (allowed_connection_ids is not None
                            and connection_id not in allowed_connection_ids):
                        raise WorkflowValidationError(
                            f"step {step_id} cannot widen access to connector {connection_id}"
                        )
                    if connection_id not in connections:
                        connections.append(connection_id)
            normalized_steps.append({
                "id": step_id, "type": kind, "title": title,
                "instruction_template": instruction, "mode": mode,
                "outputs": [
                    {"name": name, "type": field_type}
                    for name, field_type in declared_outputs[step_id].items()
                ],
                "allowed_connection_ids": connections,
                "next_step_id": checked_target(
                    raw["next_step_id"] if "next_step_id" in raw else _MISSING,
                    f"next step for {step_id}", default=natural_next
                ),
            })
            continue

        if kind == "approval":
            explanation = _clean_text(
                raw.get("explanation_template"), f"explanation for {step_id}", maximum=8_000
            )
            _validate_template(
                explanation, label=f"explanation for {step_id}", current_index=index,
                step_indexes=step_indexes, outputs=declared_outputs,
            )
            normalized_steps.append({
                "id": step_id, "type": kind, "title": title,
                "explanation_template": explanation,
                "approve_step_id": checked_target(
                    raw["approve_step_id"] if "approve_step_id" in raw else _MISSING,
                    f"approval target for {step_id}",
                    default=natural_next,
                ),
            })
            continue

        reference = _clean_text(raw.get("reference"), f"reference for {step_id}", maximum=200)
        reference_type = _reference_type(
            reference, current_index=index, step_indexes=step_indexes,
            outputs=declared_outputs,
        )
        operator = str(raw.get("operator") or "")
        if operator not in _OPERATORS:
            raise WorkflowValidationError(f"operator for {step_id} is invalid")
        compare_value = raw.get("compare_value")
        if operator not in {"exists", "is_true", "is_false"}:
            if not _json_scalar(compare_value) or compare_value is None:
                raise WorkflowValidationError(f"comparison value for {step_id} is required")
            compare_type = _value_type(compare_value)
            if reference_type != "any" and compare_type != reference_type:
                raise WorkflowValidationError(
                    f"condition {step_id} compares {reference_type} to {compare_type}"
                )
        if operator in {"is_true", "is_false"} and reference_type not in {"boolean", "any"}:
            raise WorkflowValidationError(f"condition {step_id} requires a Boolean reference")
        if operator.startswith(("greater", "less")) and reference_type not in {"number", "any"}:
            raise WorkflowValidationError(f"condition {step_id} requires a number reference")
        normalized_steps.append({
            "id": step_id, "type": kind, "title": title,
            "reference": reference, "operator": operator,
            "compare_value": compare_value,
            "true_step_id": checked_target(
                raw["true_step_id"] if "true_step_id" in raw else _MISSING,
                f"true target for {step_id}", default=natural_next
            ),
            "false_step_id": checked_target(
                raw["false_step_id"] if "false_step_id" in raw else _MISSING,
                f"false target for {step_id}"
            ),
        })
    normalized = {
        "version": WORKFLOW_VERSION, "entry_step_id": entry, "steps": normalized_steps,
    }
    incoming: dict[str, set[str]] = {step_id: set() for step_id in step_ids}
    reachable = {entry}
    frontier = [entry]
    while frontier:
        source_id = frontier.pop()
        source = next(step for step in normalized_steps if step["id"] == source_id)
        edge_names = {
            "agent": ("next_step_id",),
            "condition": ("true_step_id", "false_step_id"),
            "approval": ("approve_step_id",),
        }[source["type"]]
        for edge_name in edge_names:
            target = source.get(edge_name)
            if target is None:
                continue
            incoming[target].add(source_id)
            if len(incoming[target]) > 1:
                raise WorkflowValidationError(
                    f"step {target} is a join; workflow joins are not supported"
                )
            if target not in reachable:
                reachable.add(target)
                frontier.append(target)
    unreachable = [step_id for step_id in step_ids if step_id not in reachable]
    if unreachable:
        raise WorkflowValidationError(f"workflow step {unreachable[0]} is unreachable")
    return normalized


def step_by_id(workflow: dict[str, Any], step_id: str) -> dict[str, Any]:
    for step in workflow.get("steps", []):
        if step.get("id") == step_id:
            return step
    raise WorkflowValidationError(f"unknown workflow step: {step_id}")


def resolve_reference(reference: str, context: dict[str, Any]) -> Any:
    current: Any = context
    for part in reference.split("."):
        if not isinstance(current, dict) or part not in current:
            raise WorkflowValidationError(f"no value is available for {reference}")
        current = current[part]
    return current


def render_template(template: str, context: dict[str, Any]) -> str:
    def replace(match: re.Match[str]) -> str:
        value = resolve_reference(match.group(1).strip(), context)
        if isinstance(value, (dict, list)):
            return json.dumps(value, ensure_ascii=False, sort_keys=True)
        if isinstance(value, bool):
            return "true" if value else "false"
        return "" if value is None else str(value)
    return _TEMPLATE.sub(replace, template)


def validate_step_result(step: dict[str, Any], result: Any) -> dict[str, Any]:
    if not isinstance(result, dict):
        raise WorkflowValidationError("workflow result must be an object")
    declared = {item["name"]: item["type"] for item in step.get("outputs", [])}
    unknown = set(result) - set(declared)
    missing = set(declared) - set(result)
    if unknown:
        raise WorkflowValidationError(f"unknown workflow output: {sorted(unknown)[0]}")
    if missing:
        raise WorkflowValidationError(f"missing workflow output: {sorted(missing)[0]}")
    for name, expected in declared.items():
        actual = _value_type(result[name])
        if actual != expected:
            raise WorkflowValidationError(
                f"workflow output {name} must be {expected}, not {actual}"
            )
        if expected == "number" and not math.isfinite(float(result[name])):
            raise WorkflowValidationError(f"workflow output {name} must be finite")
    return copy.deepcopy(result)


def evaluate_condition(step: dict[str, Any], context: dict[str, Any]) -> bool:
    try:
        value = resolve_reference(str(step["reference"]), context)
        exists = True
    except WorkflowValidationError:
        value, exists = None, False
    operator = step["operator"]
    other = step.get("compare_value")
    if operator == "exists":
        return exists and value is not None
    if not exists:
        raise WorkflowValidationError(f"no value is available for {step['reference']}")
    if operator == "is_true":
        return value is True
    if operator == "is_false":
        return value is False
    if operator == "equals":
        return value == other
    if operator == "not_equals":
        return value != other
    if operator == "greater_than":
        return value > other
    if operator == "greater_than_or_equal":
        return value >= other
    if operator == "less_than":
        return value < other
    if operator == "less_than_or_equal":
        return value <= other
    raise WorkflowValidationError(f"unknown condition operator: {operator}")


def agent_prompt(step: dict[str, Any], context: dict[str, Any]) -> str:
    instruction = render_template(str(step["instruction_template"]), context)
    outputs = step.get("outputs") or []
    if not outputs:
        return instruction
    fields = ", ".join(f"{item['name']} ({item['type']})" for item in outputs)
    return (
        f"{instruction}\n\n"
        "This is one step in a Locus automation workflow. Before ending the turn, "
        "call submit_workflow_result exactly once with every declared field: "
        f"{fields}. A final answer alone does not complete this step."
    )


def simulate_workflow(
    workflow: Any,
    *,
    trigger: dict[str, Any] | None = None,
    mock_outputs: dict[str, Any] | None = None,
    allowed_connection_ids: set[str] | None = None,
) -> dict[str, Any]:
    """Walk one deterministic branch without calling models or creating history."""
    normalized = validate_workflow(
        workflow, allowed_connection_ids=allowed_connection_ids
    )
    context: dict[str, Any] = {"trigger": copy.deepcopy(trigger or {}), "steps": {}}
    mocks = mock_outputs or {}
    trace: list[dict[str, Any]] = []
    current: str | None = normalized["entry_step_id"]
    while current is not None:
        step = step_by_id(normalized, current)
        kind = step["type"]
        if kind == "agent":
            preview = agent_prompt(step, context)
            item: dict[str, Any] = {
                "step_id": current, "type": kind, "title": step["title"],
                "prompt": preview, "mode": step["mode"],
                "allowed_connection_ids": step["allowed_connection_ids"],
            }
            if current in mocks:
                result = validate_step_result(step, mocks[current])
                context["steps"][current] = result
                item["mock_result"] = result
            elif step.get("outputs"):
                item["needs_mock_outputs"] = True
                trace.append(item)
                return {"valid": True, "complete": False, "trace": trace, "context": context}
            trace.append(item)
            current = step.get("next_step_id")
        elif kind == "condition":
            outcome = evaluate_condition(step, context)
            trace.append({
                "step_id": current, "type": kind, "title": step["title"],
                "reference": step["reference"], "outcome": outcome,
            })
            current = step.get("true_step_id" if outcome else "false_step_id")
        else:
            trace.append({
                "step_id": current, "type": kind, "title": step["title"],
                "explanation": render_template(step["explanation_template"], context),
                "approve_step_id": step.get("approve_step_id"),
            })
            # A preview deliberately stops at the human decision boundary.
            return {"valid": True, "complete": False, "waiting_for_approval": True,
                    "trace": trace, "context": context}
    return {"valid": True, "complete": True, "trace": trace, "context": context}


__all__ = [
    "MAX_WORKFLOW_STEPS", "WORKFLOW_VERSION", "WorkflowValidationError",
    "agent_prompt", "evaluate_condition", "implicit_workflow", "render_template",
    "resolve_reference", "simulate_workflow", "step_by_id", "validate_step_result",
    "validate_workflow",
]
