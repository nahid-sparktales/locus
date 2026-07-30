"""OpenAI-compatible client for hosted models.

Covers anything that speaks the OpenAI chat-completions API, which is how
rented-GPU deployments of Hugging Face models are usually exposed:

- Hugging Face Inference Endpoints (dedicated GPU, TGI backend)
- The Hugging Face Inference Providers router
- vLLM / TGI / Ollama running on a rented box (RunPod, Vast.ai, Lambda, …)
- Any other OpenAI-compatible gateway

It presents the same surface as :class:`~ollama_code.ollama.OllamaClient`, so
the agent core can talk to either without knowing the difference.
"""
from __future__ import annotations

import json
from typing import Any, Callable

import requests

from .ollama import ChatResponse, OllamaError, ToolCall

#: Well-known bases, offered as presets in the UI.
HUGGINGFACE_ROUTER = "https://router.huggingface.co/v1"

DEFAULT_TIMEOUT = 600

#: Auth styles. Most endpoints take a bearer token; Anthropic's chat-completions
#: compatibility surface does too, but its native ``/v1/models`` wants the key in
#: ``x-api-key`` with an API version. Sending both satisfies either one.
AUTH_BEARER = "bearer"
AUTH_ANTHROPIC = "anthropic"
AUTH_STYLES = (AUTH_BEARER, AUTH_ANTHROPIC)

ANTHROPIC_VERSION = "2023-06-01"


def resolve_auth_style(style: str, base_url: str) -> str:
    """Return the auth style to use, inferring it from the host when unset."""
    candidate = (style or "").strip().lower()
    if candidate in AUTH_STYLES:
        return candidate
    if "api.anthropic.com" in (base_url or ""):
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
    for suffix in ("/chat/completions", "/completions"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    base = base.rstrip("/")
    if not base.endswith("/v1"):
        base += "/v1"
    return base


class RemoteClient:
    """Chat client for an OpenAI-compatible endpoint."""

    def __init__(
        self,
        base_url: str,
        api_key: str = "",
        model: str = "",
        timeout: int = DEFAULT_TIMEOUT,
        auth_style: str = "",
    ) -> None:
        self.base_url = normalize_base_url(base_url)
        self.api_key = (api_key or "").strip()
        #: Endpoints that serve exactly one model often reject /v1/models, so
        #: the configured name is used as the fallback listing.
        self.configured_model = (model or "").strip()
        self.timeout = timeout
        self.auth_style = resolve_auth_style(auth_style, self.base_url)

    # ----------------------------------------------------------------- meta

    @property
    def host(self) -> str:
        return self.base_url

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
            if self.auth_style == AUTH_ANTHROPIC:
                # Chat completions accept the bearer token; the native model
                # listing only accepts these. Servers ignore headers they do
                # not recognize, so both can travel together.
                headers["x-api-key"] = self.api_key
                headers["anthropic-version"] = ANTHROPIC_VERSION
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
        if status in (401, 403):
            return OllamaError(
                f"the endpoint rejected the API key ({status}). "
                f"Check the key and that it has access to this model. {body}".strip()
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
        try:
            response = requests.get(
                f"{self.base_url}/models", headers=self._headers(), timeout=15
            )
        except requests.RequestException as e:
            raise OllamaError(f"cannot reach {self.base_url}: {e}") from e
        if response.status_code == 404:
            # Single-model endpoints frequently omit /v1/models; that is fine.
            return
        if response.status_code >= 400:
            raise self._error(response)

    def version(self) -> str:
        return "openai-compatible"

    def list_models(self) -> list[dict[str, Any]]:
        if not self.base_url:
            raise OllamaError("no endpoint URL is configured")
        try:
            response = requests.get(
                f"{self.base_url}/models", headers=self._headers(), timeout=20
            )
        except requests.RequestException as e:
            raise OllamaError(f"failed to list models: {e}") from e
        if response.status_code == 404:
            return self._fallback_models()
        if response.status_code >= 400:
            raise self._error(response)
        try:
            payload = response.json()
        except ValueError:
            return self._fallback_models()
        entries = payload.get("data") if isinstance(payload, dict) else None
        models: list[dict[str, Any]] = []
        for entry in entries or []:
            name = (entry or {}).get("id")
            if name:
                models.append({"name": str(name), "size": 0, "details": {}})
        return models or self._fallback_models()

    def _fallback_models(self) -> list[dict[str, Any]]:
        if self.configured_model:
            return [{"name": self.configured_model, "size": 0, "details": {}}]
        return []

    def show_model(self, name: str) -> dict[str, Any]:
        return {}

    def context_length(self, name: str) -> int:
        # OpenAI-compatible servers do not advertise a window; the app falls
        # back to its own default when this is 0.
        return 0

    def loaded_context_length(self, name: str) -> int:
        # Nor do they report the window a model is being served in. Set
        # `context_window` in the config to give compaction a number to work
        # against on a remote endpoint.
        return 0

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
        payload: dict[str, Any] = {
            "model": model or self.configured_model,
            "messages": [_to_openai_message(m) for m in messages],
            "stream": True,
        }
        if tools:
            payload["tools"] = tools
        if options:
            payload.update(options)
        try:
            return self._stream(payload, on_token, should_stop, on_thinking)
        except OllamaError as e:
            message = str(e).lower()
            # Not every hosted model exposes tool calling. Retry once without
            # tools so the user still gets an answer, and say what happened.
            if tools and ("tool" in message or "function" in message):
                payload.pop("tools", None)
                response = self._stream(payload, on_token, should_stop, on_thinking)
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
        try:
            with requests.post(
                f"{self.base_url}/chat/completions",
                json=payload,
                headers=self._headers(),
                stream=True,
                timeout=self.timeout,
            ) as r:
                if r.status_code >= 400:
                    raise self._error(r)
                for line in r.iter_lines(decode_unicode=True):
                    if should_stop is not None and should_stop():
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
        except requests.RequestException as e:
            raise OllamaError(f"chat request failed: {e}") from e

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
            resp.tool_calls.append(ToolCall(name=name, arguments=arguments))
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
                slot = partial.setdefault(index, {"name": "", "arguments": ""})
                function = call.get("function") or {}
                if function.get("name"):
                    slot["name"] = str(function["name"])
                if function.get("arguments"):
                    slot["arguments"] += str(function["arguments"])
            finish = choice.get("finish_reason")
            if finish:
                resp.done = True
                resp.done_reason = "length" if finish == "length" else str(finish)


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
            # Names are carried instead of ids: the agent runs tools serially
            # and matches results positionally.
            "tool_call_id": str(message.get("name") or "tool"),
        }
    out: dict[str, Any] = {
        "role": role,
        "content": str(message.get("content") or ""),
    }
    tool_calls = message.get("tool_calls") or []
    if tool_calls:
        out["tool_calls"] = [
            {
                "id": (tc.get("function") or {}).get("name", f"call_{i}"),
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
