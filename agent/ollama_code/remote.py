"""Hosted-model client for OpenAI-compatible and Anthropic endpoints.

Covers anything that speaks the OpenAI chat-completions API, which is how
rented-GPU deployments of Hugging Face models are usually exposed:

- Hugging Face Inference Endpoints (dedicated GPU, TGI backend)
- The Hugging Face Inference Providers router
- vLLM / TGI / Ollama running on a rented box (RunPod, Vast.ai, Lambda, …)
- Any other OpenAI-compatible gateway
- Anthropic's native Messages and Models APIs

Anthropic's native Messages protocol is adapted alongside the OpenAI-compatible
surface. Both present the same interface as :class:`~ollama_code.ollama.OllamaClient`.
"""
from __future__ import annotations

import ipaddress
import json
import threading
from collections.abc import Callable
from typing import Any
from urllib.parse import urlsplit

import requests

from . import USER_AGENT, proxy
from .ollama import ChatResponse, OllamaError, ToolCall

#: Well-known bases, offered as presets in the UI.
HUGGINGFACE_ROUTER = "https://router.huggingface.co/v1"

DEFAULT_TIMEOUT = 600

#: Auth styles. Most endpoints take a bearer token; Anthropic's native API uses
#: ``x-api-key`` with an API version.
AUTH_BEARER = "bearer"
AUTH_ANTHROPIC = "anthropic"
AUTH_STYLES = (AUTH_BEARER, AUTH_ANTHROPIC)

ANTHROPIC_VERSION = "2023-06-01"

#: Anthropic's Messages API requires `max_tokens`, so an agent that does not know
#: its window still has to name one. Only a default: a session with a settled
#: window sends the room it actually reserved for a reply instead, so a full
#: reply cannot overrun the budget compaction was planning around.
ANTHROPIC_MAX_OUTPUT_TOKENS = 8_192

#: Fields that name the window a deployment actually serves, most authoritative
#: first. A bare ``max_tokens`` is deliberately absent: several gateways use it
#: for the *output* cap, so reading it as the context window would understate a
#: 128k model as an 8k one and compact away most of a working conversation.
WINDOW_KEYS = (
    "max_model_len",        # vLLM — exact, and the common case for rented GPUs
    "max_total_tokens",     # TGI
    "context_length",       # most gateways
    "context_window",
    "max_context_length",
    "n_ctx",                # llama.cpp
    "max_input_tokens",     # LiteLLM proxy — input only, so conservative
)

#: Fields that name an architectural ceiling rather than what is being served.
CEILING_KEYS = ("max_position_embeddings", "trained_context_length")

#: TGI's ``GET /info``. `max_total_tokens` is prompt + generation, which is the
#: window; `max_input_length` is the prompt-only bound, used when it is all there
#: is.
TGI_WINDOW_KEYS = ("max_total_tokens", "max_input_length")

#: llama.cpp's ``GET /props``. The per-slot value is the right one: it is the
#: window a single request gets.
LLAMA_CPP_WINDOW_KEYS = ("n_ctx", "default_generation_settings")

#: Vendor APIs that serve neither runtime metadata route. Probing them would
#: send an authenticated GET to a path they never published, for no answer.
NO_RUNTIME_PROBE_HOSTS = frozenset({
    "api.anthropic.com",
    "api.openai.com",
    "api.moonshot.ai",
    "api.moonshot.cn",
    "api.kimi.com",
    "router.huggingface.co",
})

#: Bounds for a plausible window. Below the first, a "window" is a unit mix-up
#: or a boolean; above the second it is a byte count or a token *budget* rather
#: than a context length.
MIN_PLAUSIBLE_WINDOW = 1_024
MAX_PLAUSIBLE_WINDOW = 4_000_000


def _as_window(value: Any) -> int:
    """A plausible window from a JSON scalar, else 0."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, str):
        try:
            value = int(value.strip())
        except (TypeError, ValueError):
            return 0
    if not isinstance(value, int):
        return 0
    return value if MIN_PLAUSIBLE_WINDOW <= value <= MAX_PLAUSIBLE_WINDOW else 0


def parse_context_length(
    entry: Any, keys: tuple[str, ...] = WINDOW_KEYS, _depth: int = 3
) -> int:
    """The first plausible window named by ``keys`` anywhere in ``entry``.

    Gateways nest this differently — LiteLLM under ``model_info``, OpenRouter
    under ``top_provider``, llama.cpp under ``default_generation_settings``, the
    Hugging Face router under ``providers[]`` — so rather than enumerate paths
    that will be wrong again next quarter, the walk is bounded and looks for the
    keys wherever they are. Bounded because this parses a response from a remote
    server: depth 3 and 64 nodes, then it gives up.
    """
    budget = [64]

    def walk(node: Any, depth: int) -> int:
        if budget[0] <= 0 or depth < 0:
            return 0
        budget[0] -= 1
        if isinstance(node, dict):
            for key in keys:
                if key in node:
                    window = _as_window(node[key])
                    if window:
                        return window
            for value in node.values():
                if isinstance(value, (dict, list)):
                    found = walk(value, depth - 1)
                    if found:
                        return found
        elif isinstance(node, list):
            for value in node:
                found = walk(value, depth - 1)
                if found:
                    return found
        return 0

    return walk(entry, _depth)


def resolve_auth_style(style: str, base_url: str) -> str:
    """Return the auth style to use, inferring it from the host when unset."""
    candidate = (style or "").strip().lower()
    if candidate in AUTH_STYLES:
        return candidate
    try:
        host = (urlsplit(base_url).hostname or "").lower()
    except ValueError:
        host = ""
    if host == "api.anthropic.com":
        return AUTH_ANTHROPIC
    return AUTH_BEARER


def normalize_base_url(url: str) -> str:
    """Return a base URL ending in a single ``/v1``.

    People paste endpoints in every shape: with or without ``/v1``, with a
    trailing slash, or with the full ``/v1/chat/completions`` path. Accept all
    of them rather than failing with a confusing 404.
    """
    base = (url or "").strip().rstrip("/")
    if not base:
        return ""
    if "://" not in base:
        base = "https://" + base
    for suffix in ("/chat/completions", "/completions", "/messages"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    base = base.rstrip("/")
    if not base.endswith("/v1"):
        base += "/v1"
    return base


def validate_remote_url(base_url: str, api_key: str = "") -> None:
    """Require HTTPS whenever credentials leave the loopback interface."""
    parsed = urlsplit(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("remote endpoint must be an HTTP or HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("put credentials in the API key field, not in the endpoint URL")
    if parsed.query or parsed.fragment:
        raise ValueError("remote endpoint URLs cannot contain a query or fragment")
    host = parsed.hostname
    loopback = host.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(host).is_loopback
    except ValueError:
        pass
    if api_key and parsed.scheme != "https" and not loopback:
        raise ValueError("API keys require HTTPS unless the endpoint is on this Mac")


class RemoteClient:
    """Chat client for an OpenAI-compatible endpoint."""

    def __init__(
        self,
        base_url: str,
        api_key: str = "",
        model: str = "",
        timeout: int = DEFAULT_TIMEOUT,
        auth_style: str = "",
        lists_models: bool = True,
    ) -> None:
        self.base_url = normalize_base_url(base_url)
        self.api_key = (api_key or "").strip()
        validate_remote_url(self.base_url, self.api_key)
        #: Endpoints that serve exactly one model often reject /v1/models, so
        #: the configured name is used as the fallback listing.
        self.configured_model = (model or "").strip()
        self.timeout = timeout
        self.auth_style = resolve_auth_style(auth_style, self.base_url)
        #: Whether ``GET {base}/models`` is a route this provider serves.
        #: Kimi Code documents chat completions and nothing else, and an
        #: endpoint that answers 401 there would read as a rejected key on
        #: every health poll.
        self.lists_models = lists_models
        #: Discovered windows, per model id, and the ceiling if one was stated.
        self._windows: dict[str, int] = {}
        self._ceilings: dict[str, int] = {}
        #: A single-model deployment (TGI, llama.cpp) has one window for the
        #: whole endpoint rather than one per id.
        self._host_window = 0
        self._discovered = False

    # ----------------------------------------------------------------- meta

    @property
    def host(self) -> str:
        return self.base_url

    def _headers(self) -> dict[str, str]:
        # The identity travels outside the api_key branch on purpose: an
        # unauthenticated probe should still say who is calling.
        headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
        if self.api_key:
            if self.auth_style == AUTH_ANTHROPIC:
                headers["x-api-key"] = self.api_key
                headers["anthropic-version"] = ANTHROPIC_VERSION
            else:
                headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _error(self, response: requests.Response) -> OllamaError:
        """Turn an HTTP failure into a message that says what to fix."""
        status = response.status_code
        body = ""
        try:
            payload = response.json()
            if isinstance(payload, dict):
                error = payload.get("error")
                if isinstance(error, dict):
                    body = str(error.get("message") or "")
                elif error:
                    body = str(error)
                body = body or str(payload.get("message") or "")
        except ValueError:
            body = response.text[:300]
        if self.api_key:
            body = body.replace(self.api_key, "[redacted]")
        if status in (401, 403):
            return OllamaError(
                f"the endpoint rejected the API key ({status}). "
                f"Check the key and that it has access to this model. {body}".strip()
            )
        if 300 <= status < 400:
            return OllamaError(
                "the endpoint tried to redirect an authenticated request. "
                "Configure the final HTTPS endpoint URL directly."
            )
        if status == 404:
            return OllamaError(
                f"not found at {self.base_url} ({status}). Check the endpoint URL "
                f"and the model name. {body}".strip()
            )
        if status == 503:
            return OllamaError(
                f"the endpoint is not ready yet ({status}). A scaled-to-zero GPU "
                f"endpoint can take a minute to wake. {body}".strip()
            )
        return OllamaError(f"endpoint returned HTTP {status}. {body}".strip())

    def check(self) -> None:
        """Raise OllamaError when the endpoint is unusable."""
        if not self.base_url:
            raise OllamaError("no endpoint URL is configured")
        if not self.lists_models:
            if not self.api_key:
                # Kimi Code cannot be checked through /models, but accepting an
                # empty in-memory key as healthy makes a freshly restarted
                # helper look connected before the app restores its credential.
                raise OllamaError("no API key is loaded for this provider")
            # Nothing here that would not lie. A provider serving only chat
            # completions answers this path with an auth error whatever the
            # key is, and reporting that as "offline" would condemn a
            # working subscription on every 15-second poll. The turn itself
            # is the real check.
            return
        try:
            response = requests.get(
                f"{self.base_url}/models",
                headers=self._headers(),
                timeout=15,
                allow_redirects=False,
            )
        except requests.RequestException as e:
            raise OllamaError(proxy.redact(f"cannot reach {self.base_url}: {e}")) from e
        if response.status_code == 404:
            # Single-model endpoints frequently omit /v1/models; that is fine.
            return
        if response.status_code >= 300:
            raise self._error(response)

    def version(self) -> str:
        return "openai-compatible"

    def list_models(self) -> list[dict[str, Any]]:
        if not self.base_url:
            raise OllamaError("no endpoint URL is configured")
        if not self.lists_models:
            # Same reasoning as `check`: this provider does not serve the route.
            # Asking anyway produced an auth error that the caller reported as a
            # rejected key, which then failed model switching for a key that
            # works perfectly well for chat.
            return self._fallback_models()
        try:
            response = requests.get(
                f"{self.base_url}/models",
                headers=self._headers(),
                timeout=20,
                allow_redirects=False,
            )
        except requests.RequestException as e:
            raise OllamaError(proxy.redact(f"failed to list models: {e}")) from e
        if response.status_code == 404:
            return self._fallback_models()
        if response.status_code >= 300:
            raise self._error(response)
        try:
            payload = response.json()
        except ValueError:
            return self._fallback_models()
        entries = payload.get("data") if isinstance(payload, dict) else None
        models: list[dict[str, Any]] = []
        for entry in entries or []:
            name = (entry or {}).get("id")
            if not name:
                continue
            window = parse_context_length(entry)
            ceiling = parse_context_length(entry, CEILING_KEYS)
            if window:
                self._windows[str(name)] = window
            if ceiling:
                self._ceilings[str(name)] = ceiling
            models.append({
                "name": str(name),
                "size": 0,
                "details": {},
                "context_length": window,
                "trained_context_length": ceiling or window,
            })
        return models or self._fallback_models()

    def _fallback_models(self) -> list[dict[str, Any]]:
        if self.configured_model:
            window = self.loaded_context_length(self.configured_model)
            return [{
                "name": self.configured_model,
                "size": 0,
                "details": {},
                "context_length": window,
                "trained_context_length": window,
            }]
        return []

    # ------------------------------------------------------- context windows

    def discover_windows(self) -> None:
        """Find out what window this endpoint serves. One pass, never raises.

        Deployments that run open models — vLLM, TGI, llama.cpp, a Hugging Face
        Inference Endpoint — do state their window; the ids in `/v1/models` are
        simply the only field anyone bothered to read. So the listing is parsed
        first, since that request is being made anyway for the model picker, and
        only when it yields nothing are the two runtime metadata routes tried.

        Vendor APIs are skipped entirely: they serve neither route, so probing
        them means sending an authenticated GET to a path they never published,
        for no answer.
        """
        if self._discovered:
            return
        self._discovered = True
        try:
            self.list_models()          # fills _windows / _ceilings as a side effect
        except OllamaError:
            pass
        if self._windows or self._host_window or self._skips_runtime_probes():
            return
        self._probe_runtime()

    def _skips_runtime_probes(self) -> bool:
        host = urlsplit(self.base_url).hostname or ""
        return host.lower() in NO_RUNTIME_PROBE_HOSTS

    def _runtime_root(self) -> str:
        """The base URL without the OpenAI-compatibility suffix."""
        base = self.base_url
        return base[: -len("/v1")] if base.endswith("/v1") else base

    def _probe_runtime(self) -> None:
        root = self._runtime_root()
        for path, keys in (("/info", TGI_WINDOW_KEYS), ("/props", LLAMA_CPP_WINDOW_KEYS)):
            payload = self._get_json(f"{root}{path}")
            if not isinstance(payload, dict):
                continue
            window = parse_context_length(payload, keys)
            if window:
                self._host_window = window
                return

    def _get_json(self, url: str) -> Any:
        """A best-effort metadata read. Any failure means "it did not say"."""
        try:
            response = requests.get(
                url, headers=self._headers(), timeout=(5, 5), allow_redirects=False
            )
            if response.status_code >= 300:
                return None
            return response.json()
        except (requests.RequestException, ValueError):
            return None

    def show_model(self, name: str) -> dict[str, Any]:
        return {}

    def context_length(self, name: str) -> int:
        """The ceiling this endpoint reported, if it reported one. Cache read."""
        key = (name or self.configured_model).strip()
        return self._ceilings.get(key) or self.loaded_context_length(key)

    def loaded_context_length(self, name: str) -> int:
        """The window this endpoint serves, 0 when it never said. Cache read.

        Never does HTTP: `refresh_context_limit` calls this on every turn, and
        `discover_windows` is the one place a request is made.
        """
        key = (name or self.configured_model).strip()
        return self._windows.get(key) or self._host_window

    def supports_tools(self, name: str) -> bool:
        return True

    # ----------------------------------------------------------------- chat

    def chat_stream(
        self,
        model: str,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        on_token: Callable[[str], None] | None = None,
        think: bool = False,
        should_stop: Callable[[], bool] | None = None,
        on_thinking: Callable[[str], None] | None = None,
        options: dict[str, Any] | None = None,
    ) -> ChatResponse:
        if self.auth_style == AUTH_ANTHROPIC:
            system, native_messages = _to_anthropic_messages(messages)
            payload: dict[str, Any] = {
                "model": model or self.configured_model,
                "messages": native_messages,
                # Anthropic requires an output cap. The caller overrides it
                # through `options` with the room the budget actually reserved;
                # this default is for callers that have no window to reason from.
                "max_tokens": ANTHROPIC_MAX_OUTPUT_TOKENS,
                "stream": True,
            }
            if system:
                payload["system"] = system
            stream = self._stream_anthropic
        else:
            payload = {
                "model": model or self.configured_model,
                "messages": [_to_openai_message(m) for m in messages],
                "stream": True,
            }
            stream = self._stream
        if tools:
            payload["tools"] = (
                [_to_anthropic_tool(tool) for tool in tools]
                if self.auth_style == AUTH_ANTHROPIC
                else tools
            )
        if options:
            payload.update(options)
        try:
            return stream(payload, on_token, should_stop, on_thinking)
        except OllamaError as e:
            message = str(e).lower()
            # Not every hosted model exposes tool calling. Retry once without
            # tools so the user still gets an answer, and say what happened.
            if tools and ("tool" in message or "function" in message):
                payload.pop("tools", None)
                payload.pop("tool_choice", None)
                payload.pop("parallel_tool_calls", None)
                response = stream(payload, on_token, should_stop, on_thinking)
                response.provider_fields["tools_rejected"] = True
                response.content_parts.insert(
                    0,
                    "[This endpoint rejected tool calling, so I answered without "
                    "using tools.]\n\n",
                )
                return response
            raise

    def _stream(
        self,
        payload: dict[str, Any],
        on_token: Callable[[str], None] | None,
        should_stop: Callable[[], bool] | None,
        on_thinking: Callable[[str], None] | None,
    ) -> ChatResponse:
        resp = ChatResponse()
        #: index -> partial tool call, since arguments stream in fragments.
        partial: dict[int, dict[str, str]] = {}
        watcher_done = threading.Event()
        watcher: threading.Thread | None = None
        try:
            with requests.post(
                f"{self.base_url}/chat/completions",
                json=payload,
                headers=self._headers(),
                stream=True,
                timeout=(10, self.timeout),
                allow_redirects=False,
            ) as r:
                if r.status_code >= 300:
                    raise self._error(r)
                if should_stop is not None:
                    watcher = threading.Thread(
                        target=_close_when_stopped,
                        args=(r, should_stop, watcher_done),
                        daemon=True,
                    )
                    watcher.start()
                for line in r.iter_lines(decode_unicode=True):
                    if should_stop is not None and should_stop():
                        resp.done = True
                        resp.done_reason = resp.done_reason or "interrupted"
                        break
                    if not line:
                        continue
                    if line.startswith("data:"):
                        line = line[5:].strip()
                    if not line or line == "[DONE]":
                        if line == "[DONE]":
                            resp.done = True
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(chunk, dict) and chunk.get("error"):
                        raise OllamaError(_error_text(chunk["error"]))
                    self._consume(chunk, resp, partial, on_token, on_thinking)
                    if resp.done:
                        break
                if should_stop is not None and should_stop():
                    resp.done = True
                    resp.done_reason = "interrupted"
        except requests.RequestException as e:
            if should_stop is not None and should_stop():
                resp.done = True
                resp.done_reason = "interrupted"
                return resp
            raise OllamaError(proxy.redact(f"chat request failed: {e}")) from e
        except Exception:
            # Closing a requests/urllib3 response from the stop watcher can
            # surface an implementation error such as
            # ``AttributeError: 'NoneType' object has no attribute 'read'``
            # instead of RequestException. Once Stop is set, that exception is
            # the expected wake-up path and must not trigger dispatcher repair
            # or fallback work.
            if should_stop is not None and should_stop():
                resp.done = True
                resp.done_reason = "interrupted"
                return resp
            raise
        finally:
            watcher_done.set()
            if watcher is not None:
                watcher.join(timeout=0.2)

        for index in sorted(partial):
            call = partial[index]
            name = call.get("name", "")
            if not name:
                continue
            raw = call.get("arguments", "") or "{}"
            try:
                arguments = json.loads(raw)
            except json.JSONDecodeError:
                arguments = {"_raw": raw}
            if not isinstance(arguments, dict):
                arguments = {"value": arguments}
            resp.tool_calls.append(
                ToolCall(
                    name=name,
                    arguments=arguments,
                    call_id=call.get("id", ""),
                )
            )
        return resp

    def _stream_anthropic(
        self,
        payload: dict[str, Any],
        on_token: Callable[[str], None] | None,
        should_stop: Callable[[], bool] | None,
        on_thinking: Callable[[str], None] | None,
    ) -> ChatResponse:
        """Stream Anthropic's native Messages SSE protocol."""
        resp = ChatResponse()
        partial: dict[int, dict[str, str]] = {}
        native_blocks: dict[int, dict[str, Any]] = {}
        watcher_done = threading.Event()
        watcher: threading.Thread | None = None
        try:
            with requests.post(
                f"{self.base_url}/messages",
                json=payload,
                headers=self._headers(),
                stream=True,
                timeout=(10, self.timeout),
                allow_redirects=False,
            ) as response:
                if response.status_code >= 300:
                    raise self._error(response)
                if should_stop is not None:
                    watcher = threading.Thread(
                        target=_close_when_stopped,
                        args=(response, should_stop, watcher_done),
                        daemon=True,
                    )
                    watcher.start()
                for line in response.iter_lines(decode_unicode=True):
                    if should_stop is not None and should_stop():
                        resp.done = True
                        resp.done_reason = "interrupted"
                        break
                    if not line or not line.startswith("data:"):
                        continue
                    raw = line[5:].strip()
                    if not raw:
                        continue
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    if event.get("type") == "error":
                        raise OllamaError(_error_text(event.get("error")))
                    _consume_anthropic_event(
                        event,
                        resp,
                        partial,
                        native_blocks,
                        on_token,
                        on_thinking,
                    )
                    if resp.done:
                        break
                if should_stop is not None and should_stop():
                    resp.done = True
                    resp.done_reason = "interrupted"
        except requests.RequestException as e:
            if should_stop is not None and should_stop():
                resp.done = True
                resp.done_reason = "interrupted"
                return resp
            raise OllamaError(proxy.redact(f"chat request failed: {e}")) from e
        except Exception:
            if should_stop is not None and should_stop():
                resp.done = True
                resp.done_reason = "interrupted"
                return resp
            raise
        finally:
            watcher_done.set()
            if watcher is not None:
                watcher.join(timeout=0.2)

        for index in sorted(partial):
            call = partial[index]
            name = call.get("name", "")
            if not name:
                continue
            raw = call.get("arguments", "") or "{}"
            try:
                arguments = json.loads(raw)
            except json.JSONDecodeError:
                arguments = {"_raw": raw}
            if not isinstance(arguments, dict):
                arguments = {"value": arguments}
            resp.tool_calls.append(
                ToolCall(
                    name=name,
                    arguments=arguments,
                    call_id=call.get("id", ""),
                )
            )
            block = native_blocks.get(index)
            if block is not None and block.get("type") == "tool_use":
                block["input"] = arguments
        if native_blocks:
            resp.provider_fields["anthropic_content"] = [
                native_blocks[index] for index in sorted(native_blocks)
            ]
        return resp

    @staticmethod
    def _consume(
        chunk: dict[str, Any],
        resp: ChatResponse,
        partial: dict[int, dict[str, str]],
        on_token: Callable[[str], None] | None,
        on_thinking: Callable[[str], None] | None,
    ) -> None:
        usage = chunk.get("usage") or {}
        if usage:
            resp.prompt_eval_count = int(usage.get("prompt_tokens") or 0)
            resp.eval_count = int(usage.get("completion_tokens") or 0)
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or choice.get("message") or {}
            content = delta.get("content")
            if content:
                resp.content_parts.append(content)
                if on_token:
                    on_token(content)
            # vLLM and TGI expose reasoning models through this field.
            reasoning = delta.get("reasoning_content") or delta.get("reasoning")
            if reasoning:
                resp.thinking_parts.append(reasoning)
                if on_thinking:
                    on_thinking(reasoning)
            for call in delta.get("tool_calls") or []:
                index = int(call.get("index") or 0)
                slot = partial.setdefault(
                    index,
                    {"id": "", "name": "", "arguments": ""},
                )
                if call.get("id"):
                    slot["id"] = str(call["id"])
                function = call.get("function") or {}
                if function.get("name"):
                    slot["name"] = str(function["name"])
                if function.get("arguments"):
                    slot["arguments"] += str(function["arguments"])
            finish = choice.get("finish_reason")
            if finish:
                resp.done = True
                resp.done_reason = "length" if finish == "length" else str(finish)


def _close_when_stopped(
    response: requests.Response,
    should_stop: Callable[[], bool],
    done: threading.Event,
) -> None:
    """Close a stalled streaming response as soon as the turn is interrupted."""
    while not done.wait(0.05):
        if should_stop():
            response.close()
            return


def _consume_anthropic_event(
    event: dict[str, Any],
    resp: ChatResponse,
    partial: dict[int, dict[str, str]],
    native_blocks: dict[int, dict[str, Any]],
    on_token: Callable[[str], None] | None,
    on_thinking: Callable[[str], None] | None,
) -> None:
    event_type = event.get("type")
    if event_type == "message_start":
        usage = (event.get("message") or {}).get("usage") or {}
        resp.prompt_eval_count = int(usage.get("input_tokens") or 0)
        return
    if event_type == "content_block_start":
        block = event.get("content_block") or {}
        index = int(event.get("index") or 0)
        block_type = block.get("type")
        if block_type == "text":
            initial_text = str(block.get("text") or "")
            native_blocks[index] = {
                "type": "text",
                "text": initial_text,
            }
            if initial_text:
                resp.content_parts.append(initial_text)
                if on_token:
                    on_token(initial_text)
        elif block_type == "thinking":
            initial_thinking = str(block.get("thinking") or "")
            native_blocks[index] = {
                "type": "thinking",
                "thinking": initial_thinking,
                "signature": str(block.get("signature") or ""),
            }
            if initial_thinking:
                resp.thinking_parts.append(initial_thinking)
                if on_thinking:
                    on_thinking(initial_thinking)
        elif block_type == "redacted_thinking":
            native_blocks[index] = {
                "type": "redacted_thinking",
                "data": str(block.get("data") or ""),
            }
        if block.get("type") == "tool_use":
            slot = partial.setdefault(
                index,
                {"id": "", "name": "", "arguments": ""},
            )
            slot["id"] = str(block.get("id") or "")
            slot["name"] = str(block.get("name") or "")
            initial = block.get("input")
            if initial:
                slot["arguments"] = json.dumps(initial, ensure_ascii=False)
            native_blocks[index] = {
                "type": "tool_use",
                "id": slot["id"],
                "name": slot["name"],
                "input": initial or {},
            }
        return
    if event_type == "content_block_delta":
        delta = event.get("delta") or {}
        delta_type = delta.get("type")
        index = int(event.get("index") or 0)
        if delta_type == "text_delta":
            text = str(delta.get("text") or "")
            if text:
                resp.content_parts.append(text)
                block = native_blocks.setdefault(
                    index,
                    {"type": "text", "text": ""},
                )
                block["text"] = str(block.get("text") or "") + text
                if on_token:
                    on_token(text)
        elif delta_type == "thinking_delta":
            thinking = str(delta.get("thinking") or "")
            if thinking:
                resp.thinking_parts.append(thinking)
                block = native_blocks.setdefault(
                    index,
                    {"type": "thinking", "thinking": "", "signature": ""},
                )
                block["thinking"] = str(block.get("thinking") or "") + thinking
                if on_thinking:
                    on_thinking(thinking)
        elif delta_type == "signature_delta":
            block = native_blocks.setdefault(
                index,
                {"type": "thinking", "thinking": "", "signature": ""},
            )
            block["signature"] = (
                str(block.get("signature") or "")
                + str(delta.get("signature") or "")
            )
        elif delta_type == "input_json_delta":
            slot = partial.setdefault(
                index,
                {"id": "", "name": "", "arguments": ""},
            )
            slot["arguments"] += str(delta.get("partial_json") or "")
        return
    if event_type == "message_delta":
        usage = event.get("usage") or {}
        if usage.get("output_tokens") is not None:
            resp.eval_count = int(usage.get("output_tokens") or 0)
        stop = (event.get("delta") or {}).get("stop_reason")
        if stop:
            resp.done_reason = "length" if stop == "max_tokens" else str(stop)
        return
    if event_type == "message_stop":
        resp.done = True
        resp.done_reason = resp.done_reason or "stop"


def _error_text(error: Any) -> str:
    if isinstance(error, dict):
        return str(error.get("message") or error)
    return str(error)


def _to_openai_message(message: dict[str, Any]) -> dict[str, Any]:
    """Convert an internal message to OpenAI chat-completions shape."""
    role = message.get("role")
    if role == "tool":
        return {
            "role": "tool",
            "content": str(message.get("content") or ""),
            "tool_call_id": str(
                message.get("tool_call_id") or message.get("name") or "tool"
            ),
        }
    content: Any = str(message.get("content") or "")
    attachments = message.get("attachments") or []
    if role == "user" and attachments:
        blocks: list[dict[str, Any]] = []
        if content:
            blocks.append({"type": "text", "text": content})
        for attachment in attachments:
            if not isinstance(attachment, dict):
                continue
            data = str(attachment.get("data") or "")
            mime_type = str(attachment.get("mime_type") or "")
            if data and mime_type.startswith("image/"):
                blocks.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:{mime_type};base64,{data}"},
                })
        if blocks:
            content = blocks
    out: dict[str, Any] = {
        "role": role,
        "content": content,
    }
    reasoning = message.get("reasoning_content")
    if isinstance(reasoning, str) and reasoning:
        out["reasoning_content"] = reasoning
    tool_calls = message.get("tool_calls") or []
    if tool_calls:
        out["tool_calls"] = [
            {
                "id": str(
                    tc.get("id")
                    or (tc.get("function") or {}).get("name")
                    or f"call_{i}"
                ),
                "type": "function",
                "function": {
                    "name": (tc.get("function") or {}).get("name", ""),
                    "arguments": json.dumps(
                        (tc.get("function") or {}).get("arguments", {}),
                        ensure_ascii=False,
                    ),
                },
            }
            for i, tc in enumerate(tool_calls)
        ]
    return out


def _to_anthropic_tool(tool: dict[str, Any]) -> dict[str, Any]:
    function = tool.get("function") or {}
    return {
        "name": str(function.get("name") or ""),
        "description": str(function.get("description") or ""),
        "input_schema": function.get("parameters") or {"type": "object"},
    }


def _to_anthropic_messages(
    messages: list[dict[str, Any]],
) -> tuple[str, list[dict[str, Any]]]:
    """Convert internal chat history to Anthropic's Messages shape."""
    systems: list[str] = []
    converted: list[dict[str, Any]] = []
    for message in messages:
        role = message.get("role")
        content = str(message.get("content") or "")
        if role == "system":
            if content:
                systems.append(content)
            continue
        if role == "tool":
            native_role = "user"
            blocks: list[dict[str, Any]] = [{
                "type": "tool_result",
                "tool_use_id": str(
                    message.get("tool_call_id") or message.get("name") or "tool"
                ),
                "content": content,
            }]
        elif role == "assistant":
            native_role = "assistant"
            preserved = message.get("anthropic_content")
            if isinstance(preserved, list) and all(
                isinstance(block, dict) for block in preserved
            ):
                blocks = [dict(block) for block in preserved]
            else:
                blocks = []
                if content:
                    blocks.append({"type": "text", "text": content})
                for call in message.get("tool_calls") or []:
                    function = call.get("function") or {}
                    name = str(function.get("name") or "tool")
                    blocks.append({
                        "type": "tool_use",
                        "id": str(call.get("id") or name),
                        "name": name,
                        "input": function.get("arguments") or {},
                    })
        else:
            native_role = "user"
            blocks = []
            if content:
                blocks.append({"type": "text", "text": content})
            for attachment in message.get("attachments") or []:
                if not isinstance(attachment, dict):
                    continue
                data = str(attachment.get("data") or "")
                mime_type = str(attachment.get("mime_type") or "")
                if data and mime_type.startswith("image/"):
                    blocks.append({
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": mime_type,
                            "data": data,
                        },
                    })
        if not blocks:
            continue
        if converted and converted[-1]["role"] == native_role:
            converted[-1]["content"].extend(blocks)
        else:
            converted.append({"role": native_role, "content": blocks})
    return "\n\n".join(systems), converted
