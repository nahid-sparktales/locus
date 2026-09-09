"""Explicit correction proposals and immutable, project-scoped check versions."""
from __future__ import annotations

import fnmatch
import json
import os
import time
import uuid
from pathlib import Path

from .task_state import TaskStateError, digest, encoded, fingerprints, normalize_checks


def initialize_schema(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS reusable_checks(
            id TEXT NOT NULL, version INTEGER NOT NULL, workspace TEXT NOT NULL,
            state TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL,
            updated_at REAL NOT NULL, PRIMARY KEY(id,version)
        );
        CREATE INDEX IF NOT EXISTS reusable_check_workspace ON reusable_checks(workspace,state);
    ''')


def scope(value):
    value = value or {}
    if not isinstance(value, dict) or set(value) - {'agent_id', 'files'}:
        raise TaskStateError('Check scope supports an agent and relative file patterns.')
    agent = value.get('agent_id') or ''
    patterns = value.get('files') or []
    if not isinstance(agent, str) or len(agent) > 200 or not isinstance(patterns, list) or len(patterns) > 64:
        raise TaskStateError('Check scope is too large.')
    for pattern in patterns:
        if not isinstance(pattern, str) or not pattern or len(pattern) > 500 or pattern.startswith(('/', '~')) or '..' in Path(pattern).parts or '\\' in pattern:
            raise TaskStateError('File scopes must stay inside the project.')
    return {'agent_id': agent, 'files': list(dict.fromkeys(patterns))}


def matches(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) or pattern.startswith('**/') and fnmatch.fnmatchcase(path, pattern[3:]) for pattern in patterns)


def scoped_state(execution, patterns):
    paths = []
    for directory, dirs, files in os.walk(execution, followlinks=False):
        dirs[:] = [name for name in dirs if name not in {'.git', '.venv', 'node_modules', '__pycache__', '.build'} and not (Path(directory) / name).is_symlink()]
        for name in files:
            path = str((Path(directory) / name).relative_to(execution))
            if matches(path, patterns):
                paths.append(path)
                if len(paths) > 4096:
                    raise TaskStateError('Narrow this check to fewer than 4,096 files.')
    return fingerprints(execution, paths)


class ReusableCheckStore:
    def __init__(self, runs):
        self.runs = runs

    def list(self, workspace):
        with self.runs._connect(readonly=True) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='reusable_checks'").fetchone():
                return []
            rows = db.execute('SELECT payload FROM reusable_checks r WHERE workspace=? AND version=(SELECT MAX(version) FROM reusable_checks WHERE id=r.id) ORDER BY updated_at DESC', (str(Path(workspace).resolve()),)).fetchall()
        return [json.loads(row[0]) for row in rows]

    def get(self, key, version=None):
        with self.runs._connect(readonly=True) as db:
            row = db.execute('SELECT payload FROM reusable_checks WHERE id=? AND (? IS NULL OR version=?) ORDER BY version DESC LIMIT 1', (key, version, version)).fetchone()
        if not row:
            raise TaskStateError('Reusable check not found.')
        return json.loads(row[0])

    def propose(self, *, workspace, correction, source, proposal, generation_task_id='', key=None):
        workspace = str(Path(workspace).resolve())
        if not Path(workspace).is_dir() or not isinstance(correction, str) or not correction.strip() or len(correction) > 240000:
            raise TaskStateError('A correction and an existing project are required.')
        if not isinstance(proposal, dict):
            raise TaskStateError('The proposal must be an object.')
        check = normalize_checks([proposal.get('check')])[0]
        value = {'id': key or uuid.uuid4().hex, 'version': 1, 'revision': 1, 'state': 'proposed', 'workspace_root': workspace,
                 'correction': correction, 'source': source, 'check': check, 'scope': scope(proposal.get('scope')),
                 'verification_limits': str(proposal.get('verification_limits') or 'This check only covers the stated condition; review its scope and limitations.')[:8000],
                 'generation_task_id': generation_task_id, 'created_at': time.time()}
        self._write(value, create=True)
        return value

    def _write(self, value, *, create=False, expected_revision=None):
        if self.runs.read_only:
            raise TaskStateError('Check storage is read-only.')
        with self.runs._connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT revision,payload FROM reusable_checks WHERE id=? ORDER BY version DESC LIMIT 1', (value['id'],)).fetchone()
            if expected_revision is not None and (not row or row[0] != expected_revision):
                raise TaskStateError('This check changed. Reload before reviewing it.')
            if expected_revision is not None and value['revision'] != expected_revision and row:
                from .runstore import _alive
                testing = json.loads(row[1]).get('last_test') or {}
                if testing.get('verification_status') == 'checking' and _alive(testing.get('owner_pid', 0)):
                    raise TaskStateError('Stop or finish the running test before changing this check.')
            if create:
                db.execute('INSERT INTO reusable_checks VALUES(?,?,?,?,?,?,?)', (value['id'], value['version'], value['workspace_root'], value['state'], value['revision'], encoded(value), time.time()))
            else:
                db.execute('UPDATE reusable_checks SET state=?,revision=?,payload=?,updated_at=? WHERE id=? AND version=?', (value['state'], value['revision'], encoded(value), time.time(), value['id'], value['version']))

    def review(self, key, action, expected_revision, edits=None):
        value = self.get(key)
        from .runstore import _alive
        testing = value.get('last_test') or {}
        if testing.get('verification_status') == 'checking' and _alive(testing.get('owner_pid', 0)):
            raise TaskStateError('Stop or finish the running test before changing this check.')
        if type(expected_revision) is not int or value['revision'] != expected_revision:
            raise TaskStateError('This check changed. Reload before reviewing it.')
        create = False
        if action == 'edit':
            if value['state'] in {'dismissed', 'disabled'}:
                raise TaskStateError('Start a new proposal to replace a dismissed or disabled check.')
            if value['state'] == 'approved':
                value = {**value, 'version': value['version'] + 1, 'state': 'proposed'}
                value.pop('approved_at', None)
                create = True
            edits = edits or {}
            value.update(check=normalize_checks([edits.get('check', value['check'])])[0], scope=scope(edits.get('scope', value['scope'])),
                         verification_limits=str(edits.get('verification_limits', value['verification_limits']))[:8000])
            value.pop('last_test', None)
        elif action == 'approve' and value['state'] == 'proposed':
            value.update(state='approved', approved_at=time.time())
        elif action == 'dismiss' and value['state'] == 'proposed':
            value['state'] = 'dismissed'
        elif action == 'disable' and value['state'] == 'approved':
            value['state'] = 'disabled'
        else:
            raise TaskStateError('That review action is unavailable for this version.')
        value['revision'] += 1
        self._write(value, create=create, expected_revision=expected_revision)
        return value

    def record_test(self, key, version, revision, result):
        value = self.get(key, version)
        if value['revision'] != revision or value['state'] not in {'proposed', 'approved'}:
            return  # Evidence cannot attach to an edited or dismissed proposal.
        value['last_test'] = result
        self._write(value, expected_revision=revision)

    def begin_test(self, key, version, revision):
        from .runstore import _alive
        with self.runs._connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT payload FROM reusable_checks WHERE id=? ORDER BY version DESC LIMIT 1', (key,)).fetchone()
            if not row:
                raise TaskStateError('Reusable check not found.')
            value = json.loads(row[0])
            testing = value.get('last_test') or {}
            if value['version'] != version or value['revision'] != revision or value['state'] not in {'proposed', 'approved'}:
                raise TaskStateError('The proposal changed before testing started.')
            if testing.get('verification_status') == 'checking' and _alive(testing.get('owner_pid', 0)):
                raise TaskStateError('This check already has a running test.')
            value['last_test'] = {'verification_status': 'checking', 'owner_pid': os.getpid()}
            db.execute('UPDATE reusable_checks SET payload=?,updated_at=? WHERE id=? AND version=?', (encoded(value), time.time(), key, version))

    def import_approved(self, item, workspace, deployment_id):
        if not isinstance(item, dict) or item.get('state') != 'approved' or type(item.get('version')) is not int or item['version'] < 1:
            raise TaskStateError('Deployment checks must identify approved versions.')
        check = normalize_checks([item.get('check')])[0]
        narrowed = scope(item.get('scope'))
        # IDs are local to the imported workspace; provenance retains source identity.
        key = digest({'deployment': deployment_id, 'source_id': item['id']})[:32]
        value = {**item, 'id': key, 'workspace_root': str(Path(workspace).resolve()), 'check': check, 'scope': narrowed,
                 'generation_task_id': '', 'revision': 1, 'source': {**item.get('source', {}), 'imported_from': {
                     'id': item['id'], 'version': item['version'], 'workspace_root': item['workspace_root'], 'deployment_id': deployment_id}}}
        value.pop('last_test', None)
        try:
            existing = self.get(key)
        except TaskStateError:
            self._write(value, create=True)
            return value
        if any(existing.get(field) != value.get(field) for field in ('version', 'check', 'scope', 'source')):
            raise TaskStateError('This deployment already imported a different check definition.')
        return existing

    def freeze(self, workspace, execution, *, agent_id='', selected=None):
        values = self.list(workspace)
        if selected is not None:
            if not isinstance(selected, list) or len(selected) > 64:
                raise TaskStateError('Select at most 64 approved checks.')
            values = [self.get(item['id'], item['version']) for item in selected]
            if any(value['workspace_root'] != str(Path(workspace).resolve()) for value in values):
                raise TaskStateError('Selected checks belong to another project.')
        frozen = []
        for value in values:
            if value['state'] != 'approved':
                if selected is not None:
                    raise TaskStateError('Only approved checks can be selected.')
                continue
            if value['scope']['agent_id'] and value['scope']['agent_id'] != agent_id:
                if selected is not None:
                    raise TaskStateError('A selected check belongs to a different agent.')
                continue
            frozen.append({'id': value['id'], 'version': value['version'], 'check': value['check'], 'scope': value['scope'],
                           'provenance': {'source': value['source'], 'correction': value['correction'], 'approved_at': value['approved_at']},
                           'baseline': scoped_state(execution, value['scope']['files']) if value['scope']['files'] else {},
                           'definition_hash': digest({'check': value['check'], 'scope': value['scope']})})
        if len(frozen) > 64:
            raise TaskStateError('Narrow applicable project checks to at most 64.')
        return frozen


def applicable(task):
    """Frozen versions remain authoritative even after later edits or disabling."""
    result = []
    for item in task.get('reusable_checks', []):
        if digest({'check': item['check'], 'scope': item['scope']}) != item['definition_hash']:
            raise TaskStateError('A frozen check definition changed.')
        patterns = item['scope']['files']
        if patterns and not item.get('explicitly_applied'):
            before, after = item.get('baseline', {}), scoped_state(task['execution_path'], patterns)
            changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
            named = any(path in task.get('request', '') for path in before.keys() | after.keys())
            if not changed and not named:
                continue
        result.append({**item['check'], 'id': f"reusable:{item['id']}:{item['version']}"})
    return result
