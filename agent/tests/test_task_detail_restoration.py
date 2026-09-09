"""Task UI contracts and restoration gates through the authenticated API."""
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.file_history import FileHistory
from ollama_code.goals import GoalStore
from ollama_code.runstore import SCHEMA_VERSION, RunStore
from ollama_code.server import create_app
from ollama_code.task_journal import TaskJournal
from ollama_code.task_state import TaskStateError


@pytest.fixture
def workspace_task(tmp_path):
    root = tmp_path / 'workspace'
    root.mkdir()
    runs = RunStore(tmp_path / 'runs.db')
    core = AgentCore(cwd=str(root), config={'permission_mode': 'bypass'})
    service = ChatService(core)
    service.close_codex()
    service.run_store = runs
    session = core.session.session_id
    runs.start_run('run', session_id=session, workspace_root=str(root), execution_path=str(root), request='Restore the task output')
    runs.set_state('run', 'completed')
    journal = TaskJournal.bind(runs, runs.run('run'))
    yield SimpleNamespace(root=root, runs=runs, service=service, session=session, journal=journal,
                          history=FileHistory(journal, str(root)), client=TestClient(create_app(chat_service=service)),
                          endpoint=f'/api/sessions/{session}/task')
    core.close()


def edit(task, paths=('result.txt',)):
    for path in paths:
        (task.root / path).write_text('before\ntwo\nthree\nfour\nfive\nsix\n')
    ids = task.history.begin('edit', list(paths))
    for path in paths:
        (task.root / path).write_text('after\ntwo\nthree\nfour\nfive\nsix\n')
    task.history.finish(ids, ok=True)
    return ids


def apply_body(preview, selected=None):
    paths = selected if selected is not None else [e['path'] for e in preview['entries'] if e['status'] == 'ready']
    return {'action': 'apply', 'token': preview['token'], 'revision': preview['revision'],
            'selected_paths': paths, 'fingerprints': {e['path']: e.get('current') for e in preview['entries'] if e['path'] in paths}}


def test_saved_plan_without_execution_is_read_only_and_cannot_be_accepted(workspace_task):
    t = workspace_task
    with t.runs._connect() as db:
        db.execute('DELETE FROM runs WHERE id=?', ('run',))
    ref = t.journal.save_plan({'id': 'saved', 'title': 'Review the saved plan', 'steps': ['Deliver result']}, str(t.root))
    before = t.history.revision()
    for _ in range(2):
        detail = t.client.get(t.endpoint).json()
        assert detail['state'] == 'planned'
        assert detail['plan']['approval_reference'] == ref
        assert detail['actions'] == ['restore']
        assert detail['run_id'] == ''
    assert t.history.revision() == before
    assert not t.runs.list_runs()
    assert t.client.post(t.endpoint + '/accept', json={'revision': before}).status_code == 409


def test_completed_goal_does_not_own_later_ordinary_work(workspace_task):
    t = workspace_task
    goal = GoalStore(t.runs).create(t.session, 'Earlier goal', execution={'provider': 'ollama', 'model': 'fixture', 'workspace_root': str(t.root)})
    with t.runs._connect() as db:
        db.execute("UPDATE goals SET status='completed' WHERE id=?", (goal['id'],))
    detail = t.client.get(t.endpoint).json()
    assert detail['owner_kind'] == 'work'
    assert detail['goal'] is None
    assert 'accept' in detail['actions']
    assert t.client.post(t.endpoint + '/accept', json={'revision': detail['revision']}).status_code == 200
    assert t.client.get(t.endpoint).json()['state'] == 'accepted'
    t.runs.start_run('later', session_id=t.session, workspace_root=str(t.root), execution_path=str(t.root))
    t.runs.set_state('later', 'failed')
    assert t.client.get(t.endpoint).json()['state'] == 'failed'


def test_other_chat_in_same_checkout_blocks_restoration_and_controls(workspace_task):
    t = workspace_task
    ids = edit(t)
    t.runs.start_run('other', session_id='other-chat', workspace_root=str(t.root), execution_path=str(t.root))
    assert t.client.get(t.endpoint).json()['actions'] == []
    response = t.client.post(t.endpoint + '/restore', json={'change_ids': ids})
    assert response.status_code == 409
    assert (t.root / 'result.txt').read_text().startswith('after')
    t.runs.set_state('other', 'completed')
    assert 'restore' in t.client.get(t.endpoint).json()['actions']


def test_api_preview_apply_selection_preserves_unselected_and_later_edits(workspace_task):
    t = workspace_task
    ids = edit(t, ('one.txt', 'two.txt'))
    one = t.root / 'one.txt'
    one.write_text(one.read_text().replace('six', 'SIX'))
    preview = t.client.post(t.endpoint + '/restore', json={'change_ids': ids}).json()
    body = apply_body(preview, ['one.txt'])
    assert t.client.post(t.endpoint + '/restore', json=body).status_code == 200
    assert one.read_text().startswith('before') and one.read_text().endswith('SIX\n')
    assert (t.root / 'two.txt').read_text().startswith('after')
    assert t.client.post(t.endpoint + '/restore', json=body).status_code == 409
    assert t.client.post(t.endpoint + '/restore', json={'action': 'recover', 'token': preview['token']}).status_code == 200
    assert one.read_text().startswith('after') and one.read_text().endswith('SIX\n')
    history = t.client.get(t.endpoint).json()['restorations']
    assert history[0]['state'] == 'recovered' and history[0]['paths'] == ['one.txt']


@pytest.mark.parametrize('tamper', ['revision', 'fingerprints', 'selected_paths'])
def test_api_rejects_stale_or_foreign_preview_input_before_writes(workspace_task, tamper):
    t = workspace_task
    preview = t.client.post(t.endpoint + '/restore', json={'change_ids': edit(t)}).json()
    body = apply_body(preview)
    body[tamper] = {'revision': -1, 'fingerprints': {}, 'selected_paths': ['foreign.txt']}[tamper]
    assert t.client.post(t.endpoint + '/restore', json=body).status_code == 409
    assert (t.root / 'result.txt').read_text().startswith('after')


def test_changed_file_excluded_while_independent_selection_can_restore(workspace_task):
    t = workspace_task
    ids = edit(t, ('one.txt', 'two.txt'))
    (t.root / 'two.txt').write_text('A conflicting user edit')
    preview = t.client.post(t.endpoint + '/restore', json={'change_ids': ids}).json()
    assert [e['status'] for e in preview['entries']] == ['ready', 'conflict']
    assert t.client.post(t.endpoint + '/restore', json=apply_body(preview)).status_code == 200
    assert (t.root / 'two.txt').read_text() == 'A conflicting user edit'


def test_crash_after_atomic_write_before_journal_update_reopens_inert(workspace_task, monkeypatch):
    t = workspace_task
    preview = t.history.preview(edit(t))
    original = t.history._write
    def crash(*args, **kwargs):
        original(*args, **kwargs)
        raise KeyboardInterrupt('Simulated process loss before marking the file applied')
    monkeypatch.setattr(t.history, '_write', crash)
    body = apply_body(preview)
    with pytest.raises(KeyboardInterrupt):
        t.history.apply(body['token'], body['selected_paths'], body['revision'], body['fingerprints'])
    reopened = RunStore(t.runs.path)
    t.service.run_store = reopened
    detail = t.client.get(t.endpoint).json()
    assert detail['restorations'][0]['state'] == 'applying'
    assert (t.root / 'result.txt').read_text().startswith('before')
    assert t.client.post(t.endpoint + '/restore', json={'action': 'recover', 'token': preview['token']}).status_code == 200
    assert (t.root / 'result.txt').read_text().startswith('after')


def test_symlink_parent_never_captures_or_restores_external_content(workspace_task, tmp_path):
    t = workspace_task
    outside = tmp_path / 'outside'
    outside.mkdir()
    (outside / 'secret').write_text('external')
    (t.root / 'link').symlink_to(outside, target_is_directory=True)
    ids = t.history.begin('unsafe', ['link/secret'])
    assert t.history.changes()[0]['state'] == 'unsupported'
    with pytest.raises(TaskStateError):
        t.history.preview(ids)
    assert (outside / 'secret').read_text() == 'external'


@pytest.mark.parametrize('git_workspace', [False, True])
def test_binary_exact_match_and_file_creation_deletion_restore(workspace_task, git_workspace):
    t = workspace_task
    if git_workspace:
        import subprocess
        subprocess.run(['git', 'init', '-q', str(t.root)], check=True)
    (t.root / 'binary').write_bytes(b'old\x00')
    (t.root / 'deleted').write_text('kept')
    ids = t.history.begin('edits', ['binary', 'created', 'deleted'])
    (t.root / 'binary').write_bytes(b'new\x00')
    (t.root / 'created').write_text('created')
    (t.root / 'deleted').unlink()
    t.history.finish(ids, ok=True)
    preview = t.history.preview(ids)
    assert all(e['status'] == 'ready' for e in preview['entries'])
    body = apply_body(preview)
    t.history.apply(body['token'], body['selected_paths'], body['revision'], body['fingerprints'])
    assert (t.root / 'binary').read_bytes() == b'old\x00'
    assert not (t.root / 'created').exists()
    assert (t.root / 'deleted').read_text() == 'kept'


@pytest.mark.parametrize("source_version", [14, 17])
def test_upgrade_retains_old_records_with_unknown_evidence(workspace_task, source_version):
    t = workspace_task
    from ollama_code.usage_ledger import UsageLedger
    UsageLedger(t.runs).set_limits("runtime-task", {"max_calls": 12})
    with t.runs._connect() as db:
        tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for name in tables:
            if name.startswith('task_') and name not in {'task_states', 'task_check_receipts'}:
                # Remove only the new task tables; preserve runtime state and v14 verification.
                if name in {'task_links', 'task_plans', 'task_observations', 'task_milestones', 'task_reviews',
                            'task_usage', 'task_limits', 'task_spans', 'task_file_changes', 'task_restorations'}:
                    db.execute(f'DROP TABLE {name}')
        db.execute('UPDATE schema_meta SET version=? WHERE singleton=1', (source_version,))
    reopened = RunStore(t.runs.path)
    t.service.run_store = reopened
    assert reopened.run('run')['request'] == 'Restore the task output'
    assert UsageLedger(reopened).limits('runtime-task') == {'max_calls': 12}
    detail = t.client.get(t.endpoint).json()
    assert detail['schema_version'] == SCHEMA_VERSION
    assert detail['verification'] is None and detail['progress'] == []
    assert detail['usage']['coverage'] == 'unknown'
    assert detail['state'] == 'completed'
    with reopened._connect(readonly=True) as db:
        assert db.execute('SELECT version FROM schema_meta').fetchone()[0] == SCHEMA_VERSION
        assert db.execute('SELECT COUNT(*) FROM runs').fetchone()[0] == 1


def test_history_change_invalidates_preview_even_when_other_file_was_edited(workspace_task):
    t = workspace_task
    preview = t.history.preview(edit(t))
    (t.root / 'other').write_text('old')
    ids = t.history.begin('later-change', ['other'])
    (t.root / 'other').write_text('new')
    t.history.finish(ids, ok=True)
    body = apply_body(preview)
    with pytest.raises(TaskStateError, match='task changed'):
        t.history.apply(body['token'], body['selected_paths'], body['revision'], body['fingerprints'])
    assert (t.root / 'result.txt').read_text().startswith('after')


def test_restoration_reports_candidate_file_and_batch_exclusions(workspace_task, monkeypatch):
    from ollama_code import file_history
    t = workspace_task
    ids = edit(t, ('one.txt', 'two.txt'))
    monkeypatch.setattr(file_history, 'MAX_FILES', 2)
    assert t.history.begin('overflow', ['extra']) == []
    exclusions = t.client.get(t.endpoint).json()['exclusions']
    assert exclusions[0]['excluded_count'] == 1
    monkeypatch.setattr(file_history, 'MAX_BATCH_BYTES', 1)
    preview = t.history.preview(ids)
    assert all(e['status'] == 'conflict' for e in preview['entries'])
    assert all('128 MiB' in e['reason'] for e in preview['entries'])
    assert (t.root / 'one.txt').read_text().startswith('after')


def test_outputs_and_recovery_remain_visible_without_claiming_verification(workspace_task):
    t = workspace_task
    edit(t)
    t.runs.set_state('run', 'interrupted', recoverable=True, reason='A check was interrupted')
    detail = t.client.get(t.endpoint).json()
    assert detail['outputs'] == [{'path': 'result.txt', 'state': 'present'}]
    assert detail['verification'] is None
    assert detail['recovery_history'][0]['reason'] == 'A check was interrupted'
    assert 'resume' in detail['actions']
    assert 'retry_checks' not in detail['actions']


@pytest.mark.parametrize('unresolved', [None, 'uncertain_action', 'pending_usage'])
def test_capsule_controls_use_saved_attempt_and_do_not_bypass_uncertainty(workspace_task, unresolved):
    from ollama_code.capsule_progress import CapsuleProgressStore
    from ollama_code.capsules import CapsuleStore
    t = workspace_task
    capsule = CapsuleStore(str(t.root)).create({
        'title': 'Saved capsule', 'request': 'Build the result',
        'plan': {'id': 'capsule-plan', 'title': 'Saved decisions', 'steps': ['Deliver output'],
                 'step_details': [{'id': 'output', 'title': 'Deliver output'}]},
        'recipe': {'planner_profile_id': 'planner', 'executor_profile_id': 'executor'}})
    t.runs.start_run('capsule-run', session_id=t.session, workspace_root=str(t.root), execution_path=str(t.root),
                     manifest={'capsule_context': {'id': capsule['id'], 'stage': 'execute'}})
    t.runs.set_state('capsule-run', 'completed')
    attempt = {'id': 'attempt', 'capsule_id': capsule['id'], 'revision': capsule['revision'],
               'active_run_id': 'capsule-run', 'state': 'needs_review', 'steps': {}}
    if unresolved:
        attempt[unresolved] = {'id': 'unsettled', 'tool': 'external_action'}
    CapsuleProgressStore(t.runs).save(attempt)
    detail = t.client.get(t.endpoint).json()
    assert detail['owner_kind'] == 'capsule'
    assert detail['capsule']['id'] == capsule['id']
    assert detail['capsule']['attempts'][0]['id'] == 'attempt'
    assert detail['plan']['title'] == 'Saved decisions'
    assert ('resume' in detail['actions']) == (unresolved is None)
    assert ('accept' in detail['actions']) == (unresolved is None)
    assert ('run_again' in detail['actions']) == (unresolved is None)
    assert t.client.post(t.endpoint + '/accept', json={'revision': detail['revision']}).status_code == 409
