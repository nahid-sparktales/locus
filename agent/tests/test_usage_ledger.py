import concurrent.futures

import pytest

from ollama_code.runstore import RunStore
from ollama_code.usage_ledger import UsageLedger, UsageLimitError, normalize_usage


@pytest.fixture
def ledger(tmp_path):
    return UsageLedger(RunStore(tmp_path / 'usage.sqlite3'))


def context(**updates):
    return {'task_id': 'task', 'run_id': 'run', 'session_id': 'session', 'purpose': 'worker',
            'provider': 'remote', 'model': 'fixture', 'route': 'https://fixture.invalid',
            'pricing': {'version': 'fixture-v1', 'source': 'fixture', 'currency': 'USD',
                        'rates_per_million': {'input_uncached': 1, 'output_tokens': 2, 'cache_read': .1, 'cache_write_5m': 1.25, 'cache_write_1h': 2}}, **updates}


def test_openai_cached_and_reasoning_tokens_are_not_counted_twice():
    usage = normalize_usage('openai', {'prompt_tokens': 100, 'completion_tokens': 40,
                                      'prompt_tokens_details': {'cached_tokens': 75},
                                      'completion_tokens_details': {'reasoning_tokens': 30}})
    assert usage['input_uncached'] == 25
    assert usage['cache_read'] == 75
    assert usage['reasoning_tokens'] == 30
    assert usage['total_tokens'] == 140


def test_anthropic_cache_writes_keep_their_durations(ledger):
    usage = normalize_usage('anthropic', {'input_tokens': 10, 'output_tokens': 20, 'cache_read_input_tokens': 100,
                                         'cache_creation_input_tokens': 50,
                                         'cache_creation': {'ephemeral_5m_input_tokens': 20, 'ephemeral_1h_input_tokens': 30}})
    assert usage['input_tokens'] == 160
    assert usage['total_tokens'] == 180
    invocation = ledger.begin(context())
    result = ledger.settle(invocation['id'], usage)
    assert result['estimated_cost'] == pytest.approx((10 + 40 + 10 + 25 + 60) / 1e6)
    assert result['coverage'] == 'known'


def test_usage_and_reservation_are_deduplicated(ledger):
    a = ledger.begin(context(), invocation_id='stable', attempt=2)
    b = ledger.begin(context(), invocation_id='stable', attempt=2)
    assert a['id'] == b['id']
    usage = normalize_usage('openai', {'prompt_tokens': 100, 'completion_tokens': 10})
    ledger.settle(a['id'], usage)
    ledger.settle(a['id'], usage)
    assert ledger.summary()['total_tokens'] == 110
    assert ledger.summary()['invocations'] == 1
    with pytest.raises(ValueError, match='already recorded'):
        ledger.settle(a['id'], {**usage, 'total_tokens': 220})


def test_uncertain_call_survives_restart_and_blocks_estimated_spending(ledger):
    ledger.set_limits('task', {'max_estimated_usd': 1})
    invocation = ledger.begin(context(), input_tokens=100, output_tokens=200)
    ledger.uncertain(invocation['id'])
    reconstructed = UsageLedger(RunStore(ledger.runs.path))
    assert reconstructed.summary()['uncertain_calls'] == 1
    with pytest.raises(UsageLimitError, match='unsettled'):
        reconstructed.begin(context())


def test_concurrent_reservations_cannot_oversubscribe(ledger):
    ledger.set_limits('task', {'max_estimated_usd': .025})
    def reserve(_):
        try:
            return ledger.begin(context(), input_tokens=10000, output_tokens=1000)['id']
        except UsageLimitError:
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(reserve, range(8)))
    assert len([item for item in results if item]) == 1
    assert ledger.summary()['pending_calls'] == 1


def test_unknown_pricing_and_subscription_never_become_zero_dollar_estimates(ledger):
    for provider in ('remote', 'ollama', 'chatgpt'):
        invocation = ledger.begin(context(provider=provider, pricing=None, task_id=provider))
        ledger.settle(invocation['id'], normalize_usage('openai', {'prompt_tokens': 10, 'completion_tokens': 10}))
        assert ledger.summary(task_id=provider)['estimated_api_cost'] is None
    assert ledger.summary(task_id='remote')['cost_coverage'] == 'unavailable'
    assert ledger.summary(task_id='chatgpt')['cost_coverage'] == 'subscription'
    assert ledger.summary(task_id='ollama')['cost_coverage'] == 'local'
    ledger.set_limits('unknown', {'max_estimated_usd': 1})
    with pytest.raises(UsageLimitError, match='pricing'):
        ledger.begin(context(task_id='unknown', pricing=None))


def test_call_and_token_limits_are_central_and_persistent(ledger):
    ledger.set_limits('task', {'max_calls': 1, 'max_tokens': 100})
    with pytest.raises(UsageLimitError, match='token'):
        ledger.begin(context(), input_tokens=50, output_tokens=100)
    first = ledger.begin(context(), input_tokens=10, output_tokens=10)
    ledger.settle(first['id'], normalize_usage('openai', {'prompt_tokens': 10, 'completion_tokens': 10}))
    with pytest.raises(UsageLimitError, match='call'):
        UsageLedger(RunStore(ledger.runs.path)).begin(context(), input_tokens=1, output_tokens=1)


def test_unknown_cache_duration_preserves_known_subtotal(ledger):
    call = ledger.begin(context())
    usage = normalize_usage('anthropic', {'input_tokens': 10, 'output_tokens': 20, 'cache_creation_input_tokens': 50})
    result = ledger.settle(call['id'], usage)
    assert result['coverage'] == 'partial'
    assert result['estimated_cost'] == pytest.approx(50 / 1e6)
    assert ledger.summary()['total_tokens'] == 80


def test_native_cumulative_usage_survives_worker_recreation(ledger):
    from ollama_code.model_usage import tracked_native
    def call(values):
        def run(**kwargs):
            for input_tokens, output_tokens, cached in values:
                kwargs['event_handler']({'method': 'thread/tokenUsage/updated', 'params': {'tokenUsage': {'total': {'inputTokens': input_tokens, 'outputTokens': output_tokens, 'cachedInputTokens': cached}}}})
            return {'status': 'completed'}
        return run
    tracked_native(None, call([(100, 20, 60), (100, 20, 60)]), context=context(provider='chatgpt'), runs=ledger.runs, thread_id='thread')
    tracked_native(None, call([(100, 20, 60), (130, 25, 80), (130, 25, 80)]), context=context(provider='chatgpt'), runs=RunStore(ledger.runs.path), thread_id='thread')
    result = ledger.summary()
    assert result['total_tokens'] == 155
    assert result['model_calls'] == 2
    assert result['token_categories']['cache_read'] == 80
    assert result['estimated_api_cost'] is None


def test_limits_from_agent_context_are_not_reset_by_later_calls(ledger):
    first = ledger.begin(context(limits={'max_calls': 1}), input_tokens=10, output_tokens=10)
    ledger.settle(first['id'], normalize_usage('openai', {'prompt_tokens': 1, 'completion_tokens': 1}))
    with pytest.raises(UsageLimitError):
        ledger.begin(context(limits={'max_calls': 100}), input_tokens=1, output_tokens=1)
