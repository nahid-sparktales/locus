"""Side-blind checks against the real HTTP middleware, using private fixtures."""
import http.client
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

checkout = Path(os.environ['PPV_CHECKOUT'])
sys.path[:0] = [str(checkout / 'agent'), str(checkout / 'agent/tests')]
base = Path(tempfile.mkdtemp(prefix='disconnect-')).resolve()
os.environ['OLLAMA_CODE_HOME'] = str(base / 'home')
from test_plugin_panel_context import panel
from ollama_code import server as server_mod
from ollama_code.image_generation import ImageProviderError
import uvicorn

mode = sys.argv[1]
fixture = panel.__wrapped__(base)
service, payload, manager, runtime = next(fixture)
started, published, cancelled = (base / name for name in ('started', 'published', 'cancelled'))
token = 'private-validation-token'
path = '/api/extensions/plugins/panel-tool'

if mode == 'plugin':
    source = Path(manager._plugin(payload['plugin_id'])['root']) / 'server.py'
    source.write_text(source.read_text().replace(
        "    await asyncio.sleep(30)\n    return 'finished'",
        "    try:\n        await asyncio.sleep(2)\n"
        f"        Path({str(published)!r}).write_text('published')\n"
        "        return 'finished'\n    except asyncio.CancelledError:\n"
        f"        Path({str(cancelled)!r}).write_text('cancelled')\n        raise"))
    payload = {**payload, 'tool': 'slow', 'arguments': {'marker': str(started)}}
elif mode == 'portrait':
    from ollama_code.capabilities import CAPABILITY_ENV
    os.environ[CAPABILITY_ENV['image_generation_v1']] = '1'
    def preview(prompt, account, ctx):
        started.touch()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if ctx.stopped():
                cancelled.touch()
                raise ImageProviderError('interrupted')
            time.sleep(.01)
        published.touch()
        return b'fixture'
    service.image_generation = SimpleNamespace(portrait_preview=preview)
    path = '/api/images/portrait'
    payload = {'request_id': '2873cfd9-460b-422a-9cfa-e4b37b160b54',
               'account_id': 'synthetic', 'prompt': 'fixture'}

app = server_mod.create_app(chat_service=service, auth_token=token)
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
port = listener.getsockname()[1]
server = uvicorn.Server(uvicorn.Config(app, log_level='critical', lifespan='off', timeout_graceful_shutdown=3))
worker = threading.Thread(target=server.run, kwargs={'sockets': [listener]}, daemon=True)
worker.start()

def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.01)
    assert predicate(), 'fixture failed to reach the target operation'

def post(headers):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        connection.request('POST', path, json.dumps(payload), {'content-type': 'application/json', **headers})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()

try:
    wait_for(lambda: server.started)
    if mode in ('plugin', 'portrait'):
        with socket.create_connection(('127.0.0.1', port), timeout=5) as client:
            body = json.dumps(payload).encode()
            headers = (f'POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                       f'Content-Type: application/json\r\nX-Locus-Token: {token}\r\n'
                       f'Content-Length: {len(body)}\r\n\r\n').encode()
            client.sendall(headers + body)
            wait_for(started.exists)
            client.shutdown(socket.SHUT_RDWR)
        time.sleep(3)
        observed = {'cancelled': cancelled.exists(), 'published': published.exists()}
        print(json.dumps(observed, sort_keys=True), flush=True)
        print('PPV_REACHED', flush=True)
        assert not observed['published'], 'deferred work executed after disconnect'
    elif mode == 'guards':
        calls = []
        runtime.call_tool = lambda *args, **kwargs: calls.append(True)
        assert post({})[0] == 401
        assert post({'x-locus-token': 'wrong'})[0] == 401
        assert post({'x-locus-token': token, 'origin': 'https://untrusted.example'})[0] == 403
        app.state.runtime = SimpleNamespace(maintenance=True)
        assert post({'x-locus-token': token})[0] == 409
        assert calls == []
        print('auth, origin and maintenance reject before dispatch')
    else:
        status, body = post({'x-locus-token': token})
        assert status == 200, body
        data = json.loads(body)
        assert not data['is_error'], data
        metadata = json.loads(data['content'])['context']['com.locus/panel']
        assert metadata['workspace'] == payload['workspace']
        assert metadata['digest'] == payload['digest']
        print('200: real MCP status preserves workspace and digest')
finally:
    server.should_exit = True
    worker.join(timeout=8)
    listener.close()
    try:
        next(fixture)
    except StopIteration:
        pass
    assert not worker.is_alive(), 'server failed to stop'
