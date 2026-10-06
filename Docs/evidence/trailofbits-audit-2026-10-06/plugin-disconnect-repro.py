"""Real loopback socket probe; uses only temp files and synthetic plugin writes."""
import json, os, socket, sys, tempfile, threading, time
from pathlib import Path
from importlib.metadata import version
from fastapi import FastAPI
import uvicorn

base = Path(tempfile.mkdtemp(prefix="locus-panel-tcp-audit-"))
os.environ["OLLAMA_CODE_HOME"] = str(base / "home")
repo = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(repo / "agent"), str(repo / "agent/tests")]
import test_plugin_panel_context as context_tests
from ollama_code.api.dependencies import get_service
from ollama_code.api.extensions import call_extension_plugin_panel_tool_http
from ollama_code.server import create_app

fixture = context_tests.panel.__wrapped__(base)
service, payload, manager, runtime = next(fixture)
marker, published, cancelled = (base / name for name in ("validation-started", "published", "cancelled"))
source = Path(manager._plugin(payload["plugin_id"])["root"]) / "server.py"
source.write_text(source.read_text().replace(
    "    await asyncio.sleep(30)\n    return 'finished'",
    "    try:\n"
    "        await asyncio.sleep(2)\n"
    f"        Path({str(published)!r}).write_text('published')\n"
    "        return 'finished'\n"
    "    except asyncio.CancelledError:\n"
    f"        Path({str(cancelled)!r}).write_text('cancelled')\n"
    "        raise",
))
if "--bare" in sys.argv:
    app = FastAPI()
    app.dependency_overrides[get_service] = lambda: service
    app.add_api_route("/api/extensions/plugins/panel-tool", call_extension_plugin_panel_tool_http, methods=["POST"])
else:
    app = create_app(chat_service=service, auth_token="synthetic-audit-token")
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
port = listener.getsockname()[1]
server = uvicorn.Server(uvicorn.Config(app, log_level="critical", lifespan="off", timeout_graceful_shutdown=3))
worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
worker.start()
deadline = time.monotonic() + 10
while not server.started and time.monotonic() < deadline:
    time.sleep(0.01)
assert server.started
started = time.monotonic()
try:
    client = socket.create_connection(("127.0.0.1", port), timeout=5)
    body = json.dumps({**payload, "tool": "slow", "arguments": {"marker": str(marker)}}).encode()
    headers = f"POST /api/extensions/plugins/panel-tool HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nX-Locus-Token: synthetic-audit-token\r\nContent-Length: {len(body)}\r\n\r\n".encode()
    client.sendall(headers + body)
    deadline = time.monotonic() + 10
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert marker.exists(), "tool did not start"
    closed_at = time.monotonic() - started
    client.shutdown(socket.SHUT_RDWR)
    client.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        time.sleep(0.05)
    print(json.dumps({"bare": "--bare" in sys.argv, "versions": {name: version(name) for name in ["fastapi", "starlette", "anyio", "uvicorn", "mcp"]},
        "http_auth": "synthetic valid token", "closed_after_seconds": closed_at,
        "validation_started": marker.exists(), "published_after_disconnect": published.exists(),
        "cancelled": cancelled.exists(), "fixture_root": str(base)}, indent=2))
finally:
    server.should_exit = True
    worker.join(timeout=8)
    try:
        next(fixture)
    except StopIteration:
        pass
