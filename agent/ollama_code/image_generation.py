"""Image generation and editing through the user's configured Images API account.

The provider key lives only on the ``ImageGenerationService`` the chat
service owns: never in ``core.config`` (which ``save_config`` writes to disk),
never in an event, a preview, a tool result or an error string. The tools
themselves are thin wrappers in ``tools.py`` that call
``ToolContext.image_generation``; nothing here is reachable until the app
configures a provider, and the registry re-checks that at dispatch.

Outbound traffic is one ``POST`` per call to a constant path under a validated
base URL, no redirects, a bounded streamed body, and a payload that must carry
the image bytes inline (``data[0].b64_json``): a ``url``-only answer is refused
rather than fetched. The bytes are sniffed and header-parsed before anything is
written, and the file is written atomically under ``Locus Images/`` with a name
that never overwrites an existing one.
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import re
import secrets
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import requests

from . import USER_AGENT, proxy
from .image_files import FORMAT_MIME, image_info, sniff_format
from .remote import normalize_base_url, validate_remote_url
from .response_parts import IMAGE_SUFFIXES, MAX_ALT_CHARS, MAX_PROMPT_CHARS
from .tools import ToolContext, _close_response_when_stopped, _schema, _workspace_write_root

IMAGE_TOOL_NAMES = frozenset({"generate_image", "edit_image"})
IMAGES_FOLDER = "Locus Images"
MAX_IMAGES_PER_TURN = 4
MAX_IMAGES_PER_SESSION = 24
IMAGE_SIZES = ("auto", "1024x1024", "1536x1024", "1024x1536")
IMAGE_QUALITIES = ("auto", "low", "medium", "high")
DEFAULT_MODEL = "gpt-image-1"
MODEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MAX_API_KEY_CHARS = 4096
MAX_LABEL_CHARS = 200
MAX_TITLE_CHARS = 200
#: The provider answer is JSON around one base64 image; 40 MB of body admits a
#: 20 MB picture with room for the envelope and refuses anything larger.
MAX_RESPONSE_BYTES = 40_000_000
MAX_DECODED_BYTES = 20_000_000
#: Matches the chat attachment ceiling: what the user may send in, the model
#: may send back out for editing, and nothing bigger.
MAX_SOURCE_BYTES = 15 * 1024 * 1024
MAX_SLUG_CHARS = 48
MAX_COLLISION_SUFFIX = 999
REQUEST_TIMEOUT = (10, 180)
#: Only an ``error.code`` token this short and this plain reaches the model.
_ERROR_CODE = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")
SETUP_HINT = "add an OpenAI API account under Settings › Models & Providers › Image generation"
INTERRUPTED = "Error: image generation interrupted."


class ImageProviderError(Exception):
    """A failure whose text is already safe to show the model."""


class ImageToolError(Exception):
    """A tool-argument or workspace problem; text is safe for the model."""


@dataclass(frozen=True)
class ImageProviderConfig:
    base_url: str
    api_key: str = ""
    model: str = DEFAULT_MODEL
    size: str = "auto"
    quality: str = "auto"
    account_id: str = ""
    account_label: str = ""

    @property
    def host(self) -> str:
        return urlsplit(self.base_url).hostname or ""

    def public(self) -> dict[str, Any]:
        """What previews and the settings UI may see. Never the key."""
        return {
            "configured": True,
            "host": self.host,
            "model": self.model,
            "size": self.size,
            "quality": self.quality,
            "account_id": self.account_id,
            "account_label": self.account_label,
            "has_api_key": bool(self.api_key),
        }

    @classmethod
    def parse(cls, body: dict[str, Any]) -> ImageProviderConfig:
        """Validate a ``POST /api/images/provider`` body. Raises ``ValueError``."""
        base_url = normalize_base_url(str(body.get("base_url") or ""))
        if not base_url:
            raise ValueError("base_url is required")
        api_key = body.get("api_key")
        api_key = "" if api_key is None else str(api_key).strip()
        if len(api_key) > MAX_API_KEY_CHARS:
            raise ValueError("api_key is too long")
        if any(ch.isspace() or not ch.isprintable() for ch in api_key):
            # A key that is not a clean header token would make ``requests``
            # raise with the key repr-escaped inside the message, which the
            # raw-key redaction cannot match. The message itself names no key.
            raise ValueError("api_key must not contain whitespace or control characters")
        validate_remote_url(base_url, api_key)
        parsed = urlsplit(base_url)
        host = (parsed.hostname or "").lower()
        loopback = host == "localhost"
        if not loopback:
            import ipaddress
            try:
                loopback = ipaddress.ip_address(host).is_loopback
            except ValueError:
                pass
        if parsed.scheme != "https" and not loopback:
            # Prompts leave the Mac even when no key does.
            raise ValueError("image providers require HTTPS unless the endpoint is on this Mac")
        model = str(body.get("model") or DEFAULT_MODEL).strip()
        if not MODEL_PATTERN.match(model):
            raise ValueError("model must be 1–128 letters, digits, dots, dashes, colons or underscores")
        size = str(body.get("size") or "auto").strip().lower()
        if size not in IMAGE_SIZES:
            raise ValueError("size must be one of " + ", ".join(IMAGE_SIZES))
        quality = str(body.get("quality") or "auto").strip().lower()
        if quality not in IMAGE_QUALITIES:
            raise ValueError("quality must be one of " + ", ".join(IMAGE_QUALITIES))
        account_id = str(body.get("account_id") or "").strip()[:MAX_LABEL_CHARS]
        account_label = str(body.get("account_label") or "").strip()[:MAX_LABEL_CHARS]
        return cls(
            base_url=base_url, api_key=api_key, model=model, size=size, quality=quality,
            account_id=account_id, account_label=account_label,
        )


UNCONFIGURED_STATE: dict[str, Any] = {
    "configured": False, "host": "", "model": "", "size": "", "quality": "",
    "account_id": "", "account_label": "", "has_api_key": False,
}


# ---------------------------------------------------------------- outbound


class _PendingPost:
    """One outbound request on a daemon thread, so the caller can keep polling Stop.

    Whichever side sees the response last closes it: the caller after
    ``abandon()`` if the answer already arrived, otherwise the helper thread when
    the late answer finally lands. Either way the connection is released.
    """

    def __init__(self, send: Callable[[], Any]) -> None:
        self._send = send
        self.done = threading.Event()
        self._lock = threading.Lock()
        self._response: Any = None
        self._error: BaseException | None = None
        self._abandoned = False

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self) -> None:
        try:
            response = self._send()
        except BaseException as exc:  # noqa: BLE001 - re-raised on the calling thread
            self._error = exc
        else:
            with self._lock:
                self._response = response
                late = self._abandoned
            if late:
                _close_quietly(response)
        finally:
            self.done.set()

    def abandon(self) -> None:
        with self._lock:
            self._abandoned = True
            response = self._response
        if response is not None:
            _close_quietly(response)

    def result(self) -> Any:
        if self._error is not None:
            raise self._error
        return self._response


def _close_quietly(response: Any) -> None:
    close = getattr(response, "close", None)
    if callable(close):
        try:
            close()
        except Exception:  # noqa: BLE001 - releasing a socket must never mask the outcome
            pass


class ImageProviderClient:
    """One request per call against the OpenAI Images API shape."""

    def __init__(self, config: ImageProviderConfig) -> None:
        self.config = config

    def generate(self, prompt: str, size: str, quality: str, ctx: ToolContext) -> bytes:
        return self._request("/images/generations", ctx, json_body=self._payload(prompt, size, quality))

    def edit(
        self,
        prompt: str,
        size: str,
        quality: str,
        source: ResolvedSource,
        mask: ResolvedSource | None,
        ctx: ToolContext,
    ) -> bytes:
        files = {"image": (source.name, source.data, source.mime)}
        if mask is not None:
            files["mask"] = (mask.name, mask.data, mask.mime)
        data = {key: str(value) for key, value in self._payload(prompt, size, quality).items()}
        return self._request("/images/edits", ctx, files=files, data=data)

    def _payload(self, prompt: str, size: str, quality: str) -> dict[str, Any]:
        payload: dict[str, Any] = {"model": self.config.model, "prompt": prompt, "n": 1}
        if size != "auto":
            payload["size"] = size
        if quality != "auto":
            payload["quality"] = quality
        if self.config.model.lower().startswith("dall-e"):
            # gpt-image models always answer inline; the older family only
            # does so when asked, and would otherwise hand back a URL.
            payload["response_format"] = "b64_json"
        return payload

    def _headers(self) -> dict[str, str]:
        headers = {"User-Agent": USER_AGENT}
        if self.config.api_key:
            headers["Authorization"] = f"Bearer {self.config.api_key}"
        return headers

    def _redact(self, text: str) -> str:
        key = self.config.api_key
        if key:
            # Exceptions ``repr`` the offending value, so the escaped forms of
            # the key must go too, not only the key itself.
            for variant in (key, repr(key)[1:-1], key.encode("unicode_escape").decode("ascii")):
                text = text.replace(variant, "[redacted]")
        return proxy.redact(text)

    def _request(
        self,
        path: str,
        ctx: ToolContext,
        *,
        json_body: dict[str, Any] | None = None,
        files: dict[str, Any] | None = None,
        data: dict[str, str] | None = None,
    ) -> bytes:
        if ctx.stopped():
            raise ImageProviderError("interrupted")
        url = self.config.base_url + path
        watcher_done = threading.Event()
        watcher: threading.Thread | None = None
        response: Any = None
        try:
            # The provider sends no headers until the picture is finished, so
            # the post itself runs on a helper thread and this thread polls
            # Stop meanwhile; a late answer is closed by whoever sees it last.
            post = _PendingPost(
                lambda: requests.post(
                    url,
                    headers=self._headers(),
                    json=json_body,
                    files=files,
                    data=data,
                    timeout=REQUEST_TIMEOUT,
                    stream=True,
                    allow_redirects=False,
                )
            )
            post.start()
            while not post.done.wait(0.05):
                if ctx.stopped():
                    post.abandon()
                    raise ImageProviderError("interrupted")
            response = post.result()
            if ctx.should_stop is not None:
                watcher = threading.Thread(
                    target=_close_response_when_stopped,
                    args=(response, ctx.should_stop, watcher_done),
                    daemon=True,
                )
                watcher.start()
            status = int(response.status_code)
            if 300 <= status < 400:
                raise ImageProviderError(
                    "the provider redirected the request; configure the final endpoint URL directly."
                )
            raw = self._read_body(response, ctx, MAX_RESPONSE_BYTES if status == 200 else 65_536)
            if status != 200:
                raise self._status_error(status, raw)
            try:
                payload = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError) as exc:
                raise ImageProviderError("the provider returned an unreadable response.") from exc
            return self._decode(payload)
        except ImageProviderError:
            if ctx.stopped():
                raise ImageProviderError("interrupted") from None
            raise
        except Exception as exc:  # noqa: BLE001 - every transport failure reaches the model as text
            if ctx.stopped():
                raise ImageProviderError("interrupted") from None
            raise ImageProviderError(
                self._redact(f"the provider request failed: {type(exc).__name__}: {exc}")
            ) from None
        finally:
            watcher_done.set()
            if watcher is not None:
                watcher.join(timeout=0.2)
            close = getattr(response, "close", None)
            if callable(close):
                close()

    def _read_body(self, response: Any, ctx: ToolContext, limit: int) -> bytes:
        raw = bytearray()
        for chunk in response.iter_content(chunk_size=64 * 1024):
            if ctx.stopped():
                raise ImageProviderError("interrupted")
            if not chunk:
                continue
            if len(raw) + len(chunk) > limit:
                raise ImageProviderError(
                    f"the provider response exceeds the {_size_label(limit)} safety limit."
                )
            raw.extend(chunk)
        return bytes(raw)

    @staticmethod
    def _error_code(raw: bytes) -> str:
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return ""
        error = payload.get("error") if isinstance(payload, dict) else None
        code = error.get("code") if isinstance(error, dict) else None
        if isinstance(code, str) and _ERROR_CODE.match(code):
            return code
        return ""

    def _status_error(self, status: int, raw: bytes) -> ImageProviderError:
        code = self._error_code(raw)
        if code == "moderation_blocked" or "moderation" in code:
            return ImageProviderError(
                f"the provider blocked this prompt ({code}); do not retry the same prompt."
            )
        if status in (401, 403):
            return ImageProviderError(
                f"the provider rejected the API key ({status}); check the account in Settings."
            )
        if status == 429:
            return ImageProviderError(
                "the provider rate-limited this request (429); do not retry automatically."
            )
        if status >= 500:
            return ImageProviderError(f"the provider is unavailable ({status}); try again later.")
        suffix = f": {code}" if code else ""
        return ImageProviderError(f"the provider rejected the request ({status}{suffix}).")

    @staticmethod
    def _decode(payload: Any) -> bytes:
        items = payload.get("data") if isinstance(payload, dict) else None
        first = items[0] if isinstance(items, list) and items and isinstance(items[0], dict) else {}
        encoded = first.get("b64_json")
        if not isinstance(encoded, str) or not encoded:
            if first.get("url"):
                raise ImageProviderError(
                    "the provider returned an image URL instead of image data; Locus does not "
                    "fetch it. Use an endpoint or model that returns b64_json."
                )
            raise ImageProviderError("the provider returned no image.")
        if len(encoded) > MAX_DECODED_BYTES * 4 // 3 + 4:
            raise ImageProviderError("the provider returned an image over 20 MB.")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ImageProviderError("the provider returned unreadable image data.") from exc
        if len(decoded) > MAX_DECODED_BYTES:
            raise ImageProviderError("the provider returned an image over 20 MB.")
        return decoded


# --------------------------------------------------------------- workspace


def _slug(prompt: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", prompt.lower()).strip("-")[:MAX_SLUG_CHARS].strip("-")
    return slug or "image"


def plan_destination(
    ctx: ToolContext, filename: Any, prompt: Any, *, source: Any = None
) -> tuple[Path, str]:
    """The exact file a call will create, as ``(absolute, workspace-relative)``.

    Pure and reproducible: ``file_effects`` names the path before the
    permission prompt and the tool writes the same one afterwards. An edit of
    a workspace file lands beside its ``source``; everything else goes under
    ``Locus Images/``. Raises ``ValueError`` with model-safe text.
    """
    if not ctx.cwd:
        raise ValueError("image generation needs an open workspace")
    raw = str(filename or "").strip()
    beside = _source_sibling(ctx, source)
    if raw:
        if raw.startswith("~") or Path(raw).is_absolute():
            raise ValueError("filename must be a relative workspace path")
        candidate = Path(raw)
        if any(part == ".." for part in candidate.parts):
            raise ValueError("filename must not contain '..'")
        if any(part.startswith(".") for part in candidate.parts):
            raise ValueError("filename components must not start with a dot")
        suffix = candidate.suffix.lower()
        if suffix == ".png":
            relative = candidate
        elif suffix in IMAGE_SUFFIXES:
            relative = candidate.with_suffix(".png")
        else:
            relative = candidate.with_name(candidate.name + ".png")
    elif beside is not None:
        relative = beside
    else:
        relative = Path(IMAGES_FOLDER) / (_slug(str(prompt or "")) + ".png")
    root = Path(ctx.cwd)
    absolute = root / relative
    if ctx.symlink_component(absolute) is not None:
        raise ValueError("the destination crosses a symlink")
    if _workspace_write_root(ctx, absolute) is None or not ctx.is_inside_workspace(absolute):
        raise ValueError("the destination must stay inside the workspace")
    base = absolute
    counter = 1
    while absolute.exists() or absolute.is_symlink():
        counter += 1
        if counter > MAX_COLLISION_SUFFIX:
            raise ValueError("too many images already share this name")
        absolute = base.with_name(f"{base.stem}-{counter}.png")
    return absolute, str(absolute.relative_to(root))


def _source_sibling(ctx: ToolContext, source: Any) -> Path | None:
    """``<source>-edited.png`` next to a contained workspace source, else None."""
    text = str(source or "").strip()
    if not text or text.startswith("attachment:") or not ctx.cwd:
        return None
    try:
        path = ctx.resolve(text)
        if not path.is_file() or not ctx.is_inside_workspace(path):
            return None
        relative = path.relative_to(Path(ctx.cwd))
    except (OSError, RuntimeError, ValueError):
        return None
    if any(part.startswith(".") for part in relative.parts):
        return None
    return relative.with_name(f"{relative.stem}-edited.png")


def write_image_atomically(destination: Path, data: bytes) -> None:
    """Create ``destination`` from a dot-prefixed temp file beside it; never overwrite."""
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    temp = destination.parent / f".tmp-{secrets.token_hex(8)}.png"
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o644)
        if destination.exists() or destination.is_symlink():
            raise FileExistsError(f"{destination.name} appeared before the image was saved")
        os.replace(temp, destination)
    except BaseException:
        try:
            temp.unlink()
        except OSError:
            pass
        raise


@dataclass(frozen=True)
class ResolvedSource:
    name: str
    data: bytes
    mime: str
    #: Workspace-relative path for a file source; None for an attachment.
    path: str | None


def resolve_source(ctx: ToolContext, value: Any, *, mask: bool = False) -> ResolvedSource:
    """Bytes for ``source``/``mask``: a contained workspace image or ``attachment:<name>``."""
    label = "mask" if mask else "source"
    text = str(value or "").strip()
    if not text:
        raise ImageToolError(f"'{label}' is required.")
    if text.startswith("attachment:"):
        name = text[len("attachment:"):].strip()
        for item in ctx.turn_attachments:
            if not isinstance(item, dict) or str(item.get("name") or "") != name:
                continue
            mime = str(item.get("mime_type") or "")
            if not mime.startswith("image/"):
                raise ImageToolError(f"attachment {name!r} is not an image.")
            try:
                data = base64.b64decode(str(item.get("data") or ""), validate=True)
            except (binascii.Error, ValueError) as exc:
                raise ImageToolError(f"attachment {name!r} could not be decoded.") from exc
            return ResolvedSource(name=name or "attachment.png", data=_checked_source(data, name, mask), mime=_mime(data), path=None)
        raise ImageToolError(f"no image named {name!r} is attached to this message.")
    path = ctx.resolve(text)
    if ctx.symlink_component(path) is not None:
        raise ImageToolError(f"{label} {text} crosses a symlink.")
    if not ctx.is_inside_workspace(path):
        raise ImageToolError(f"{label} must be inside the workspace.")
    if not path.is_file():
        raise ImageToolError(f"{label} not found: {text}")
    if path.suffix.lower() not in IMAGE_SUFFIXES:
        raise ImageToolError(f"{label} must be a PNG, JPEG, GIF or WebP file.")
    if path.stat().st_size > MAX_SOURCE_BYTES:
        raise ImageToolError(f"{label} exceeds the 15 MB limit.")
    data = path.read_bytes()
    try:
        relative = str(path.relative_to(Path(ctx.cwd)))
    except ValueError:
        relative = str(path)
    return ResolvedSource(name=path.name, data=_checked_source(data, text, mask), mime=_mime(data), path=relative)


def _checked_source(data: bytes, label: str, mask: bool) -> bytes:
    if len(data) > MAX_SOURCE_BYTES:
        raise ImageToolError(f"{label} exceeds the 15 MB limit.")
    fmt = sniff_format(data[:16])
    if fmt is None or image_info(data, MAX_SOURCE_BYTES) is None:
        raise ImageToolError(f"{label} is not a readable PNG, JPEG, GIF or WebP image.")
    if mask and fmt != "png":
        raise ImageToolError("mask must be a PNG whose transparent pixels mark the region to edit.")
    return data


def _mime(data: bytes) -> str:
    return FORMAT_MIME.get(sniff_format(data[:16]) or "", "application/octet-stream")


# ----------------------------------------------------------------- service


def _clip(text: str, limit: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "…"


def _size_label(size: int) -> str:
    if size >= 1_000_000:
        return f"{size / 1_000_000:.1f} MB"
    if size >= 1_000:
        return f"{size / 1_000:.0f} KB"
    return f"{size} bytes"


def _choice(args: dict[str, Any], key: str, default: str, allowed: tuple[str, ...]) -> str:
    value = args.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        return default
    text = str(value).strip().lower()
    if text not in allowed:
        raise ImageToolError(f"'{key}' must be one of " + ", ".join(allowed) + ".")
    return text


def _describe_source(ctx: ToolContext, value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return "(none)"
    if text.startswith("attachment:"):
        name = text[len("attachment:"):].strip()
        for item in ctx.turn_attachments:
            if isinstance(item, dict) and str(item.get("name") or "") == name:
                encoded = str(item.get("data") or "")
                return f"{name} ({_size_label(len(encoded) * 3 // 4)})"
        return f"{name} (not attached to this message)"
    try:
        path = ctx.resolve(text)
        if path.is_file():
            return f"{text} ({_size_label(path.stat().st_size)})"
    except (OSError, RuntimeError):
        pass
    return f"{text} (not found)"


def build_image_preview(name: str, args: dict[str, Any], ctx: ToolContext) -> tuple[str, str]:
    """The permission panel's summary and detail for an image tool call."""
    prompt = str(args.get("prompt") or "").strip()
    short = _clip(prompt, 60)
    edit = name == "edit_image"
    source = str(args.get("source") or "").strip()
    summary = f'edit image {source}: "{short}"' if edit else f'generate image: "{short}"'
    provider = ctx.image_provider if isinstance(ctx.image_provider, dict) else {}
    try:
        size = _choice(args, "size", str(provider.get("size") or "auto"), IMAGE_SIZES)
    except ImageToolError:
        size = str(args.get("size"))
    try:
        quality = _choice(args, "quality", str(provider.get("quality") or "auto"), IMAGE_QUALITIES)
    except ImageToolError:
        quality = str(args.get("quality"))
    host = str(provider.get("host") or "") or "not configured"
    label = str(provider.get("account_label") or "")
    try:
        _, destination = plan_destination(
            ctx, args.get("filename"), prompt, source=source if edit else None
        )
        saves = f"Saves to: {destination}"
    except ValueError as exc:
        saves = f"Saves to: (unavailable — {exc})"
    lines = [
        f"Prompt: {_clip(prompt, 2000)}",
        f"Model · Size · Quality: {provider.get('model') or 'not configured'} · {size} · {quality}",
        f"Provider host: {host}" + (f" ({label})" if label else ""),
        saves,
        f"Limit: {ctx.image_generations_this_turn} of {MAX_IMAGES_PER_TURN} used this turn, "
        f"{ctx.image_generations_this_session} of {MAX_IMAGES_PER_SESSION} this session.",
        "The prompt is sent to the provider.",
    ]
    if edit:
        sends = _describe_source(ctx, source)
        if args.get("mask"):
            sends += " and " + _describe_source(ctx, args.get("mask"))
        lines.append(f"Sends: {sends} leave this Mac.")
    return summary, "\n".join(lines)


class ImageGenerationService:
    """Holds the configured provider in memory and runs the two image tools."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._config: ImageProviderConfig | None = None

    def configure(self, config: ImageProviderConfig | None) -> None:
        with self._lock:
            self._config = config

    def clear(self) -> None:
        self.configure(None)

    @property
    def configured(self) -> bool:
        with self._lock:
            return self._config is not None

    def state(self) -> dict[str, Any]:
        with self._lock:
            return self._config.public() if self._config is not None else dict(UNCONFIGURED_STATE)

    def execute(self, name: str, args: dict[str, Any], ctx: ToolContext) -> str:
        if name not in IMAGE_TOOL_NAMES:
            return f"Error: unknown image tool '{name}'."
        ctx.last_image_result = None
        with self._lock:
            config = self._config
        if config is None:
            return f"Error: image generation is not set up; {SETUP_HINT}."
        if ctx.image_generations_this_turn >= MAX_IMAGES_PER_TURN:
            return (
                f"Error: the limit of {MAX_IMAGES_PER_TURN} images per turn is reached; "
                "ask the user before generating more."
            )
        if ctx.image_generations_this_session >= MAX_IMAGES_PER_SESSION:
            return (
                f"Error: the limit of {MAX_IMAGES_PER_SESSION} images per session is reached; "
                "ask the user before generating more."
            )
        if not isinstance(args, dict):
            return "Error: image tool arguments must be an object."
        try:
            return self._run(name, args, ctx, config)
        except ImageToolError as exc:
            return f"Error: {exc}"
        except ImageProviderError as exc:
            if str(exc) == "interrupted":
                return INTERRUPTED
            return f"Error: {exc}"

    def _run(self, name: str, args: dict[str, Any], ctx: ToolContext, config: ImageProviderConfig) -> str:
        prompt = str(args.get("prompt") or "").strip()
        if not prompt:
            raise ImageToolError("'prompt' is required.")
        if len(prompt) > MAX_PROMPT_CHARS:
            raise ImageToolError(f"'prompt' must be at most {MAX_PROMPT_CHARS} characters.")
        title = " ".join(str(args.get("title") or "").split())[:MAX_TITLE_CHARS]
        size = _choice(args, "size", config.size, IMAGE_SIZES)
        quality = _choice(args, "quality", config.quality, IMAGE_QUALITIES)
        edit = name == "edit_image"
        source = mask = None
        if edit:
            source = resolve_source(ctx, args.get("source"))
            if args.get("mask") is not None and str(args.get("mask")).strip():
                mask = resolve_source(ctx, args.get("mask"), mask=True)
        try:
            destination, relative = plan_destination(
                ctx, args.get("filename"), prompt, source=args.get("source") if edit else None
            )
        except ValueError as exc:
            raise ImageToolError(str(exc)) from None
        if ctx.stopped():
            raise ImageProviderError("interrupted")
        client = ImageProviderClient(config)
        if edit:
            assert source is not None
            data = client.edit(prompt, size, quality, source, mask, ctx)
        else:
            data = client.generate(prompt, size, quality, ctx)
        info = image_info(data, MAX_DECODED_BYTES)
        if info is None or info.format != "png":
            raise ImageToolError("the provider returned data that is not a PNG image; nothing was saved.")
        if ctx.stopped():
            raise ImageProviderError("interrupted")
        try:
            write_image_atomically(destination, data)
        except OSError as exc:
            raise ImageToolError(
                proxy.redact(f"the image could not be saved to {relative}: {exc}")
            ) from None
        part: dict[str, Any] = {
            "type": "image", "id": f"image-{destination.stem}", "path": relative,
            "alt": (title or prompt)[:MAX_ALT_CHARS], "prompt": prompt,
        }
        if title:
            part["title"] = title
        if source is not None and source.path is not None:
            part["source_path"] = source.path
        staged = False
        if ctx.response_parts_enabled and ctx.stage_response_parts is not None:
            staged = not ctx.stage_response_parts([part]).startswith("Error:")
        ctx.image_generations_this_turn += 1
        ctx.image_generations_this_session += 1
        ctx.last_image_result = {
            "name": name, "path": relative, "width": info.width, "height": info.height,
            "format": info.format, "size": len(data),
            **({"source": source.name} if source is not None else {}),
        }
        remaining = MAX_IMAGES_PER_TURN - ctx.image_generations_this_turn
        verb = "Edited" if edit else "Created"
        origin = f" from {source.name}" if source is not None else ""
        text = (
            f"{verb} image {relative}{origin} ({info.width}×{info.height} PNG, "
            f"{_size_label(len(data))}, {config.model})."
        )
        if staged:
            text += (
                " It is attached to your final answer as an image card; "
                "do not repeat it in prose or Markdown."
            )
        else:
            alt = part["alt"].replace("]", "")
            link = relative.replace(" ", "%20")
            text += (
                " Presentation output is unavailable here, so reference it in your "
                f"answer as ![{alt}]({link})."
            )
        plural = "" if remaining == 1 else "s"
        return f"{text} {remaining} generation{plural} remain this turn."


# ----------------------------------------------------------------- schemas


_SHARED_PROPERTIES: dict[str, Any] = {
    "prompt": {"type": "string", "description": "What the image should show."},
    "title": {"type": "string", "description": "Short caption shown with the image."},
    "size": {"type": "string", "enum": list(IMAGE_SIZES)},
    "quality": {"type": "string", "enum": list(IMAGE_QUALITIES)},
    "filename": {"type": "string", "description": "Optional relative path; .png is forced and an existing file is never overwritten."},
}

IMAGE_TOOL_SCHEMAS: list[dict[str, Any]] = [
    _schema(
        "generate_image",
        "Create one PNG image from a text prompt with the user's configured image provider and save it under Locus Images/ in the workspace. "
        "The prompt is sent to that provider and the user approves each call. The image is attached to your final answer automatically; "
        "do not repeat it in prose or Markdown and never paste image data. Not for charts from data (write a script and stage the PNG with attach_output_parts). At most 4 per turn.",
        dict(_SHARED_PROPERTIES),
        ["prompt"],
    ),
    _schema(
        "edit_image",
        "Edit an existing image with the user's configured image provider: source is a workspace-relative image path or attachment:<name> for an image attached to this message; "
        "mask is an optional workspace PNG whose transparent pixels mark the region to change. Source and mask bytes are uploaded to the provider and the user confirms every call. "
        "The result is saved as a new PNG beside the source and attached to your final answer automatically.",
        {
            **_SHARED_PROPERTIES,
            "source": {"type": "string", "description": "Workspace-relative image path, or attachment:<name>."},
            "mask": {"type": "string", "description": "Workspace-relative PNG mask."},
        },
        ["prompt", "source"],
    ),
]


__all__ = [
    "IMAGES_FOLDER",
    "IMAGE_QUALITIES",
    "IMAGE_SIZES",
    "IMAGE_TOOL_NAMES",
    "IMAGE_TOOL_SCHEMAS",
    "MAX_IMAGES_PER_SESSION",
    "MAX_IMAGES_PER_TURN",
    "ImageGenerationService",
    "ImageProviderClient",
    "ImageProviderConfig",
    "ImageProviderError",
    "ImageToolError",
    "ResolvedSource",
    "build_image_preview",
    "plan_destination",
    "resolve_source",
    "write_image_atomically",
]
