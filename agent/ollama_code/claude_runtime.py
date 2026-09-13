"""Subscription transport using Anthropic's SDK, with Locus-owned tools.

The event contract matches the existing managed-turn adapter (whose internal
names predate multiple subscription providers). No OAuth token is read by Locus.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import queue
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from .capabilities import enabled
from .codex_app_server import CodexAppServerError, CodexBrokerClient
from .paths import APP_DIR
from .proxy import sanitized_child_environment

SDK_VERSION = "0.2.152"
RUNTIME_VERSION = "2.1.259"
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class ClaudeRuntimeError(CodexAppServerError):
    pass


def claude_home_for_account(account_id: str) -> Path:
    if not isinstance(account_id, str) or not _ID.fullmatch(account_id):
        raise ValueError("A valid Claude account identifier is required")
    return APP_DIR / "claude-accounts" / account_id


def subscription_environment(home: Path) -> dict[str, str]:
    env = sanitized_child_environment()
    # API keys, alternate hosts, cloud billing and token overrides must never
    # take precedence over the runtime's own subscription login.
    for key in list(env):
        if key.startswith(("ANTHROPIC_", "CLAUDE_", "AWS_", "GOOGLE_", "AZURE_", "LOCUS_")):
            env.pop(key, None)
    # SDK subprocesses merge options.env over os.environ; explicit tombstones
    # are required to remove inherited values there as well as in auth commands.
    for key in os.environ:
        if key not in env:
            env[key] = ""
    env.update(CLAUDE_CONFIG_DIR=str(home), DISABLE_AUTOUPDATER="1")
    return env


class ClaudeManager:
    supports_parity = False
    provider = "claude_plan"

    def __init__(self, account_id: str):
        self.home = claude_home_for_account(account_id)
        self.account_id = account_id
        self.path = os.environ.get("LOCUS_CLAUDE_RUNTIME_PATH", "")
        self.runtime_version = "claude-sdk-" + SDK_VERSION
        self._listeners: list = []
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.RLock()
        self._login: tuple[str, subprocess.Popen] | None = None
        self._limits: dict[str, Any] = {}
        self._stops: set[threading.Event] = set()
        self._verified_binary = None

    @property
    def available(self):
        return (enabled("claude_plan_v1") and bool(self.path)
                and os.path.isfile(self.path) and os.access(self.path, os.X_OK)
                and importlib.util.find_spec("claude_agent_sdk") is not None)

    def _ready(self):
        if not self.available:
            raise ClaudeRuntimeError("Claude plan support is disabled or its runtime is not installed.")
        from importlib.metadata import version
        if version("claude-agent-sdk") != SDK_VERSION:
            raise ClaudeRuntimeError("The Claude SDK version does not match this Locus release.")
        stamp = (os.stat(self.path).st_mtime_ns, os.stat(self.path).st_size)
        if stamp != self._verified_binary:
            try:
                result = subprocess.run([self.path, "--version"], capture_output=True, text=True, timeout=15,
                                        env=subscription_environment(self.home))
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ClaudeRuntimeError("Claude could not start. Retry installing its runtime.") from error
            if result.returncode or not result.stdout.startswith(RUNTIME_VERSION + " "):
                raise ClaudeRuntimeError("The installed Claude runtime is incompatible. Install the matching component.")
            self._verified_binary = stamp
        self.home.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.home.chmod(0o700)

    def add_listener(self, listener):
        self._listeners.append(listener)

    def _notify(self, method):
        for listener in self._listeners:
            listener({"method": method, "params": {"account_id": self.account_id}})

    def _auth(self, operation):
        self._ready()
        try:
            result = subprocess.run([self.path, "auth", operation], env=subscription_environment(self.home),
                                    capture_output=True, text=True, timeout=30, cwd=str(self.home))
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ClaudeRuntimeError("Claude authentication could not finish. Refresh the account and retry.") from error
        if operation == "logout":
            if result.returncode:
                raise ClaudeRuntimeError("Claude sign-out failed.")
            return {}
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError) as error:
            raise ClaudeRuntimeError("Claude returned an unreadable authentication status.") from error

    def account(self, *, refresh=False):
        del refresh  # The official runtime owns token refresh.
        raw = self._auth("status")
        signed = raw.get("loggedIn") is True and raw.get("authMethod") == "claude.ai"
        return {"account": ({"type": self.provider, "email": raw.get("email"),
                             "planType": raw.get("subscriptionType")} if signed else None),
                "runtimeVersion": self.runtime_version}

    def start_login(self, **_):
        self._ready()
        with self._guard:
            if self._login and self._login[1].poll() is None:
                raise ClaudeRuntimeError("Claude sign-in is already in progress.")
            login_id = uuid.uuid4().hex
            try:
                process = subprocess.Popen([self.path, "auth", "login"],
                    env=subscription_environment(self.home), cwd=str(self.home),
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, bufsize=1)
            except OSError as error:
                raise ClaudeRuntimeError("Claude sign-in could not start. Refresh the account and retry.") from error
            self._login = (login_id, process)
        urls: queue.Queue = queue.Queue()

        def read_login():
            # Only return the official login URL, never persist subprocess output.
            try:
                for line in process.stdout:
                    match = re.search(r"https://(?:claude\.ai|platform\.claude\.com|console\.anthropic\.com)/[^\s\x1b]+", line)
                    if match:
                        urls.put(match.group(0))
                process.wait()
            finally:
                process.stdout.close()
                urls.put("")
                self._notify("account/login/completed")
        threading.Thread(target=read_login, daemon=True).start()
        try:
            url = urls.get(timeout=10)
        except queue.Empty:
            url = ""  # The runtime may have opened the system browser itself.
        return {"loginId": login_id, "authUrl": url}

    def cancel_login(self, login_id):
        with self._guard:
            if not self._login or self._login[0] != login_id:
                raise ClaudeRuntimeError("Unknown Claude sign-in attempt.")
            process = self._login[1]
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            self._login = None

    def logout(self):
        with self._guard:
            if self._stops:
                raise ClaudeRuntimeError("Stop this account's active tasks before signing out.")
            if self._login:
                self.cancel_login(self._login[0])
            self._auth("logout")
            self._limits = {}
        self._notify("account/updated")

    def models(self):
        self._ready()
        from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

        async def discover():
            async with ClaudeSDKClient(options=ClaudeAgentOptions(
                cli_path=self.path, cwd=str(self.home), env=subscription_environment(self.home),
                tools=[], setting_sources=[], strict_mcp_config=True,
            )) as client:
                return await client.get_server_info() or {}
        try:
            info = asyncio.run(asyncio.wait_for(discover(), timeout=30))
        except Exception:
            # The runtime's default remains usable when metadata is unavailable;
            # do not substitute an API catalog or guess effort capabilities.
            info = {}
        rows = info.get("models") or []
        return [{"model": row.get("value") or row.get("id"),
                 "displayName": row.get("displayName") or row.get("value"),
                 "description": (row.get("description") or "").split(" · $")[0],
                 "isDefault": row.get("value") == "default",
                 "supportedReasoningEfforts": [{"effort": value} for value in row.get("supportedEffortLevels", [])]
                    if row.get("supportsEffort") else []}
                for row in rows if isinstance(row, dict) and (row.get("value") or row.get("id"))] or [
                    {"model": "default", "displayName": "Claude default", "isDefault": True}]

    def usage(self):
        return dict(self._limits)

    def _file(self, thread_id):
        if not isinstance(thread_id, str) or not _ID.fullmatch(thread_id):
            raise ValueError("Invalid Claude session identifier")
        return self.home / "locus-sessions" / (thread_id + ".json")

    def _save(self, thread_id, state):
        path = self._file(thread_id)
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        with tmp.open("w") as stream:
            os.chmod(tmp, 0o600)
            json.dump(state, stream)
        tmp.replace(path)

    def _load(self, thread_id):
        try:
            state = json.loads(self._file(thread_id).read_text())
        except (OSError, ValueError) as error:
            raise ClaudeRuntimeError("Claude session is unavailable for this account.") from error
        if state.get("account_id") != self.account_id:
            raise ClaudeRuntimeError("Claude session belongs to another account.")
        return state

    def start_thread(self, *, model, cwd, base_instructions="", tools=(), **_):
        self._ready()
        thread_id = uuid.uuid4().hex
        self._save(thread_id, {"account_id": self.account_id, "model": model, "cwd": cwd,
            "instructions": base_instructions, "tools": list(tools), "sdk_session": None,
            "input": 0, "output": 0, "confirmed": [], "uncertain": False})
        return thread_id

    def resume_thread(self, thread_id, *, model, cwd, **_):
        state = self._load(thread_id)
        if state["uncertain"]:
            raise ClaudeRuntimeError("Claude's previous turn has an uncertain outcome; it was not replayed.")
        if state["model"] != model or state["cwd"] != cwd:
            raise ClaudeRuntimeError("Claude session settings changed.")
        return thread_id

    def read_thread(self, thread_id):
        state = self._load(thread_id)
        return {"thread": {"id": thread_id, "turns": [
            {"items": [{"type": "userMessage", "clientId": value}]} for value in state["confirmed"]]}}

    def steer_turn(self, *_, **__):
        # Queued guidance is delivered through the existing Locus outbox after
        # this turn completes. Never acknowledge input the SDK hasn't accepted.
        raise ClaudeRuntimeError("No active steer channel; guidance will run at the next turn boundary.")

    def run_turn(self, *, thread_id, text, model="", effort="", input_items=None,
                 client_message_id="", tool_handler=None, event_handler=None,
                 should_interrupt=None, on_tick=None, timeout=1800, output_schema=None, max_turns=40):
        self._ready()
        if should_interrupt and should_interrupt():
            turn = {"status": "interrupted"}
            if event_handler:
                event_handler({"method": "turn/completed", "params": {"threadId": thread_id, "turn": turn}})
            return turn
        with self._guard:
            lock = self._locks.setdefault(thread_id, threading.Lock())
        if not lock.acquire(blocking=False):
            raise ClaudeRuntimeError("This Claude session already has an active turn.")
        events: queue.Queue = queue.Queue()
        stop = threading.Event()
        with self._guard:
            self._stops.add(stop)
        try:
            state = self._load(thread_id)
            if state["uncertain"]:
                raise ClaudeRuntimeError("Claude's previous turn has an uncertain outcome; resume requires review.")
            def execute():
                try:
                    result = asyncio.run(self._execute(state, thread_id, text, input_items, effort,
                        output_schema, client_message_id, events, stop, timeout, max_turns))
                    events.put(("done", result))
                except Exception as error:
                    events.put(("error", error))
            worker = threading.Thread(target=execute, daemon=True)
            worker.start()
            deadline = time.monotonic() + timeout + 10
            while True:
                if should_interrupt and should_interrupt():
                    stop.set()
                if on_tick:
                    on_tick()
                if time.monotonic() > deadline:
                    stop.set()
                    raise ClaudeRuntimeError("Claude turn timed out; its outcome may be uncertain.")
                try:
                    kind, payload = events.get(timeout=.1)
                except queue.Empty:
                    continue
                if kind == "event" and event_handler:
                    event_handler(payload)
                elif kind == "tool":
                    name, arguments, call_id, reply = payload
                    try:
                        result = tool_handler(name, arguments, call_id) if tool_handler and not stop.is_set() else "Not run: tool access is unavailable."
                        reply.put({"content": [{"type": "text", "text": str(result)}],
                                   "isError": str(result).startswith(("Error", "Permission denied", "Not run:"))})
                    except Exception as error:
                        reply.put({"content": [{"type": "text", "text": str(error)}], "isError": True})
                elif kind == "error":
                    raise ClaudeRuntimeError(str(payload)) from payload
                elif kind == "done":
                    return payload
        finally:
            stop.set()
            if 'worker' in locals():
                worker.join(timeout=5)
            def release():
                with self._guard:
                    self._stops.discard(stop)
                lock.release()
            if 'worker' in locals() and worker.is_alive():
                # Never let another turn or logout race an SDK still unwinding.
                def release_after_worker():
                    worker.join()
                    release()
                threading.Thread(target=release_after_worker, daemon=True).start()
            else:
                release()

    async def _execute(self, state, thread_id, text, input_items, effort, output_schema,
                       client_id, events, stop, timeout, max_turns):
        from claude_agent_sdk import (
            ClaudeAgentOptions,
            ClaudeSDKClient,
            PermissionResultDeny,
            SdkMcpTool,
            create_sdk_mcp_server,
        )

        def emit(method, **params):
            events.put(("event", {"method": method, "params": {"threadId": thread_id, **params}}))

        sdk_tools = []
        for schema in state["tools"]:
            function = schema.get("function", schema)
            name = function["name"]

            async def call(arguments, name=name):
                if stop.is_set():
                    return {"content": [{"type": "text", "text": "Task interrupted."}], "isError": True}
                reply: queue.Queue = queue.Queue()
                events.put(("tool", (name, arguments, uuid.uuid4().hex, reply)))
                while not stop.is_set():
                    try:
                        return reply.get_nowait()
                    except queue.Empty:
                        await asyncio.sleep(.05)
                return {"content": [{"type": "text", "text": "Task interrupted."}], "isError": True}
            sdk_tools.append(SdkMcpTool(name=name, description=function.get("description", ""),
                input_schema=function.get("parameters", {"type": "object", "properties": {}}), handler=call))

        async def deny_native(*_):
            return PermissionResultDeny(message="Only Locus tools are available in this task.")

        options = ClaudeAgentOptions(cli_path=self.path, cwd=state["cwd"],
            env=subscription_environment(self.home), model=None if state["model"] == "default" else state["model"],
            system_prompt=state["instructions"], tools=[], setting_sources=[], strict_mcp_config=True,
            mcp_servers={"locus": create_sdk_mcp_server(name="locus", tools=sdk_tools)} if sdk_tools else {},
            allowed_tools=["mcp__locus__" + tool.name for tool in sdk_tools],
            can_use_tool=deny_native, permission_mode="dontAsk", include_partial_messages=True,
            resume=state["sdk_session"], effort=effort or None, max_turns=max(1, int(max_turns)),
            output_format={"type": "json_schema", "schema": output_schema} if output_schema else None)
        content = []
        for item in input_items or [{"type": "text", "text": text}]:
            if item.get("type") == "text":
                content.append({"type": "text", "text": item.get("text", "")})
            elif item.get("type") == "image":
                match = re.fullmatch(r"data:(image/[\w.+-]+);base64,(.+)", item.get("url", ""), re.S)
                if not match:
                    raise ClaudeRuntimeError("Claude attachments require validated image data.")
                content.append({"type": "image", "source": {"type": "base64", "media_type": match[1], "data": match[2]}})

        async def prompt():
            yield {"type": "user", "message": {"role": "user", "content": content}}

        async def run():
            async with ClaudeSDKClient(options=options) as client:
                async def monitor():
                    while not stop.is_set():
                        await asyncio.sleep(.1)
                    await client.interrupt()
                monitor_task = asyncio.create_task(monitor())
                try:
                    if stop.is_set():
                        turn = {"status": "interrupted"}
                        emit("turn/completed", turn=turn)
                        return turn
                    state["uncertain"] = True
                    self._save(thread_id, state)
                    await client.query(prompt())
                    message_id = uuid.uuid4().hex
                    blocks: dict[int, dict] = {}
                    result = None
                    account_error = None
                    async for message in client.receive_response():
                        kind = type(message).__name__
                        if kind == "SystemMessage" and message.subtype == "init":
                            state["sdk_session"] = message.data.get("session_id")
                            self._save(thread_id, state)
                        elif kind == "StreamEvent":
                            event = message.event
                            index = event.get("index", 0)
                            if event.get("type") == "message_start":
                                message_id = event.get("message", {}).get("id") or uuid.uuid4().hex
                                blocks = {}
                            elif event.get("type") == "content_block_start":
                                block = event.get("content_block", {})
                                blocks[index] = {"id": f"{message_id}-{index}", "type": block.get("type"), "text": ""}
                            elif event.get("type") == "content_block_delta":
                                block = blocks.get(index)
                                delta = event.get("delta", {})
                                if block and block["type"] in {"text", "thinking"}:
                                    value = delta.get("text") or delta.get("thinking") or ""
                                    block["text"] += value
                                    emit("item/agentMessage/delta" if block["type"] == "text" else "item/reasoning/summaryTextDelta",
                                         itemId=block["id"], delta=value)
                        elif kind == "AssistantMessage":
                            account_error = getattr(message, "error", None) or account_error
                            if account_error == "authentication_failed":
                                self._notify("account/updated")
                            elif account_error == "rate_limit":
                                self._limits = {"status": "rejected", "observed_at": time.time()}
                                self._notify("account/rateLimits/updated")
                            has_tools = any(type(block).__name__ == "ToolUseBlock" for block in message.content)
                            for index, block in enumerate(message.content):
                                block_kind = type(block).__name__
                                if block_kind not in {"TextBlock", "ThinkingBlock"}:
                                    continue
                                item_id = blocks.get(index, {}).get("id", f"{message_id}-{index}")
                                value = getattr(block, "text", None) or getattr(block, "thinking", "")
                                if index not in blocks:
                                    emit("item/agentMessage/delta" if block_kind == "TextBlock" else "item/reasoning/summaryTextDelta", itemId=item_id, delta=value)
                                item = {"id": item_id, "type": "agentMessage" if block_kind == "TextBlock" else "reasoning"}
                                if block_kind == "TextBlock":
                                    item.update(text=value, phase="commentary" if has_tools else "final_answer")
                                else:
                                    item["summary"] = [{"text": value}]
                                emit("item/completed", item=item)
                            blocks = {}
                            message_id = uuid.uuid4().hex
                        elif kind == "RateLimitEvent":
                            info = message.rate_limit_info
                            self._limits = {"status": info.status, "observed_at": time.time(),
                                "resets_at": info.resets_at, "utilization": info.utilization,
                                "window": info.rate_limit_type}
                            self._notify("account/rateLimits/updated")
                        elif kind == "ResultMessage":
                            result = message
                    if result is None:
                        raise ClaudeRuntimeError("Claude disconnected without a completed turn; outcome is uncertain.")
                    state["sdk_session"] = result.session_id
                    usage = result.usage or {}
                    inp = sum(int(usage.get(key) or 0) for key in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                    out = int(usage.get("output_tokens") or 0)
                    state["input"] += inp
                    state["output"] += out
                    state["uncertain"] = False
                    if client_id:
                        state["confirmed"].append(client_id)
                        emit("item/completed", item={"type": "userMessage", "clientId": client_id})
                    self._save(thread_id, state)
                    emit("thread/tokenUsage/updated", tokenUsage={"modelCalls": max(int(getattr(result, "num_turns", 1)), 1), "last": {"inputTokens": inp, "outputTokens": out},
                        "total": {"inputTokens": state["input"], "outputTokens": state["output"]}})
                    status = "interrupted" if stop.is_set() else "failed" if result.is_error else "completed"
                    turn = {"status": status}
                    if status == "failed":
                        guidance = {
                            "authentication_failed": "Claude authentication expired. Refresh this account in Manage Accounts or sign in again.",
                            "rate_limit": "This Claude subscription has reached its usage limit. Check this account's usage and retry after its limit resets.",
                            "billing_error": "Claude could not authorize this subscription. Check the selected account in Manage Accounts.",
                        }
                        turn["error"] = {"message": guidance.get(account_error) or "; ".join(result.errors or []) or "Claude turn failed."}
                    if result.structured_output is not None:
                        turn["structured_output"] = result.structured_output
                    emit("turn/completed", turn=turn)
                    return turn
                finally:
                    monitor_task.cancel()
                    await asyncio.gather(monitor_task, return_exceptions=True)
        return await asyncio.wait_for(run(), timeout=timeout)

    def complete(self, *, model, cwd, base_instructions, prompt, output_schema=None, timeout=300):
        thread_id = self.start_thread(model=model, cwd=cwd, base_instructions=base_instructions)
        text, usage = [], {}

        def collect(event):
            nonlocal usage
            if event["method"] == "item/agentMessage/delta":
                text.append(event["params"]["delta"])
            elif event["method"] == "thread/tokenUsage/updated":
                usage = event["params"]["tokenUsage"]
        turn = self.run_turn(thread_id=thread_id, text=prompt, output_schema=output_schema,
                             event_handler=collect, timeout=timeout)
        answer = json.dumps(turn["structured_output"]) if "structured_output" in turn else "".join(text)
        return {"text": answer, "turn": turn, "usage": usage, "threadId": thread_id}

    def close(self):
        with self._guard:
            for stop in self._stops:
                stop.set()
            if self._login:
                self.cancel_login(self._login[0])


class ClaudeBrokerClient(CodexBrokerClient):
    provider = "claude_plan"

    @property
    def runtime_version(self):
        return "claude-sdk-" + SDK_VERSION

    def for_account(self, home_id):
        claude_home_for_account(home_id)
        return ClaudeBrokerClient(self.url, self.token, home_id=home_id)

    def _request(self, operation, payload=None):
        request = super()._request(operation, payload)
        request["provider"] = "claude_plan"
        request["claude_account_id"] = self._home_id
        return request


class ClaudeManagerRegistry:
    def __init__(self):
        self._managers: dict[str, ClaudeManager] = {}
        self._guard = threading.Lock()
        self._listeners = []

    def manager(self, account_id):
        claude_home_for_account(account_id)
        with self._guard:
            if account_id not in self._managers:
                manager = ClaudeManager(account_id)
                for listener in self._listeners:
                    manager.add_listener(listener)
                self._managers[account_id] = manager
            return self._managers[account_id]

    def add_listener(self, listener):
        with self._guard:
            self._listeners.append(listener)
            for manager in self._managers.values():
                manager.add_listener(listener)

    def close_all(self):
        with self._guard:
            managers = list(self._managers.values())
        for manager in managers:
            manager.close()
