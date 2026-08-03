"""Dynamic tool schemas and dispatch for built-ins, skills, and MCP tools."""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from .extensions import ExtensionError, ExtensionManager
from .tools import TOOL_SCHEMAS, ToolContext, execute_tool

_SAFE_EXTENSION_TOOLS = {"search_extension_tools", "load_skill", "read_skill_file"}


def _schema(
    name: str,
    description: str,
    properties: dict[str, Any],
    required: list[str],
) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
            },
        },
    }


EXTENSION_TOOL_SCHEMAS = [
    _schema(
        "search_extension_tools",
        "Search installed MCP tools and make matching tools available for the next step.",
        {
            "query": {
                "type": "string",
                "description": "Capability or action to find, such as 'search Linear issues'.",
            },
            "limit": {
                "type": "integer",
                "description": "Maximum matching tools to activate. Optional, default 8.",
            },
        },
        ["query"],
    ),
    _schema(
        "load_skill",
        "Load the complete instructions for an installed skill before following its workflow.",
        {
            "skill": {
                "type": "string",
                "description": "Skill id from the available-skills list, without the '$'.",
            },
        },
        ["skill"],
    ),
    _schema(
        "read_skill_file",
        "Read a text reference, template, or script belonging to a loaded skill.",
        {
            "skill": {"type": "string", "description": "Installed skill id."},
            "path": {"type": "string", "description": "Relative path inside the skill."},
        },
        ["skill", "path"],
    ),
]


def _qualified_tool_name(server_name: str, tool_name: str, server_id: str) -> str:
    def clean(value: str) -> str:
        return re.sub(r"[^a-zA-Z0-9_-]+", "_", value).strip("_")[:48] or "tool"

    base = f"mcp__{clean(server_name)}__{clean(tool_name)}"
    if len(base) <= 120:
        return base
    suffix = hashlib.sha256(f"{server_id}:{tool_name}".encode()).hexdigest()[:8]
    return f"{base[:111]}_{suffix}"


class ToolRegistry:
    """Per-core registry with per-turn deferred MCP activation."""

    def __init__(
        self,
        extensions: ExtensionManager,
        mcp: Any | None = None,
    ) -> None:
        self.extensions = extensions
        self.mcp = mcp
        self._mcp_by_qualified: dict[str, dict[str, Any]] = {}
        self._active_mcp: set[str] = set()
        self._recent_mcp: list[str] = []
        self._explicit_skill_context = ""
        self._loaded_skill_context: dict[str, str] = {}
        self._explicit_skill_ids: set[str] = set()
        self._workspace = extensions.cwd
        self.refresh()

    def refresh(self) -> None:
        self._mcp_by_qualified = {}
        if self.mcp is None:
            return
        discovered = sorted(
            self.mcp.available_tools(),
            key=lambda item: (str(item.get("server_id")), str(item.get("name"))),
        )
        candidates = [
            (_qualified_tool_name(
                str(tool.get("server_name") or "mcp"),
                str(tool.get("name") or "tool"),
                str(tool.get("server_id") or "mcp"),
            ), tool)
            for tool in discovered
        ]
        counts: dict[str, int] = {}
        for base, _ in candidates:
            counts[base] = counts.get(base, 0) + 1
        for base, tool in candidates:
            name = base
            if counts[base] > 1:
                suffix = hashlib.sha256(
                    f"{tool.get('server_id')}:{tool.get('name')}".encode()
                ).hexdigest()[:8]
                name = f"{base[:111]}_{suffix}"
            self._mcp_by_qualified[name] = {**tool, "qualified_name": name}

    def begin_turn(self, user_text: str, workspace: str) -> None:
        self._workspace = workspace
        self.extensions.set_cwd(workspace)
        self.refresh()
        self._active_mcp = {
            name for name in self._recent_mcp[:4] if name in self._mcp_by_qualified
        }
        self._active_mcp.update(
            name for name in self._mcp_by_qualified if name in user_text
        )
        contexts: list[str] = []
        explicit_skill_ids = self.extensions.explicit_skill_ids(user_text, workspace)
        self._explicit_skill_ids = set(explicit_skill_ids)
        for skill_id in explicit_skill_ids:
            try:
                contexts.append(
                    f"Explicitly activated skill ${skill_id}:\n"
                    + self.extensions.load_skill(skill_id, workspace)
                )
            except ExtensionError:
                continue
        self._explicit_skill_context = "\n\n".join(contexts)

    def end_turn(self) -> None:
        self._active_mcp.clear()
        self._explicit_skill_context = ""
        self._explicit_skill_ids.clear()
        self._loaded_skill_context.clear()

    @property
    def explicit_skill_context(self) -> str:
        loaded = "\n\n".join(
            f"Loaded skill ${skill_id}:\n{text}"
            for skill_id, text in self._loaded_skill_context.items()
        )
        return "\n\n".join(
            section for section in (self._explicit_skill_context, loaded) if section
        )

    def skill_index(self, context_window: int) -> str:
        return self.extensions.skill_index(context_window, self._workspace)

    def schemas(self) -> list[dict[str, Any]]:
        schemas = [*TOOL_SCHEMAS, *EXTENSION_TOOL_SCHEMAS]
        for name in sorted(self._active_mcp):
            tool = self._mcp_by_qualified.get(name)
            if not tool:
                continue
            input_schema = tool.get("input_schema")
            if not isinstance(input_schema, dict):
                input_schema = {"type": "object", "properties": {}}
            schemas.append({
                "type": "function",
                "function": {
                    "name": name,
                    "description": str(tool.get("description") or tool.get("title") or name)[:4_000],
                    "parameters": input_schema,
                },
            })
        return schemas

    def schema_tokens(self) -> int:
        return len(json.dumps(self.schemas(), separators=(",", ":"))) // 4

    def execute(self, name: str, arguments: dict[str, Any], ctx: ToolContext) -> str:
        if name == "search_extension_tools":
            return self._search(arguments)
        if name == "load_skill":
            skill_id = str(arguments.get("skill") or "")
            selected = next(
                (
                    item for item in self.extensions.skills(self._workspace)
                    if item.get("id") == skill_id or item.get("name") == skill_id
                ),
                None,
            )
            if selected and selected.get("allow_implicit_invocation") is False \
                    and str(selected.get("id")) not in self._explicit_skill_ids:
                return f"Error: skill ${selected.get('id')} requires an explicit user mention."
            try:
                instructions = self.extensions.load_skill(skill_id, self._workspace)
                resolved_id = str(selected.get("id")) if selected else skill_id
                self._loaded_skill_context[resolved_id] = instructions
                return (
                    f"Loaded skill ${resolved_id} for this turn. Its instructions are now "
                    "available in the ephemeral extension context."
                )
            except ExtensionError as exc:
                return f"Error: {exc}"
        if name == "read_skill_file":
            requested = str(arguments.get("skill") or "")
            selected = next(
                (
                    item for item in self.extensions.skills(self._workspace)
                    if item.get("id") == requested or item.get("name") == requested
                ),
                None,
            )
            resolved_id = str(selected.get("id")) if selected else requested
            if resolved_id not in self._loaded_skill_context \
                    and resolved_id not in self._explicit_skill_ids:
                return f"Error: load skill ${resolved_id} before reading its supporting files."
            try:
                return self.extensions.read_skill_file(
                    resolved_id,
                    str(arguments.get("path") or ""),
                    self._workspace,
                )
            except (ExtensionError, OSError) as exc:
                return f"Error: {exc}"
        tool = self._mcp_by_qualified.get(name)
        if tool is not None:
            if self.mcp is None:
                return "Error: MCP runtime is unavailable."
            self._recent_mcp = [name, *[item for item in self._recent_mcp if item != name]][:8]
            return self.mcp.call_tool(
                str(tool["server_id"]), str(tool["name"]), arguments, ctx.should_stop
            )
        return execute_tool(name, arguments, ctx)

    def _search(self, arguments: dict[str, Any]) -> str:
        query = str(arguments.get("query") or "").strip().lower()
        if not query:
            return "Error: 'query' is required."
        try:
            limit = max(1, min(int(arguments.get("limit") or 8), 20))
        except (TypeError, ValueError):
            limit = 8
        terms = [term for term in re.split(r"\W+", query) if term]
        scored: list[tuple[int, str, dict[str, Any]]] = []
        for name, tool in self._mcp_by_qualified.items():
            haystack = " ".join(
                str(tool.get(key) or "")
                for key in ("server_name", "name", "title", "description")
            ).lower()
            score = sum(3 if term in str(tool.get("name") or "").lower() else 1 for term in terms if term in haystack)
            if score:
                scored.append((score, name, tool))
        scored.sort(key=lambda item: (-item[0], item[1]))
        selected = scored[:limit]
        if not selected:
            return f"No installed MCP tools match '{query}'."
        lines = ["Activated MCP tools for the next model step:"]
        for _, name, tool in selected:
            self._active_mcp.add(name)
            lines.append(
                f"- {name}: {str(tool.get('description') or tool.get('title') or '').strip()}"
            )
        return "\n".join(lines)

    def is_safe(self, name: str) -> bool:
        if name in _SAFE_EXTENSION_TOOLS:
            return True
        tool = self._mcp_by_qualified.get(name)
        if not tool:
            return False
        policy = str(tool.get("approval_mode") or "annotations").lower()
        if policy == "allow":
            return True
        if policy in {"ask", "prompt", "disabled"}:
            return False
        annotations = tool.get("annotations") if isinstance(tool.get("annotations"), dict) else {}
        return (
            annotations.get("readOnlyHint") is True
            and annotations.get("destructiveHint") is not True
            and annotations.get("openWorldHint") is False
        )

    def tool_info(self, name: str) -> dict[str, Any] | None:
        if name in _SAFE_EXTENSION_TOOLS:
            return {"origin": "extension", "annotations": {"readOnlyHint": True}}
        tool = self._mcp_by_qualified.get(name)
        if tool:
            return {
                "origin": "mcp",
                "server_id": tool.get("server_id"),
                "server_name": tool.get("server_name"),
                "tool_name": tool.get("name"),
                "annotations": tool.get("annotations") or {},
                "schema_digest": tool.get("schema_digest"),
                "server_fingerprint": tool.get("server_fingerprint"),
                "approval_mode": tool.get("approval_mode"),
            }
        return None

    def metadata(self) -> list[dict[str, Any]]:
        active = self._active_mcp
        out: list[dict[str, Any]] = []
        for schema in [*TOOL_SCHEMAS, *EXTENSION_TOOL_SCHEMAS]:
            fn = schema["function"]
            out.append({
                "name": fn["name"],
                "description": fn["description"],
                "parameters": fn["parameters"],
                "origin": "builtin" if schema in TOOL_SCHEMAS else "extension",
                "active": True,
                "deferred": False,
                "annotations": {"readOnlyHint": fn["name"] in _SAFE_EXTENSION_TOOLS},
            })
        for name, tool in sorted(self._mcp_by_qualified.items()):
            out.append({
                "name": name,
                "description": str(tool.get("description") or ""),
                "parameters": tool.get("input_schema") or {},
                "origin": "mcp",
                "server_id": tool.get("server_id"),
                "server_name": tool.get("server_name"),
                "active": name in active,
                "deferred": name not in active,
                "annotations": tool.get("annotations") or {},
                "schema_digest": tool.get("schema_digest"),
                "server_fingerprint": tool.get("server_fingerprint"),
                "approval_mode": tool.get("approval_mode"),
            })
        return out


__all__ = ["EXTENSION_TOOL_SCHEMAS", "ToolRegistry"]
