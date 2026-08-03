"""Long-lived MCP client sessions for Locus extensions."""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .extensions import ExtensionError, ExtensionManager
from .tools import MAX_OUTPUT, _truncate

EventHandler = Callable[[dict[str, Any]], None]


class MCPRuntimeUnavailable(RuntimeError):
    pass


def _fingerprint(server: dict[str, Any], credentials: dict[str, Any]) -> str:
    safe = {
        key: server.get(key)
        for key in (
            "id", "transport", "url", "command", "args", "cwd", "env", "env_vars",
            "http_headers", "env_http_headers", "enabled_tools", "disabled_tools",
            "startup_timeout_sec", "tool_timeout_sec", "approval_mode", "tool_policies",
        )
    }
    safe["credential_version"] = hashlib.sha256(
        json.dumps(credentials, sort_keys=True, default=str).encode()
    ).hexdigest() if credentials else ""
    return hashlib.sha256(json.dumps(safe, sort_keys=True, default=str).encode()).hexdigest()


def _substitute(value: str, server: dict[str, Any], workspace: str) -> str:
    replacements = {
        "${PLUGIN_ROOT}": str(server.get("plugin_root") or ""),
        "${PLUGIN_DATA}": str(server.get("plugin_data") or ""),
        "${LOCUS_WORKSPACE}": workspace,
        "${CLAUDE_PLUGIN_ROOT}": str(server.get("plugin_root") or ""),
        "${CLAUDE_PLUGIN_DATA}": str(server.get("plugin_data") or ""),
        "${CLAUDE_PROJECT_DIR}": workspace,
        "${CODEX_PLUGIN_ROOT}": str(server.get("plugin_root") or ""),
    }
    for source, target in replacements.items():
        value = value.replace(source, target)
    return value


class MCPManager:
    """Owns MCP sessions on one private asyncio loop.

    AgentCore is synchronous and itself runs in a worker thread.  Giving MCP a
    dedicated loop keeps its async transports alive between model calls while
    presenting a small synchronous dispatch surface to the core.
    """

    def __init__(
        self,
        extensions: ExtensionManager,
        emit: EventHandler | None = None,
    ) -> None:
        self.extensions = extensions
        self.emit = emit or (lambda _event: None)
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(
            target=self._run_loop,
            name="locus-mcp-runtime",
            daemon=True,
        )
        self._clients: dict[str, dict[str, Any]] = {}
        self._public_tools: list[dict[str, Any]] = []
        self._statuses: dict[str, dict[str, Any]] = {}
        self._guard = threading.RLock()
        self._closed = False
        self._started = False

    def _ensure_started(self) -> bool:
        with self._guard:
            if self._closed:
                return False
            if not self._started:
                self._thread.start()
                self._started = True
        return True

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()
        pending = asyncio.all_tasks(self._loop)
        for task in pending:
            task.cancel()
        if pending:
            self._loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
        self._loop.close()

    def set_event_handler(self, emit: EventHandler) -> None:
        self.emit = emit

    def refresh(self, *, wait: bool = True) -> None:
        if not self._ensure_started():
            return
        future = asyncio.run_coroutine_threadsafe(self._refresh(), self._loop)
        if wait:
            try:
                future.result(timeout=130)
            except Exception:
                future.cancel()

    async def _refresh(self) -> None:
        active = {
            str(server["id"]): server
            for server in self.extensions.mcp_servers()
            if server.get("active", True) and server.get("enabled", True)
        }
        for server_id in list(self._clients):
            server = active.get(server_id)
            credentials = self.extensions.credentials(server_id)
            if server is None or self._clients[server_id].get("fingerprint") != _fingerprint(server, credentials):
                await self._disconnect(server_id)
        for server_id, server in active.items():
            if server_id in self._clients:
                continue
            await self._connect(server)
        self._publish_tools()

    async def _connect(self, server: dict[str, Any]) -> None:
        server_id = str(server["id"])
        if server.get("transport") == "stdio" and self.extensions.sandboxed:
            self._set_status(server, "unsupported", "Local stdio MCP is unavailable in the App Store build.")
            return
        self._set_status(server, "connecting", None)
        credentials = self.extensions.credentials(server_id)
        transport_http = None
        client = None
        try:
            from mcp import Client, types

            async def message_handler(message: Any) -> None:
                if isinstance(message, types.ToolListChangedNotification):
                    if server_id in self._clients:
                        await self._load_tools(server_id)
                        self._publish_tools()
                        self.emit({
                            "type": "extensions_changed",
                            "reason": "mcp_tools_changed",
                            "server_id": server_id,
                        })
                elif isinstance(message, Exception):
                    self._set_status(server, "error", self._error_text(message))
            if server.get("transport") == "stdio":
                from mcp.client.stdio import (
                    StdioServerParameters,
                    get_default_environment,
                    stdio_client,
                )

                environment = get_default_environment()
                environment.update({
                    str(key): _substitute(str(value), server, self.extensions.cwd)
                    for key, value in (server.get("env") or {}).items()
                })
                for name in server.get("env_vars") or []:
                    if name in os.environ:
                        environment[str(name)] = os.environ[str(name)]
                environment.update({str(key): str(value) for key, value in (credentials.get("env") or {}).items()})
                plugin_data = str(server.get("plugin_data") or "")
                if plugin_data:
                    Path(plugin_data).mkdir(parents=True, exist_ok=True)
                params = StdioServerParameters(
                    command=_substitute(str(server.get("command") or ""), server, self.extensions.cwd),
                    args=[
                        _substitute(str(value), server, self.extensions.cwd)
                        for value in server.get("args") or []
                    ],
                    env=environment,
                    cwd=_substitute(str(server.get("cwd") or ""), server, self.extensions.cwd) or None,
                )
                transport = stdio_client(params)
            else:
                from mcp.client.streamable_http import streamable_http_client
                from mcp.shared._httpx_utils import create_mcp_http_client

                headers = {
                    str(key): _substitute(str(value), server, self.extensions.cwd)
                    for key, value in (server.get("http_headers") or {}).items()
                }
                for header, env_name in (server.get("env_http_headers") or {}).items():
                    if str(env_name) in os.environ:
                        headers[str(header)] = os.environ[str(env_name)]
                headers.update({str(key): str(value) for key, value in (credentials.get("headers") or {}).items()})
                access_token = str(credentials.get("access_token") or "")
                if not access_token:
                    token_env = str(server.get("bearer_token_env_var") or "")
                    access_token = os.environ.get(token_env, "") if token_env else ""
                if access_token:
                    headers["Authorization"] = f"Bearer {access_token}"
                transport_http = create_mcp_http_client(headers=headers)
                await transport_http.__aenter__()
                transport = streamable_http_client(
                    str(server.get("url") or ""), http_client=transport_http
                )
            client = Client(
                transport,
                read_timeout_seconds=float(server.get("tool_timeout_sec") or 60),
                message_handler=message_handler,
                cache=None,
            )
            await asyncio.wait_for(
                client.__aenter__(), timeout=float(server.get("startup_timeout_sec") or 10)
            )
            record = {
                "client": client,
                "http": transport_http,
                "server": server,
                "fingerprint": _fingerprint(server, credentials),
                "instructions": client.instructions,
                "tools": [],
            }
            self._clients[server_id] = record
            await self._load_tools(server_id)
            self._set_status(server, "connected", None, instructions=client.instructions)
        except Exception as exc:  # MCP transports expose several library-specific errors
            self._clients.pop(server_id, None)
            if client is not None:
                try:
                    await client.__aexit__(None, None, None)
                except Exception:
                    pass
            if transport_http is not None:
                try:
                    await transport_http.__aexit__(None, None, None)
                except Exception:
                    pass
            message = self._error_text(exc)
            state = "needs_auth" if self._looks_like_auth(message) else "error"
            self._set_status(server, state, message)
            if state == "needs_auth":
                self.emit({
                    "type": "mcp_auth_required",
                    "server_id": server_id,
                    "server_name": server.get("name"),
                    "message": message,
                })

    async def _load_tools(self, server_id: str) -> None:
        record = self._clients[server_id]
        client = record["client"]
        listed: list[Any] = []
        cursor = None
        while True:
            result = await client.list_tools(cursor=cursor, cache_mode="refresh")
            listed.extend(result.tools)
            cursor = getattr(result, "next_cursor", None)
            if not cursor or len(listed) >= 1_000:
                break
        server = record["server"]
        enabled = set(str(value) for value in server.get("enabled_tools") or [])
        disabled = set(str(value) for value in server.get("disabled_tools") or [])
        policies = server.get("tool_policies") if isinstance(server.get("tool_policies"), dict) else {}
        tools: list[dict[str, Any]] = []
        for tool in listed[:1_000]:
            if enabled and tool.name not in enabled:
                continue
            if tool.name in disabled:
                continue
            raw_policy = policies.get(tool.name)
            policy = str(
                raw_policy.get("approval_mode") if isinstance(raw_policy, dict) else raw_policy or ""
            ).lower()
            if policy == "disabled":
                continue
            annotations = (
                tool.annotations.model_dump(by_alias=True, exclude_none=True)
                if tool.annotations is not None else {}
            )
            input_schema = dict(tool.input_schema or {"type": "object", "properties": {}})
            serialized_schema = json.dumps(input_schema, sort_keys=True, default=str)
            if len(serialized_schema) > 256_000:
                input_schema = {
                    "type": "object",
                    "description": "The MCP server supplied an oversized schema; arguments require manual review.",
                    "additionalProperties": True,
                }
            schema_digest = hashlib.sha256(
                json.dumps({"input": serialized_schema, "annotations": annotations}, sort_keys=True).encode()
            ).hexdigest()
            tools.append({
                "server_id": server_id,
                "server_name": str(server.get("name") or server_id),
                "name": tool.name,
                "title": tool.title,
                "description": tool.description or "",
                "input_schema": input_schema,
                "output_schema": tool.output_schema,
                "annotations": annotations,
                "schema_digest": schema_digest,
                "approval_mode": policy or str(server.get("approval_mode") or "annotations").lower(),
                "server_fingerprint": record.get("fingerprint"),
            })
        record["tools"] = tools

    async def _disconnect(self, server_id: str) -> None:
        record = self._clients.pop(server_id, None)
        if not record:
            return
        try:
            await record["client"].__aexit__(None, None, None)
        except Exception:
            pass
        if record.get("http") is not None:
            try:
                await record["http"].__aexit__(None, None, None)
            except Exception:
                pass
        self._set_status(record["server"], "disconnected", None)

    def reconnect(self, server_id: str, *, wait: bool = True) -> None:
        server = next(
            (item for item in self.extensions.mcp_servers() if item.get("id") == server_id),
            None,
        )
        if server is None:
            raise ExtensionError("MCP server not found")
        if not server.get("active", True) or not server.get("enabled", True):
            raise ExtensionError("MCP server is disabled in this workspace")
        if not self._ensure_started():
            raise ExtensionError("MCP runtime is closed")
        future = asyncio.run_coroutine_threadsafe(self._reconnect(server), self._loop)
        if wait:
            try:
                future.result(timeout=float(server.get("startup_timeout_sec") or 10) + 5)
            except TimeoutError as exc:
                future.cancel()
                raise ExtensionError("MCP reconnect timed out") from exc

    async def _reconnect(self, server: dict[str, Any]) -> None:
        await self._disconnect(str(server["id"]))
        await self._connect(server)
        self._publish_tools()

    def call_tool(
        self,
        server_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        should_stop: Callable[[], bool] | None = None,
    ) -> str:
        if self._closed:
            return "Error: MCP runtime is closed."
        self._ensure_started()
        future = asyncio.run_coroutine_threadsafe(
            self._call_tool(server_id, tool_name, arguments), self._loop
        )
        record = self._clients.get(server_id)
        timeout = float((record or {}).get("server", {}).get("tool_timeout_sec") or 60) + 5
        deadline = time.monotonic() + timeout
        while True:
            if should_stop is not None and should_stop():
                future.cancel()
                return f"Error: MCP tool {tool_name} was cancelled by the user."
            try:
                return future.result(timeout=min(0.1, max(deadline - time.monotonic(), 0.01)))
            except TimeoutError as exc:
                if time.monotonic() < deadline:
                    continue
                future.cancel()
                return f"Error: MCP tool {tool_name} timed out: {self._error_text(exc)}"
            except Exception as exc:
                future.cancel()
                return f"Error: MCP tool {tool_name} failed: {self._error_text(exc)}"

    async def _call_tool(
        self, server_id: str, tool_name: str, arguments: dict[str, Any]
    ) -> str:
        record = self._clients.get(server_id)
        if record is None:
            await self._refresh()
            record = self._clients.get(server_id)
        if record is None:
            status = self._statuses.get(server_id) or {}
            return f"Error: MCP server is unavailable: {status.get('error') or 'not connected'}"
        tool = next((item for item in record["tools"] if item["name"] == tool_name), None)
        if tool is None:
            return f"Error: MCP tool is no longer available: {tool_name}"
        try:
            result = await record["client"].call_tool(
                tool_name,
                arguments,
                read_timeout_seconds=float(record["server"].get("tool_timeout_sec") or 60),
            )
        except Exception as exc:
            annotations = tool.get("annotations") or {}
            retryable = annotations.get("readOnlyHint") is True or annotations.get("idempotentHint") is True
            if not retryable:
                return (
                    f"Error: MCP call ended with an uncertain result and was not retried: "
                    f"{self._error_text(exc)}. Verify the external system before trying again."
                )
            server = dict(record["server"])
            await self._disconnect(server_id)
            await self._connect(server)
            replacement = self._clients.get(server_id)
            if replacement is None:
                return f"Error: MCP reconnect failed: {self._statuses.get(server_id, {}).get('error')}"
            try:
                result = await replacement["client"].call_tool(
                    tool_name,
                    arguments,
                    read_timeout_seconds=float(server.get("tool_timeout_sec") or 60),
                )
            except Exception as second:
                return f"Error: MCP tool failed after reconnect: {self._error_text(second)}"
        return self._format_result(result)

    @staticmethod
    def _format_result(result: Any) -> str:
        chunks: list[str] = []
        for item in getattr(result, "content", []) or []:
            kind = getattr(item, "type", "content")
            if kind == "text":
                chunks.append(str(getattr(item, "text", "")))
            elif kind == "resource":
                resource = getattr(item, "resource", None)
                text = getattr(resource, "text", None)
                uri = getattr(resource, "uri", "")
                chunks.append(str(text) if text is not None else f"[MCP resource: {uri}]")
            elif kind == "resource_link":
                chunks.append(
                    f"[MCP resource link: {getattr(item, 'name', '')} {getattr(item, 'uri', '')}]"
                )
            else:
                mime = getattr(item, "mime_type", "")
                chunks.append(f"[Unsupported MCP {kind} content{f' ({mime})' if mime else ''}]")
        structured = getattr(result, "structured_content", None)
        if structured is not None:
            chunks.append("Structured result:\n" + json.dumps(structured, indent=2, ensure_ascii=False, default=str))
        text = "\n\n".join(chunk for chunk in chunks if chunk).strip() or "(empty MCP result)"
        if bool(getattr(result, "is_error", False)) and not text.startswith("Error"):
            text = "Error: " + text
        return _truncate(text, MAX_OUTPUT)

    def available_tools(self) -> list[dict[str, Any]]:
        with self._guard:
            return [dict(item) for item in self._public_tools]

    def statuses(self) -> list[dict[str, Any]]:
        with self._guard:
            return [dict(value) for _, value in sorted(self._statuses.items())]

    def status(self, server_id: str) -> dict[str, Any] | None:
        with self._guard:
            value = self._statuses.get(server_id)
            return dict(value) if value else None

    def _publish_tools(self) -> None:
        tools = [dict(tool) for record in self._clients.values() for tool in record.get("tools", [])]
        with self._guard:
            self._public_tools = tools

    def _set_status(
        self,
        server: dict[str, Any],
        state: str,
        error: str | None,
        *,
        instructions: str | None = None,
    ) -> None:
        value = {
            "id": str(server.get("id")),
            "name": str(server.get("name") or server.get("id")),
            "state": state,
            "error": error,
            "instructions": instructions,
            "tool_count": len((self._clients.get(str(server.get("id"))) or {}).get("tools", [])),
        }
        with self._guard:
            self._statuses[value["id"]] = value
        self.emit({"type": "mcp_status", **value})

    @staticmethod
    def _looks_like_auth(message: str) -> bool:
        lowered = message.lower()
        return any(marker in lowered for marker in ("401", "403", "unauthorized", "forbidden", "oauth"))

    @staticmethod
    def _error_text(exc: BaseException) -> str:
        # ExceptionGroup is common at async transport boundaries. Flatten it
        # into one bounded, user-readable status rather than exposing a trace.
        nested = getattr(exc, "exceptions", None)
        if nested:
            parts = [MCPManager._error_text(item) for item in nested]
            return "; ".join(dict.fromkeys(part for part in parts if part))[:2_000]
        return (str(exc) or type(exc).__name__)[:2_000]

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if not self._started:
            self._loop.close()
            return
        try:
            future = asyncio.run_coroutine_threadsafe(self._close_all(), self._loop)
            future.result(timeout=8)
        except Exception:
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=3)

    async def _close_all(self) -> None:
        for server_id in list(self._clients):
            await self._disconnect(server_id)
        self._publish_tools()


__all__ = ["MCPManager", "MCPRuntimeUnavailable"]
