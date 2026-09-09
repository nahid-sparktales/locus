import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.ollama import ChatResponse
from ollama_code.reusable_checks import ReusableCheckStore, applicable
from ollama_code.runstore import RunStore
from ollama_code.server import _run_user_turn, create_app
from ollama_code.task_state import TaskStateError, TaskStateStore, TaskVerifier


@pytest.fixture
def setup(tmp_path):
    root = tmp_path / 'project'
    root.mkdir()
    core = AgentCore(cwd=str(root), model='fixture', skip_permissions=True, config={'provider': 'ollama', 'auto_compact': False})
    service = ChatService(core)
    service.run_store = RunStore(tmp_path / 'runs.sqlite3')
    core.usage_store = service.run_store
    core._emit_info = lambda: None
    yield root, core, service, ReusableCheckStore(service.run_store)
    core.mcp.close()
    service.close_codex()


def propose(store, root, **updates):
    return store.propose(workspace=str(root), correction='Always keep the result ready.', source={'session_id': 'chat'},
                         proposal={'check': {'id': 'result', 'kind': 'file_contains', 'path': 'result.txt', 'value': 'ready', 'requirement': 'The result contains ready'}, **updates})


def freeze(service, root, key='task', **kwargs):
    tasks = TaskStateStore(service.run_store)
    return tasks.ensure(key, request='Do the task', revision=1, workspace=str(root), execution=str(root), **kwargs)


def test_no_proposals_or_checks_without_explicit_request(setup):
    root, _, service, store = setup
    assert store.list(root) == []
    assert freeze(service, root)['reusable_checks'] == []
    assert store.list(root) == []


def test_proposed_and_dismissed_checks_never_enter_task_contracts(setup):
    root, _, service, store = setup
    value = propose(store, root)
    assert not freeze(service, root)['reusable_checks']
    store.review(value['id'], 'dismiss', 1)
    assert not freeze(service, root, 'next')['reusable_checks']
    with pytest.raises(TaskStateError):
        store.review(value['id'], 'approve', 2)


def test_approved_versions_are_frozen_and_later_edits_require_approval(setup):
    root, _, service, store = setup
    value = store.review(propose(store, root)['id'], 'approve', 1)
    task = freeze(service, root)
    assert task['reusable_checks'][0]['version'] == 1
    edited = store.review(value['id'], 'edit', value['revision'], {'check': {**value['check'], 'value': 'changed'}})
    assert edited['version'] == 2
    assert edited['state'] == 'proposed'
    assert freeze(service, root, 'next')['reusable_checks'][0]['version'] == 1
    approved = store.review(edited['id'], 'approve', edited['revision'])
    assert freeze(service, root, 'after')['reusable_checks'][0]['version'] == 2
    assert freeze(service, root)['reusable_checks'][0]['check']['value'] == 'ready'
    store.review(approved['id'], 'disable', approved['revision'])
    assert not freeze(service, root, 'disabled')['reusable_checks']
    assert applicable(task)[0]['value'] == 'ready'


def test_agent_and_file_scope_and_new_files(setup):
    root, _, service, store = setup
    value = propose(store, root, scope={'agent_id': 'builder', 'files': ['src/**/*.py', 'src/*.py']})
    store.review(value['id'], 'approve', 1)
    assert not freeze(service, root, 'wrong', agent_id='other')['reusable_checks']
    task = freeze(service, root, agent_id='builder')
    assert not applicable(task)
    (root / 'notes.txt').write_text('other')
    assert not applicable(task)
    (root / 'src').mkdir()
    (root / 'src' / 'new.py').write_text('pass')
    assert len(applicable(task)) == 1


def test_existing_verifier_enforces_frozen_definition_and_stale_evidence(setup):
    root, core, service, store = setup
    value = propose(store, root)
    store.review(value['id'], 'approve', 1)
    freeze(service, root)
    (root / 'result.txt').write_text('ready')
    tasks = TaskStateStore(service.run_store)
    verifier = TaskVerifier(tasks, 'task', core, 'run')
    assert verifier.verify([], lambda *_: 'once')['verification_status'] == 'passed'
    assert tasks.completion('task')[0] == 'passed'
    (root / 'result.txt').write_text('changed')
    assert tasks.completion('task')[0] == 'failed'
    weakened = {**applicable(tasks.get('task'))[0], 'value': 'changed'}
    with pytest.raises(TaskStateError, match='weakened'):
        verifier.verify([weakened], lambda *_: 'once')


def test_command_check_approval_does_not_grant_command_permission(setup):
    root, core, service, store = setup
    value = propose(store, root, check={'id': 'command', 'kind': 'command', 'requirement': 'Test a command', 'command': 'touch forbidden.txt'})
    store.review(value['id'], 'approve', 1)
    freeze(service, root)
    core.perms.set_mode('ask')
    result = TaskVerifier(TaskStateStore(service.run_store), 'task', core, 'run').verify([], lambda *_: 'deny')
    assert result['verification_status'] == 'needs_review'
    assert not (root / 'forbidden.txt').exists()


def test_generic_task_cannot_complete_after_failed_reusable_check(setup):
    root, core, service, store = setup
    value = propose(store, root)
    store.review(value['id'], 'approve', 1)
    core.client = SimpleNamespace(loaded_context_length=lambda *_: 64000, context_length=lambda *_: 64000, chat_stream=lambda *_, **__: ChatResponse(content_parts=['Done'], done=True, done_reason='stop', prompt_eval_count=5, eval_count=1))
    _run_user_turn(service, 'Do the task', False, solo_swarm_enabled=False)
    run = service.run_store.list_runs()[0]
    assert run['state'] == 'failed'
    task = TaskStateStore(service.run_store).get('run:' + run['id'])
    assert task['repair_attempts'] == 1
    assert task['verification_status'] == 'failed'
    assert run['accounting']['model_calls'] == 2


def test_explicit_api_proposal_records_generation_cost_and_requires_review(setup):
    root, core, service, store = setup
    core._add_message({'role': 'user', 'content': 'Keep result.txt ready.'})
    proposal = {'check': {'id': 'ready', 'kind': 'file_contains', 'path': 'result.txt', 'value': 'ready', 'requirement': 'The result contains ready'}, 'verification_limits': 'Checks text only.'}
    core.client = SimpleNamespace(loaded_context_length=lambda *_: 64000, context_length=lambda *_: 64000, chat_stream=lambda *_, **__: ChatResponse(content_parts=[json.dumps(proposal)], done=True, done_reason='stop', prompt_eval_count=5, eval_count=2))
    with TestClient(create_app(chat_service=service)) as client:
        assert not client.get('/api/reusable-checks').json()['checks']
        assert client.post('/api/reusable-checks/propose', json={'correction': 'Not in this chat'}).status_code == 422
        response = client.post('/api/reusable-checks/propose', json={'correction': 'Keep result.txt ready.'})
        assert response.status_code == 200, response.text
        value = response.json()
        assert value['state'] == 'proposed'
        detail = client.get('/api/reusable-checks/' + value['id']).json()
        assert detail['accounting']['by_purpose'] == {'check_generation': 1}
        assert detail['accounting']['total_tokens'] == 7
        assert not freeze(service, root)['reusable_checks']
        assert client.patch('/api/reusable-checks/' + value['id'], json={'action': 'approve', 'expected_revision': 1}).status_code == 200
        assert freeze(service, root, 'future')['reusable_checks']


def test_explicit_application_invalidates_prior_task_evidence(setup):
    root, core, service, store = setup
    service.run_store.start_run('prior', session_id=core.session.session_id, request='Create output', workspace_root=str(root), execution_path=str(root), state='completed')
    value = store.review(propose(store, root, scope={'files': ['src/**']})['id'], 'approve', 1)
    app = create_app()
    app.state.service = service
    with TestClient(app) as client:
        result = client.post('/api/reusable-checks/' + value['id'] + '/apply', json={'task_id': 'run:prior', 'expected_revision': 0, 'version': 1})
        assert result.status_code == 200, result.text
        assert result.json()['reusable_checks'][0]['explicitly_applied']
        assert client.post('/api/reusable-checks/' + value['id'] + '/apply', json={'task_id': 'run:prior', 'expected_revision': 0, 'version': 1}).status_code == 409
        verified = client.post('/api/reusable-checks/contracts/prior/verify')
        assert verified.status_code == 200, verified.text
        assert verified.json()['verification_status'] == 'failed'
        assert service.run_store.run('prior')['state'] != 'completed'
        (root / 'result.txt').write_text('ready')
        assert client.post('/api/reusable-checks/contracts/prior/verify').json()['verification_status'] == 'passed'
        assert service.run_store.run('prior')['state'] == 'completed'


def test_testing_excludes_duplicate_tests_and_edits(setup):
    root, _, _, store = setup
    value = propose(store, root)
    store.begin_test(value['id'], 1, 1)
    with pytest.raises(TaskStateError, match='running test'):
        store.begin_test(value['id'], 1, 1)
    with pytest.raises(TaskStateError, match='running test'):
        store.review(value['id'], 'approve', 1)
    store.record_test(value['id'], 1, 1, {'verification_status': 'passed'})
    assert store.review(value['id'], 'approve', 1)['state'] == 'approved'


def test_dismissed_replacement_keeps_prior_approved_check_but_disabled_does_not(setup):
    root, _, service, store = setup
    approved = store.review(propose(store, root)['id'], 'approve', 1)
    replacement = store.review(approved['id'], 'edit', approved['revision'], {'check': {**approved['check'], 'value': 'new'}})
    dismissed = store.review(replacement['id'], 'dismiss', replacement['revision'])
    assert store.active(root)[0]['version'] == 1
    assert freeze(service, root)['reusable_checks'][0]['version'] == 1
    store.review(dismissed['id'], 'disable', dismissed['revision'])
    assert not store.active(root)
    with pytest.raises(TaskStateError, match='disabled'):
        store.freeze(root, root, selected=[{'id': approved['id'], 'version': 1}])
