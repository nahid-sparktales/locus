"""Execution evidence, namespace isolation and reviewed procedure evaluation."""
from types import SimpleNamespace

import pytest
from locus_memory.models import ProcedureDraft

from ollama_code.core import AgentCore
from ollama_code.memory_adapter import MemoryAdapter
from ollama_code.memory_learning import (
    ApprovedProcedureRunner,
    LearningError,
    ProcedureSuiteBindings,
    TaskVerificationAuthority,
    capture_terminal,
    learning_context,
)
from ollama_code.runstore import RunStore
from ollama_code.task_state import TaskStateStore, TaskVerifier


@pytest.fixture
def setup(tmp_path, isolated_app_dir):
    workspace = tmp_path / 'workspace'
    workspace.mkdir()
    (workspace / 'result.txt').write_text('ready')
    core = AgentCore(cwd=str(workspace), model='fixture', skip_permissions=True,
        config={'provider': 'ollama', 'auto_compact': False})
    core.configure_agent({}, agent_id='builder')
    adapter = MemoryAdapter(app_dir=isolated_app_dir, edition='locus', mode='enabled')
    runs = RunStore(tmp_path / 'runs.sqlite3')
    core.usage_store = runs
    core.memory_adapter = adapter
    service = SimpleNamespace(core=core, run_store=runs, memory_adapter=adapter,
                              active_evaluation_id=None)
    runs.start_run('run-one', request='Make the result ready', workspace_root=str(workspace), run_kind='solo')
    tasks = TaskStateStore(runs)
    tasks.ensure('run:run-one', request='Make the result ready', revision=1, workspace=str(workspace),
                 execution=str(workspace), agent_id='builder', include_reusable=False)
    yield workspace, service, tasks
    adapter.close()
    core.close()


def verify(service, tasks, task_id='run:run-one'):
    return TaskVerifier(tasks, task_id, service.core, 'run-one').verify([
        {'id': 'result', 'kind': 'file_contains', 'path': 'result.txt', 'value': 'ready',
         'requirement': 'The result is ready'}], lambda *_: True)


def test_actual_receipts_bind_task_agent_revision_and_inputs(setup):
    root, service, tasks = setup
    task = verify(service, tasks)
    authority = TaskVerificationAuthority(service.run_store, task['id'], workspace=str(root), agent_id='builder')
    receipt = task['evidence_ids'][0]
    assert authority.resolve(receipt).trusted
    assert authority.resolve('forged') is None
    assert TaskVerificationAuthority(service.run_store, task['id'], workspace=str(root), agent_id='foreign').resolve(receipt) is None
    (root / 'result.txt').write_text('changed')
    assert not authority.resolve(receipt).trusted
    task['agent_id'] = ''
    tasks.save(task)
    assert authority.resolve(receipt) is None


def test_episode_capture_deduplicates_and_revokes_changed_evidence(setup):
    root, service, tasks = setup
    verify(service, tasks)
    episode_id = capture_terminal(service, {'reason': 'complete'}, 'run-one')
    adapter, access, _ = learning_context(service)
    episode = adapter.engine.get_episode(access, episode_id)
    assert episode.outcome.value == 'verified_success'
    assert episode.scope.get('agent') == 'builder'
    assert capture_terminal(service, {'reason': 'complete'}, 'run-one') == episode_id
    assert len(adapter.engine.get_episode(access, episode_id).attempts) == 1
    (root / 'result.txt').write_text('changed')
    capture_terminal(service, {'reason': 'complete'}, 'run-one')
    assert adapter.engine.get_episode(access, episode_id).outcome.value != 'verified_success'


@pytest.mark.parametrize('reason,outcome', [('complete', 'unknown'), ('interrupted', 'interrupted'), ('cancelled', 'cancelled'), ('failed', 'failure')])
def test_unverified_or_negative_completion_stays_accurate(setup, reason, outcome):
    _, service, _ = setup
    episode_id = capture_terminal(service, {'reason': reason}, 'run-one')
    adapter, access, _ = learning_context(service)
    assert adapter.engine.get_episode(access, episode_id).outcome.value == outcome


def test_evaluation_private_and_disabled_agents_do_not_learn(setup):
    _, service, _ = setup
    service.core.memory_evaluation_disabled = True
    assert capture_terminal(service, {'reason': 'complete'}, 'run-one') is None
    service.core.memory_evaluation_disabled = False
    service.core.identity_mode = True
    assert capture_terminal(service, {'reason': 'complete'}, 'run-one') is None
    service.core.identity_mode = False
    service.core.configure_agent({'memory_policy': {'recall_enabled': False, 'search_enabled': False, 'proposals_enabled': False}}, agent_id='builder')
    assert capture_terminal(service, {'reason': 'complete'}, 'run-one') is None


def test_suite_binding_requires_negative_positive_fixed_cases(setup, monkeypatch):
    root, service, _ = setup
    procedure = SimpleNamespace(procedure_id='proc', version=1, draft=ProcedureDraft(
        name='Read result', purpose='Read readiness', applicability='A result file exists',
        steps=('Read result.txt',), negative_cases=('Missing file',)))
    suite = {'id': 'suite', 'workspace_root': str(root), 'cases': [
        {'id': 'positive', 'target': 'solo', 'baseline_fixture': {'task_id': 'missing'}, 'assertions': [1]},
        {'id': 'negative', 'target': 'solo', 'baseline_fixture': {'task_id': 'missing'}, 'assertions': [1]}]}
    bindings = ProcedureSuiteBindings(service.run_store)
    with pytest.raises(LearningError, match='negative'):
        bindings.approve(procedure, suite, workspace=str(root), agent_id='builder', negative_case_ids=[])
    with pytest.raises(LearningError, match='fixture'):
        bindings.approve(procedure, suite, workspace=str(root), agent_id='builder', negative_case_ids=['negative'])
    monkeypatch.setattr(ProcedureSuiteBindings, 'fixture_hashes', staticmethod(lambda _: {'positive': 'a', 'negative': 'b'}))
    binding = bindings.approve(procedure, suite, workspace=str(root), agent_id='builder', negative_case_ids=['negative'])
    assert binding['version'] == 1
    assert 'steps' not in binding


def test_cancelled_procedure_cannot_pass_even_when_results_pass(setup, monkeypatch):
    from ollama_code.evaluations import EvaluationStore
    from ollama_code.task_state import digest
    root, service, _ = setup
    procedure = SimpleNamespace(procedure_id='proc', version=1, draft=ProcedureDraft(
        name='Read result', purpose='Read readiness', applicability='A result file exists',
        steps=('Read result.txt',), negative_cases=('Missing file',)))
    suite = {'id': 'suite', 'workspace_root': str(root), 'cases': [
        {'id': 'positive', 'target': 'solo', 'prompt': 'Read ready'},
        {'id': 'negative', 'target': 'solo', 'prompt': 'Handle missing'}]}
    binding = {'procedure_id': 'proc', 'version': 1, 'draft_hash': digest(procedure.draft.to_dict()),
               'suite_id': 'suite', 'suite_hash': digest(suite), 'agent_id': 'builder',
               'workspace': str(root), 'negative_case_ids': ['negative'], 'fixtures': {}}
    monkeypatch.setattr(ProcedureSuiteBindings, 'get', lambda *_: binding)
    monkeypatch.setattr(ProcedureSuiteBindings, 'fixture_hashes', staticmethod(lambda _: {}))
    monkeypatch.setattr(EvaluationStore, 'get_suite', lambda *_: suite)
    results = []
    monkeypatch.setattr(EvaluationStore, 'results', lambda *_: results)
    monkeypatch.setattr(service.memory_adapter.engine, 'get_procedure', lambda *_: procedure)
    def execute(_service, _suite, _manifest, _manifests, identifier, _runner):
        results.extend({'case_id': c['id'], 'run_id': 'eval-' + identifier[:12] + '-' + str(i),
                        'deterministic_passed': True, 'execution_outcome': 'completed'}
                       for i, c in enumerate(suite['cases']))
        service.core._interrupt.clear()  # matches the runtime's cleanup behavior
        return {'cancelled': True}
    result = ApprovedProcedureRunner(service, procedure, execute=execute).evaluate(
        {'version': 1, 'procedure_id': 'proc'}, deadline_s=10)
    assert result['negative_cases_checked']
    assert not result['passed']
