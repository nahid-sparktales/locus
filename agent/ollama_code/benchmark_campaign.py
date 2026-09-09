"""Reproducible, opt-in campaign admission and reporting, independent of execution.

Adapters own provider transport and interruption fixtures. This module never
starts a provider call and treats missing adapter coverage as an explicit gap.
"""
from __future__ import annotations

import hashlib
import json
import time
from decimal import Decimal

RECOVERY_SCENARIOS = ('verified_step', 'model_call', 'mutation', 'repair_review_restart',
                      'changed_dependency', 'compaction_correction', 'interrupted_checks', 'uncertain_http_action')
BENCHMARK_SCENARIOS = ('bug_fix', 'multi_file', 'long_context_correction', 'interrupted_capsule',
                       'changed_dependency', 'document_artifact', 'browser_task', 'provider_failure')
MODES = ('work', 'plan_work', 'goal', 'capsule')


def fingerprint(configuration):
    required = {'provider', 'model', 'model_version', 'account_class', 'mode', 'recipe', 'effort', 'tools', 'permissions', 'app_version'}
    if required - configuration.keys():
        raise ValueError('Record every configuration field before admission.')
    return hashlib.sha256(json.dumps(configuration, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def matrix(configurations, *, phase):
    if phase not in {1, 2}:
        raise ValueError('A campaign belongs to phase 1 or phase 2.')
    scenarios = RECOVERY_SCENARIOS if phase == 1 else BENCHMARK_SCENARIOS
    # Repetition then scenario then configuration interleaves all routes.
    return [{'id': f'{repetition}:{scenario}:{fingerprint(config)}', 'repetition': repetition,
             'scenario': scenario, 'configuration': config, 'state': 'pending',
             'max_calls': 30 if phase == 1 else 50, 'max_seconds': 600 if phase == 1 else 1200}
            for repetition in range(1, 4) for scenario in scenarios for config in configurations]


class Campaign:
    """Persist campaign attempts/reservations before an adapter starts work."""
    def __init__(self, runs, identifier, *, phase, configurations):
        from .task_journal import TaskJournal
        from .task_usage_ledger import UsageLedger
        self.runs, self.identifier = runs, identifier
        if phase not in {1, 2}:
            raise ValueError("Invalid campaign phase")
        self.journal = TaskJournal(runs, 'campaign:' + identifier)
        self.ledger = UsageLedger(self.journal)
        self.cap = Decimal(50 if phase == 1 else 200)
        self.cases = matrix(configurations, phase=phase)
        with runs._connect(readonly=True) as db:
            previous = db.execute("SELECT payload FROM task_observations WHERE id=?", (identifier + ':configuration',)).fetchone()
        if previous and (json.loads(previous[0])['cases'] != self.cases or json.loads(previous[0])['phase'] != phase):
            raise ValueError('A resumed campaign must keep its original configuration.')
        self.ledger.set_limit(self.cap)
        self.journal.observe(identifier + ':configuration', 'campaign_configuration', {'phase': phase, 'cases': self.cases, 'cap_usd': str(self.cap)})

    def start(self, case):
        if case not in self.cases:
            raise ValueError('Case is not in the approved campaign matrix.')
        identifier = self.identifier + ':' + case['id']
        if self.runs.run(identifier):
            raise ValueError('This attempt already started. Inspect its saved outcome; restart requires a new campaign.')
        self.runs.start_run(identifier, request=case['scenario'], run_kind='evaluation', state='running', manifest={'benchmark_configuration': case['configuration']})
        self.journal.observe(identifier + ':started', 'case_started', {'case_id': case['id'], 'started_at': time.time()})
        return identifier

    def reserve(self, case, call_id, *, upper_bound, rates=None):
        if case not in self.cases:
            raise ValueError('Case is not in the approved campaign matrix.')
        with self.runs._connect(readonly=True) as db:
            started = db.execute("SELECT payload FROM task_observations WHERE id=?", (self.identifier + ':' + case['id'] + ':started',)).fetchone()
            finished = db.execute("SELECT 1 FROM task_observations WHERE id=?", (self.identifier + ':' + case['id'] + ':result',)).fetchone()
        if not started or finished:
            raise ValueError('This scenario is not an active started attempt.')
        from .task_journal import TaskJournal
        from .task_usage_ledger import UsageLedger
        ledger = UsageLedger(TaskJournal(self.runs, self.journal.task_id, self.identifier + ':' + case['id']))
        config = case['configuration']
        return ledger.reserve(provider=config['provider'], model=config['model'], stage=case['scenario'],
            metering=config['account_class'], upper_bound=upper_bound, rates=rates, identifier=call_id,
            max_calls_per_run=case['max_calls'], deadline=json.loads(started[0])['started_at'] + case['max_seconds'])

    def finish(self, case, result):
        if case not in self.cases:
            raise ValueError('Case is not in the approved campaign matrix.')
        allowed = {'passed', 'failed', 'ungraded', 'unsupported', 'incomplete'}
        if result.get('state') not in allowed:
            raise ValueError('Record an explicit measured outcome or coverage gap.')
        if result['state'] == 'passed' and (result.get('execution_outcome') != 'completed' or result.get('acceptance_passed') is not True):
            raise ValueError('Incomplete execution cannot pass a benchmark.')
        if result['state'] == 'unsupported' and not result.get('reason'):
            raise ValueError('Record why the condition is unmatched or unsupported.')
        if result['state'] != 'unsupported':
            with self.runs._connect(readonly=True) as db:
                if not db.execute("SELECT 1 FROM task_observations WHERE id=?", (self.identifier + ':' + case['id'] + ':started',)).fetchone():
                    raise ValueError('A result requires a started attempt.')
        self.journal.observe(self.identifier + ':' + case['id'] + ':result', 'case_result', {'case_id': case['id'], **result})
        if self.runs.run(self.identifier + ':' + case['id']):
            self.runs.set_state(self.identifier + ':' + case['id'], 'completed' if result['state'] == 'passed' else 'failed' if result['state'] == 'failed' else 'interrupted')

    def report(self):
        with self.runs._connect(readonly=True) as db:
            results = {r['case_id']: r for r in [json.loads(row[0]) for row in db.execute("SELECT payload FROM task_observations WHERE task_id=? AND kind='case_result'", (self.journal.task_id,))]}
            started = {json.loads(row[0])['case_id'] for row in db.execute("SELECT payload FROM task_observations WHERE task_id=? AND kind='case_started'", (self.journal.task_id,))}
        metrics = {k: None for k in ('interventions', 'correction_ms', 'repair_attempts', 'time_to_acceptance_ms', 'duration_ms')}
        cases = [{**metrics, **case, **results.get(case['id'], {'state': 'incomplete' if case['id'] in started else 'pending'})} for case in self.cases]
        accepted = sum(c['state'] == 'passed' for c in cases)
        usage = self.ledger.summary()
        return {'cases': cases, 'complete': all(c['state'] in {'passed', 'failed', 'unsupported'} for c in cases),
            'release_gate_passed': all(c['state'] == 'passed' for c in cases) and bool(cases),
            'started_attempts': len(started), 'accepted': accepted,
            'acceptance_rate': accepted / len(started) if started else None,
            'known_spend_per_accepted': usage['known_subtotal'] / accepted if accepted else None,
            'usage': usage, 'cap_usd': float(self.cap), 'limitations': ['Missing conditions remain gaps; this report makes no superiority claim.']}
