"""Durable HTTP action commit under a dropped response and a service restart."""
import subprocess
import sys
from pathlib import Path

import pytest
import requests


def test_http_commit_survives_dropped_response_and_service_restart(tmp_path):
    script = Path(__file__).parent / 'live' / 'durable_actions.py'
    store = tmp_path / 'actions.db'
    def start():
        process = subprocess.Popen([sys.executable, str(script), '--store', str(store)], stdout=subprocess.PIPE, text=True)
        return process, process.stdout.readline().strip()
    process, url = start()
    try:
        with pytest.raises(requests.ConnectionError):
            requests.post(url + '/actions', json={'action_id': 'one', 'value': 'disposable fixture'},
                          headers={'X-Drop-Response': 'after-commit'}, timeout=5)
        assert len(requests.get(url + '/actions', timeout=5).json()['actions']) == 1
    finally:
        process.terminate()
        process.wait(timeout=5)
    process, url = start()
    try:
        actions = requests.get(url + '/actions', timeout=5).json()['actions']
        assert actions == [{'sequence': 1, 'action_id': 'one', 'value': 'disposable fixture'}]
    finally:
        process.terminate()
        process.wait(timeout=5)
