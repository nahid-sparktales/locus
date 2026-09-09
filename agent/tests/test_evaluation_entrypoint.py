"""Exercise the actual runtime against an empty database and disposable checkout."""
from types import SimpleNamespace

import pytest

from ollama_code.chat_service import ChatService
from ollama_code.core import AgentCore
from ollama_code.evaluation_runtime import run_evaluation_suite
from ollama_code.evaluations import EvaluationStore
from ollama_code.ollama import ChatResponse
from ollama_code.runstore import RunStore


@pytest.mark.parametrize('reason,expected', [('stop', 'passed'), ('length', 'failed')])
def test_fresh_database_starts_run_before_result(tmp_path, monkeypatch, reason, expected):
    from ollama_code import evaluation_runtime as runtime
    root = tmp_path / 'workspace'
    root.mkdir()
    core = AgentCore(cwd=str(root), config={'model': 'fixture', 'max_iterations': 1})
    service = ChatService(core)
    service.close_codex()
    service.run_store = RunStore(tmp_path / 'fresh.db')
    store = EvaluationStore(service.run_store)
    suite = store.save_suite({'name': 'Fresh', 'workspace_root': str(root), 'cases': [{
        'id': 'case', 'name': 'Output', 'target': 'solo', 'prompt': 'Say done',
        'assertions': [{'kind': 'output_contains', 'value': 'done'}]}]})
    class Fixture:
        state = 'ready'
        id = 'fixture'
        workspace_root = str(root)
        execution_path = str(root)
        def save(self): pass
        def as_dict(self): return {'id': self.id, 'workspace_root': str(root), 'execution_path': str(root)}
        def patch(self): return '', ''
    monkeypatch.setattr(runtime.TaskCheckoutStore, 'create', lambda *_: Fixture())
    monkeypatch.setattr(runtime, '_evaluation_changed_paths', lambda *_: [])
    core.client = SimpleNamespace(context_length=lambda *_: 32768, loaded_context_length=lambda *_: 32768, model_info=lambda *_: {}, chat_stream=lambda *a, **kw: ChatResponse(
        content_parts=['done'], done=True, done_reason=reason, prompt_eval_count=4, eval_count=1))
    try:
        run_evaluation_suite(service, suite, {}, {}, 'fresh-evaluation', lambda *_: pytest.fail('solo used team'))
        results = store.results(suite['id'])
        assert len(results) == 1
        assert results[0]['state'] == expected
        assert results[0]['prompt_tokens'] > 0
        assert results[0]['configuration']['fingerprint']
        assert service.run_store.run(results[0]['run_id'])
    finally:
        core.close()


def test_startup_failure_remains_in_denominator(tmp_path, monkeypatch):
    from ollama_code import evaluation_runtime as runtime
    from ollama_code.worktrees import WorktreeError
    core = AgentCore(cwd=str(tmp_path), config={'model': 'fixture'})
    service = ChatService(core)
    service.close_codex()
    service.run_store = RunStore(tmp_path / 'fresh.db')
    store = EvaluationStore(service.run_store)
    suite = store.save_suite({'name': 'Startup', 'workspace_root': str(tmp_path), 'cases': [{
        'id': 'case', 'name': 'Fail', 'target': 'solo', 'prompt': 'Run',
        'assertions': [{'kind': 'output_contains', 'value': 'done'}]}]})
    def fail(*_): raise WorktreeError('Fixture unavailable')
    monkeypatch.setattr(runtime.TaskCheckoutStore, 'create', fail)
    try:
        run_evaluation_suite(service, suite, {}, {}, 'failed-evaluation', lambda *_: None)
        result = store.results(suite['id'])[0]
        assert result['state'] == 'failed'
        assert result['execution_outcome'] == 'failed'
        assert result['estimated_cost'] is None
        assert result['duration_ms'] >= 0
    finally:
        core.close()
