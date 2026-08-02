"""Event-driven agent core shared by the terminal CLI and the web server.

The core owns the conversation, the Ollama client, tool execution, sessions
and permissions. It never prints: it emits structured event dicts through a
handler, and receives permission decisions through a pluggable blocking
callback, so a CLI (same thread) or a WebSocket server (worker thread plus a
future) can both drive it.

Event types emitted:
    message_start / token / message_end     assistant streaming
    thinking                                {text} reasoning-model output
    tool_call_proposed                      {id, tool, summary, detail, auto}
    permission_request                      {request_id, id, tool, preview}
    tool_result                             {id, tool, summary, result, ok, denied}
    todo_update                             {todos}
    turn_done                               {reason: complete|interrupted|max_iterations|error}
    error                                   {message}
    session_info                            full session_info() dict
    session_started                         {reason, session_info}
    slash_result                            {command, text?, data?, error?}
"""
from __future__ import annotations

import json
import os
import platform
import threading
import uuid
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Any

from .config import (
    DEFAULTS,
    MINIMUM_CONTEXT_WINDOW,
    context_window,
    load_config,
    non_negative_int,
    save_config,
)
from .ollama import (
    DEFAULT_HOST,
    ChatResponse,
    OllamaClient,
    OllamaError,
    ToolCall,
    effective_context_length,
)
from .permissions import PermissionManager, build_preview
from .remote import (
    RemoteClient,
    normalize_base_url,
    resolve_auth_style,
    validate_remote_url,
)
from .render import ThinkFilter, strip_think
from .sessions import (
    SessionMeta,
    SessionStore,
    clear_saved_sessions,
    strip_prompt_decoration,
)
from .tools import TOOL_SCHEMAS, ToolContext, execute_tool

EventHandler = Callable[[dict[str, Any]], None]
PermissionDecider = Callable[[str, str, str, str], str]
"""(tool_name, summary, detail, request_id) -> "once" | "always" | "deny"."""

CONTEXT_FILES = ("OLLAMA.md", "CLAUDE.md", "AGENTS.md")

#: Rough token cost of the tool schemas. They ride along on every request but
#: are not part of `self.messages`, so `approx_tokens` cannot see them.
TOOL_SCHEMA_TOKENS = len(json.dumps(TOOL_SCHEMAS)) // 4

#: Room kept back for the model's reply. One `edit_file` call carries two whole
#: blocks of code as JSON-escaped strings; running out of window partway through
#: is what makes Ollama reject a tool call with "unexpected end of JSON input".
RESERVED_REPLY_TOKENS = 4_096

#: What compacting leaves behind on top of the system prompt: the summary it
#: just wrote. Part of the floor below which compacting reclaims nothing.
SUMMARY_ALLOWANCE_TOKENS = 512

#: `approx_tokens` counts four characters to a token, which is about right for
#: prose and optimistic for what this agent actually sends — source code, diffs,
#: JSON arguments and shell output all tokenize denser than that, and the chat
#: template adds framing around every message that never reaches the estimate.
#: The budget is scaled to absorb the bias rather than pretending otherwise.
ESTIMATE_OPTIMISM = 0.75

#: Tool outputs shorter than this are cheaper to keep than to stub: interrupt
#: notices, denials and empty results carry signal the model still needs, and
#: skipping them makes eviction idempotent — a stub is never re-stubbed.
EVICTABLE_MIN_CHARS = 200

#: What replaces an evicted tool output. Short, and it tells the model the
#: honest way back: the tool still exists and can simply be called again.
EVICTION_STUB = (
    "[Old {tool} output dropped to fit the context window. "
    "Call the tool again if you still need it.]"
)

#: Ceiling on the transcript /compact sends: the request that rescues the
#: window must itself fit inside it.
COMPACT_TRANSCRIPT_CAP_CHARS = 24_000

#: Ollama's wording when generation ran out of window partway through a tool
#: call's JSON arguments (passed through verbatim from llama-server).
_WINDOW_OVERFLOW_MARKERS = (
    "unexpected end of json input",
    "invalid tool call arguments",
    "error parsing tool call",
)


def _different_host(before: str, after: str) -> bool:
    """Whether two endpoint URLs point at different services.

    Compared by host alone: a path change on the same host is the same
    provider, so a remembered model is still meaningful there.
    """
    def host(url: str) -> str:
        rest = url.split("://", 1)[-1]
        return rest.split("/", 1)[0].lower()

    return bool(before) and bool(after) and host(before) != host(after)


def _looks_like_window_overflow(error_text: str) -> bool:
    """Whether an OllamaError is the window running out mid-tool-call."""
    lowered = error_text.lower()
    return any(marker in lowered for marker in _WINDOW_OVERFLOW_MARKERS)

BASE_SYSTEM_PROMPT = """You are ollama-code, a CLI coding agent running in the user's terminal on macOS.

You help with software engineering tasks: reading, writing and editing code, running shell commands, and searching the codebase.

Rules:
1. Always use your tools for file and shell work. Do not print file contents or big code blocks in chat when a tool can create, edit, or run things directly.
2. Prefer small exact edits with edit_file over rewriting whole files with write_file. Read a file before editing it.
3. Use todo_write to plan and track tasks that need multiple steps.
4. Paths are relative to the working directory unless they start with /.
5. Keep going: after a tool result comes back, continue with the next step until the task is fully done, then stop calling tools and give your final answer.
6. Be concise. Final answers: 1-3 short sentences saying what you did and which files changed.

Environment:
- OS: {os_name}
- Working directory: {cwd}
- Date: {date}
"""

INIT_PROMPT = (
    "Analyze this project and create an OLLAMA.md file that will help future AI "
    "coding sessions in this directory. First list the directory, read the key "
    "files (README, package manifests, main entry points), then write OLLAMA.md "
    "with: the project's purpose, tech stack, how to build/run/test it, and the "
    "code layout. Keep it under 80 lines."
)

HELP_PLAIN = """Slash commands:
  /help                    show this help
  /model [name]            list installed models / switch model
  /clear                   start a fresh conversation
  /compact                 summarize older messages to free up context
  /init                    scan the project and write an OLLAMA.md context file
  /todos                   show the current task list
  /status, /cost           model, cwd, session, token usage
  /sessions                list recent sessions
  /resume [n|id]           resume a session
  /permissions [reset]     show or reset tool allowances
  /permissions mode M      ask | accept_edits | bypass
  /tools                   list the tools the agent can call
  /diff                    show the working-tree diff
  /retry                   regenerate the last response
  /exit                    quit (CLI only)

Permissions: read_file, glob, grep, list_dir and todo_write run automatically;
other tools ask first (once / always / deny)."""

SLASH_COMMANDS = [
    "/help", "/model", "/clear", "/compact", "/init", "/todos", "/tools",
    "/status", "/cost", "/sessions", "/resume", "/permissions", "/diff",
    "/retry", "/exit",
]


class AgentCore:
    """The agent. One instance per process; turns run one at a time."""

    def __init__(
        self,
        host: str | None = None,
        model: str = "",
        max_iterations: int | None = None,
        skip_permissions: bool = False,
        cwd: str | None = None,
        config: dict[str, Any] | None = None,
    ) -> None:
        # A caller-supplied config is merged over the defaults so a partial
        # dict cannot silently drop safety settings such as deny_commands.
        if config is None:
            self.config = load_config()
        else:
            self.config = {**DEFAULTS, **config}
        self.host = (host or str(self.config.get("host") or DEFAULT_HOST)).rstrip("/")
        self.provider = str(self.config.get("provider") or "ollama")
        self.client: Any = OllamaClient(self.host)
        self.model: str = model or str(self.config.get("model") or "")
        if self.provider == "remote":
            self._build_remote_client()
        self.max_iterations = int(max_iterations or self.config.get("max_iterations") or 40)
        self.perms = PermissionManager(
            skip_all=skip_permissions,
            mode=str(self.config.get("permission_mode") or "ask"),
            always_allow=list(self.config.get("always_allow") or []),
            deny_commands=list(self.config.get("deny_commands") or []),
        )
        # Expanded but not resolved: the caller's path is reported back as
        # given. Workspace confinement resolves symlinks where it matters, in
        # ToolContext.is_inside_workspace.
        self.cwd = str(Path(cwd).expanduser()) if cwd else os.getcwd()
        self.tool_ctx = ToolContext(cwd=self.cwd)
        self.project_context: tuple[str, str] | None = None
        self.reload_context()
        self.messages: list[dict[str, Any]] = []
        self.session = self._new_session_store()
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.context_limit = 0
        #: Which model `context_limit` was settled for; see refresh_context_limit.
        self._context_limit_for = ""
        #: `/api/show`'s answer, memoised per model — it describes the file on
        #: disk, which does not change while the model does not.
        self._trained_window = 0
        self._trained_window_for = ""
        self._event_handler: EventHandler | None = None
        self._interrupt = threading.Event()
        self.tool_ctx.should_stop = self._interrupt.is_set
        self._last_user_message: str | None = None
        #: The server's ground-truth size of the last completed model call
        #: (prompt + reply tokens) and the message count at that moment. The
        #: mid-turn budget guard extends this with whatever was appended since.
        self._last_call_tokens = 0
        self._messages_at_last_call = 0

    # --------------------------------------------------------------- events

    def on_event(self, handler: EventHandler) -> None:
        self._event_handler = handler

    def _emit(self, event: dict[str, Any]) -> None:
        if self._event_handler is not None:
            try:
                self._event_handler(event)
            except Exception:  # noqa: BLE001 - a broken UI must not kill a turn
                pass

    def interrupt(self) -> None:
        """Soft-interrupt the current turn (safe to call from any thread)."""
        self._interrupt.set()

    # ---------------------------------------------------------------- setup

    def reload_context(self) -> None:
        self.project_context = None
        for name in CONTEXT_FILES:
            p = Path(self.cwd) / name
            if p.is_file():
                try:
                    self.project_context = (name, p.read_text(errors="replace")[:8000])
                except OSError:
                    continue
                break

    def system_message(self) -> dict[str, str]:
        text = BASE_SYSTEM_PROMPT.format(
            os_name=f"{platform.system()} {platform.release()}",
            cwd=self.cwd,
            date=datetime.now().strftime("%Y-%m-%d"),
        )
        if self.project_context:
            name, content = self.project_context
            text += f"\nProject context from {name} (follow its instructions):\n```\n{content}\n```\n"
        return {"role": "system", "content": text}

    def reset_system_message(self) -> None:
        """Refresh messages[0] after cwd/context changes."""
        if self.messages and self.messages[0].get("role") == "system":
            self.messages[0] = self.system_message()
        elif not self.messages:
            self.messages = [self.system_message()]

    def ensure_model(self) -> str | None:
        """Pick a model if unset. Returns a warning or None. Raises OllamaError."""
        names = [m.get("name") for m in self.client.list_models() if m.get("name")]
        if not names:
            if self.provider == "remote":
                # A dedicated endpoint may not list models at all; trust the
                # configured name rather than refusing to start.
                if self.model:
                    return None
                raise OllamaError(
                    "the endpoint did not report any models — set the model name in Settings"
                )
            raise OllamaError("no models installed — run: ollama pull qwen3:8b")
        if not self.model:
            self.model = names[0]
        elif self.model not in names:
            match = next((n for n in names if n.startswith(self.model) or self.model in n), None)
            if match:
                self.model = match
            else:
                return f"model '{self.model}' is not in the installed list; trying anyway."
        self.refresh_context_limit()
        return None

    def refresh_context_limit(self) -> None:
        """Settle on the window this session is really running in.

        Whatever this ends up being is both what gets requested as ``num_ctx``
        (when the user asked for a specific window) and what compaction budgets
        against, so the budget and the runtime window cannot drift apart. An
        OpenAI-compatible endpoint advertises no window and takes no per-request
        override, so there the limit is only what the user configured — 0, and
        no budgeting, when they configured nothing.
        """
        if not self.model:
            return
        # Tolerant: `self.config` is not always the dict `load_config` built —
        # callers pass their own, and a hand-edited config.json reaches here
        # unvalidated.
        configured = context_window(self.config.get("context_window"))
        if self.provider == "remote":
            self.context_limit = configured
            return
        # Asking Ollama what it loaded is only needed when we are not telling
        # it what to load.
        loaded = 0 if configured > 0 else self.client.loaded_context_length(self.model)
        if loaded > 0:
            self.remember_model_window(self.model, loaded)
        window = effective_context_length(loaded, self._trained_context_length(), configured)
        if window <= 0:
            # Nothing resident to measure, but this model may have been
            # measured before. A remembered window is still an observation
            # rather than a guess, and it is what lets the meter work from
            # launch instead of staying blank until the first turn loads a
            # model — Ollama evicts after five idle minutes, so "not resident"
            # is the normal state, not the exception.
            window = self.remembered_model_window(self.model)
        # A model Ollama has since evicted drops off /api/ps and reads as
        # unknown again. Forgetting the window at that point would quietly
        # switch compaction off for the rest of the session, so a number once
        # known is never downgraded to unknown.
        #
        # Scoped to the model it was measured for, not to the process. Without
        # that, picking a different model in the header kept the previous one's
        # number: a 4K model would read ~12% at ~96% of its real window and
        # budget compaction against a window that does not exist — the failure
        # effective_context_length exists to prevent, one layer up.
        if self.model != self._context_limit_for:
            self.context_limit = 0
            self._context_limit_for = self.model
        if window > 0 or self.context_limit <= 0:
            self.context_limit = window

    def _window_key(self, model: str) -> str:
        """Remembered windows are per host as well as per model.

        The same model name runs in different windows on different Ollama
        hosts — a GPU box on the LAN may serve qwen3:8b at 32768 while this
        laptop serves it at 4096. Keying on the name alone would carry the
        big number over to the small host and budget compaction against a
        window that does not exist, which is the exact failure
        effective_context_length was written to prevent.
        """
        return f"{self.host}|{model}"

    def remembered_model_window(self, model: str) -> int:
        """The last window Ollama was seen running this model in, or 0."""
        windows = self.config.get("model_windows")
        if not isinstance(windows, dict):
            return 0
        value = windows.get(self._window_key(model))
        return value if isinstance(value, int) and value > 0 else 0

    def remember_model_window(self, model: str, window: int) -> None:
        """Record a measured window, so a later session need not re-measure.

        Replaces the mapping rather than mutating it. `DEFAULTS` holds a real
        dict and a config built as ``{**DEFAULTS, **overrides}`` shallow-copies,
        so the mapping can be the very object every other core is reading —
        mutating it in place would leak one session's models into all of them.
        """
        if not model or window <= 0:
            return
        current = self.config.get("model_windows")
        windows = dict(current) if isinstance(current, dict) else {}
        key = self._window_key(model)
        if windows.get(key) == window:
            return  # Unchanged: refreshed twice a turn, so do not rewrite.
        windows[key] = window
        self.config["model_windows"] = windows
        save_config(self.config)

    def _trained_context_length(self) -> int:
        """The current model's trained window, asked for once per model.

        `/api/show` is a POST with a 15-second timeout and its answer describes
        a file on disk, so re-asking it twice a turn is pure latency.
        """
        if self._trained_window_for != self.model:
            self._trained_window = self.client.context_length(self.model)
            self._trained_window_for = self.model
        return self._trained_window

    def chat_options(self) -> dict[str, Any] | None:
        """Per-request model options, or None when there are none to send.

        Nothing is sent unless the user asked for a specific window. Ollama
        sizes the window itself otherwise, and overriding that with a guess
        would second-guess its memory accounting and evict a resident runner
        that was loaded with different options — for a number we can simply
        read back instead.

        Only Ollama takes options at all: `RemoteClient` merges the dict into
        the top level of an OpenAI-style payload, where `num_ctx` is meaningless
        and some servers reject unknown fields outright.
        """
        if self.provider == "remote" or self.context_limit <= 0:
            return None
        if context_window(self.config.get("context_window")) <= 0:
            return None
        return {"num_ctx": self.context_limit}

    # ------------------------------------------------------------- provider

    def _build_remote_client(self) -> None:
        base = str(self.config.get("remote_base_url") or "")
        self.client = RemoteClient(
            base_url=base,
            api_key=str(self.config.get("remote_api_key") or ""),
            model=str(self.config.get("remote_model") or ""),
            auth_style=str(self.config.get("remote_auth_style") or ""),
            lists_models=bool(self.config.get("remote_lists_models", True)),
        )
        self.host = self.client.host
        remote_model = str(self.config.get("remote_model") or "")
        if remote_model:
            self.model = remote_model

    def apply_context_window(self, requested: Any) -> None:
        """Set the configured window, or clear it when 0/None.

        Same coercion as POST /api/config, so a value typed in the app and one
        sent over that endpoint cannot disagree. Below MINIMUM_CONTEXT_WINDOW
        the value is not usable at all — it could not hold the system prompt
        and the tool schemas — so it is rejected rather than silently honoured.
        """
        if requested is None:
            return
        resolved = context_window(requested)
        if resolved <= 0 and non_negative_int(requested) > 0:
            raise ValueError(
                f"context_window must be at least {MINIMUM_CONTEXT_WINDOW} tokens, "
                "or 0 to let the provider size the window"
            )
        self.config["context_window"] = resolved

    def use_ollama(
        self, host: str | None = None, context_window_tokens: Any = None
    ) -> None:
        """Switch back to the local Ollama runtime."""
        self.apply_context_window(context_window_tokens)
        self.provider = "ollama"
        self.host = (host or str(self.config.get("host") or DEFAULT_HOST)).rstrip("/")
        self.client = OllamaClient(self.host)
        self.config["provider"] = "ollama"
        self.config["host"] = self.host
        # The label describes a remote account; it would be a lie about the
        # local runtime, and the transcript reads it.
        self.config["remote_account_label"] = ""
        self.model = str(self.config.get("model") or "")
        # Left unknown rather than resolved here: resolving costs Ollama I/O and
        # the app awaits this endpoint on a short timeout. `run_turn` settles it
        # before anything can use it.
        self.context_limit = 0
        self._trained_window_for = ""
        save_config(self.config)
        self._emit_info()

    def use_remote(
        self,
        base_url: str,
        api_key: str | None = None,
        model: str = "",
        auth_style: str | None = None,
        account_label: str | None = None,
        lists_models: bool | None = None,
        context_window_tokens: Any = None,
    ) -> None:
        """Point the agent at an OpenAI-compatible endpoint.

        ``api_key=None`` keeps the key already in memory, so the app can
        update the URL or model without re-sending the secret. ``auth_style``
        and ``account_label`` follow the same rule: ``None`` leaves them alone.
        """
        normalized_url = normalize_base_url(base_url)
        effective_key = (
            api_key.strip()
            if api_key is not None
            else str(self.config.get("remote_api_key") or "")
        )
        # Validate before mutating provider, model, URL, or context state. A
        # rejected credential transport must leave the working provider intact.
        validate_remote_url(normalized_url, effective_key)
        self.apply_context_window(context_window_tokens)
        self.provider = "remote"
        self.config["provider"] = "remote"
        previous_url = str(self.config.get("remote_base_url") or "")
        self.config["remote_base_url"] = normalized_url
        if api_key is not None:
            self.config["remote_api_key"] = api_key.strip()
        if model:
            self.config["remote_model"] = model.strip()
        elif _different_host(previous_url, self.config["remote_base_url"]):
            # The remembered model belongs to the endpoint we just left. Keeping
            # it here is how a Kimi model name ends up pointed at Anthropic,
            # failing with a model-not-found that names neither problem.
            self.config["remote_model"] = ""
        if auth_style is not None:
            self.config["remote_auth_style"] = resolve_auth_style(
                auth_style, self.config["remote_base_url"]
            )
        if account_label is not None:
            self.config["remote_account_label"] = account_label.strip()
        if lists_models is not None:
            self.config["remote_lists_models"] = bool(lists_models)
        self._build_remote_client()
        # _build_remote_client only adopts a non-empty model, so clearing the
        # config above is not enough on its own: self.model would keep the
        # previous endpoint's name and get sent to this one. Empty is the
        # honest value — ensure_model settles it against the new endpoint.
        self.model = str(self.config.get("remote_model") or "")
        self.context_limit = context_window(self.config.get("context_window"))
        self._trained_window_for = ""
        save_config(self.config)  # never writes the key
        self._emit_info()

    def provider_state(self) -> dict[str, Any]:
        """Provider description for the UI. Never includes the key itself."""
        return {
            "provider": self.provider,
            "host": self.host,
            "model": self.model,
            "remote_base_url": str(self.config.get("remote_base_url") or ""),
            "remote_model": str(self.config.get("remote_model") or ""),
            "has_api_key": bool(self.config.get("remote_api_key")),
            "account_label": self.account_label,
        }

    def _new_session_store(self) -> SessionStore:
        return SessionStore(
            self.cwd,
            self.model,
            provider=self.provider,
            account=self.account_label,
        )

    @property
    def account_label(self) -> str:
        """The app's name for the account in use, or "" for local Ollama."""
        if self.provider != "remote":
            return ""
        return str(self.config.get("remote_account_label") or "")

    def set_model(self, name: str) -> None:
        self.model = name
        # Each provider remembers its own model, so switching back and forth
        # does not clobber the other's choice.
        if self.provider == "remote":
            self.config["remote_model"] = name
            self.client.configured_model = name
        else:
            self.config["model"] = name
        # Recorded in the transcript so an exported session shows which model
        # actually produced it, even if the choice changed mid-conversation.
        self.session.append({"type": "model", "model": name})
        save_config(self.config)
        self.refresh_context_limit()
        self._emit_info()

    def set_cwd(self, path: str) -> None:
        p = Path(path).expanduser()
        if not p.is_dir():
            raise ValueError(f"not a directory: {path}")
        os.chdir(p)
        self.cwd = os.getcwd()
        self.tool_ctx.cwd = self.cwd
        self.reload_context()
        self.session = self._new_session_store()
        self.messages = [self.system_message()]
        self.tool_ctx.todos = []
        self._emit({"type": "todo_update", "todos": []})
        self._emit_info()

    def reset_conversation(self) -> None:
        self.messages = [self.system_message()]
        self.tool_ctx.todos = []
        self.tool_ctx.read_files.clear()
        self._last_user_message = None
        self._emit({"type": "todo_update", "todos": []})
        self._emit_info()

    def start_new_session(self, reason: str = "new_session") -> dict[str, Any]:
        """Start a fresh saved session and announce it. Returns session_info.

        A new chat starts clean: session-scoped tool permissions and the token
        counters belong to the conversation that just ended, not the next one.
        """
        self.session = self._new_session_store()
        self.reset_conversation()
        self.perms.allowed.clear()
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        info = self.session_info()
        self._emit({"type": "session_started", "reason": reason, "session_info": info})
        return info

    #: Shorter alias used by the WebSocket handler.
    new_session = start_new_session

    # ------------------------------------------------------------------ info

    def approx_tokens(self) -> int:
        """Rough token count of the live conversation.

        Tool-call arguments are included: they are often the largest part of a
        message, and leaving them out made the context meter read low exactly
        when the window was filling up.
        """
        total = 0
        for message in self.messages:
            total += len(str(message.get("content", "")))
            total += len(str(message.get("reasoning_content", "")))
            for block in message.get("anthropic_content") or []:
                if isinstance(block, dict) and block.get("type") in {
                    "thinking",
                    "redacted_thinking",
                }:
                    total += len(str(block.get("thinking") or block.get("data") or ""))
            for call in message.get("tool_calls") or []:
                function = call.get("function") or {}
                total += len(str(function.get("name", "")))
                arguments = function.get("arguments", "")
                # Measured as the JSON that goes on the wire. `str()` on a dict
                # gives Python repr — close in length, but it drifts the more
                # nested the arguments are, and these are the largest thing in
                # the conversation.
                if isinstance(arguments, (dict, list)):
                    try:
                        arguments = json.dumps(arguments)
                    except (TypeError, ValueError):
                        arguments = str(arguments)
                total += len(str(arguments))
        return total // 4

    def session_info(self) -> dict[str, Any]:
        approx = self.approx_tokens()
        return {
            "model": self.model,
            "host": self.host,
            "cwd": self.cwd,
            "session": str(self.session.path),
            "session_id": self.session.session_id,
            "messages": len(self.messages),
            "approx_tokens": approx,
            "prompt_tokens": self.total_prompt_tokens,
            "completion_tokens": self.total_completion_tokens,
            "max_iterations": self.max_iterations,
            "context_limit": self.context_limit,
            # What a conversation may actually occupy, which is what the
            # meter should divide by — see budget_tokens.
            "usable_tokens": self.budget_tokens(),
            "has_project_context": bool(self.project_context),
            "permissions": self.perms.state(),
            "provider": self.provider,
            "account_label": self.account_label,
        }

    def _emit_info(self) -> None:
        self._emit({"type": "session_info", **self.session_info()})

    # ----------------------------------------------------------- agentic loop

    def _add_message(self, message: dict[str, Any]) -> None:
        self.messages.append(message)
        self.session.append({"type": "message", "message": message})

    def run_turn(self, user_text: str, decider: PermissionDecider | None = None) -> None:
        """One user turn: stream model responses and run tools until done."""
        self._interrupt.clear()
        self.tool_ctx.read_files.clear()
        self._last_user_message = user_text
        # Stale counts from a previous turn must not leak into this turn's
        # budget projection.
        self._last_call_tokens = 0
        self._messages_at_last_call = 0
        # Ollama only says what window it chose once the model is resident, so
        # the first turn budgets against nothing and every turn after that
        # against the truth. One cheap local call, once per user turn.
        self.refresh_context_limit()
        self.auto_compact_if_needed()
        self._add_message({"role": "user", "content": user_text})
        self._run_response_loop(decider)
        # And again now the model is certainly resident, so the next turn's
        # compaction check has a real number rather than having to wait a turn
        # for one. Announced so clients tracking session_info see it change.
        before = self.context_limit
        self.refresh_context_limit()
        if self.context_limit != before:
            self._emit_info()

    def _reply_room(self) -> int:
        """Window share held back for the model's reply; scales down on small windows."""
        return min(RESERVED_REPLY_TOKENS, self.context_limit // 4)

    def auto_compact_if_needed(self) -> bool:
        """Summarize the conversation before it overflows the model window.

        Without this a long session eventually sends more tokens than the
        model accepts and every further turn fails.
        """
        if not self.config.get("auto_compact", True) or self.context_limit <= 0:
            return False
        # The tool schemas and the reply both need room inside the same window,
        # and neither is visible to `approx_tokens`, so both come out of it
        # before the conversation gets its share of what is left. The reply
        # allowance scales: reserving 4k of an 8k window would leave no room to
        # hold a conversation in.
        reply_room = self._reply_room()
        budget = int((self.context_limit - TOOL_SCHEMA_TOKENS - reply_room) * ESTIMATE_OPTIMISM)
        # Compacting leaves the system prompt — project context and all — plus
        # the summary it just wrote. That is the floor: below it there is
        # nothing left to reclaim, and compacting anyway would summarize on
        # every single turn while never getting under budget.
        floor = (
            len(str(self.system_message().get("content", ""))) // 4
            + SUMMARY_ALLOWANCE_TOKENS
        )
        if budget <= floor or self.approx_tokens() < budget:
            return False
        # Announcing a compaction and then reporting there was nothing to
        # compact is pure noise.
        if len(self._compactable_history()) < 2:
            return False
        self._emit({
            "type": "note",
            "text": "Context is nearly full — compacting the conversation.",
        })
        result = self._slash_compact()
        # Reported as a note, not a slash_result: this is part of the turn the
        # user asked for, not a command they ran.
        self._emit({
            "type": "note",
            "text": str(result.get("text") or ""),
            "error": bool(result.get("error", False)),
        })
        return not result.get("error", False)

    def budget_tokens(self, headroom_tokens: int = 0) -> int:
        """How much of the window a conversation may actually occupy.

        The raw window is not what a conversation gets: the tool schemas ride
        along on every request, room has to be kept for the reply, and
        `approx_tokens` counts four characters to a token, which is optimistic
        for the code and JSON this agent really sends.

        Reported in `session_info` so the meter divides by the same number
        compaction compares against. Dividing by the raw window instead is why
        compaction used to fire at a displayed ~55%.
        """
        if self.context_limit <= 0:
            return 0
        reply_room = self._reply_room() + headroom_tokens
        budget = int((self.context_limit - TOOL_SCHEMA_TOKENS - reply_room) * ESTIMATE_OPTIMISM)
        return max(budget, 0)

    def _over_budget(self, headroom_tokens: int = 0) -> bool:
        """Whether the next request likely overflows the window in use.

        Two signals, OR-ed. The estimate is exactly the turn-start compaction
        math. The server's own count for the last call is exact — it includes
        the chat template and tool schemas `approx_tokens` cannot see — but KV
        prefix caching can make `prompt_eval_count` report only what was newly
        evaluated, so it extends the estimate rather than replacing it.
        """
        if self.context_limit <= 0:
            return False
        reply_room = self._reply_room() + headroom_tokens
        budget = self.budget_tokens(headroom_tokens)
        if budget <= 0 or self.approx_tokens() >= budget:
            return True
        if self._last_call_tokens > 0:
            appended = sum(
                len(str(m.get("content", "")))
                for m in self.messages[self._messages_at_last_call:]
            ) // 4
            return self._last_call_tokens + appended >= self.context_limit - reply_room
        return False

    def _evict_tool_results_if_needed(
        self, headroom_tokens: int = 0, allow_newest: bool = False
    ) -> int:
        """Stub out old tool outputs in place until the next request fits.

        Compaction cannot run mid-turn: `_compactable_history` drops
        role:"tool" messages and tool-call-only assistant messages, which
        would orphan the tool pairing and forget everything the model just
        read. Blanking old tool *contents* keeps the structure the chat
        template expects while reclaiming the bulk of the space. Only the
        in-memory list changes — the session file already holds the full
        outputs and stays append-only. Returns how many were evicted; the
        caller announces it (one note per event, worded per call site).
        """
        if self.context_limit <= 0 or not self._over_budget(headroom_tokens):
            return 0
        # Results after the last assistant message are the batch the model
        # just asked for and has never seen; evicting those defeats the
        # iteration, so they go last — and the newest one is only taken as a
        # last resort, when overflow recovery has nothing else left.
        last_assistant = max(
            (i for i, m in enumerate(self.messages) if m.get("role") == "assistant"),
            default=len(self.messages),
        )
        candidates = [
            i for i, m in enumerate(self.messages)
            if m.get("role") == "tool"
            and len(str(m.get("content") or "")) > EVICTABLE_MIN_CHARS
        ]
        older = [i for i in candidates if i < last_assistant]
        batch = [i for i in candidates if i > last_assistant]
        evictable = older + (batch if allow_newest else batch[:-1])
        evicted = 0
        for index in evictable:
            if not self._over_budget(headroom_tokens):
                break
            message = self.messages[index]
            dropped = len(str(message.get("content") or ""))
            message["content"] = EVICTION_STUB.format(tool=message.get("name") or "tool")
            # The grounded tally measured the un-evicted history. chars/4 is
            # an optimistic shrink, so the tally stays slightly high — erring
            # toward evicting one more rather than one too few.
            self._last_call_tokens = max(0, self._last_call_tokens - dropped // 4)
            evicted += 1
        return evicted

    def _recover_from_window_overflow(self) -> bool:
        """Make room after generation died mid-tool-call; True when a retry is worth it.

        Refresh first: on a cold first turn the failing call is itself proof
        the model is resident now, so the window that was unknown at turn
        start is readable at last.
        """
        self.refresh_context_limit()
        if self.context_limit <= 0:
            return False
        # The failure is ground truth that the request filled the window,
        # whatever the chars/4 estimate believed. Seed the grounded tally
        # with a full window so eviction has real pressure to relieve —
        # otherwise an optimistic estimate would refuse to evict anything
        # and the retry could never be earned.
        self._last_call_tokens = max(self._last_call_tokens, self.context_limit)
        self._messages_at_last_call = len(self.messages)
        evicted = self._evict_tool_results_if_needed(headroom_tokens=RESERVED_REPLY_TOKENS)
        if evicted == 0:
            # The polite pass protects the newest tool result so the model
            # keeps what it just asked for — but when the window cannot hold
            # even that, losing one read (the stub says how to get it back)
            # beats losing the whole turn.
            evicted = self._evict_tool_results_if_needed(
                headroom_tokens=RESERVED_REPLY_TOKENS, allow_newest=True
            )
        return evicted > 0

    def retry_last_response(self, decider: PermissionDecider | None = None) -> bool:
        """Drop everything after the last user message and answer it again."""
        index = None
        for i in range(len(self.messages) - 1, -1, -1):
            if self.messages[i].get("role") == "user":
                index = i
                break
        if index is None:
            self._emit({"type": "error", "message": "Nothing to regenerate yet."})
            self._emit({"type": "turn_done", "reason": "error"})
            return False
        self.messages = self.messages[: index + 1]
        self._interrupt.clear()
        self.tool_ctx.read_files.clear()
        # Branch onto a fresh saved session so the original transcript survives.
        self.session = self._new_session_store()
        for message in self.messages[1:]:
            self.session.append({"type": "message", "message": message})
        self._emit({
            "type": "session_started",
            "reason": "retry",
            "session_info": self.session_info(),
        })
        self._run_response_loop(decider)
        return True

    #: Shorter alias used by the WebSocket handler.
    retry_last = retry_last_response

    def _run_response_loop(self, decider: PermissionDecider | None = None) -> None:
        reason = "complete"
        for _ in range(self.max_iterations):
            if self._interrupt.is_set():
                reason = "interrupted"
                break
            # Tool results are appended uncapped in aggregate (a dozen reads
            # in one iteration is legal), so the window can fill *inside* a
            # turn where the turn-start compaction check cannot help. Trim
            # before asking again.
            evicted = self._evict_tool_results_if_needed()
            if evicted:
                plural = "s" if evicted != 1 else ""
                self._emit({
                    "type": "note",
                    "text": (
                        f"Context is nearly full — dropped {evicted} older "
                        f"tool result{plural} to make room."
                    ),
                })
            resp = self._stream_response()
            if resp is None:  # error already emitted
                reason = "error"
                break
            assistant_msg: dict[str, Any] = {"role": "assistant", "content": strip_think(resp.content)}
            if self.provider == "remote" and resp.thinking:
                assistant_msg["reasoning_content"] = resp.thinking
            anthropic_content = resp.provider_fields.get("anthropic_content")
            if self.provider == "remote" and isinstance(anthropic_content, list):
                assistant_msg["anthropic_content"] = anthropic_content
            if resp.tool_calls:
                assistant_msg["tool_calls"] = [
                    {
                        "id": tc.call_id or tc.name,
                        "type": "function",
                        "function": {"name": tc.name, "arguments": tc.arguments},
                    }
                    for tc in resp.tool_calls
                ]
            self._add_message(assistant_msg)
            self.total_prompt_tokens += resp.prompt_eval_count
            self.total_completion_tokens += resp.eval_count
            # The per-call counts are the server's ground truth for what this
            # history costs; keep them for the mid-turn budget guard before
            # the totals swallow them.
            self._last_call_tokens = resp.prompt_eval_count + resp.eval_count
            self._messages_at_last_call = len(self.messages)
            # A response proves the model is resident, so a window this turn
            # started without (cold start: nothing on /api/ps yet) is readable
            # now instead of a turn late. Free once known — refresh never
            # downgrades a known window, so num_ctx stays stable mid-turn.
            if self.context_limit <= 0:
                self.refresh_context_limit()
            if resp.done_reason == "length":
                # The model hit its output cap: say so rather than presenting
                # a cut-off answer as a finished one.
                self._emit({
                    "type": "note",
                    "text": "The model stopped at its output limit — the answer may be incomplete.",
                })
            if not resp.tool_calls:
                if self._interrupt.is_set():
                    reason = "interrupted"
                break
            interrupted = False
            for index, tc in enumerate(resp.tool_calls):
                if self._interrupt.is_set():
                    interrupted = True
                    # Every proposed call needs a result message, or the
                    # conversation carries tool_calls with no answer and the
                    # model gets confused on the next turn.
                    for skipped in resp.tool_calls[index:]:
                        self._add_message({
                            "role": "tool",
                            "name": skipped.name,
                            "tool_call_id": skipped.call_id or skipped.name,
                            "content": "Not run: the user interrupted this turn.",
                        })
                    break
                result = self._run_tool_call(tc, decider)
                self._add_message({
                    "role": "tool",
                    "name": tc.name,
                    "tool_call_id": tc.call_id or tc.name,
                    "content": result,
                })
            # Tool output is most of what fills a window, and until this the
            # meter only learned about it when the whole turn ended — so a turn
            # that read twenty files showed a flat meter and then jumped. One
            # event per iteration, not per tool, keeps that honest without
            # flooding the socket.
            self._emit_info()
            if interrupted:
                reason = "interrupted"
                break
        else:
            reason = "max_iterations"
        self._emit({"type": "turn_done", "reason": reason})
        self._emit_info()

    def _stream_response(self, allow_overflow_retry: bool = True) -> ChatResponse | None:
        self._emit({"type": "message_start"})
        think_filter = ThinkFilter()

        def on_token(token: str) -> None:
            piece = think_filter.feed(token)
            if piece:
                self._emit({"type": "token", "text": piece})

        def on_thinking(text: str) -> None:
            # Native reasoning output is surfaced as its own event so the GUI
            # can render it collapsed instead of mixing it into the answer.
            self._emit({"type": "thinking", "text": text})

        try:
            resp = self.client.chat_stream(
                model=self.model,
                messages=self.messages,
                tools=TOOL_SCHEMAS,
                on_token=on_token,
                should_stop=self._interrupt.is_set,
                on_thinking=on_thinking,
                options=self.chat_options(),
            )
        except KeyboardInterrupt:  # CLI Ctrl+C on the main thread
            self._interrupt.set()
            resp = None
        except OllamaError as e:
            # Keep whatever already streamed: the user has read it on screen,
            # so it must exist in the conversation and the session file too.
            partial = strip_think(think_filter.flush_all())
            if (
                allow_overflow_retry
                and not partial
                and not self._interrupt.is_set()
                and _looks_like_window_overflow(str(e))
                and self._recover_from_window_overflow()
            ):
                # The window ran out mid-tool-call. Nothing visible was lost
                # and the request is rebuilt from self.messages, so close the
                # aborted (empty) message pair and ask once more. The flag
                # caps the recursion at one, and recovery only says yes when
                # it actually shrank the history — an identical prompt would
                # only fail identically.
                self._emit({"type": "message_end"})
                self._emit({
                    "type": "note",
                    "text": (
                        "The model's tool call was cut off by the context "
                        "window — dropped older tool output and retrying."
                    ),
                })
                return self._stream_response(allow_overflow_retry=False)
            if partial:
                self._add_message({"role": "assistant", "content": partial})
            self._emit({"type": "error", "message": str(e)})
            self._emit({"type": "message_end"})
            return None
        if resp is None:  # interrupted mid-stream: synthesize an empty response
            self._emit({"type": "message_end"})
            return ChatResponse(done=True, done_reason="interrupted")
        tail = think_filter.flush()
        if tail:
            self._emit({"type": "token", "text": tail})
        self._emit({"type": "message_end"})
        return resp

    # ------------------------------------------------------------------ tools

    def _run_tool_call(self, tc: ToolCall, decider: PermissionDecider | None) -> str:
        call_id = uuid.uuid4().hex[:10]
        summary, detail = build_preview(tc.name, tc.arguments, self.tool_ctx)
        blocked = self.perms.blocked_reason(tc.name, tc.arguments)
        if blocked:
            result = f"Error: {blocked}. Ask the user to run it manually if it is really needed."
            self._emit({
                "type": "tool_call_proposed",
                "id": call_id,
                "tool": tc.name,
                "summary": summary,
                "detail": detail,
                "auto": True,
            })
            self._emit({
                "type": "tool_result",
                "id": call_id,
                "tool": tc.name,
                "summary": summary,
                "result": result,
                "ok": False,
                "denied": True,
            })
            return result
        auto = self.perms.is_auto_allowed(
            tc.name, inside_workspace=self._targets_workspace(tc)
        )
        self._emit({
            "type": "tool_call_proposed",
            "id": call_id,
            "tool": tc.name,
            "summary": summary,
            "detail": detail,
            "auto": auto,
        })
        if not auto:
            request_id = uuid.uuid4().hex[:12]
            self._emit({
                "type": "permission_request",
                "request_id": request_id,
                "id": call_id,
                "tool": tc.name,
                "summary": summary,
                "detail": detail,
                "preview": {"summary": summary, "detail": detail},
            })
            decision = decider(tc.name, summary, detail, request_id) if decider else "deny"
            if decision == "always":
                self.perms.allow_tool(tc.name)
            if decision not in ("once", "always"):
                result = (
                    f"Permission denied: the user did not allow running {tc.name}. "
                    "Do not retry the same call; ask the user or propose an alternative."
                )
                self._emit({
                    "type": "tool_result",
                    "id": call_id,
                    "tool": tc.name,
                    "summary": summary,
                    "result": result,
                    "ok": False,
                    "denied": True,
                })
                return result
        result = execute_tool(tc.name, tc.arguments, self.tool_ctx)
        ok = not result.startswith("Error")
        self._emit({
            "type": "tool_result",
            "id": call_id,
            "tool": tc.name,
            "summary": summary,
            "result": result,
            "ok": ok,
            "denied": False,
        })
        if tc.name == "todo_write":
            self._emit({"type": "todo_update", "todos": self.tool_ctx.todos})
        return result

    def _targets_workspace(self, tc: ToolCall) -> bool:
        """Whether a tool call stays inside the workspace.

        Auto-approval is scoped to the project the user opened: reading or
        editing something elsewhere on the disk still asks first.
        """
        if not isinstance(tc.arguments, dict):
            return True
        path = tc.arguments.get("path")
        if tc.name == "glob" and (
            not isinstance(path, str) or not path.strip()
        ):
            path = tc.arguments.get("pattern")
        if not isinstance(path, str) or not path.strip():
            return True
        return self.tool_ctx.is_inside_workspace(self.tool_ctx.resolve(path))

    # ---------------------------------------------------------- slash commands

    def handle_slash(self, text: str, decider: PermissionDecider | None = None) -> dict[str, Any]:
        """Run a slash command. Returns {command, text?, data?, error?}."""
        parts = text.strip().split(maxsplit=1)
        cmd = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""
        if cmd in ("/exit", "/quit"):
            return {"command": "exit", "text": "Goodbye."}
        if cmd == "/help":
            return {"command": "help", "text": HELP_PLAIN}
        if cmd == "/model":
            return self._slash_model(arg)
        if cmd == "/clear":
            self.new_session(reason="clear_chat")
            return {"command": "clear", "text": "Conversation cleared."}
        if cmd == "/compact":
            return self._slash_compact()
        if cmd == "/init":
            self.run_turn(INIT_PROMPT, decider)
            return {"command": "init", "text": "Finished writing OLLAMA.md."}
        if cmd == "/todos":
            return {"command": "todos", "data": {"todos": self.tool_ctx.todos}}
        if cmd == "/tools":
            names = [s["function"]["name"] for s in TOOL_SCHEMAS]
            listing = "\n".join(
                f"  {s['function']['name']:<12} {s['function']['description']}"
                for s in TOOL_SCHEMAS
            )
            return {
                "command": "tools",
                "text": f"Available tools:\n{listing}",
                "data": {"tools": names},
            }
        if cmd in ("/status", "/cost"):
            return {"command": "status", "data": self.session_info()}
        if cmd == "/sessions":
            return {"command": "sessions", "data": {"sessions": self.list_session_summaries()}}
        if cmd == "/resume":
            return self._slash_resume(arg)
        if cmd == "/permissions":
            return self._slash_permissions(arg)
        if cmd == "/diff":
            result = execute_tool("git_diff", {"path": arg} if arg else {}, self.tool_ctx)
            return {"command": "diff", "text": result, "error": result.startswith("Error")}
        if cmd == "/retry":
            ok = self.retry_last(decider)
            return {"command": "retry", "text": "Regenerating…" if ok else "Nothing to regenerate.",
                    "error": not ok}
        return {"command": cmd.lstrip("/"), "text": f"Unknown command {cmd} — try /help", "error": True}

    def _slash_model(self, arg: str) -> dict[str, Any]:
        try:
            models = self.client.list_models()
        except OllamaError as e:
            return {"command": "model", "text": str(e), "error": True}
        names = [m.get("name") for m in models if m.get("name")]
        if not names:
            return {"command": "model", "text": "No models installed — run: ollama pull qwen3:8b", "error": True}
        if arg:
            match = next((n for n in names if n == arg), None) or next(
                (n for n in names if arg in n), None
            )
            if not match:
                return {
                    "command": "model",
                    "text": f"Model '{arg}' not found. Installed: {', '.join(names)}",
                    "error": True,
                }
            self.set_model(match)
            return {"command": "model", "text": f"Switched to model {match} (saved as default)."}
        listing = "\n".join(
            f"{'*' if n == self.model else ' '} {i}. {n}" for i, n in enumerate(names, 1)
        )
        return {
            "command": "model",
            "text": f"Installed models (* = current):\n{listing}",
            "data": {"models": names, "current": self.model},
        }

    def _compactable_history(self) -> list[dict[str, Any]]:
        """The messages a summary could replace. Fewer than two is not worth it."""
        return [
            m for m in self.messages[1:]
            if m.get("role") in ("user", "assistant") and m.get("content")
        ]

    def _slash_compact(self) -> dict[str, Any]:
        history = self._compactable_history()
        if len(history) < 2:
            return {"command": "compact", "text": "Nothing to compact yet."}
        # Newest-first until the cap: the request that summarizes the
        # conversation must itself fit the window it is trying to rescue.
        # 3 chars per token is the inverse of the estimate convention
        # (4 chars/token at 0.75 optimism); the summary allowance is carved
        # out so the reply has room to exist.
        cap = COMPACT_TRANSCRIPT_CAP_CHARS
        if self.context_limit > 0:
            cap = min(cap, max(2_000, 3 * (self.context_limit - SUMMARY_ALLOWANCE_TOKENS)))
        kept: list[str] = []
        total = 0
        for m in reversed(history):
            piece = (
                f"{m['role'].upper()}: "
                f"{strip_prompt_decoration(str(m.get('content', '')))[:2000]}"
            )
            if kept and total + len(piece) > cap:
                break
            kept.append(piece)
            total += len(piece)
        kept.reverse()
        if len(kept) < len(history):
            kept.insert(0, "[Earlier messages omitted — too long to summarize at once.]")
        transcript = "\n\n".join(kept)
        req = [
            {
                "role": "system",
                "content": (
                    "You summarize conversations for a coding agent. Produce a compact "
                    "summary preserving: user goals, decisions made, files created or "
                    "modified (with paths), commands run, and pending tasks."
                ),
            },
            {"role": "user", "content": f"Summarize this conversation:\n\n{transcript}"},
        ]
        try:
            resp = self.client.chat_stream(
                self.model, req, tools=None, options=self.chat_options()
            )
        except OllamaError as e:
            return {"command": "compact", "text": str(e), "error": True}
        summary = strip_think(resp.content) or "(empty summary)"
        self.messages = [
            self.system_message(),
            {
                "role": "user",
                "content": "[Summary of the earlier conversation, compacted to save context]\n" + summary,
            },
        ]
        self._emit_info()
        return {
            "command": "compact",
            "text": f"Conversation compacted to a summary ({len(summary)} chars).",
            "data": {"summary": summary},
        }

    def _slash_resume(self, arg: str) -> dict[str, Any]:
        files = SessionStore.list_sessions()
        if not files:
            return {"command": "resume", "text": "No saved sessions found.", "error": True}
        arg = arg.strip()
        if not arg:
            session_id = files[0].stem
        elif arg.isdigit():
            idx = int(arg) - 1
            if not (0 <= idx < len(files)):
                return {"command": "resume", "text": "Session number out of range.", "error": True}
            session_id = files[idx].stem
        else:
            session_id = arg
        try:
            return self.resume_session(session_id)
        except (ValueError, FileNotFoundError) as e:
            return {"command": "resume", "text": str(e), "error": True}

    def _slash_permissions(self, arg: str) -> dict[str, Any]:
        arg = arg.strip()
        if arg == "reset":
            self.perms.reset()
            self._emit_info()
            return {"command": "permissions", "text": "Permissions reset (session allowances cleared)."}
        if arg.startswith("mode"):
            mode = arg.removeprefix("mode").strip()
            if mode not in ("ask", "accept_edits", "bypass"):
                return {
                    "command": "permissions",
                    "text": "Usage: /permissions mode ask|accept_edits|bypass",
                    "error": True,
                }
            self.perms.set_mode(mode)
            self.config["permission_mode"] = mode
            save_config(self.config)
            self._emit_info()
            return {"command": "permissions", "text": f"Permission mode set to {mode}."}
        return {
            "command": "permissions",
            "text": "\n".join(self.perms.summary_lines()),
            "data": self.perms.state(),
        }

    # --------------------------------------------------------------- sessions

    @staticmethod
    def list_session_summaries(
        limit: int = 50,
        include_archived: bool = False,
        query: str = "",
    ) -> list[dict[str, Any]]:
        return SessionStore.summaries(
            limit=limit, include_archived=include_archived, query=query
        )

    @staticmethod
    def sanitize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Trim stored messages to what a UI needs to render history."""
        out: list[dict[str, Any]] = []
        for m in messages:
            role = m.get("role")
            if role == "system":
                continue
            content = str(m.get("content") or "")
            if role == "user":
                content = strip_prompt_decoration(content)
            item: dict[str, Any] = {"role": role, "content": content[:4000]}
            if role == "tool":
                item["name"] = m.get("name", "tool")
            tool_calls = m.get("tool_calls") or []
            if tool_calls:
                item["tool_calls"] = [
                    (tc.get("function") or {}).get("name", "tool") for tc in tool_calls
                ]
            out.append(item)
        return out

    def resume_session(self, session_id: str) -> dict[str, Any]:
        path = SessionStore.path_for(session_id)
        if path is None:
            raise FileNotFoundError(f"session not found: {session_id}")
        messages = SessionStore.load(path)
        if not messages:
            raise ValueError(f"no messages found in {path.name}")
        header = SessionStore.header(path)
        cwd = str(header.get("cwd") or "")
        if cwd and Path(cwd).is_dir() and cwd != self.cwd:
            try:
                os.chdir(cwd)
                self.cwd = os.getcwd()
                self.tool_ctx.cwd = self.cwd
                self.reload_context()
            except OSError:
                pass
        self.messages = [self.system_message()] + messages
        # Continue appending to the session the user resumed.
        self.session.path = path
        self._last_user_message = next(
            (str(m.get("content")) for m in reversed(messages) if m.get("role") == "user"),
            None,
        )
        self._emit_info()
        return {
            "command": "resume",
            "text": f"Resumed {path.name} ({len(messages)} messages).",
            "data": {"messages": self.sanitize_messages(messages)},
        }

    def clear_saved_sessions(self) -> dict[str, Any]:
        """Move every session except the active one into the recovery folder."""
        return clear_saved_sessions(self.session.session_id)

    @staticmethod
    def update_session_metadata(
        session_id: str,
        title: str | None = None,
        pinned: bool | None = None,
        archived: bool | None = None,
    ) -> dict[str, Any]:
        if SessionStore.path_for(session_id) is None:
            raise FileNotFoundError(f"session not found: {session_id}")
        fields: dict[str, Any] = {}
        if title is not None:
            cleaned = " ".join(title.split())[:120]
            fields["title"] = cleaned or None
        if pinned is not None:
            fields["pinned"] = bool(pinned) or None
        if archived is not None:
            fields["archived"] = bool(archived) or None
        entry = SessionMeta.update(session_id, **fields)
        return {
            "ok": True,
            "id": session_id,
            "title": str(entry.get("title") or ""),
            "pinned": bool(entry.get("pinned", False)),
            "archived": bool(entry.get("archived", False)),
        }
