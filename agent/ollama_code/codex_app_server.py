"""Managed OpenAI Codex App Server transport for ChatGPT-plan accounts.

The helper owns OAuth credentials and refreshes them itself. Locus communicates
over the documented JSONL/stdin protocol, never reads the token file, and never
turns a ChatGPT credential into an API bearer token.
"""
from __future__ import annotations

import json
import logging
import os
import queue
import re
import subprocess
import threading
import time
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

from .paths import APP_DIR

logger = logging.getLogger(__name__)

PINNED_CODEX_APP_SERVER_VERSION = "0.147.0"
_TOOL_NAME = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class CodexAppServerError(RuntimeError):
    """The bundled helper is unavailable or rejected a protocol request."""


class CodexProtocolMismatch(CodexAppServerError):
    """The helper exposed behavior outside Locus's pinned compatibility contract."""


def helper_path_from_environment() -> str:
    """Return the explicitly bundled helper path, with a development opt-in.

    Release builds always set ``LOCUS_CODEX_APP_SERVER_PATH``. The ChatGPT app
    fallback exists only for local source-tree development and is never used
    unless the developer explicitly opts in.
    """
    configured = os.environ.get("LOCUS_CODEX_APP_SERVER_PATH", "").strip()
    if configured:
        return configured
    if os.environ.get("LOCUS_CODEX_ALLOW_DEVELOPMENT_HELPER") == "1":
        candidate = "/Applications/ChatGPT.app/Contents/Resources/codex"
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""


def codex_home_from_environment() -> Path:
    configured = os.environ.get("LOCUS_CODEX_HOME", "").strip()
    return Path(configured).expanduser() if configured else APP_DIR / "codex"


_HOME_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def codex_home_for_account(home_id: str) -> Path:
    """The CODEX_HOME holding one ChatGPT account's credentials.

    Each account gets its own home because that directory *is* the identity:
    the helper keeps one signed-in account per home, so isolated homes are what
    make several ChatGPT plans usable side by side without either one's tokens
    being visible to the other.

    An empty id means the single pre-multi-account home. Keeping that mapping
    is what stops an upgrade from silently signing the existing user out.
    """
    base = codex_home_from_environment()
    slug = (home_id or "").strip()
    if not slug:
        return base
    # The id reaches here from the app over HTTP, and it is about to become a
    # path component. Anything that is not a plain identifier — a separator, a
    # traversal, a leading dot — is refused rather than sanitised into
    # something that silently points at a different account's credentials.
    if not _HOME_ID.match(slug):
        raise ValueError(f"invalid ChatGPT account home id: {slug!r}")
    return base.parent / f"{base.name}-accounts" / slug


def _thread_id(message: dict[str, Any]) -> str:
    params = message.get("params")
    if not isinstance(params, dict):
        return ""
    direct = params.get("threadId") or params.get("thread_id")
    if isinstance(direct, str):
        return direct
    thread = params.get("thread")
    if isinstance(thread, dict) and isinstance(thread.get("id"), str):
        return str(thread["id"])
    turn = params.get("turn")
    if isinstance(turn, dict) and isinstance(turn.get("threadId"), str):
        return str(turn["threadId"])
    return ""


def dynamic_tools(schemas: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Translate Locus/OpenAI function schemas to App Server dynamic tools."""
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in schemas:
        function = raw.get("function") if isinstance(raw, dict) else None
        if not isinstance(function, dict):
            raise CodexProtocolMismatch("Locus produced a non-function tool schema")
        name = str(function.get("name") or "")
        if not _TOOL_NAME.fullmatch(name):
            raise CodexProtocolMismatch(f"Locus tool name is not App Server compatible: {name!r}")
        if name in seen:
            raise CodexProtocolMismatch(f"Locus tool schema contains duplicate name: {name}")
        seen.add(name)
        schema = function.get("parameters")
        if not isinstance(schema, dict):
            schema = {"type": "object", "properties": {}, "additionalProperties": False}
        result.append({
            "type": "function",
            "name": name,
            "description": str(function.get("description") or "")[:8_192],
            "inputSchema": schema,
            "deferLoading": False,
        })
    return result


class CodexAppServerManager:
    """One multiplexed App Server process owned by the primary Locus backend."""

    def __init__(
        self,
        *,
        helper_path: str | None = None,
        codex_home: Path | None = None,
        client_version: str = "0",
    ) -> None:
        self.helper_path = helper_path if helper_path is not None else helper_path_from_environment()
        self.codex_home = codex_home or codex_home_from_environment()
        self.client_version = client_version
        self._process: subprocess.Popen[str] | None = None
        self._write_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._next_id = 1
        self._pending: dict[int | str, queue.Queue[dict[str, Any]]] = {}
        self._thread_queues: dict[str, list[queue.Queue[dict[str, Any]]]] = {}
        self._global_listeners: list[Callable[[dict[str, Any]], None]] = []
        self._stderr_tail = ""
        self._reader: threading.Thread | None = None
        self._stderr_reader: threading.Thread | None = None
        self._initialized: dict[str, Any] = {}

    @property
    def available(self) -> bool:
        return bool(
            self.helper_path
            and os.path.isfile(self.helper_path)
            and os.access(self.helper_path, os.X_OK)
        )

    @property
    def is_running(self) -> bool:
        process = self._process
        return process is not None and process.poll() is None

    @property
    def runtime_version(self) -> str:
        user_agent = str(self._initialized.get("userAgent") or "")
        return user_agent or PINNED_CODEX_APP_SERVER_VERSION

    @property
    def recent_error(self) -> str:
        return self._stderr_tail[-2_000:]

    def add_listener(self, listener: Callable[[dict[str, Any]], None]) -> None:
        with self._state_lock:
            self._global_listeners.append(listener)

    def remove_listener(self, listener: Callable[[dict[str, Any]], None]) -> None:
        with self._state_lock:
            self._global_listeners = [item for item in self._global_listeners if item != listener]

    def _prepare_home(self) -> None:
        self.codex_home.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self.codex_home.chmod(0o700)
        except OSError:
            pass
        config = self.codex_home / "config.toml"
        content = (
            'cli_auth_credentials_store = "file"\n'
            'check_for_update_on_startup = false\n'
            'web_search = "disabled"\n'
            'include_permissions_instructions = false\n'
            'include_apps_instructions = false\n'
            'include_collaboration_mode_instructions = false\n'
            'include_environment_context = false\n\n'
            '[analytics]\n'
            'enabled = false\n\n'
            '[features]\n'
            'shell_tool = false\n'
            'view_image = false\n'
            'unified_exec = false\n'
            'tool_suggest = false\n'
            'plugins = false\n'
            'goals = false\n'
            'apps = false\n'
            'multi_agent = false\n'
            'multi_agent_v2 = false\n'
            'standalone_web_search = false\n'
            'web_search_request = false\n'
            'web_search_cached = false\n\n'
            '[agents]\n'
            'enabled = false\n\n'
            '[skills]\n'
            'include_instructions = false\n\n'
            '[tools.update_plan]\n'
            'enabled = false\n\n'
            '[tools.experimental_request_user_input]\n'
            'enabled = false\n'
        )
        # This is an isolated Locus-owned CODEX_HOME. Rewrite only its policy
        # file so an app update cannot retain a looser, older tool inventory;
        # auth.json and the helper's other credential state are untouched.
        temporary = self.codex_home / "config.toml.locus.tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
        temporary.chmod(0o600)
        os.replace(temporary, config)

    def _command(self) -> list[str]:
        path = self.helper_path
        if not path:
            raise CodexAppServerError("The bundled ChatGPT helper is unavailable")
        name = Path(path).name
        args = [path]
        if name == "codex" or (name.startswith("codex-") and "app-server" not in name):
            args.append("app-server")
        args.extend(["--listen", "stdio://"])
        return args

    def _verify_version(self) -> None:
        if os.environ.get("LOCUS_CODEX_SKIP_VERSION_CHECK") == "1":
            return
        try:
            result = subprocess.run(
                [self.helper_path, "--version"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CodexAppServerError(f"Could not verify the ChatGPT helper: {error}") from error
        reported = (result.stdout + " " + result.stderr).strip()
        if result.returncode != 0 or PINNED_CODEX_APP_SERVER_VERSION not in reported:
            raise CodexProtocolMismatch(
                "ChatGPT runtime version mismatch: "
                f"expected {PINNED_CODEX_APP_SERVER_VERSION}, got {reported or 'unknown'}"
            )

    def ensure_started(self) -> None:
        with self._state_lock:
            if self.is_running:
                return
            if not self.available:
                raise CodexAppServerError("The bundled ChatGPT helper is unavailable")
            self._verify_version()
            self._prepare_home()
            environment = dict(os.environ)
            environment["CODEX_HOME"] = str(self.codex_home)
            environment.pop("OPENAI_API_KEY", None)
            environment.pop("LOCUS_REMOTE_API_KEY", None)
            try:
                process = subprocess.Popen(
                    self._command(),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    bufsize=1,
                    env=environment,
                )
            except OSError as error:
                raise CodexAppServerError(f"Could not launch the ChatGPT helper: {error}") from error
            self._process = process
            self._stderr_tail = ""
            self._reader = threading.Thread(
                target=self._read_loop, name="locus-codex-jsonl", daemon=True
            )
            self._stderr_reader = threading.Thread(
                target=self._read_stderr, name="locus-codex-stderr", daemon=True
            )
            self._reader.start()
            self._stderr_reader.start()
        try:
            initialized = self._rpc(
                "initialize",
                {
                    "clientInfo": {
                        "name": "locus",
                        "title": "Locus",
                        "version": self.client_version,
                    },
                    "capabilities": {"experimentalApi": True},
                },
                timeout=15,
            )
            self._initialized = initialized
            self.notify("initialized", {})
        except Exception:
            self.close()
            raise

    def _read_stderr(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        for line in process.stderr:
            # App Server logs may contain account identifiers. Keep only a
            # bounded diagnostic tail in memory and never persist it.
            self._stderr_tail = (self._stderr_tail + line)[-8_000:]

    def _read_loop(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        try:
            for raw_line in process.stdout:
                try:
                    message = json.loads(raw_line)
                except (TypeError, json.JSONDecodeError):
                    logger.warning("ignored malformed JSONL from ChatGPT helper")
                    continue
                if not isinstance(message, dict):
                    continue
                identifier = message.get("id")
                method = message.get("method")
                if identifier is not None and not isinstance(method, str):
                    with self._state_lock:
                        target = self._pending.get(identifier)
                    if target is not None:
                        target.put(message)
                    continue
                thread_id = _thread_id(message)
                delivered = False
                if thread_id:
                    with self._state_lock:
                        targets = list(self._thread_queues.get(thread_id, []))
                    for target in targets:
                        target.put(message)
                        delivered = True
                if identifier is not None and isinstance(method, str) and not delivered:
                    self.respond_error(identifier, -32601, "Locus rejected an unexpected helper request")
                with self._state_lock:
                    listeners = list(self._global_listeners)
                for listener in listeners:
                    try:
                        listener(message)
                    except Exception:  # noqa: BLE001 - observers cannot break transport
                        logger.exception("ChatGPT helper listener failed")
        finally:
            error = CodexAppServerError(
                self.recent_error.strip() or "The ChatGPT helper stopped unexpectedly"
            )
            with self._state_lock:
                pending = list(self._pending.values())
                thread_queues = [item for values in self._thread_queues.values() for item in values]
            failure = {"error": {"code": -32099, "message": str(error)}}
            for target in pending + thread_queues:
                target.put(failure)

    def _send(self, message: dict[str, Any]) -> None:
        process = self._process
        if process is None or process.poll() is not None or process.stdin is None:
            raise CodexAppServerError("The ChatGPT helper is not running")
        encoded = json.dumps(message, separators=(",", ":"), ensure_ascii=False)
        with self._write_lock:
            try:
                process.stdin.write(encoded + "\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError) as error:
                raise CodexAppServerError("The ChatGPT helper connection closed") from error

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def _rpc(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float = 30,
    ) -> dict[str, Any]:
        with self._state_lock:
            identifier = self._next_id
            self._next_id += 1
            target: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._pending[identifier] = target
        message: dict[str, Any] = {"method": method, "id": identifier}
        if params is not None:
            message["params"] = params
        try:
            self._send(message)
            try:
                response = target.get(timeout=timeout)
            except queue.Empty as error:
                raise CodexAppServerError(f"ChatGPT helper timed out during {method}") from error
        finally:
            with self._state_lock:
                self._pending.pop(identifier, None)
        failure = response.get("error")
        if isinstance(failure, dict):
            text = str(failure.get("message") or f"ChatGPT helper rejected {method}")
            raise CodexAppServerError(text)
        result = response.get("result")
        return result if isinstance(result, dict) else {}

    def request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float = 30,
    ) -> dict[str, Any]:
        self.ensure_started()
        return self._rpc(method, params, timeout=timeout)

    def respond(self, identifier: int | str, result: dict[str, Any]) -> None:
        self._send({"id": identifier, "result": result})

    def respond_error(self, identifier: int | str, code: int, message: str) -> None:
        self._send({"id": identifier, "error": {"code": code, "message": message}})

    def account(self, *, refresh: bool = False) -> dict[str, Any]:
        result = self.request("account/read", {"refreshToken": refresh})
        result["runtimeVersion"] = self.runtime_version
        return result

    def start_login(self) -> dict[str, Any]:
        return self.request(
            "account/login/start",
            {"type": "chatgpt", "useHostedLoginSuccessPage": True, "appBrand": "chatgpt"},
            timeout=30,
        )

    def cancel_login(self, login_id: str) -> None:
        self.request("account/login/cancel", {"loginId": login_id})

    def logout(self) -> None:
        self.request("account/logout")

    def models(self) -> list[dict[str, Any]]:
        data: list[dict[str, Any]] = []
        cursor: str | None = None
        while True:
            params: dict[str, Any] = {"limit": 100, "includeHidden": False}
            if cursor:
                params["cursor"] = cursor
            page = self.request("model/list", params)
            rows = page.get("data")
            if isinstance(rows, list):
                data.extend(item for item in rows if isinstance(item, dict))
            cursor = page.get("nextCursor") if isinstance(page.get("nextCursor"), str) else None
            if not cursor:
                return data

    def usage(self) -> dict[str, Any]:
        limits = self.request("account/rateLimits/read")
        activity = self.request("account/usage/read")
        return {"rateLimits": limits, "activity": activity}

    def _subscribe(self, thread_id: str) -> queue.Queue[dict[str, Any]]:
        target: queue.Queue[dict[str, Any]] = queue.Queue()
        with self._state_lock:
            self._thread_queues.setdefault(thread_id, []).append(target)
        return target

    def _unsubscribe(self, thread_id: str, target: queue.Queue[dict[str, Any]]) -> None:
        with self._state_lock:
            remaining = [item for item in self._thread_queues.get(thread_id, []) if item is not target]
            if remaining:
                self._thread_queues[thread_id] = remaining
            else:
                self._thread_queues.pop(thread_id, None)

    @staticmethod
    def parity_config() -> dict[str, Any]:
        return {
            "web_search": "disabled",
            # Request the provider's user-visible reasoning summary. Raw
            # reasoning deltas remain private and are never mapped to Locus.
            "model_reasoning_summary": "auto",
            "include_permissions_instructions": False,
            "include_apps_instructions": False,
            "include_collaboration_mode_instructions": False,
            "include_environment_context": False,
            "features": {
                "shell_tool": False,
                "view_image": False,
                "unified_exec": False,
                "tool_suggest": False,
                "plugins": False,
                "goals": False,
                "apps": False,
                "multi_agent": False,
                "multi_agent_v2": False,
                "standalone_web_search": False,
                "web_search_request": False,
                "web_search_cached": False,
            },
            "agents": {"enabled": False},
            "skills": {"include_instructions": False},
            "tools": {
                "update_plan": {"enabled": False},
                "experimental_request_user_input": {"enabled": False},
            },
        }

    def start_thread(
        self,
        *,
        model: str,
        cwd: str,
        base_instructions: str,
        tools: Iterable[dict[str, Any]],
        ephemeral: bool = False,
    ) -> str:
        result = self.request(
            "thread/start",
            {
                "model": model or None,
                "cwd": cwd,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "baseInstructions": base_instructions,
                "developerInstructions": "",
                "personality": "none",
                "ephemeral": ephemeral,
                "environments": [],
                "dynamicTools": dynamic_tools(tools),
                "config": self.parity_config(),
                "serviceName": "locus",
            },
            timeout=60,
        )
        thread = result.get("thread")
        thread_id = thread.get("id") if isinstance(thread, dict) else None
        if not isinstance(thread_id, str) or not thread_id:
            raise CodexProtocolMismatch("ChatGPT helper returned no thread id")
        return thread_id

    def resume_thread(self, thread_id: str, *, model: str, cwd: str) -> str:
        result = self.request(
            "thread/resume",
            {
                "threadId": thread_id,
                "model": model or None,
                "cwd": cwd,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "excludeTurns": True,
                "config": self.parity_config(),
            },
            timeout=60,
        )
        thread = result.get("thread")
        resumed = thread.get("id") if isinstance(thread, dict) else None
        if not isinstance(resumed, str) or not resumed:
            raise CodexProtocolMismatch("ChatGPT helper could not resume the thread")
        return resumed

    def run_turn(
        self,
        *,
        thread_id: str,
        text: str,
        input_items: list[dict[str, Any]] | None = None,
        model: str = "",
        output_schema: dict[str, Any] | None = None,
        tool_handler: Callable[[str, dict[str, Any], str], str] | None = None,
        event_handler: Callable[[dict[str, Any]], None] | None = None,
        should_interrupt: Callable[[], bool] | None = None,
        timeout: float = 1_800,
    ) -> dict[str, Any]:
        target = self._subscribe(thread_id)
        turn_id = ""
        interrupted = False
        started = time.monotonic()
        try:
            params: dict[str, Any] = {
                "threadId": thread_id,
                "input": input_items or [{"type": "text", "text": text}],
            }
            if model:
                params["model"] = model
            if output_schema is not None:
                params["outputSchema"] = output_schema
            response = self.request("turn/start", params, timeout=60)
            turn = response.get("turn")
            if isinstance(turn, dict):
                turn_id = str(turn.get("id") or "")
            while True:
                if time.monotonic() - started > timeout:
                    if turn_id:
                        try:
                            self.request(
                                "turn/interrupt",
                                {"threadId": thread_id, "turnId": turn_id},
                                timeout=10,
                            )
                        except CodexAppServerError:
                            pass
                    raise CodexAppServerError("ChatGPT turn timed out")
                if should_interrupt is not None and should_interrupt() and not interrupted:
                    interrupted = True
                    if turn_id:
                        self.request(
                            "turn/interrupt",
                            {"threadId": thread_id, "turnId": turn_id},
                            timeout=10,
                        )
                try:
                    event = target.get(timeout=0.1)
                except queue.Empty:
                    continue
                failure = event.get("error")
                if isinstance(failure, dict) and not event.get("method"):
                    raise CodexAppServerError(str(failure.get("message") or "ChatGPT turn failed"))
                method = str(event.get("method") or "")
                identifier = event.get("id")
                if identifier is not None and method != "item/tool/call":
                    self.respond_error(
                        identifier, -32601, "Locus accepts only registered dynamic tool calls"
                    )
                    raise CodexProtocolMismatch(f"Unexpected helper request: {method or 'unknown'}")
                if event_handler is not None:
                    event_handler(event)
                if identifier is not None:
                    call = event.get("params")
                    if not isinstance(call, dict):
                        self.respond_error(identifier, -32602, "Invalid dynamic tool request")
                        continue
                    name = str(call.get("tool") or "")
                    arguments = call.get("arguments")
                    call_id = str(call.get("callId") or "")
                    if tool_handler is None:
                        result = "Not run: this Locus route has no tool access."
                        success = False
                    else:
                        try:
                            result = tool_handler(
                                name,
                                arguments if isinstance(arguments, dict) else {},
                                call_id,
                            )
                            success = not str(result).startswith("Error")
                        except Exception as error:  # noqa: BLE001 - tool errors return to model
                            logger.exception("Locus dynamic tool failed")
                            result = f"Error: {error}"
                            success = False
                    self.respond(
                        identifier,
                        {
                            "contentItems": [{"type": "inputText", "text": str(result)}],
                            "success": success,
                        },
                    )
                    continue
                if method == "turn/completed":
                    params_value = event.get("params")
                    completed = params_value.get("turn") if isinstance(params_value, dict) else None
                    return completed if isinstance(completed, dict) else {}
        finally:
            self._unsubscribe(thread_id, target)

    def complete(
        self,
        *,
        model: str,
        cwd: str,
        base_instructions: str,
        prompt: str,
        output_schema: dict[str, Any] | None = None,
        timeout: float = 300,
    ) -> dict[str, Any]:
        thread_id = self.start_thread(
            model=model,
            cwd=cwd,
            base_instructions=base_instructions,
            tools=[],
            ephemeral=True,
        )
        text_parts: list[str] = []
        reasoning_parts: list[str] = []
        usage: dict[str, Any] = {}

        def collect(event: dict[str, Any]) -> None:
            nonlocal usage
            method = event.get("method")
            params = event.get("params")
            if not isinstance(params, dict):
                return
            if method == "item/agentMessage/delta":
                delta = params.get("delta")
                if isinstance(delta, str):
                    text_parts.append(delta)
            elif method == "item/reasoning/summaryTextDelta":
                delta = params.get("delta")
                if isinstance(delta, str):
                    reasoning_parts.append(delta)
            elif method == "thread/tokenUsage/updated":
                candidate = params.get("tokenUsage")
                if isinstance(candidate, dict):
                    usage = candidate

        turn = self.run_turn(
            thread_id=thread_id,
            text=prompt,
            model=model,
            output_schema=output_schema,
            event_handler=collect,
            timeout=timeout,
        )
        return {
            "text": "".join(text_parts),
            "reasoning": "".join(reasoning_parts),
            "turn": turn,
            "usage": usage,
            "threadId": thread_id,
        }

    def interrupt(self, thread_id: str, turn_id: str) -> None:
        self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id}, timeout=10)

    def close(self) -> None:
        with self._state_lock:
            process = self._process
            self._process = None
            self._initialized = {}
        if process is None:
            return
        try:
            if process.stdin is not None:
                process.stdin.close()
        except OSError:
            pass
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


class CodexBrokerClient:
    """Worker-side proxy to the primary backend's sole App Server owner."""

    def __init__(self, url: str, token: str) -> None:
        self.url = url.strip()
        self.token = token.strip()

    @property
    def available(self) -> bool:
        return bool(self.url and self.token)

    @property
    def runtime_version(self) -> str:
        return PINNED_CODEX_APP_SERVER_VERSION

    def add_listener(self, listener: Callable[[dict[str, Any]], None]) -> None:
        del listener

    def _connect(self):
        if not self.available:
            raise CodexAppServerError("The internal ChatGPT broker is unavailable")
        try:
            from websockets.sync.client import connect
            return connect(
                self.url,
                additional_headers={"X-Locus-Token": self.token},
                open_timeout=10,
                max_size=40 * 1024 * 1024,
            )
        except Exception as error:  # noqa: BLE001
            raise CodexAppServerError(f"Could not connect to the ChatGPT broker: {error}") from error

    def _call(self, operation: str, payload: dict[str, Any] | None = None) -> Any:
        with self._connect() as socket:
            socket.send(json.dumps({"op": operation, **(payload or {})}))
            raw = socket.recv(timeout=1_800)
        try:
            response = json.loads(raw)
        except (TypeError, json.JSONDecodeError) as error:
            raise CodexProtocolMismatch("The ChatGPT broker returned malformed JSON") from error
        if not isinstance(response, dict):
            raise CodexProtocolMismatch("The ChatGPT broker returned an invalid response")
        if response.get("type") == "error":
            raise CodexAppServerError(str(response.get("message") or "ChatGPT broker failed"))
        return response.get("result")

    def account(self, *, refresh: bool = False) -> dict[str, Any]:
        result = self._call("account", {"refresh": refresh})
        return result if isinstance(result, dict) else {}

    def models(self) -> list[dict[str, Any]]:
        result = self._call("models")
        return [item for item in result if isinstance(item, dict)] if isinstance(result, list) else []

    def usage(self) -> dict[str, Any]:
        result = self._call("usage")
        return result if isinstance(result, dict) else {}

    def start_thread(
        self,
        *,
        model: str,
        cwd: str,
        base_instructions: str,
        tools: Iterable[dict[str, Any]],
        ephemeral: bool = False,
    ) -> str:
        result = self._call("thread_start", {
            "model": model,
            "cwd": cwd,
            "base_instructions": base_instructions,
            "tools": list(tools),
            "ephemeral": ephemeral,
        })
        if not isinstance(result, str) or not result:
            raise CodexProtocolMismatch("The ChatGPT broker returned no thread id")
        return result

    def resume_thread(self, thread_id: str, *, model: str, cwd: str) -> str:
        result = self._call("thread_resume", {
            "thread_id": thread_id,
            "model": model,
            "cwd": cwd,
        })
        if not isinstance(result, str) or not result:
            raise CodexProtocolMismatch("The ChatGPT broker could not resume the thread")
        return result

    def run_turn(
        self,
        *,
        thread_id: str,
        text: str,
        input_items: list[dict[str, Any]] | None = None,
        model: str = "",
        output_schema: dict[str, Any] | None = None,
        tool_handler: Callable[[str, dict[str, Any], str], str] | None = None,
        event_handler: Callable[[dict[str, Any]], None] | None = None,
        should_interrupt: Callable[[], bool] | None = None,
        timeout: float = 1_800,
    ) -> dict[str, Any]:
        with self._connect() as socket:
            socket.send(json.dumps({
                "op": "turn_run",
                "thread_id": thread_id,
                "text": text,
                "input_items": input_items,
                "model": model,
                "output_schema": output_schema,
                "timeout": timeout,
            }))
            while True:
                if should_interrupt is not None and should_interrupt():
                    socket.send(json.dumps({"type": "interrupt"}))
                try:
                    raw = socket.recv(timeout=min(timeout, 30))
                except TimeoutError:
                    continue
                message = json.loads(raw)
                kind = str(message.get("type") or "")
                if kind == "event":
                    event = message.get("event")
                    if event_handler is not None and isinstance(event, dict):
                        event_handler(event)
                elif kind == "tool_call":
                    name = str(message.get("tool") or "")
                    arguments = message.get("arguments")
                    call_id = str(message.get("call_id") or "")
                    result = (
                        tool_handler(name, arguments if isinstance(arguments, dict) else {}, call_id)
                        if tool_handler is not None
                        else "Not run: this route has no tool access."
                    )
                    socket.send(json.dumps({
                        "type": "tool_result", "call_id": call_id, "result": str(result),
                    }))
                elif kind == "completed":
                    turn = message.get("turn")
                    return turn if isinstance(turn, dict) else {}
                elif kind == "error":
                    raise CodexAppServerError(str(message.get("message") or "ChatGPT broker failed"))

    def complete(
        self,
        *,
        model: str,
        cwd: str,
        base_instructions: str,
        prompt: str,
        output_schema: dict[str, Any] | None = None,
        timeout: float = 300,
    ) -> dict[str, Any]:
        result = self._call("complete", {
            "model": model,
            "cwd": cwd,
            "base_instructions": base_instructions,
            "prompt": prompt,
            "output_schema": output_schema,
            "timeout": timeout,
        })
        return result if isinstance(result, dict) else {}

    def close(self) -> None:
        return


class CodexManagerRegistry:
    """The helper processes backing the signed-in ChatGPT accounts.

    One manager per account home, created on first use and kept afterwards.
    Laziness is the point: a user with three ChatGPT accounts pays for one
    helper process until they actually touch the others, and an account that is
    only ever listed in settings never launches anything.
    """

    def __init__(self, *, client_version: str = "0") -> None:
        self.client_version = client_version
        self._managers: dict[str, CodexAppServerManager] = {}
        self._listeners: list[Callable[[dict[str, Any]], None]] = []
        self._lock = threading.RLock()

    def add_listener(self, listener: Callable[[dict[str, Any]], None]) -> None:
        """Register a listener on every manager, including ones not yet built."""
        with self._lock:
            self._listeners.append(listener)
            managers = list(self._managers.values())
        for manager in managers:
            manager.add_listener(listener)

    def manager(self, home_id: str = "") -> CodexAppServerManager:
        key = (home_id or "").strip()
        # Resolve the path outside the lock so an invalid id raises before any
        # state is touched.
        home = codex_home_for_account(key)
        with self._lock:
            existing = self._managers.get(key)
            if existing is not None:
                return existing
            manager = CodexAppServerManager(
                codex_home=home,
                client_version=self.client_version,
            )
            for listener in self._listeners:
                manager.add_listener(listener)
            self._managers[key] = manager
            return manager

    def existing(self, home_id: str = "") -> CodexAppServerManager | None:
        """The manager for an account, but only if one has already been built.

        Callers that merely report status use this: asking about an account
        must not be what launches its helper.
        """
        with self._lock:
            return self._managers.get((home_id or "").strip())

    def close(self, home_id: str = "") -> None:
        with self._lock:
            manager = self._managers.pop((home_id or "").strip(), None)
        if manager is not None:
            manager.close()

    def close_all(self) -> None:
        with self._lock:
            managers = list(self._managers.values())
            self._managers.clear()
        for manager in managers:
            manager.close()
