"""The extracted runtime keeps the existing product database and authority."""
import json

import pytest
from locus_runtime.storage import RuntimeStore as PackageRuntimeStore

from ollama_code.runstore import RunStore
from ollama_code.runtime_store import RuntimeStore
from ollama_code.usage_ledger import UsageLedger, UsageLimitError, normalize_usage


def test_runtime_restart_preserves_shared_state_and_consumed_product_budget(tmp_path):
    path = tmp_path / "existing-runs.sqlite3"
    runs = RunStore(path)
    runtime = RuntimeStore(runs)
    ledger = UsageLedger(runs)
    ledger.set_limits("task", {"max_calls": 1})
    context = {"task_id": "task", "run_id": "run", "session_id": "session",
               "purpose": "worker", "provider": "ollama", "model": "fixture"}
    call = ledger.begin(context, invocation_id="existing-invocation")
    ledger.settle(call["id"], normalize_usage("openai", {"prompt_tokens": 10, "completion_tokens": 2}))
    runtime.save_worker("session", str(tmp_path), keep_running=True)
    event = runtime.append("session", {"type": "message", "request_id": "request", "text": "done"})
    runtime.enqueue("session", {"type": "user_message", "request_id": "pending", "text": "work"})
    runtime.command_state("pending", "sent")
    decision = runtime.decision("session", {"type": "permission_request", "request_id": "approval"})
    runtime.save_deployment({"id": "deployment", "session_id": "session", "workspace": str(tmp_path)})
    before = ledger.summary()
    with runs.runtime_connection(readonly=True) as db:
        schema = [tuple(row) for row in db.execute(
            "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")]

    reopened_runs = RunStore(path)
    reopened = RuntimeStore(reopened_runs)
    assert isinstance(reopened, PackageRuntimeStore)
    assert reopened.events("session") == [event]
    assert reopened.cursor("session") == event["runtime_seq"]
    assert reopened.worker("session")["keep_running"]
    assert reopened.decisions()[0]["fingerprint"] == decision["fingerprint"]
    assert reopened.deployments()[0]["id"] == "deployment"
    reopened.interrupted("session")
    assert reopened.commands("session") == []
    assert reopened.commands("session", "uncertain")[0]["id"] == "pending"
    assert UsageLedger(reopened_runs).summary() == before
    with pytest.raises(UsageLimitError, match="call"):
        UsageLedger(reopened_runs).begin(context)
    with reopened_runs.runtime_connection(readonly=True) as db:
        assert [tuple(row) for row in db.execute(
            "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")] == schema


def test_product_redaction_remains_effective_in_extracted_runtime_records(tmp_path):
    runtime = RuntimeStore(RunStore(tmp_path / "runs.sqlite3"))
    event = {"type": "permission_request", "request_id": "stable-request", "run_id": "stable-run",
             "api_key": "fixture-api-secret", "headers": {"Authorization": "fixture-header-secret"},
             "text": "Bearer fixture-bearer-secret", "prompt_tokens": 17}
    runtime.append("session", event)
    decision = runtime.decision("session", event)
    runtime.resolve(decision["id"], decision["fingerprint"], {"decision": "allow", "password": "fixture-response-secret"})
    with runtime.runs.runtime_connection(readonly=True) as db:
        persisted = json.dumps([tuple(row) for row in db.execute("SELECT payload,response FROM runtime_decisions")])
        persisted += json.dumps([tuple(row) for row in db.execute("SELECT payload FROM runtime_events")])
    for secret in ("fixture-api-secret", "fixture-header-secret", "fixture-bearer-secret", "fixture-response-secret"):
        assert secret not in persisted
    public = runtime.events("session")[0]
    assert public["request_id"] == "stable-request"
    assert public["run_id"] == "stable-run"
    assert public["prompt_tokens"] == 17
