from types import SimpleNamespace

import pytest
from test_backend import _core

from ollama_code.agent_config import render_agent_behavior
from ollama_code.api.system import response_preview
from ollama_code.ollama import ChatResponse, ToolCall
from ollama_code.response_parts import (
    ResponsePartsError,
    markdown_fallback,
    normalize_parts,
    response_document,
)
from ollama_code.sessions import SessionStore
from ollama_code.tools import ToolContext, execute_tool


def test_runtime_metadata_and_exact_directory_completeness(tmp_path):
    (tmp_path / 'one.txt').write_text('hello')
    (tmp_path / '.hidden').write_text('x')
    raw = {'type': 'file_collection', 'id': 'files', 'directory': '.', 'complete': True,
           'total_count': 999, 'entries': [{'path': 'one.txt', 'size': 9000}]}
    visible = normalize_parts([raw], str(tmp_path))[0]
    assert visible['entries'][0]['size'] == 5
    assert visible['complete'] is True and visible['total_count'] == 1
    assert visible['show_hidden'] is False
    raw['show_hidden'] = True
    partial = normalize_parts([raw], str(tmp_path))[0]
    assert partial['complete'] is False and partial['total_count'] == 2
    raw['entries'].append({'path': '.hidden'})
    complete = normalize_parts([raw], str(tmp_path))[0]
    assert complete['complete'] is True
    assert complete['workspace'] == str(tmp_path.resolve())


def test_escape_and_capability_checks_are_enforced_before_stat(tmp_path):
    (tmp_path / 'escape').symlink_to(tmp_path.parent)
    for path in ['../outside', 'escape/outside']:
        with pytest.raises(ResponsePartsError):
            normalize_parts([{'id': 'a', 'type': 'artifact', 'path': path}], str(tmp_path))
    with pytest.raises(ResponsePartsError):
        normalize_parts([{'id': 'a', 'type': 'artifact', 'path': 'ok'}], str(tmp_path), allow_workspace=False)
    with pytest.raises(ResponsePartsError):
        normalize_parts([{'id': 's', 'type': 'sources', 'references': [{'id': 'x', 'url': 'javascript:alert(1)'}]}], str(tmp_path))


def test_staging_replaces_ids_and_is_atomic_on_validation_error(tmp_path):
    ctx = ToolContext(cwd=str(tmp_path))
    def stage(body):
        return execute_tool('attach_output_parts', {'parts': [{'id': 'draft', 'type': 'writing', 'variant': 'email', 'body': body}]}, ctx)
    assert not stage('First').startswith('Error:')
    assert not stage('Second').startswith('Error:')
    assert len(ctx.response_parts) == 1 and ctx.response_parts['draft']['body'] == 'Second'
    assert execute_tool('attach_output_parts', {'parts': [{'id': 'broken', 'type': 'unknown'}]}, ctx).startswith('Error:')
    assert ctx.response_parts['draft']['body'] == 'Second'


def test_long_typed_output_survives_live_history_checkpoint_and_export(tmp_path):
    body = 'Long writing.\n' * 1500
    core = _core(tmp_path, [
        ChatResponse(content_parts=['Preparing the draft.'], tool_calls=[ToolCall('attach_output_parts', {
            'parts': [{'id': 'email', 'type': 'writing', 'variant': 'email', 'subject': 'Hello', 'body': body}]
        })], done=True),
        ChatResponse(content_parts=['Your draft is ready.'], done=True),
    ])
    events = []
    core.on_event(events.append)
    core.run_turn('Write an email')
    final = core.messages[-1]
    assert final['_phase'] == 'final_answer'
    assert final['_response_parts']['parts'][1]['body'] == body
    assert final['content'].count(body) == 1
    end = [e for e in events if e['type'] == 'message_end'][-1]
    assert end['response_parts'] == final['_response_parts']
    assert end['item_id'] == final['_item_id'] and end['run_id'] == final['run_id']
    assert not any(e['type'] == 'tool_call_proposed' for e in events)
    history = core.sanitize_messages(core.messages)
    assert history[-1]['content'] == final['content']
    assert history[-1]['response_parts'] == final['_response_parts']
    saved = SessionStore.load(core.session.path)
    assert saved[-1]['_response_parts'] == final['_response_parts']
    exported = SessionStore.export_messages(core.session.path)
    assert exported[-1]['content'] == final['content']
    assert exported[-1]['response_parts'] == final['_response_parts']
    assert all('_response_parts' not in m for m in core._request_messages())


def test_short_answer_does_not_trigger_another_model_call(tmp_path):
    responses = [ChatResponse(tool_calls=[ToolCall('list_dir', {'path': '.'})], done=True) for _ in range(3)]
    core = _core(tmp_path, responses + [ChatResponse(content_parts=['No files.'], done=True)])
    core.run_turn('Check this directory')
    assert core.client.calls == 4
    assert core.messages[-1]['content'] == 'No files.'


def test_staged_output_does_not_leak_across_turn_or_interruption(tmp_path):
    core = _core(tmp_path, [ChatResponse(content_parts=['Hi.'], done=True)])
    core.tool_ctx.response_parts['stale'] = {'id': 'stale', 'type': 'writing', 'variant': 'standard', 'body': 'Old'}
    core.run_turn('Hello')
    assert '_response_parts' not in core.messages[-1]
    core.tool_ctx.response_parts['stale'] = {'id': 'stale', 'type': 'writing', 'variant': 'standard', 'body': 'Old'}
    core._interrupt.set()
    assert core._finalize_output('Interrupted', 'final_answer') == ('Interrupted', None)


def test_settings_share_stable_native_layer_and_preview_has_no_mutation(tmp_path):
    core = _core(tmp_path, [])
    configuration = {'response_style': {'tone': 'warm', 'verbosity': 'concise'}, 'custom_instructions': 'Prefer short answers.'}
    core.configure_agent(configuration)
    layer = render_agent_behavior(core.agent_configuration, 'work')
    assert layer in core.system_message()['content']
    assert layer in core._parity_developer_instructions()
    first = core._parity_developer_instructions()
    core.tool_ctx.response_parts['x'] = {'id': 'x', 'type': 'writing', 'variant': 'standard', 'body': 'changed'}
    assert core._parity_developer_instructions() == first
    preview = response_preview(SimpleNamespace(core=core), {'agent_config': {'response_style': {'tone': 'direct'}}})
    assert 'Tone: direct.' in preview['text']
    assert core.agent_configuration.response_style.tone == 'warm'


def test_sources_preserve_document_hash_and_location(tmp_path):
    (tmp_path / 'report.pdf').write_bytes(b'fake document')
    doc = {'workspace': str(tmp_path), 'path': 'report.pdf', 'content_hash': 'recorded-version', 'location': {'kind': 'pdf', 'page': 3}}
    parts = normalize_parts([{'type': 'sources', 'id': 'refs', 'references': [{'id': 'source', 'document': doc}]}], str(tmp_path))
    assert parts[0]['references'][0]['document'] == {**doc, 'workspace': str(tmp_path.resolve())}
    fallback = markdown_fallback(response_document('', parts))
    assert 'hash=recorded-version' in fallback and 'locator=' in fallback


def test_native_output_parts_and_stable_preference_fingerprint(tmp_path):
    from test_chatgpt_app_server import ParityFakeRuntime, _managed_core
    runtime = ParityFakeRuntime(tool_calls=[('attach_output_parts', {
        'parts': [{'id': 'draft', 'type': 'writing', 'variant': 'standard', 'body': 'Reusable answer.'}]
    })])
    core = _managed_core(tmp_path, runtime)
    core.configure_agent({'response_style': {'tone': 'warm', 'verbosity': 'concise'}})
    events = []
    core.on_event(events.append)
    core.run_turn('Make a draft')
    first = runtime.start_kwargs[0]['options'].developer_instructions
    assert 'Tone: warm.' in first
    final = core.messages[-1]
    assert final['_response_parts']['parts'][-1]['body'] == 'Reusable answer.'
    assert any(e.get('response_parts') for e in events if e['type'] == 'assistant_item_end')
    core.run_turn('Do it again')
    assert len(runtime.start_kwargs) == 1
    core.configure_agent({'response_style': {'tone': 'direct', 'verbosity': 'concise'}})
    core.run_turn('Use my new tone')
    assert len(runtime.start_kwargs) == 2
    assert 'Tone: direct.' in runtime.start_kwargs[-1]['options'].developer_instructions


def test_modern_provider_preserves_literal_reasoning_tags(tmp_path):
    literal = 'Use `<think>example</think>` as literal markup.'
    core = _core(tmp_path, [ChatResponse(content_parts=[literal], done=True)])
    core.provider = 'remote'
    response = core._stream_response()
    assert response.content == literal


def test_writing_literal_tags_are_not_stripped_from_fallback(tmp_path):
    body = '<think>These are literal writing tags.</think>\n'
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall('attach_output_parts', {'parts': [
            {'id': 'body', 'type': 'writing', 'variant': 'standard', 'body': body}
        ]})], done=True),
        ChatResponse(content_parts=['Ready.'], done=True),
    ])
    core.run_turn('Write the tags literally')
    assert body in core.messages[-1]['content']
    assert core.messages[-1]['_response_parts']['parts'][-1]['body'] == body


def test_interrupted_partial_keeps_same_text_and_identity_in_history(tmp_path):
    from test_backend import FakeClient

    class InterruptedClient(FakeClient):
        def chat_stream(self, *args, on_token=None, **kwargs):
            on_token('Partial answer')
            core._interrupt.set()
            return None

    core = _core(tmp_path, [])
    core.client = InterruptedClient([])
    events = []
    core.on_event(events.append)
    core.run_turn('Answer')
    final = core.messages[-1]
    ended = next(e for e in events if e['type'] == 'message_end')
    assert final['content'] == ended['content'] == 'Partial answer'
    assert final['_item_id'] == ended['item_id']
    assert final['run_id'] == ended['run_id']


def test_private_identity_cannot_guess_presentation_tool(tmp_path):
    core = _core(tmp_path, [])
    core.identity_mode = True
    result = core._run_tool_call(ToolCall('attach_output_parts', {'parts': [
        {'id': 'files', 'type': 'file_collection', 'entries': []}
    ]}), None)
    assert result.startswith('Error:')
    assert core.tool_ctx.response_parts == {}


def test_large_completed_document_survives_durable_reconnect_event(tmp_path):
    from ollama_code.runstore import RunStore

    body = 'A complete writing document.\n' * 12000
    document = response_document('Ready.', [{'id': 'draft', 'type': 'writing', 'variant': 'standard', 'body': body}])
    content = markdown_fallback(document)
    store = RunStore(tmp_path / 'runs.sqlite3')
    event = {'type': 'message_end', 'item_id': 'answer', 'phase': 'final_answer',
             'response_parts': document, 'content': content}
    live = store.append_event('run', event)
    replay = store.events('run')[0]
    assert live['content'] == replay['content'] == content
    assert live['response_parts'] == replay['response_parts'] == document
    assert 'content_truncated' not in replay


def test_selected_profile_preview_does_not_borrow_active_provider(tmp_path):
    from fastapi import HTTPException

    core = _core(tmp_path, [])
    core.config['remote_account_label'] = 'Unrelated active account'
    preview = response_preview(SimpleNamespace(core=core), {'provider': 'remote', 'model': 'selected-model'})
    assert preview['provider'] == 'remote' and preview['model'] == 'selected-model'
    assert 'selected-model' in preview['text']
    assert 'Unrelated active account' not in preview['text']
    assert core.provider == 'ollama' and core.model == 'test-model'
    with pytest.raises(HTTPException) as unavailable:
        response_preview(SimpleNamespace(core=core), {'provider': 'chatgpt', 'model': 'gpt-selected'})
    assert unavailable.value.status_code == 409


def test_change_check_can_collapse_without_losing_fallback_inventory(tmp_path):
    (tmp_path / 'a.txt').write_text('a')
    parts = normalize_parts([{'type': 'file_collection', 'id': 'files', 'directory': '.',
                              'collapsed': True, 'entries': [{'path': 'a.txt'}]}], str(tmp_path))
    assert parts[0]['collapsed'] is True and parts[0]['complete'] is True
    assert 'a.txt' in markdown_fallback(response_document('One file added.', parts))


def test_native_preview_override_can_select_classic_chatgpt_without_manager(tmp_path):
    core = _core(tmp_path, [])
    preview = response_preview(SimpleNamespace(core=core), {
        'provider': 'chatgpt', 'model': 'gpt-selected', 'native_mode': False,
    })
    assert preview['route'] == 'classic'
    assert 'gpt-selected' in preview['text']
    assert core.config.get('chatgpt_native_mode', True) is True


@pytest.mark.parametrize('provider', [None, [], {}, 42, True, 'unknown'])
def test_preview_rejects_invalid_provider_values_without_mutating_active_route(tmp_path, provider):
    from fastapi import HTTPException

    core = _core(tmp_path, [])
    with pytest.raises(HTTPException) as invalid:
        response_preview(SimpleNamespace(core=core), {'provider': provider})
    assert invalid.value.status_code == 422
    assert core.provider == 'ollama' and core.model == 'test-model'


@pytest.mark.parametrize('body', [{}, {'native_mode': True}, {'model': 'selected-model'}])
def test_primary_preview_reports_unavailable_active_native_runtime(tmp_path, body):
    from fastapi import HTTPException

    core = _core(tmp_path, [])
    core.provider = 'chatgpt'
    core.config['chatgpt_native_mode'] = True
    core.codex_manager = None
    with pytest.raises(HTTPException) as unavailable:
        response_preview(SimpleNamespace(core=core), body)
    assert unavailable.value.status_code == 409
    assert core.provider == 'chatgpt' and core.model == 'test-model'
    assert core.config['chatgpt_native_mode'] is True


@pytest.mark.parametrize('body', [{'mode': 'ask'}, {'native_mode': False}])
def test_primary_preview_allows_routes_that_do_not_require_native_runtime(tmp_path, body):
    core = _core(tmp_path, [])
    core.provider = 'chatgpt'
    core.config['chatgpt_native_mode'] = True
    core.codex_manager = None
    preview = response_preview(SimpleNamespace(core=core), body)
    assert preview['provider'] == 'chatgpt' and preview['route'] == 'classic'
    assert core.agent_mode == 'work' and core.config['chatgpt_native_mode'] is True


def test_verified_activity_labels_survive_classic_history(tmp_path):
    (tmp_path / 'notes.txt').write_text('hello')
    core = _core(tmp_path, [
        ChatResponse(tool_calls=[ToolCall('list_dir', {'path': '.'})], done=True),
        ChatResponse(tool_calls=[ToolCall('read_file', {'path': 'notes.txt'})], done=True),
        ChatResponse(content_parts=['Done.'], done=True),
    ])
    events = []
    core.on_event(events.append)
    core.run_turn('Inspect')
    labels = [e.get('activity_label') for e in events if e['type'] == 'tool_result']
    assert labels == [f'Checked {tmp_path.name}', 'Read notes.txt']
    history = core.sanitize_messages(core.messages)
    assert [m['activity_label'] for m in history if m['role'] == 'tool'] == labels
    assert core._verified_activity_label(ToolCall('bash', {'command': 'rm anything'}), []) == ''


def test_collection_hidden_scope_generated_directories_and_duplicate_paths(tmp_path):
    (tmp_path / '.hidden').write_text('private')
    (tmp_path / 'node_modules').mkdir()
    (tmp_path / 'one.txt').write_text('one')
    raw = {'type': 'file_collection', 'id': 'files', 'directory': '.',
           'entries': [{'path': 'node_modules'}, {'path': 'one.txt'}]}
    part = normalize_parts([raw], str(tmp_path))[0]
    assert part['complete'] is True and part['total_count'] == 2
    raw['entries'].append({'path': '.hidden'})
    assert normalize_parts([raw], str(tmp_path))[0]['complete'] is False
    raw['show_hidden'] = True
    assert normalize_parts([raw], str(tmp_path))[0]['complete'] is True
    raw['entries'].append({'path': 'node_modules/../one.txt'})
    with pytest.raises(ResponsePartsError, match='repeat a resolved path'):
        normalize_parts([raw], str(tmp_path))


def test_symlink_leaf_keeps_lexical_identity_and_checks_target_containment(tmp_path):
    (tmp_path / 'data').mkdir()
    (tmp_path / 'data' / 'inside.txt').write_text('inside')
    (tmp_path / 'shortcut').symlink_to(tmp_path / 'data', target_is_directory=True)
    raw = {'type': 'file_collection', 'id': 'files', 'entries': [{'path': 'shortcut'}]}
    entry = normalize_parts([raw], str(tmp_path))[0]['entries'][0]
    assert entry == {'path': 'shortcut', 'name': 'shortcut', 'exists': True, 'kind': 'symlink'}
    raw['entries'].append({'path': 'data'})
    with pytest.raises(ResponsePartsError, match='repeat a resolved path'):
        normalize_parts([raw], str(tmp_path))


def test_macos_hidden_file_flag_matches_files_visibility(tmp_path, monkeypatch):
    import stat
    from pathlib import Path
    hidden = tmp_path / 'flagged'
    hidden.write_text('hidden by Finder')
    original = Path.lstat
    flag = getattr(stat, 'UF_HIDDEN', 0x8000)
    monkeypatch.setattr(stat, 'UF_HIDDEN', flag, raising=False)
    def lstat(path, *args, **kwargs):
        value = original(path, *args, **kwargs)
        return SimpleNamespace(st_mode=value.st_mode, st_flags=flag) if path == hidden else value
    monkeypatch.setattr(Path, 'lstat', lstat)
    raw = {'type': 'file_collection', 'id': 'files', 'directory': '.', 'entries': []}
    part = normalize_parts([raw], str(tmp_path))[0]
    assert part['complete'] is True and part['total_count'] == 0
    raw['show_hidden'] = True
    part = normalize_parts([raw], str(tmp_path))[0]
    assert part['complete'] is False and part['total_count'] == 1


def test_local_provider_literal_code_tags_survive_live_and_history(tmp_path):
    literal = 'Example:\n```xml\n<think>literal</think>\n```\nUse `<thinking>x</thinking>`.'
    core = _core(tmp_path, [ChatResponse(content_parts=['<think>private</think>' + literal], done=True)])
    events = []
    core.on_event(events.append)
    core.run_turn('Show literal markup')
    assert core.messages[-1]['content'] == literal
    assert [event for event in events if event['type'] == 'message_end'][-1]['content'] == literal
    assert ''.join(event['text'] for event in events if event['type'] == 'token') == literal


def test_near_limit_writing_plus_prose_keeps_complete_reconnect_fallback(tmp_path):
    from ollama_code.runstore import RunStore
    body = 'x' * 900_000
    parts = normalize_parts([{'id': 'writing', 'type': 'writing', 'body': body}], str(tmp_path))
    document = response_document('Summary.\n' * 20_000, parts)
    content = markdown_fallback(document)
    assert len(content) > 1_000_000
    store = RunStore(tmp_path / 'runs.sqlite3')
    live = store.append_event('run', {'type': 'assistant_item_end', 'text': content, 'response_parts': document})
    replay = store.events('run')[0]
    assert live['text'] == replay['text'] == content
    assert live['response_parts'] == replay['response_parts'] == document


def test_verified_native_activity_label_survives_reload_without_provider_tool_message(tmp_path):
    from test_chatgpt_app_server import ParityFakeRuntime, _managed_core
    runtime = ParityFakeRuntime(tool_calls=[('list_dir', {'path': '.'})])
    core = _managed_core(tmp_path, runtime)
    events = []
    core.on_event(events.append)
    core.run_turn('Inspect the directory')
    result = next(event for event in events if event['type'] == 'tool_result')
    assert result['activity_label'] == f'Checked {tmp_path.name}'
    stored = SessionStore.load(core.session.path)
    tool = next(message for message in core.sanitize_messages(stored) if message['role'] == 'tool')
    assert tool['activity_label'] == result['activity_label']
    assert tool['run_id'] == core.messages[-1]['run_id']
    assert all(message['role'] != 'tool' for message in core._request_messages())
    exported = SessionStore.export_messages(core.session.path, include_tool_details=True)
    assert next(message for message in exported if message['role'] == 'tool')['activity_label'] == result['activity_label']


def test_output_parts_cannot_be_inherited_or_guessed_by_solo_helpers(tmp_path):
    core = _core(tmp_path, [])
    assert 'attach_output_parts' not in {schema['function']['name'] for schema in core.solo_worker_tool_schemas()}
    call = ToolCall('attach_output_parts', {'parts': [{'id': 'helper', 'type': 'writing', 'body': 'Helper draft'}]})
    assert core._run_tool_call(call, None, track_active=False).startswith('Error:')
    core.helper_allowed_tools = {'read_file'}
    assert core._run_tool_call(call, None).startswith('Error:')
    assert core.tool_ctx.response_parts == {}
