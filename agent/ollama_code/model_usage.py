"""One accounting boundary shared by workers, planners, reviews and compaction."""
from __future__ import annotations

import json
import threading
from urllib.parse import urlsplit, urlunsplit

from .usage_ledger import UsageLedger, count, normalize_usage

_STORES = {}
_LOCK = threading.Lock()


def ledger_for(core=None, runs=None):
    if runs is None:
        runs = getattr(core, 'usage_store', None)
    if runs is None:
        from . import paths
        from .runstore import RunStore
        key = str(paths.APP_DIR)
        with _LOCK:
            runs = _STORES.get(key)
            if runs is None:
                runs = _STORES[key] = RunStore()
    return UsageLedger(runs)


def safe_route(value):
    parsed = urlsplit(str(value or ''))
    host = parsed.hostname or ''
    if parsed.port:
        host += ':' + str(parsed.port)
    return urlunsplit((parsed.scheme, host, parsed.path, '', ''))


def context_for(core, purpose='worker'):
    session = getattr(core, 'session', None)
    session_id = str(getattr(session, 'session_id', '') or '')
    tool_context = getattr(core, 'tool_ctx', None)
    run_id = str(getattr(tool_context, 'memory_run_id', '') or getattr(core, '_output_run_id', '') or session_id)
    goal = getattr(core, 'goal_runtime', None)
    capsule = getattr(core, 'capsule_runtime', None)
    task_id = 'goal:' + goal.goal_id if goal is not None else 'capsule:' + str(capsule.value['id']) if capsule is not None else 'run:' + run_id
    task_id = getattr(core, 'usage_owner_task_id', '') or task_id
    route = safe_route(getattr(getattr(core, 'client', None), 'base_url', '') or getattr(core, 'host', ''))
    policy = getattr(getattr(core, 'agent_configuration', None), 'runtime_policy', None)
    limits = {key: getattr(policy, field, None) for key, field in [('max_calls', 'max_model_calls'), ('max_tokens', 'max_total_tokens'), ('max_estimated_usd', 'max_estimated_usd')]}
    return {'limits': {key: value for key, value in limits.items() if value is not None}, 'task_id': task_id, 'run_id': run_id, 'session_id': session_id,
            'provider': getattr(core, 'provider', 'ollama'), 'model': getattr(core, 'model', ''),
            'route': route, 'account_id': getattr(core, 'account_id', ''), 'purpose': purpose,
            'workspace': str(getattr(core, 'workspace_root', '') or getattr(core, 'cwd', ''))}


def response_usage(provider, response):
    fields = getattr(response, 'provider_fields', {}) or {}
    raw = fields.get('usage') or {}
    family = fields.get('usage_family', 'openai')
    value = normalize_usage(family, raw, input_tokens=getattr(response, 'prompt_eval_count', 0), output_tokens=getattr(response, 'eval_count', 0),
                            reported=bool(raw) or bool(getattr(response, 'prompt_eval_count', 0) or getattr(response, 'eval_count', 0)))
    value['model_calls'] = max(count(fields.get('locus_model_calls', 1)), 1)
    return value


def tracked_chat(core, client, *args, purpose='worker', context=None, runs=None, **kwargs):
    context = dict(context or context_for(core, purpose))
    context['purpose'] = purpose
    context['route'] = safe_route(context.get('route', ''))
    ledger = ledger_for(core, runs)
    if context.get('limits'):
        ledger.set_limits(context['task_id'], context['limits'], only_if_absent=True)
    effective_limits = ledger.limits(context['task_id'])
    context['model'] = str(kwargs.get('model') or (args[0] if args else context.get('model', '')))
    messages = kwargs.get('messages') or (args[1] if len(args) > 1 else [])
    options = kwargs.get('options') or {}
    context['service_tier'] = options.get('service_tier', '')
    estimated_input = len(json.dumps(messages, ensure_ascii=False, default=str).encode()) + len(json.dumps(kwargs.get('tools') or []).encode()) + 256
    # UTF-8 bytes conservatively bound ordinary text tokenization. Image/model
    # overhead remains an estimate, never an invoice or a hard provider cap.
    estimated_output = options.get('max_completion_tokens') or options.get('max_tokens') or options.get('num_predict') or 8192
    remaining = ledger.remaining_tokens(context['task_id'])
    if remaining is not None:
        from .usage_ledger import UsageLimitError
        if remaining <= estimated_input:
            raise UsageLimitError('The remaining token allowance cannot reserve this input')
        estimated_output = min(count(estimated_output), remaining - estimated_input)
    # Spending reservations require a bounded output allowance at the provider.
    if effective_limits.get('max_estimated_usd') or effective_limits.get('max_tokens'):
        options = dict(options)
        family = 'num_predict' if context['provider'] == 'ollama' else 'max_tokens' if 'anthropic.com' in context.get('route', '') else 'max_completion_tokens'
        options[family] = count(estimated_output)
        kwargs['options'] = options
    invocation = ledger.begin(context, input_tokens=estimated_input, output_tokens=max(count(estimated_output), 1))
    try:
        response = client.chat_stream(*args, **kwargs)
        usage = response_usage(context['provider'], response)
        reason = getattr(response, 'done_reason', '')
        complete = bool(getattr(response, 'done', False) or reason in {'stop', 'length', 'end_turn', 'tool_calls', 'tool_use'}) and reason not in {'interrupted', 'error', 'cancelled'}
        record = ledger.settle(invocation['id'], usage, complete=complete)
        if hasattr(response, 'provider_fields'):
            response.provider_fields['usage_invocation_id'] = record['id']
            response.provider_fields['cost_coverage'] = record['coverage']
            response.provider_fields['estimated_api_cost'] = record['estimated_cost']
        return response
    except BaseException:
        ledger.uncertain(invocation['id'])
        raise


def tracked_native(core, call, *, purpose='worker', context=None, runs=None, **kwargs):
    context = dict(context or context_for(core, purpose))
    context.update(provider='chatgpt', purpose=purpose)
    ledger = ledger_for(core, runs)
    invocation = ledger.begin(context, input_tokens=len(str(kwargs.get('text', ''))) // 3 + 128, output_tokens=8192)
    original = kwargs.get('event_handler')
    usage = normalize_usage('openai', {})
    totals = (0, 0, 0, 0)
    seen = set()
    calls = 0
    thread_id = str(kwargs.get('thread_id', ''))
    account_id = str(context.get('account_id') or 'default')
    with ledger.runs._connect(readonly=True) as db:
        saved = db.execute('SELECT payload FROM usage_native_cursors WHERE account_id=? AND thread_id=?', (account_id, thread_id)).fetchone()
    baseline = tuple(json.loads(saved[0])) if saved else (0, 0, 0, 0)

    def observe(event):
        nonlocal usage, totals, baseline, calls
        if event.get('method') == 'thread/tokenUsage/updated':
            token_usage = (event.get('params') or {}).get('tokenUsage') or {}
            total = token_usage.get('total') or {}
            current = tuple(count(total.get(key)) for key in ('inputTokens', 'outputTokens', 'cachedInputTokens', 'reasoningOutputTokens'))
            if current not in seen and current != baseline and any(current):
                if not seen and (current[0] < baseline[0] or current[1] < baseline[1]):
                    baseline = (0, 0, 0, 0)
                seen.add(current)
                if current[0] >= totals[0] and current[1] >= totals[1]:
                    totals = current
                    calls += 1
                    usage = normalize_usage('openai', {key: max(current[index] - baseline[index], 0) for index, key in enumerate(('inputTokens', 'outputTokens', 'cachedInputTokens', 'reasoningOutputTokens'))})
                    usage['model_calls'] = calls
                    with ledger.runs._connect() as db:
                        db.execute('INSERT INTO usage_native_cursors VALUES(?,?,?) ON CONFLICT(account_id,thread_id) DO UPDATE SET payload=excluded.payload', (account_id, thread_id, json.dumps(current)))
                        db.execute('UPDATE usage_invocations SET usage=? WHERE id=? AND state=\'pending\'', (json.dumps(usage, sort_keys=True), invocation['id']))
        if original:
            original(event)
    kwargs['event_handler'] = observe
    prior_stop = kwargs.get('should_interrupt')
    kwargs['should_interrupt'] = lambda: bool(prior_stop and prior_stop()) or ledger.exhausted(context['task_id'])
    try:
        result = call(**kwargs)
        usage['model_calls'] = max(calls, 1)
        complete = isinstance(result, dict) and result.get('status') not in {'interrupted', 'failed', 'cancelled'}
        ledger.settle(invocation['id'], usage, complete=complete)
        return result
    except BaseException:
        ledger.uncertain(invocation['id'])
        raise
