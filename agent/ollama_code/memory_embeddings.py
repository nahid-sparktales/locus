"""Explicit, local-only Ollama embeddings for the memory package.

No pull API is called. Registration discovers an already installed model's digest
and dimension. Every call checks that the selected tag still has that digest.
Transport never uses environment proxies or follows redirects.
"""
from __future__ import annotations

import http.client
import ipaddress
import json
import math
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from typing import Any

from locus_memory.errors import ProviderError
from locus_memory.providers.base import EMBED, ProviderDescriptor

PROVIDER_NAME = "ollama-local"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_INPUT_BYTES = 256 * 1024
MAX_BATCH = 32
MAX_DEADLINE_S = 4.0
PREPROCESSING_VERSION = "ollama-embed-no-truncate-v1"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProviderError("local embedding redirects are forbidden")


def local_origin(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError as exc:
        raise ProviderError("embeddings require a valid loopback origin") from exc
    if (parsed.scheme != "http" or parsed.username or parsed.password or parsed.query
            or parsed.fragment or parsed.path not in ("", "/")):
        raise ProviderError("embeddings require a plain loopback HTTP origin")
    host = parsed.hostname or ""
    # Pin localhost to a literal address: no DNS changes/rebinding during requests.
    if host == "localhost":
        host = "127.0.0.1"
    try:
        address = ipaddress.ip_address(host)
        port = parsed.port or 11434
    except ValueError as exc:
        raise ProviderError("embeddings require a loopback address") from exc
    if not address.is_loopback or not 1 <= port <= 65535:
        raise ProviderError("embeddings require a loopback address")
    authority = f"[{address}]" if address.version == 6 else str(address)
    return f"http://{authority}:{port}"


class _LocalTransport:
    def __init__(self, host: str):
        self.origin = local_origin(host)

    def _json(self, path: str, payload: dict[str, Any] | None, end: float) -> dict[str, Any]:
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise ProviderError("local embedding deadline exceeded")
        body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        parsed = urllib.parse.urlsplit(self.origin)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=remaining)
        sockets = []
        def expire():
            # Socket timeout alone measures inactivity; a dribbling response can defeat it.
            # Shutdown also bounds header reads and HTTP/1.0 response-owned sockets.
            for active in [connection.sock, *sockets]:
                if active is not None:
                    try:
                        active.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        timer = threading.Timer(remaining, expire)
        timer.daemon = True
        timer.start()
        try:
            connection.request("GET" if body is None else "POST", path, body=body,
                               headers={"Content-Type": "application/json"})
            sockets.append(connection.sock)
            response = connection.getresponse()
            if response.status != 200:
                raise ProviderError("local embedding endpoint rejected the request or redirected")
            raw = bytearray()
            while len(raw) <= MAX_RESPONSE_BYTES:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise ProviderError("local embedding deadline exceeded")
                # Recompute the socket deadline after every chunk; dribbling bytes cannot
                # extend the total call deadline. Direct HTTPConnection has no proxy/redirect.
                if connection.sock is not None:
                    connection.sock.settimeout(remaining)
                chunk = response.read1(min(65536, MAX_RESPONSE_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) > MAX_RESPONSE_BYTES or time.monotonic() >= end:
                raise ProviderError("local embedding response exceeded its budget")
            value = json.loads(raw)
        except (OSError, ValueError, http.client.HTTPException) as exc:
            raise ProviderError("local embedding endpoint unavailable or invalid") from exc
        finally:
            timer.cancel()
            connection.close()
        if not isinstance(value, dict) or value.get("error"):
            raise ProviderError("local embedding endpoint returned an invalid object")
        return value


def installed_memory_models(host: str, *, deadline_s: float = 2.0) -> list[str]:
    """Read installed names only; selection validates embedding capability separately."""
    result = _LocalTransport(host)._json("/api/tags", None, time.monotonic() + min(4, deadline_s))
    models = result.get("models")
    if not isinstance(models, list) or len(models) > 10000:
        raise ProviderError("installed model inventory is invalid")
    return sorted({str(item["name"]) for item in models if isinstance(item, dict)
                   and isinstance(item.get("name"), str) and 0 < len(item["name"]) <= 256})


class LocalOllamaEmbeddings(_LocalTransport):
    def __init__(self, model: str, *, host: str = "http://127.0.0.1:11434",
                 deadline_s: float = MAX_DEADLINE_S) -> None:
        if not isinstance(model, str) or not model.strip() or len(model) > 256:
            raise ProviderError("select an installed embedding model")
        self.model = model.strip()
        super().__init__(host)
        end = time.monotonic() + min(MAX_DEADLINE_S, max(0.001, deadline_s))
        self.digest = self._installed_digest(end)
        info = self._json("/api/show", {"model": self.model}, end)
        if not isinstance(info.get("capabilities"), list) or "embedding" not in info["capabilities"]:
            raise ProviderError("selected model does not advertise embedding support")
        model_info = info.get("model_info")
        if not isinstance(model_info, dict):
            raise ProviderError("embedding model dimensions are unavailable")
        dimensions = {value for key, value in model_info.items()
                      if key.endswith(".embedding_length") and isinstance(value, int)
                      and not isinstance(value, bool) and 1 <= value <= 16384}
        if len(dimensions) != 1:
            raise ProviderError("embedding model dimensions are ambiguous or unavailable")
        self.dimensions = dimensions.pop()
        self.descriptor = ProviderDescriptor(
            name=PROVIDER_NAME, capabilities=frozenset({EMBED}), egress=False,
            model=self.model, version=self.digest, dimensions=self.dimensions,
            preprocessing_version=PREPROCESSING_VERSION, cost_per_unit_micros=0,
            max_batch=MAX_BATCH, notes="Explicit installed local Ollama model; no automatic download",
        )

    def _installed_digest(self, end: float) -> str:
        models = self._json("/api/tags", None, end).get("models")
        if not isinstance(models, list) or len(models) > 10000:
            raise ProviderError("installed embedding model inventory is invalid")
        names = {self.model, self.model + ":latest"} if ":" not in self.model else {self.model}
        digests = {item.get("digest") for item in models if isinstance(item, dict)
                   and isinstance(item.get("digest"), str)
                   and any(isinstance(item.get(key), str) and item[key] in names for key in ("name", "model"))}
        if len(digests) != 1:
            raise ProviderError("selected embedding model is not installed unambiguously")
        digest = digests.pop()
        if not isinstance(digest, str) or not re.fullmatch(r"(?:sha256:)?[0-9a-f]{64}", digest):
            raise ProviderError("installed embedding model digest is invalid")
        return digest.removeprefix("sha256:")

    def embed(self, texts: list[str], *, deadline_s: float | None) -> list[list[float]]:
        if (not isinstance(texts, list) or not 1 <= len(texts) <= MAX_BATCH
                or any(not isinstance(text, str) for text in texts)
                or sum(len(text.encode("utf-8")) for text in texts) > MAX_INPUT_BYTES):
            raise ProviderError("local embedding input exceeds its budget")
        if deadline_s is not None and (not math.isfinite(deadline_s) or deadline_s <= 0):
            raise ProviderError("local embedding deadline exceeded")
        end = time.monotonic() + min(MAX_DEADLINE_S, deadline_s or MAX_DEADLINE_S)
        if self._installed_digest(end) != self.digest:
            raise ProviderError("embedding model changed; reselect the installed model")
        result = self._json("/api/embed", {"model": self.model, "input": texts,
                                          "truncate": False, "keep_alive": "5m"}, end)
        returned_model = result.get("model")
        valid_names = {self.model, self.model + ":latest"} if ":" not in self.model else {self.model}
        if not isinstance(returned_model, str) or returned_model not in valid_names:
            raise ProviderError("embedding response came from a different model")
        vectors = result.get("embeddings")
        if (not isinstance(vectors, list) or len(vectors) != len(texts)
                or any(not isinstance(vector, list) or len(vector) != self.dimensions for vector in vectors)
                or any(isinstance(x, bool) or not isinstance(x, (int, float))
                       or not math.isfinite(x) or abs(x) > 3e38 for vector in vectors for x in vector)):
            raise ProviderError("local embedding response dimensions or values are invalid")
        if self._installed_digest(end) != self.digest:
            raise ProviderError("embedding model changed during request; vectors discarded")
        return vectors


class _UnavailableEmbeddings:
    def __init__(self, model: str) -> None:
        self.descriptor = ProviderDescriptor(name=PROVIDER_NAME, capabilities=frozenset({EMBED}),
            egress=False, model=model[:256], version="unavailable", dimensions=1,
            preprocessing_version=PREPROCESSING_VERSION, cost_per_unit_micros=0)

    def embed(self, texts: list[str], *, deadline_s: float | None) -> list[list[float]]:
        raise ProviderError("selected local embedding model is unavailable; using keyword retrieval")


def build_memory_embedding_provider(config: Mapping[str, Any]):
    """None means disabled; unavailable selection remains visible as degraded retrieval."""
    model = str(config.get("memory_embedding_model") or "").strip()
    if not model:
        return None
    try:
        return LocalOllamaEmbeddings(model, host=str(config.get("memory_embedding_host")
                                                      or "http://127.0.0.1:11434"))
    except ProviderError:
        return _UnavailableEmbeddings(model)
