"""Run-history transactions release OS resources even without garbage collection."""
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from ollama_code.runstore import RunStore


def test_run_store_releases_connections_under_service_file_limits(tmp_path):
    code = """
import gc, resource, sys
from pathlib import Path
from ollama_code.runstore import RunStore
gc.disable()
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (min(64, hard), hard))
store = RunStore(Path(sys.argv[1]))
for _ in range(400):
    with store._connect(readonly=True) as db:
        assert db.execute('SELECT version FROM schema_meta').fetchone()[0] > 0
print('closed')
"""
    result = subprocess.run([sys.executable, "-c", code, str(tmp_path / "history?#.sqlite3")],
                            cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "closed"


def test_run_store_closes_after_commit_and_rollback(tmp_path):
    store = RunStore(tmp_path / "history.sqlite3")
    with store._connect() as db:
        db.execute("CREATE TABLE fixture(value TEXT)")
        db.execute("INSERT INTO fixture VALUES('committed')")
    with pytest.raises(sqlite3.ProgrammingError, match="closed"):
        db.execute("SELECT 1")
    with pytest.raises(ValueError), store._connect() as db:
        db.execute("INSERT INTO fixture VALUES('rolled back')")
        raise ValueError("fixture rollback")
    with store._connect(readonly=True) as db:
        assert [row[0] for row in db.execute("SELECT value FROM fixture")] == ["committed"]


