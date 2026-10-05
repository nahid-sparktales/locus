from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from locus_memory.errors import ProviderError
from ollama_code.memory_embeddings import LocalOllamaEmbeddings, build_memory_embedding_provider, local_origin


@pytest.fixture
def local_server():
    state = {"digest": "a" * 64, "calls": [], "vectors": [[0.1, 0.2]], "redirect": False}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            self.respond()
        def do_POST(self):
            self.respond()
        def respond(self):
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            state["calls"].append((self.path, payload))
            if state["redirect"]:
                self.send_response(307)
                self.send_header("Location", "http://example.com/never")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            result = ({"models": [{"name": "embed:latest", "digest": state["digest"]}]} if self.path == "/api/tags"
                      else {"capabilities": ["embedding"], "model_info": {"bert.embedding_length": 2}} if self.path == "/api/show"
                      else {"model": "embed:latest", "embeddings": state["vectors"]})
            body = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}", state
    server.shutdown()
    server.server_close()
    thread.join()


@pytest.mark.parametrize("host", ["https://localhost:11434", "http://evil.invalid", "http://10.0.0.1",
    "http://127.0.0.1/a", "http://127.0.0.1?x=1", "http://user:pass@127.0.0.1", "file:///tmp/endpoint"])
def test_non_loopback_origins_are_rejected(host):
    with pytest.raises(ProviderError):
        local_origin(host)


def test_explicit_model_uses_digest_dimensions_and_no_proxy(local_server, monkeypatch):
    origin, state = local_server
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:1")
    provider = LocalOllamaEmbeddings("embed", host=origin)
    assert provider.descriptor.version == "a" * 64
    assert provider.descriptor.dimensions == 2
    assert not provider.descriptor.egress
    assert provider.embed(["memory"], deadline_s=1) == [[0.1, 0.2]]
    assert next(payload for path, payload in state["calls"] if path == "/api/embed")["truncate"] is False
    assert not any(path == "/api/pull" for path, _ in state["calls"])


def test_model_changed_drops_cached_model_and_never_embeds(local_server):
    origin, state = local_server
    provider = LocalOllamaEmbeddings("embed", host=origin)
    state["digest"] = "b" * 64
    with pytest.raises(ProviderError, match="changed"):
        provider.embed(["memory"], deadline_s=1)
    assert not any(path == "/api/embed" for path, _ in state["calls"])


def test_redirects_and_missing_model_are_unavailable(local_server):
    origin, state = local_server
    assert build_memory_embedding_provider({}) is None
    unavailable = build_memory_embedding_provider({"memory_embedding_model": "missing", "memory_embedding_host": origin})
    with pytest.raises(ProviderError):
        unavailable.embed(["memory"], deadline_s=1)
    state["redirect"] = True
    with pytest.raises(ProviderError):
        LocalOllamaEmbeddings("embed", host=origin)


@pytest.mark.parametrize("vectors", [[[1]], [[float("nan"), 1]], [[True, 1]], [], [[1, 2], [1, 2]]])
def test_invalid_vectors_fail_closed(local_server, vectors):
    origin, state = local_server
    provider = LocalOllamaEmbeddings("embed", host=origin)
    state["vectors"] = vectors
    with pytest.raises(ProviderError):
        provider.embed(["memory"], deadline_s=1)


def test_expired_deadline_sends_nothing(local_server):
    origin, state = local_server
    provider = LocalOllamaEmbeddings("embed", host=origin)
    state["calls"].clear()
    with pytest.raises(ProviderError):
        provider.embed(["memory"], deadline_s=0)
    assert state["calls"] == []
