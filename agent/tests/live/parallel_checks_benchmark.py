"""Offline paired measurement of the real verifier, never calls a provider."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import sys
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='locus-check-measurement-') as directory:
        root = Path(directory)
        os.environ['OLLAMA_CODE_HOME'] = str(root / 'app')
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        from ollama_code.core import AgentCore
        from ollama_code.runstore import RunStore
        from ollama_code.task_journal import TaskJournal
        from ollama_code.task_state import TaskStateStore, TaskVerifier
        results = []
        for size in (100, 1024, 4096):
            workspace = root / str(size)
            workspace.mkdir()
            for index in range(size):
                (workspace / f'{index}.json').write_text(json.dumps({'index': index, 'content': 'fixture' * 1024}))
            core = AgentCore(cwd=str(workspace), config={'provider': 'ollama', 'permission_mode': 'bypass'})
            runs = RunStore(root / f'{size}.db')
            runs.start_run('measurement', session_id=str(size), workspace_root=str(workspace), execution_path=str(workspace))
            core.task_journal = TaskJournal.bind(runs, runs.run('measurement'))
            states = TaskStateStore(runs)
            states.ensure('checks', request='Fixture content', revision=1, workspace=str(workspace), execution=str(workspace))
            checks = [{'id': str(i), 'kind': 'json_value', 'path': f'{i}.json', 'pointer': '/index', 'value': i,
                       'requirement': f'Fixture {i} matches'} for i in range(32)]
            pairs = []
            try:
                for repetition in range(21):
                    pair = {}
                    for workers in ((1, 2) if repetition % 2 else (2, 1)):
                        before = time.perf_counter()
                        result = TaskVerifier(states, 'checks', core, 'measurement', parallelism=workers).verify(checks, lambda *_: 'once')
                        elapsed = time.perf_counter() - before
                        signature = result['verification_status']
                        evidence = {r['id']: r for r in states.receipts('checks')}
                        current = [{k: evidence[identifier].get(k) for k in ('check_id', 'check_hash', 'state', 'fingerprints', 'detail')}
                                   for identifier in result['evidence_ids']]
                        evidence_hash = hashlib.sha256(json.dumps(current, sort_keys=True).encode()).hexdigest()
                        pair[str(workers)] = {'seconds': elapsed, 'outcome': signature, 'evidence_hash': evidence_hash}
                    if repetition:
                        pairs.append(pair)
            finally:
                core.close()
            serial = [p['1']['seconds'] for p in pairs]
            parallel = [p['2']['seconds'] for p in pairs]
            def p95(values):
                return sorted(values)[18]
            improvement = 1 - statistics.median(parallel) / statistics.median(serial)
            regression = p95(parallel) / p95(serial) - 1
            equal = all(p['1']['outcome'] == p['2']['outcome'] == 'passed' and p['1']['evidence_hash'] == p['2']['evidence_hash'] for p in pairs)
            results.append({'workspace_files': size, 'checks': 32, 'paired_repetitions': 20,
                'median_improvement': improvement, 'p95_regression': regression, 'correctness_equal': equal,
                'qualified': equal and improvement >= .1 and regression <= .05, 'pairs': pairs})
        report = {'version': 1, 'kind': 'offline_deterministic_checks', 'platform': platform.platform(),
                  'python': platform.python_version(), 'measured_at': time.time(), 'workloads': results,
                  'automatic_concurrency': all(r['qualified'] for r in results),
                  'limitations': ['Local file/JSON verification only; no provider performance claim.',
                     'One machine and warm filesystem cache; invocation-attribution regressions run separately.']}
        Path(args.output).resolve().write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
