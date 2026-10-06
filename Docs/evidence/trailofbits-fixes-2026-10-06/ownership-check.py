"""Actual shadow -> cutover -> partial restore with synthetic encrypted records."""
from contextlib import closing
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
from types import SimpleNamespace

checkout = Path(os.environ['PPV_CHECKOUT'])
sys.path.insert(0, str(checkout / 'agent'))
root = Path(tempfile.mkdtemp(prefix='ownership-')).resolve()
os.environ['OLLAMA_CODE_HOME'] = str(root)
from ollama_code import memory_migration
from ollama_code.memory import MemoryVault, MemoryError
from ollama_code.memory_adapter import LocusKeyProvider, MemoryAdapter
from ollama_code.memory_ownership import ownership_state

# Only this private profile is exercised; the real exclusive file lease remains.
memory_migration.assert_quiescent = lambda _: None
database = root / 'memory/memory.sqlite3'
key = LocusKeyProvider(root).legacy_key()
legacy = MemoryVault(database, key=key)
first = legacy.save({'content': 'legacy canary', 'scope': 'personal', 'status': 'approved'})
adapter = MemoryAdapter(app_dir=root, edition='locus', mode='shadow')
adapter.packet(adapter.access(SimpleNamespace(workspace_root='', cwd='')), 'canary', max_tokens=1000, max_items=8)
adapter.close()
control = root / 'memory-engine/control.sqlite3'
with closing(sqlite3.connect(control)) as db:
    assert db.execute('SELECT COUNT(*) FROM ownership').fetchone()[0] == 0
assert ownership_state(root, 'locus') == 'legacy_authoritative'
assert first['id'] in {record['id'] for record in legacy.list()}

def backup(source, target):
    with closing(sqlite3.connect(source)) as db, closing(sqlite3.connect(target)) as out:
        db.backup(out)

mode = sys.argv[1]
if mode == 'control':
    legacy.save({'content': 'legitimate shadow write', 'scope': 'personal', 'status': 'approved'})
    assert len(legacy.list()) == 2
    print('empty-row shadow remains usable')
    raise SystemExit(0)

backup(control, root / 'shadow.sqlite3')
with memory_migration.HostMemoryMigration(root) as migration:
    migration.snapshot()
    assert migration.validate()['validated']
    assert migration.cutover()['state'] == 'package_authoritative'
with MemoryVault(database) as canonical:
    newer = canonical.save({'content': 'package-era canary', 'scope': 'personal', 'status': 'approved'})
    assert newer['id'] in {record['id'] for record in canonical.list()}

if mode == 'rollback':
    with memory_migration.HostMemoryMigration(root) as migration:
        assert migration.rollback()['state'] == 'legacy_authoritative'
    restored = MemoryVault(database, key=key)
    assert {record['id'] for record in restored.list()} == {first['id'], newer['id']}
    restored.save({'content': 'approved rollback write', 'scope': 'personal', 'status': 'approved'})
    assert len(restored.list()) == 3
    print('explicit rollback preserves both records and permits legacy writes')
    raise SystemExit(0)

backup(control, root / 'good.sqlite3')
shutil.copyfile(root / 'shadow.sqlite3', control)
blocked = False
try:
    if mode == 'cached-writer':
        legacy.save({'content': 'divergent write', 'scope': 'personal', 'status': 'approved'})
    else:
        opened = MemoryVault(database)
        if hasattr(opened, 'close'):
            opened.close()
except MemoryError:
    blocked = True
print('PPV_REACHED', flush=True)
assert blocked, 'stale control silently permitted legacy authority'

# Rejection does not damage the package; restoring its matching control recovers it.
shutil.copyfile(root / 'good.sqlite3', control)
with MemoryVault(database) as canonical:
    assert newer['id'] in {record['id'] for record in canonical.list()}
print('stale control rejected; matching control recovers package-era record')
