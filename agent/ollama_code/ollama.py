"""Ollama HTTP client with NDJSON streaming and native tool calling."""
from __future__ import annotations

import json
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Any

import requests

DEFAULT_HOST = "http://localhost:11434"


def effective_context_length(loaded: int, trained: int, configured: int = 0) -> int:
    """The window a model is really running in, 0 when that is not known yet.

    A model does not get the window it was trained for. Ollama sizes the window
    itself unless a request sets ``num_ctx``, so budgeting a conversation
    against the trained window is how a session reports "12% full" at 96% of
    the real one: the prompt crowds out the reply, a long tool call is cut off
    partway through its JSON arguments, and Ollama rejects it with "unexpected
    end of JSON input". Compaction never rescues it either, because the
    threshold it waits for cannot be reached inside the window in use.

    Three sources, in order of authority:

    * ``configured`` — the user asked for a specific window, so that is what
      gets requested as ``num_ctx``. Clamped to what the model can do.
    * ``loaded`` — what Ollama reports for a resident model (``/api/ps``). The
      only authoritative answer, and the reason nothing is guessed here: it is
      measured rather than assumed, and asking for nothing lets Ollama keep
      sizing the window the way it always has.
    * neither — unknown. 0, which means "send no ``num_ctx`` and do not budget",
      exactly as before this was worked out.
    """
    if configured > 0:
        return min(configured, trained) if trained > 0 else configured
    if loaded <= 0:
        return 0
    return min(loaded, trained) if trained > 0 else loaded


def pinned_context_length(trained: int, cap: int, loaded: int = 0) -> int:
    """The window to request as ``num_ctx``, or 0 to leave Ollama in charge.

    Ollama defaults to a 4096-token window, and a turn spends most of that
    before the conversation starts: the tool schemas alone are around 1,500
    tokens, plus the system prompt, the skill index and the room reserved for a
    reply. What is left cannot hold a single file read, so the agent asks for
    something workable instead of accepting a default that was chosen for chat.

    `trained` is the ceiling the model was built for and `cap` the ceiling this
    machine is willing to pay for in KV cache. A resident runner that is already
    larger is adopted rather than shrunk: asking for less than what is loaded
    would evict a working runner to build a smaller one.

    0 when the trained window is unknown — that is the one case where a request
    would be a guess, and Ollama's own accounting is better than a guess.
    """
    if trained <= 0 or cap <= 0:
        return max(loaded, 0)
    return max(min(trained, cap), max(loaded, 0))


class OllamaError(Exception):
    """Raised when the Ollama server is unreachable or returns an error."""


def looks_like_image_rejection(error_text: str) -> bool:
    """Whether a provider explicitly rejected an image-bearing request."""
    lowered = error_text.lower()
    image_terms = ("image", "vision", "multimodal", "image_url", "input_image")
    rejection_terms = (
        "not support", "unsupported", "not allowed", "invalid", "cannot", "can't",
        "could not", "unable", "does not accept", "unknown content type",
    )
    return any(term in lowered for term in image_terms) and any(
        term in lowered for term in rejection_terms
    )


@dataclass
class ToolCall:
    name: str
    arguments: dict[str, Any]
    call_id: str = ""


@dataclass
class ChatResponse:
    content_parts: list[str] = field(default_factory=list)
    thinking_parts: list[str] = field(default_factory=list)
    tool_calls: list[ToolCall] = field(default_factory=list)
    provider_fields: dict[str, Any] = field(default_factory=dict)
    done: bool = False
    done_reason: str = ""
    prompt_eval_count: int = 0
    eval_count: int = 0

    @property
    def content(self) -> str:
        return "".join(self.content_parts)

    @property
    def thinking(self) -> str:
        return "".join(self.thinking_parts)


def process_chunk(chunk: dict[str, Any], resp: ChatResponse) -> str:
    """Update ``resp`` from one parsed NDJSON chunk. Returns any content token.

    Handles tool_calls arriving in late chunks and arguments given either as a
    dict or as a JSON-encoded string (both seen in the wild from small models).
    Native reasoning output lands in ``resp.thinking_parts``; callers that
    stream it watch that list rather than the return value.
    """
    token = ""
    msg = chunk.get("message") or {}
    content = msg.get("content")
    if content:
        token = content
        resp.content_parts.append(content)
    thinking = msg.get("thinking")
    if thinking:
        resp.thinking_parts.append(thinking)
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        name = fn.get("name")
        args = fn.get("arguments") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args) if args.strip() else {}
            except json.JSONDecodeError:
                args = {"command": args} if name == "bash" else {"_raw": args}
        if not isinstance(args, dict):
            args = {"value": args}
        if name:
            resp.tool_calls.append(
                ToolCall(
                    name=str(name),
                    arguments=args,
                    call_id=str(tc.get("id") or ""),
                )
            )
    if chunk.get("done"):
        resp.done = True
        resp.done_reason = str(chunk.get("done_reason") or "")
        resp.prompt_eval_count = int(chunk.get("prompt_eval_count") or 0)
        resp.eval_count = int(chunk.get("eval_count") or 0)
    return token


class OllamaClient:
    def __init__(self, host: str = DEFAULT_HOST, timeout: int = 600) -> None:
        self.host = host.rstrip("/")
        self.timeout = timeout
        # `/api/show` describes a file on disk, so its answer only changes when a
        # model is pulled or deleted. Without this, listing models asked once per
        # installed model per call, and the app polls that list every 15s.
        self._show_cache: dict[str, dict[str, Any]] = {}

    def check(self) -> None:
        """Raise OllamaError if the server is unreachable."""
        try:
            r = requests.get(f"{self.host}/api/version", timeout=5)
            r.raise_for_status()
        except requests.RequestException as e:
            raise OllamaError(f"cannot reach Ollama at {self.host}: {e}") from e

    def version(self) -> str:
        try:
            r = requests.get(f"{self.host}/api/version", timeout=5)
            r.raise_for_status()
            return str(r.json().get("version") or "")
        except requests.RequestException as e:
            raise OllamaError(f"cannot reach Ollama at {self.host}: {e}") from e

    def list_models(self) -> list[dict[str, Any]]:
        try:
            r = requests.get(f"{self.host}/api/tags", timeout=10)
            r.raise_for_status()
            return list(r.json().get("models") or [])
        except requests.RequestException as e:
            raise OllamaError(f"failed to list models: {e}") from e

    def running_models(self) -> list[dict[str, Any]]:
        """Models currently loaded in memory (GET /api/ps)."""
        try:
            r = requests.get(f"{self.host}/api/ps", timeout=10)
            r.raise_for_status()
            return list(r.json().get("models") or [])
        except requests.RequestException as e:
            raise OllamaError(f"failed to list running models: {e}") from e

    def resident_state(self, name: str) -> dict[str, int]:
        """What `/api/ps` says about a resident model, as one read.

        Returns ``{"context_length", "size", "size_vram"}``, all 0 when the model
        is not loaded. `size` is the total the runner occupies and `size_vram` how
        much of that the GPU holds — the two numbers `ollama ps` renders as
        "100% GPU" or "48%/52% CPU/GPU". A window that made the model spill to
        CPU is measurable from them, which is the only honest way to find out:
        predicting the KV-cache cost from GGUF metadata does not survive contact
        with real models, since a hybrid attention/SSM architecture does not
        publish `head_count_kv` at all and does not pay per-token KV on every
        layer even when it does.
        """
        empty = {"context_length": 0, "size": 0, "size_vram": 0}
        if not name:
            return empty
        try:
            running = self.running_models()
        except OllamaError:
            return empty
        for entry in running:
            if name in (entry.get("name"), entry.get("model")):
                return {
                    key: int(entry.get(key) or 0)
                    if isinstance(entry.get(key), int) and int(entry.get(key) or 0) > 0
                    else 0
                    for key in empty
                }
        return empty

    def loaded_context_length(self, name: str) -> int:
        """The window a resident model was loaded with, 0 when it is not loaded.

        `/api/ps` is the only place Ollama states the window it actually chose,
        which is not the one the model was trained for and not necessarily any
        documented default either.
        """
        return self.resident_state(name)["context_length"]

    def show_model(self, name: str) -> dict[str, Any]:
        """POST /api/show — model details incl. context length. Memoised."""
        cached = self._show_cache.get(name)
        if cached is not None:
            return cached
        try:
            r = requests.post(f"{self.host}/api/show", json={"name": name}, timeout=15)
            r.raise_for_status()
            details = dict(r.json())
        except requests.RequestException as e:
            raise OllamaError(f"failed to inspect model {name}: {e}") from e
        self._show_cache[name] = details
        return details

    def forget_model_details(self, name: str = "") -> None:
        """Drop memoised `/api/show` answers — a pull or delete changed them."""
        if name:
            self._show_cache.pop(name, None)
        else:
            self._show_cache.clear()

    def context_length(self, name: str) -> int:
        """The window a model was trained for, 0 when unknown.

        This is the architectural maximum, not the window Ollama will actually
        allocate — see `effective_context_length` for that distinction.
        """
        try:
            info = (self.show_model(name).get("model_info") or {})
        except OllamaError:
            return 0
        # The text model's own key first. A multimodal GGUF publishes a window
        # for its vision encoder too, and picking whichever came first in dict
        # order would sometimes hand back that one instead.
        architecture = str(info.get("general.architecture") or "")
        if architecture:
            value = info.get(f"{architecture}.context_length")
            if isinstance(value, int):
                return value
        for key, value in info.items():
            if key.endswith(".context_length") and isinstance(value, int):
                return value
        return 0

    def supports_tools(self, name: str) -> bool:
        """True when the model advertises tool-calling support."""
        try:
            show = self.show_model(name)
        except OllamaError:
            return True  # assume yes rather than block the user
        caps = show.get("capabilities")
        if isinstance(caps, list) and caps:
            return "tools" in caps
        template = str(show.get("template") or "")
        return "tool" in template.lower()

    def vision_capability(self, name: str) -> bool | None:
        """Whether the model accepts image input; None when Ollama cannot say."""
        try:
            show = self.show_model(name)
        except OllamaError:
            return None
        caps = show.get("capabilities")
        if isinstance(caps, list) and caps:
            return "vision" in caps
        return None

    def pull(self, name: str) -> Iterator[dict[str, Any]]:
        """Stream `ollama pull` progress chunks for ``name``."""
        try:
            with requests.post(
                f"{self.host}/api/pull",
                json={"model": name, "stream": True},
                stream=True,
                timeout=(10, 300),
            ) as r:
                if r.status_code != 200:
                    raise OllamaError(f"pull failed: HTTP {r.status_code}: {r.text[:300]}")
                for line in r.iter_lines(decode_unicode=True):
                    if not line:
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if chunk.get("error"):
                        raise OllamaError(str(chunk["error"]))
                    yield chunk
        except requests.RequestException as e:
            raise OllamaError(f"pull request failed: {e}") from e
        finally:
            # The file on disk is new, so anything memoised about it is stale —
            # including the trained window the pinned window is derived from.
            self.forget_model_details(name)

    def delete_model(self, name: str) -> None:
        try:
            r = requests.delete(f"{self.host}/api/delete", json={"model": name}, timeout=30)
            r.raise_for_status()
        except requests.RequestException as e:
            raise OllamaError(f"failed to delete {name}: {e}") from e
        finally:
            self.forget_model_details(name)

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
        """Stream a chat completion. Raises OllamaError on failure.

        KeyboardInterrupt propagates so the caller can abort mid-stream.
        ``should_stop`` gives callers a soft-interrupt: the stream ends after
        the current chunk and the response is marked done_reason=interrupted.
        """
        native_messages: list[dict[str, Any]] = []
        for message in messages:
            native = dict(message)
            attachments = native.pop("attachments", None) or []
            images = [
                str(item.get("data") or "")
                for item in attachments
                if isinstance(item, dict) and item.get("data")
            ]
            if images:
                native["images"] = images
            native_messages.append(native)

        payload: dict[str, Any] = {
            "model": model,
            "messages": native_messages,
            "stream": True,
            "think": think,
        }
        if tools:
            payload["tools"] = tools
        if options:
            payload["options"] = options
        emitted = False

        def tracking(callback: Callable[[str], None] | None) -> Callable[[str], None] | None:
            if callback is None:
                return None

            def wrapped(text: str) -> None:
                nonlocal emitted
                emitted = True
                callback(text)

            return wrapped

        try:
            return self._stream(payload, tracking(on_token), should_stop, tracking(on_thinking))
        except OllamaError as e:
            # Older servers / unusual builds may reject the `think` field.
            # That rejection arrives before anything streams; once output has
            # reached the callbacks, retrying would play the whole answer to
            # the UI a second time, so it is no longer this fallback's case —
            # error text is server-controlled and can mention "think" for
            # entirely different reasons.
            if "think" in str(e).lower() and not emitted:
                payload.pop("think", None)
                return self._stream(payload, on_token, should_stop, on_thinking)
            raise

    def _stream(
        self,
        payload: dict[str, Any],
        on_token: Callable[[str], None] | None,
        should_stop: Callable[[], bool] | None = None,
        on_thinking: Callable[[str], None] | None = None,
    ) -> ChatResponse:
        resp = ChatResponse()
        watcher_done = threading.Event()
        watcher: threading.Thread | None = None
        try:
            with requests.post(
                f"{self.host}/api/chat",
                json=payload,
                stream=True,
                timeout=(10, self.timeout),
                allow_redirects=False,
            ) as r:
                if r.status_code != 200:
                    raise OllamaError(f"Ollama returned HTTP {r.status_code}: {r.text[:500]}")
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
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if chunk.get("error"):
                        raise OllamaError(str(chunk["error"]))
                    thoughts_before = len(resp.thinking_parts)
                    token = process_chunk(chunk, resp)
                    if token and on_token:
                        on_token(token)
                    if on_thinking and len(resp.thinking_parts) > thoughts_before:
                        on_thinking(resp.thinking_parts[-1])
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
            raise OllamaError(f"chat request failed: {e}") from e
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
        return resp


def _close_when_stopped(
    response: requests.Response,
    should_stop: Callable[[], bool],
    done: threading.Event,
) -> None:
    """Close a stalled response so Stop does not wait for the read timeout."""
    while not done.wait(0.05):
        if should_stop():
            response.close()
            return
