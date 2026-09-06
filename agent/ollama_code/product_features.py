"""Small private seam for features selected when the app is built.

This is not an installable extension surface. The fixed product factory owns
the implementation; user settings and native capability messages cannot add it.
"""
from __future__ import annotations

from typing import Any


class ProductFeatures:
    """The standard product has no additional native tools or messages."""

    persisted_event_types: frozenset[str] = frozenset()

    def __init__(self, registry: Any) -> None:
        self.registry = registry
        self.service: Any = None

    def bind(self, service: Any) -> None:
        self.service = service

    def schemas(self) -> list[dict[str, Any]]:
        return []

    def owns(self, name: str) -> bool:
        return False

    def is_safe(self, name: str) -> bool:
        return False

    def tool_info(self, name: str) -> dict[str, Any] | None:
        return None

    def metadata(self) -> list[dict[str, Any]]:
        result = []
        for schema in self.schemas():
            function = schema["function"]
            result.append({
                "name": function["name"],
                "description": function["description"],
                "parameters": function["parameters"],
                **(self.tool_info(function["name"]) or {}),
                "active": True,
                "deferred": False,
            })
        return result

    def execute(self, name: str, arguments: dict[str, Any], request_id: str) -> str:
        return f"Error: unknown tool: {name}"

    def handle_message(self, message: dict[str, Any]) -> bool:
        return False

    def cancel_pending(self) -> None:
        pass
