"""Exercise evaluation startup over HTTP through a real supervisor and child."""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
import requests

from ollama_code.runtime_store import PrivateStore


@pytest.mark.parametrize("scenario,expected", [("ready", "passed"), ("rubric", "ungraded"), ("loop", "budget_exhausted")])
def test_supervisor_evaluation_repetitions_and_missing_judge(tmp_path, scenario, expected):
    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"data":[]}')

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            if scenario == 'loop':
                delta = {'tool_calls': [{'index': 0, 'id': 'read-1', 'type': 'function', 'function': {'name': 'read_file', 'arguments': json.dumps({'path': 'baseline.txt'})}}]}
            else:
                delta = {'content': 'ready'}
            for data in [{'choices': [{'delta': delta, 'finish_reason': None}]},
                         {'choices': [{'delta': {}, 'finish_reason': 'tool_calls' if scenario == 'loop' else 'stop'}], 'usage': {'prompt_tokens': 10, 'completion_tokens': 2}}]:
                self.wfile.write(('data: ' + json.dumps(data) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')

    provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    workspace = tmp_path / 'project'
    workspace.mkdir()
    (workspace / 'baseline.txt').write_text('immutable')
    for args in (['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Baseline']):
        subprocess.run(['git', *args], cwd=workspace, check=True)
    root = tmp_path / 'runtime'
    token = PrivateStore(root).token()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    environment = {**os.environ, 'OLLAMA_CODE_HOME': str(tmp_path / 'profile'),
                   'PYTHONPATH': str(Path(__file__).resolve().parents[1]), 'LOCUS_CODEX_HOME': str(tmp_path / 'codex')}
    log = (tmp_path / 'service.log').open('w+')
    process = subprocess.Popen([sys.executable, '-m', 'ollama_code.runtime', '--home', str(root), '--port', str(port), '--cwd', str(workspace)],
                               env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    client = requests.Session()
    client.trust_env = False
    client.headers['X-Locus-Token'] = token
    base = f'http://127.0.0.1:{port}'
    try:
        for _ in range(150):
            try:
                if client.get(base + '/api/runtime', timeout=.3).ok:
                    break
            except requests.RequestException:
                pass
            time.sleep(.1)
        else:
            pytest.fail('Supervisor did not become ready')
        response = client.post(base + '/api/provider', json={'provider': 'remote', 'model': 'fixture', 'base_url': f'http://127.0.0.1:{provider.server_port}/v1', 'api_key': 'fixture'}, timeout=10)
        assert response.ok, response.text
        response = client.post(base + '/api/evaluations', json={'name': 'Independent evaluation', 'workspace_root': str(workspace), 'repetitions': 2,
                               'cases': [{'id': 'needs-judge', 'target': 'solo', 'mode': 'read_only', 'prompt': 'Say ready.', 'rubric': 'The answer is clear.' if scenario == 'rubric' else '', 'budget': {'max_model_calls': 1, 'max_concurrent_calls': 1},
                                          'assertions': [{'kind': 'output_contains', 'value': 'ready'}]}]}, timeout=15)
        assert response.ok, response.text
        suite_id = response.json()['suite']['id']
        response = client.post(base + f'/api/evaluations/{suite_id}/run', json={}, timeout=40)
        assert response.ok, response.text
        assert response.json()['session_id']
        for _ in range(200):
            value = client.get(base + f'/api/evaluations/{suite_id}', timeout=5).json()
            if len(value['results']) == 2 and all(row['state'] != 'running' for row in value['results']):
                break
            time.sleep(.1)
        assert len(value['results']) == 2, value
        assert {row['state'] for row in value['results']} == {expected}, value
        assert value['summary']['pass_rate'] == (1 if scenario == 'ready' else 0)
        assert value['summary']['completion_rate'] == (0 if scenario == 'loop' else 1)
        assert value['summary']['rubric_coverage'] == (0 if scenario == 'rubric' else None)
        assert len({row['configuration_id'] for row in value['results']}) == 1
        assert len({row['environment']['baseline_tree'] for row in value['results']}) == 1
        assert (workspace / 'baseline.txt').read_text() == 'immutable'
        for row in value['results']:
            usage = client.get(base + '/api/usage/invocations', params={'run_id': row['run_id']}, timeout=5).json()
            assert usage['summary']['model_calls'] == 1
            assert usage['summary']['total_tokens'] == 12
            assert usage['summary']['estimated_api_cost'] is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        provider.shutdown()
        provider.server_close()
        client.close()
        log.close()
