import subprocess
import sys
from pathlib import Path

import pytest
import requests

from ollama_code.benchmark_campaign import Campaign, matrix
from ollama_code.runstore import RunStore
from ollama_code.usage_ledger import UsageLimitError


def configuration():
    return dict(provider='anthropic', model='explicit-fixture', model_version='fixture-v1', account_class='metered', mode='work',
                recipe={}, effort='default', tools=['read_file'], permissions='fixture', app_version='test')


def test_matrix_is_interleaved_and_preserves_unmatched_conditions(tmp_path):
    configs = [configuration(), {**configuration(), 'mode': 'capsule'}]
    cases = matrix(configs, phase=2)
    assert len(cases) == 8 * 3 * 2
    assert cases[0]['scenario'] == cases[1]['scenario']
    campaign = Campaign(RunStore(tmp_path / 'runs.db'), 'fixture', phase=2, configurations=configs)
    campaign.start(cases[0])
    campaign.finish(cases[0], {'state': 'failed', 'execution_outcome': 'timeout', 'duration_ms': 20})
    campaign.finish(cases[1], {'state': 'unsupported', 'reason': 'Dedicated browser adapter is unavailable'})
    report = campaign.report()
    assert report['started_attempts'] == 1
    assert report['acceptance_rate'] == 0
    assert not report['release_gate_passed'] and not report['complete']
    assert report['cases'][1]['state'] == 'unsupported'


def test_campaign_stops_on_unknown_spend_and_never_increases_cap(tmp_path):
    campaign = Campaign(RunStore(tmp_path / 'runs.db'), 'fixture', phase=1, configurations=[configuration()])
    case = campaign.cases[0]
    campaign.start(case)
    call = campaign.reserve(case, 'request1', upper_bound=49)
    with pytest.raises(UsageLimitError):
        campaign.reserve(case, 'request2', upper_bound=1)
    campaign.ledger.reconcile(call, amount=49, note='Provider receipt')
    with pytest.raises(UsageLimitError):
        campaign.reserve(case, 'request2', upper_bound=2)
    assert campaign.report()['cap_usd'] == 50
    with pytest.raises(ValueError):
        campaign.finish(case, {'state': 'passed', 'execution_outcome': 'timeout', 'acceptance_passed': True})
    with pytest.raises(ValueError, match='already started'):
        campaign.start(case)
    with pytest.raises(ValueError, match='original configuration'):
        Campaign(campaign.runs, 'fixture', phase=2, configurations=[configuration()])
    assert campaign.ledger.summary()['limit'] == 50


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
