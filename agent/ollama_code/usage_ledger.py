"""Persistent invocation accounting and estimated spending reservations.

Token categories are exclusive. Pricing and response usage are never reconstructed
from an assistant's prose. Missing, interrupted and subscription costs stay unknown.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import time
import uuid
from collections import Counter
from urllib.parse import urlsplit

from .ollama import OllamaError


class UsageLimitError(OllamaError):
    pass


def initialize_schema(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS usage_prices(id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS usage_limits(task_id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS usage_native_cursors(account_id TEXT NOT NULL, thread_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(account_id,thread_id));
        CREATE TABLE IF NOT EXISTS usage_invocations(
            id TEXT PRIMARY KEY, invocation_id TEXT NOT NULL, attempt INTEGER NOT NULL,
            task_id TEXT NOT NULL, run_id TEXT NOT NULL, session_id TEXT NOT NULL,
            provider TEXT NOT NULL, model TEXT NOT NULL, purpose TEXT NOT NULL,
            state TEXT NOT NULL, context TEXT NOT NULL, usage TEXT NOT NULL DEFAULT '{}',
            price_id TEXT, estimated_cost REAL, coverage TEXT NOT NULL,
            reserved_cost REAL, reserved_tokens INTEGER NOT NULL,
            created_at REAL NOT NULL, completed_at REAL, owner_pid INTEGER NOT NULL,
            UNIQUE(invocation_id,attempt)
        );
        CREATE INDEX IF NOT EXISTS usage_task ON usage_invocations(task_id,created_at);
        CREATE INDEX IF NOT EXISTS usage_run ON usage_invocations(run_id,created_at);
        CREATE INDEX IF NOT EXISTS usage_session ON usage_invocations(session_id,created_at);
    ''')


def count(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return 0
    return int(value)


def normalize_usage(provider, raw, *, input_tokens=0, output_tokens=0, reported=False):
    raw = raw if isinstance(raw, dict) else {}
    if provider == 'anthropic':
        uncached = count(raw.get('input_tokens'))
        reads = count(raw.get('cache_read_input_tokens'))
        writes = count(raw.get('cache_creation_input_tokens'))
        creation = raw.get('cache_creation') or {}
        short = count(creation.get('ephemeral_5m_input_tokens'))
        long = count(creation.get('ephemeral_1h_input_tokens'))
        # Older responses omit duration: preserve those writes as unknown TTL.
        unknown = max(writes - short - long, 0)
        output = count(raw.get('output_tokens'))
        reasoning = 0
    else:
        total = count(raw.get('prompt_tokens', raw.get('input_tokens', raw.get('inputTokens', input_tokens))))
        details = raw.get('prompt_tokens_details', raw.get('input_tokens_details')) or {}
        reads = min(count(details.get('cached_tokens', raw.get('cachedInputTokens', 0))), total)
        short = min(count(details.get('cache_write_tokens', 0)), total - reads)
        long, unknown = 0, 0
        uncached = total - reads - short
        output = count(raw.get('completion_tokens', raw.get('output_tokens', raw.get('outputTokens', output_tokens))))
        reasoning = min(count((raw.get('completion_tokens_details') or raw.get('output_tokens_details') or {}).get('reasoning_tokens', raw.get('reasoningOutputTokens', 0))), output)
    charges = raw.get('tool_charges')
    known_charges = isinstance(charges, list) and bool(charges) and all(isinstance(item, dict) and item.get('currency') == 'USD' and isinstance(item.get('amount'), (int, float)) and not isinstance(item['amount'], bool) and math.isfinite(item['amount']) and item['amount'] >= 0 for item in charges)
    tool_cost = sum(item['amount'] for item in charges) if known_charges else None
    return {'reported_tool_usage': raw.get('server_tool_use') or charges, 'reported_tool_cost_usd': tool_cost, 'input_uncached': uncached, 'cache_read': reads, 'cache_write_5m': short,
            'cache_write_1h': long, 'cache_write_unknown': unknown, 'output_tokens': output,
            'reasoning_tokens': reasoning, 'input_tokens': uncached + reads + short + long + unknown,
            'total_tokens': uncached + reads + short + long + unknown + output,
            'reported': bool(reported or raw), 'unpriced_tools': bool(raw.get('server_tool_use') or charges) and not known_charges}


def default_price(context, input_tokens):
    """Conservative coverage: exact direct endpoints/models, standard short requests.

    Tables verified on 2026-09-09. Other tiers, long requests and resellers require
    a separately versioned price definition instead of guessing their charges.
    """
    host = urlsplit(str(context.get('route', ''))).hostname
    if input_tokens > 128000 or context.get('service_tier') not in {None, '', 'auto', 'default', 'standard'}:
        return None
    model = context['model']
    if host == 'api.anthropic.com':
        rates = {'claude-sonnet-5': (2, .2, 2.5, 4, 10),
                 'claude-sonnet-4-6': (3, .3, 3.75, 6, 15),
                 'claude-sonnet-4-5': (3, .3, 3.75, 6, 15),
                 'claude-opus-4-6': (5, .5, 6.25, 10, 25),
                 'claude-opus-5': (5, .5, 6.25, 10, 25),
                 'claude-haiku-4-5': (1, .1, 1.25, 2, 5)}
        source = 'https://platform.claude.com/docs/en/about-claude/pricing'
    elif host == 'api.openai.com':
        rates = {'gpt-6-astra': (10, 1, 12.5, None, 50),
                 'gpt-5.6-sol': (4, .4, 5, None, 20),
                 'gpt-5.6-terra': (2, .2, 2.5, None, 12),
                 'gpt-5.6-luna': (.2, .02, .25, None, 1.2)}
        source = 'https://developers.openai.com/api/docs/pricing'
    else:
        return None
    if model not in rates:
        return None
    values = dict(zip(('input_uncached', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'output_tokens'), rates[model], strict=True))
    return {'version': '2026-09-09-direct-standard', 'source': source, 'currency': 'USD',
            'rates_per_million': values, 'model': model, 'route': context.get('route'), 'max_input_tokens': 128000}


def estimate(usage, price, *, partial=False):
    if price is None:
        return None
    value = 0.0
    for name in ('input_uncached', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'cache_write_unknown', 'output_tokens'):
        amount = count(usage.get(name))
        rate = price['rates_per_million'].get(name)
        if amount and rate is None:
            if partial:
                continue
            return None
        value += amount * float(rate or 0) / 1_000_000
    return value


class UsageLedger:
    def __init__(self, runs):
        self.runs = runs

    def set_limits(self, task_id, value, *, only_if_absent=False):
        normalized = {}
        for key in ('max_tokens', 'max_calls', 'max_estimated_usd'):
            if value.get(key) is not None:
                number = value[key]
                if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or number <= 0:
                    raise ValueError('Usage limits must be positive finite numbers')
                if key != 'max_estimated_usd' and int(number) != number:
                    raise ValueError('Token and call limits must be whole numbers')
                normalized[key] = number
        with self.runs._connect() as db:
            db.execute('INSERT INTO usage_limits VALUES(?,?,?) ON CONFLICT(task_id) ' + ('DO NOTHING' if only_if_absent else 'DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at'), (task_id, json.dumps(normalized), time.time()))
        return normalized

    def begin(self, context, *, input_tokens=0, output_tokens=4096, invocation_id=None, attempt=1):
        context = dict(context)
        for key in ('task_id', 'run_id', 'session_id', 'provider', 'model', 'purpose'):
            context[key] = str(context.get(key) or '')
        if not context['task_id']:
            raise ValueError('Every invocation requires an owning task')
        if context.get('limits'):
            self.set_limits(context['task_id'], context['limits'], only_if_absent=True)
        invocation_id = invocation_id or uuid.uuid4().hex
        key = f'{invocation_id}:{attempt}'
        provider = context['provider']
        price = context.get('pricing') or default_price(context, input_tokens)
        if price:
            for rate in price.get('rates_per_million', {}).values():
                if rate is not None and (isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or rate < 0):
                    raise ValueError('Invalid pricing rate')
            if not price.get('version') or not price.get('source') or price.get('currency') != 'USD':
                raise ValueError('Pricing requires a version, source and USD currency')
        price_id = hashlib.sha256(json.dumps(price, sort_keys=True).encode()).hexdigest() if price else None
        # Reserve the full output allowance and the most expensive input category.
        maximum_rate = max((float(value) for name, value in (price or {}).get('rates_per_million', {}).items() if name != 'output_tokens' and value is not None), default=0)
        reservation = (count(input_tokens) * maximum_rate + count(output_tokens) * float(price['rates_per_million'].get('output_tokens') or 0)) / 1e6 if price else None
        coverage = 'local' if provider == 'ollama' else 'subscription' if provider == 'chatgpt' else 'pending' if price else 'unavailable'
        tokens = count(input_tokens) + count(output_tokens)
        with self.runs._connect() as db:
            db.execute('BEGIN IMMEDIATE')
            existing = db.execute('SELECT * FROM usage_invocations WHERE id=?', (key,)).fetchone()
            if existing:
                if existing['context'] != json.dumps(context, sort_keys=True):
                    raise ValueError('This invocation ID already identifies a different call')
                return dict(existing)
            row = db.execute('SELECT payload FROM usage_limits WHERE task_id=?', (context['task_id'],)).fetchone()
            limits = json.loads(row[0]) if row else {}
            previous = [dict(row) for row in db.execute('SELECT * FROM usage_invocations WHERE task_id=?', (context['task_id'],))]
            if limits.get('max_calls') and sum(max(count(json.loads(row['usage']).get('model_calls')), 1) for row in previous) >= limits['max_calls']:
                raise UsageLimitError('The task model-call limit is exhausted')
            consumed = sum(count(json.loads(row['usage']).get('total_tokens')) if row['state'] == 'settled' else max(row['reserved_tokens'], count(json.loads(row['usage']).get('total_tokens'))) for row in previous)
            if limits.get('max_tokens') and consumed + tokens > limits['max_tokens']:
                raise UsageLimitError('The remaining token allowance cannot reserve this call')
            if limits.get('max_estimated_usd') and provider not in {'ollama', 'chatgpt'}:
                billable = [row for row in previous if row['provider'] not in {'ollama', 'chatgpt'}]
                if price is None or any(row['state'] == 'uncertain' or row['coverage'] in {'partial', 'unavailable'} or (row['state'] == 'pending' and row['reserved_cost'] is None) for row in billable):
                    raise UsageLimitError('Estimated spending control is paused until pricing and unsettled usage are reconciled')
                spent = sum(float(row['estimated_cost'] if row['state'] == 'settled' else row['reserved_cost'] or 0) for row in billable)
                if spent + reservation > limits['max_estimated_usd']:
                    raise UsageLimitError('The remaining estimated spending allowance cannot reserve this call')
            if price:
                db.execute('INSERT OR IGNORE INTO usage_prices VALUES(?,?,?)', (price_id, json.dumps(price), time.time()))
            db.execute('INSERT INTO usage_invocations(id,invocation_id,attempt,task_id,run_id,session_id,provider,model,purpose,state,context,price_id,coverage,reserved_cost,reserved_tokens,created_at,owner_pid) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                       (key, invocation_id, attempt, context['task_id'], context['run_id'], context['session_id'], provider, context['model'], context['purpose'], 'pending', json.dumps(context, sort_keys=True), price_id, coverage, reservation, tokens, time.time(), os.getpid()))
        return self.get(key)

    def get(self, key):
        with self.runs._connect(readonly=True) as db:
            row = db.execute('SELECT * FROM usage_invocations WHERE id=?', (key,)).fetchone()
        return dict(row) if row else None

    def settle(self, key, usage, *, complete=True):
        with self.runs._connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM usage_invocations WHERE id=?', (key,)).fetchone()
            if row is None:
                raise ValueError('Unknown invocation')
            payload = json.dumps(usage, sort_keys=True)
            if row['state'] == 'settled':
                if row['usage'] != payload:
                    raise ValueError('Final usage already recorded for this invocation')
                return self.get(key)
            price_row = db.execute('SELECT payload FROM usage_prices WHERE id=?', (row['price_id'],)).fetchone()
            price = json.loads(price_row[0]) if price_row else None
            if price and price.get('max_input_tokens') and count(usage.get('input_tokens')) > price['max_input_tokens']:
                price = None
            full_cost = estimate(usage, price)
            cost = estimate(usage, price, partial=True)
            coverage = 'local' if row['provider'] == 'ollama' else 'subscription' if row['provider'] == 'chatgpt' else 'known' if cost is not None and usage.get('reported') else 'unavailable'
            if coverage == 'known' and (full_cost is None or usage.get('unpriced_tools')):
                coverage = 'partial'
            if usage.get('reported_tool_cost_usd') is not None:
                cost = float(cost or 0) + float(usage['reported_tool_cost_usd'])
                if coverage == 'unavailable':
                    coverage = 'partial'
            if not complete:
                coverage = 'uncertain'
            if coverage in {'local', 'subscription', 'unavailable'}:
                cost = None
            db.execute('UPDATE usage_invocations SET state=?,usage=?,estimated_cost=?,coverage=?,completed_at=? WHERE id=?',
                       ('settled' if complete and usage.get('reported') else 'uncertain', payload, cost, coverage, time.time(), key))
        return self.get(key)

    def uncertain(self, key):
        with self.runs._connect() as db:
            db.execute("UPDATE usage_invocations SET state='uncertain',coverage='uncertain' WHERE id=? AND state='pending'", (key,))

    def exhausted(self, task_id):
        with self.runs._connect(readonly=True) as db:
            row = db.execute('SELECT payload FROM usage_limits WHERE task_id=?', (task_id,)).fetchone()
        limits = json.loads(row[0]) if row else {}
        if not limits:
            return False
        summary = self.summary(task_id=task_id)
        # Native helpers expose usage after each internal call. Interrupt at the
        # next observable boundary; subscriptions never acquire API dollar prices.
        return bool((limits.get('max_tokens') and summary['total_tokens'] >= limits['max_tokens']) or
                    (limits.get('max_calls') and summary['model_calls'] >= limits['max_calls'] and summary['total_tokens'] > 0))

    def recover(self):
        # A dead process cannot reconcile the outcome of an interrupted call.
        with self.runs._connect() as db:
            for row in db.execute("SELECT id,owner_pid FROM usage_invocations WHERE state='pending'").fetchall():
                try:
                    os.kill(row['owner_pid'], 0)
                except ProcessLookupError:
                    db.execute("UPDATE usage_invocations SET state='uncertain',coverage='uncertain' WHERE id=?", (row['id'],))
                except PermissionError:
                    pass

    def records(self, *, task_id='', run_id='', session_id='', since=0):
        with self.runs._connect(readonly=True) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='usage_invocations'").fetchone():
                return []
            rows = db.execute("SELECT i.*, p.payload AS pricing FROM usage_invocations i LEFT JOIN usage_prices p ON p.id=i.price_id WHERE (?='' OR task_id=?) AND (?='' OR run_id=?) AND (?='' OR session_id=?) AND i.created_at>=? ORDER BY i.created_at,id", (task_id, task_id, run_id, run_id, session_id, session_id, since)).fetchall()
        return [{**dict(row), 'context': json.loads(row['context']), 'usage': json.loads(row['usage']), 'pricing': json.loads(row['pricing']) if row['pricing'] else None} for row in rows]

    def summary(self, **filters):
        return self.summarize(self.records(**filters))

    @staticmethod
    def summarize(records):
        coverage = Counter(row['coverage'] for row in records)
        known = [row for row in records if row['estimated_cost'] is not None]
        status = 'unavailable' if not records or not known else 'partial' if any(row['coverage'] not in {'known', 'local', 'subscription'} for row in records) else 'known'
        if records and all(row['coverage'] == 'local' for row in records):
            status = 'local'
        elif records and all(row['coverage'] == 'subscription' for row in records):
            status = 'subscription'
        return {'invocations': len(records), 'model_calls': sum(max(row['usage'].get('model_calls', 1), 1) for row in records), 'input_tokens': sum(row['usage'].get('input_tokens', 0) for row in records),
                'output_tokens': sum(row['usage'].get('output_tokens', 0) for row in records), 'total_tokens': sum(row['usage'].get('total_tokens', 0) for row in records),
                'estimated_api_cost': sum(row['estimated_cost'] for row in known) if known else None,
                'cost_coverage': status, 'coverage_counts': dict(coverage),
                'pending_calls': sum(row['state'] == 'pending' for row in records),
                'uncertain_calls': sum(row['state'] == 'uncertain' for row in records),
                'pricing_versions': sorted({row['pricing']['version'] for row in records if row['pricing']}),
                'by_purpose': dict(Counter(row['purpose'] for row in records)),
                'token_categories': {key: sum(row['usage'].get(key, 0) for row in records) for key in ('input_uncached', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'cache_write_unknown', 'output_tokens', 'reasoning_tokens')}}

    def dashboard(self, since=0):
        records = self.records(since=since)
        def groups(key):
            grouped = {}
            for row in records:
                name = str(key(row) or 'Unassigned')
                grouped.setdefault(name, []).append(row)
            return [{'name': name, **self.summarize(rows)} for name, rows in sorted(grouped.items())]
        return {**self.summarize(records),
                'by_model': groups(lambda row: row['provider'] + '/' + row['model']),
                'by_workspace': groups(lambda row: row['context'].get('workspace')),
                'by_agent': groups(lambda row: row['context'].get('agent_id')),
                'by_day': groups(lambda row: time.strftime('%Y-%m-%d', time.localtime(row['created_at']))),
                'by_task': groups(lambda row: row['task_id'])}
