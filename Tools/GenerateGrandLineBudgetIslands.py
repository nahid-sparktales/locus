#!/usr/bin/env python3
"""Developer-only Meshy Smart Topology island campaign (four at 15 credits). Requires an explicitly approved budget.

Keeps credentials in memory, provider URLs and originals outside the repository,
and durably reserves every submission before contacting Meshy. Restarting resumes
known tasks; ambiguous submissions are never submitted a second time.
"""
from __future__ import annotations
import argparse
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request

from GenerateAgentWorldAssets import NoAPIRedirects, save
from OptimizeGrandLineAssets import optimize


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--approved-credits', type=int, required=True)
    parser.add_argument('--plan', type=Path, default=repo / 'Tools/GrandLineBudgetIslandPrompts.json')
    parser.add_argument('--phase', choices=['previews', 'models', 'all'], default='all')
    args = parser.parse_args()
    plan_bytes = args.plan.read_bytes()
    plan = json.loads(plan_bytes)
    if args.approved_credits != plan['credit_ceiling']:
        parser.error('Use the explicitly approved campaign ceiling')
    private = args.state_dir.resolve()
    if private.is_relative_to(repo):
        parser.error('Private state must stay outside the project')
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(private, 0o700)
    lock = (private / 'lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    ledger_path = private / 'ledger.json'
    state = json.loads(ledger_path.read_text()) if ledger_path.exists() else {
        'version': 1, 'approved_credits': args.approved_credits,
        'plan_sha256': hashlib.sha256(plan_bytes).hexdigest(), 'tasks': [], 'assets': {}, 'references': {}}
    assert state['plan_sha256'] == hashlib.sha256(plan_bytes).hexdigest(), 'Cannot change a running campaign'
    assert state['approved_credits'] == args.approved_credits
    key = getpass.getpass('Meshy API key (hidden): ')
    assert key.startswith('msy_')
    opener = urllib.request.build_opener(NoAPIRedirects())
    def api(endpoint, payload=None):
        request = urllib.request.Request('https://api.meshy.ai/openapi/' + endpoint,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        try:
            with opener.open(request, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f'Meshy returned HTTP {error.code}') from None
        except Exception:
            raise RuntimeError('Provider request incomplete; reconcile the saved reservation before retrying') from None
    balance = api('v1/balance')['balance']
    print('Available credits:', balance, flush=True)
    state.setdefault('starting_balance', balance)
    def reserved():
        return sum(max(t['reserved_credits'], t.get('consumed_credits', 0)) for t in state['tasks'])
    if balance < args.approved_credits - reserved():
        raise SystemExit('Balance cannot cover the remaining approved campaign; nothing new submitted')
    output = repo / 'plugins/agent-world/ui/themes/grand-line'
    (output / 'assets').mkdir(exist_ok=True)
    (output / 'references').mkdir(exist_ok=True)
    def download(url, target):
        # Signed output URLs need no authorization. Never forward the API key.
        parsed = urllib.parse.urlparse(url)
        assert parsed.scheme == 'https' and not parsed.username and not parsed.password
        with urllib.request.urlopen(url, timeout=180) as response:
            data = response.read(150 * 1024 * 1024 + 1)
        assert 0 < len(data) <= 150 * 1024 * 1024
        target.write_bytes(data)
        return data
    def submit(asset, stage, payload, endpoint, cost):
        if reserved() + cost > args.approved_credits:
            raise RuntimeError('Campaign credit ceiling reached')
        if api('v1/balance')['balance'] < cost:
            raise RuntimeError('Insufficient balance')
        task = {'asset': asset, 'stage': stage, 'endpoint': endpoint, 'reserved_credits': cost,
                'ai_model': payload['ai_model'], 'status': 'SUBMITTING', 'settings': payload}
        state['tasks'].append(task)
        save(ledger_path, state)
        result = api(endpoint, payload)
        task['id'] = result['result']
        task['status'] = 'PENDING'
        save(ledger_path, state)
        print('Submitted', asset, stage, task['id'], flush=True)
        return task
    def complete(task, response):
        name = task['asset']
        if task['stage'] == 'preview':
            target = output / 'references' / (name + '.png')
            data = target.read_bytes() if target.exists() else download(response['thumbnail_url'], target)
            state['references'][name] = {'path': 'references/' + target.name,
                'sha256': hashlib.sha256(data).hexdigest(), 'task_id': task['id']}
        else:
            original = private / (name + '.glb')
            source = original.read_bytes() if original.exists() else download(response['model_urls']['glb'], original)
            packed, metadata = optimize(source, color_size=1024, pbr_size=512)
            target = output / 'assets' / (name + '.glb')
            target.write_bytes(packed)
            state['assets'][name] = {'path': 'assets/' + target.name, 'source_task_id': task['id'],
                'reference_task_id': state['references'][name]['task_id'], **metadata}
        task['downloaded'] = True
        save(ledger_path, state)
        print('Prepared', name, task['stage'], flush=True)
    def run_phase(stage):
        endpoint, cost = 'v2/text-to-3d', (5 if stage == 'preview' else 10)
        while True:
            by_name = {t['asset']: t for t in state['tasks'] if t['stage'] == stage}
            if any(not t.get('id') for t in by_name.values()):
                raise RuntimeError('Ambiguous submission; reconcile the durable ledger manually')
            if any(t['status'] in ('FAILED', 'CANCELED') for t in by_name.values()):
                raise RuntimeError('A task failed; review before generating any replacement')
            active = sum(t['status'] != 'SUCCEEDED' for t in by_name.values())
            for item in plan['assets']:
                if item['asset'] in by_name or active >= 4:
                    continue
                if stage == 'preview':
                    payload = {'mode': 'preview', 'ai_model': 'meshy-t2', 'model_type': 'smart-topology',
                        'prompt': item['prompt'], 'topology': 'triangle', 'target_polycount': 15000,
                        'target_formats': ['glb']}
                else:
                    payload = {'mode': 'refine', 'ai_model': 'meshy-7.1',
                        'preview_task_id': state['references'][item['asset']]['task_id'],
                        'texture_prompt': item['prompt'], 'enable_pbr': True,
                        'texture_resolution': '4k', 'target_formats': ['glb']}
                task = submit(item['asset'], stage, payload, endpoint, cost)
                by_name[item['asset']] = task
                active += 1
            for task in by_name.values():
                if task.get('downloaded'):
                    continue
                response = api(endpoint + '/' + task['id'])
                save(private / (task['id'] + '.json'), response)
                previous = (task['status'], task.get('progress'))
                task['status'] = response['status']
                task['progress'] = response.get('progress', 0)
                if 'consumed_credits' in response:
                    task['consumed_credits'] = response['consumed_credits']
                save(ledger_path, state)
                if previous != (task['status'], task['progress']):
                    print(task['asset'], stage, task['status'], task['progress'], flush=True)
                if task['status'] == 'SUCCEEDED':
                    complete(task, response)
            if len(by_name) == len(plan['assets']) and all(t.get('downloaded') for t in by_name.values()):
                break
            time.sleep(12)
    if args.phase in ('previews', 'all'):
        run_phase('preview')
    if args.phase == 'all':
        print('Preview geometry ready for visual review. Enter MODELS to begin approved model stage.', flush=True)
        if input().strip() != 'MODELS':
            return
    if args.phase in ('models', 'all'):
        run_phase('model')
    print('Campaign reserved:', reserved(), 'credits. Remaining:', api('v1/balance')['balance'], flush=True)

if __name__ == '__main__':
    main()
