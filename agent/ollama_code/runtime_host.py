"""Trusted Locus composition for the independent execution package.

Product bootstrap, provider environment, continuation/connector policy and
worker command selection stay here. Process and transport mechanics have one
implementation in locus_runtime.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from locus_runtime.contracts import WorkerLaunch, WorkerLaunchRequest, WorkerRequest
from locus_runtime.supervisor import RuntimeSupervisor as ExecutionSupervisor

from .capabilities import enabled as capability_enabled
from .runtime_store import PrivateStore, RuntimeStore, identifier

CONFIG_PATHS = frozenset({"/api/provider", "/api/permissions", "/api/config", "/api/images/provider"})


class LocusWorkerDriver:
    def prepare(self, request: WorkerLaunchRequest) -> WorkerLaunch:
        environment = dict(os.environ)
        environment.update(LOCUS_PARENT_PID=str(request.parent_pid), LOCUS_AGENT_TOKEN=request.token,
                           LOCUS_RUNTIME_CHILD="1", LOCUS_DOCUMENT_COORDINATOR="0",
                           LOCUS_RUNTIME_PROFILE_ROOT=str(request.root),
                           LOCUS_CODEX_BROKER_URL=f"ws://127.0.0.1:{request.broker_port}/ws/internal/codex",
                           LOCUS_CODEX_BROKER_TOKEN=request.broker_token)
        environment.pop("LOCUS_RUNTIME_HOME", None)
        return WorkerLaunch(
            argv=(sys.executable, "-m", "ollama_code.server", "--host", "127.0.0.1",
                  "--port", str(request.port), "--cwd", request.workspace),
            environment=environment, headers={"X-Locus-Token": request.token},
            health_path="/api/health", websocket_path="/ws/chat",
            resume=WorkerRequest("POST", f"/api/sessions/{request.session_id}/resume", {}),
            configuration_paths=CONFIG_PATHS)

    def command_request(self, command: dict) -> WorkerRequest | None:
        if command.get("type") == "set_model":
            return WorkerRequest("POST", "/api/config", {"model": command.get("model")})
        if command.get("type") == "evaluation_run":
            return WorkerRequest("POST", f"/api/evaluations/{identifier(command['suite_id'])}/run", command["body"])
        return None


class LocusConnectorBroker:
    def __init__(self, runtime):
        self.runtime = runtime

    def capabilities(self) -> list[dict]:
        saved = self.runtime.private.read()
        return [{"id": row["id"], "kind": row["kind"]}
                for row in self.runtime.service.run_store.connector_connections()
                if row.get("enabled", True) and saved.get(f"connector:{row['id']}")]

    async def action(self, event: dict) -> dict:
        from .runtime_connectors import RuntimeConnectors
        return await RuntimeConnectors(self.runtime).action(event)


class RuntimeSupervisor(ExecutionSupervisor):
    """Compatibility composition used by product routes and continuation policy."""
    def __init__(self, app, root: Path, *, port: int, limit: int = 2):
        from .runtime_automation import RuntimeAutomation
        from .runtime_providers import RuntimeProviders
        from .runtime_remote import RemoteRuntimes
        from .usage_ledger import UsageLedger

        self.app = app
        self.service = app.state.service
        super().__init__(root, store=RuntimeStore(self.service.run_store), private=PrivateStore(root),
                         driver=LocusWorkerDriver(), port=port, limit=limit,
                         recover=lambda: UsageLedger(self.service.run_store).recover(),
                         event_sink=self._product_event,
                         capabilities={"background_schedules": True, "remote_chatgpt": True,
                                       "remote_claude_plan": capability_enabled("claude_plan_v1")},
                         package_id=os.environ.get("LOCUS_RUNTIME_PACKAGE_ID", str(Path(__file__).resolve().parents[1])))
        self.remotes = RemoteRuntimes(self)
        self.providers = RuntimeProviders(self)
        self.automation = RuntimeAutomation(self)
        self.connectors = LocusConnectorBroker(self)

    def _product_event(self, event: dict) -> None:
        if str(event.get("type")).startswith("evaluation_"):
            self.service.emit(event)


def main(argv: list[str] | None = None) -> None:
    import argparse

    import uvicorn

    from . import server
    parser = argparse.ArgumentParser(description="Independent Locus agent runtime")
    parser.add_argument("--home", required=True)
    parser.add_argument("--port", type=int, default=8793)
    parser.add_argument("--cwd", default=os.getcwd())
    args = parser.parse_args(argv)
    root = Path(args.home).expanduser().resolve()
    private = PrivateStore(root)
    import fcntl
    ownership = (root / "supervisor.lock").open("a")
    try:
        fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("This runtime already has a supervisor") from None
    os.environ["LOCUS_RUNTIME_COORDINATOR"] = "1"
    os.environ["LOCUS_RUNTIME_PROFILE_ROOT"] = str(root)
    os.environ.pop("LOCUS_PARENT_PID", None)
    app = server.create_app()
    app.state.auth_token = private.token()
    app.state.service = server.build_service(cwd=args.cwd)
    app.state.runtime = RuntimeSupervisor(app, root, port=args.port)
    descriptor = root / "endpoint.json"
    descriptor.write_text(json.dumps({"id": app.state.runtime.runtime_id, "url": f"http://127.0.0.1:{args.port}", "version": 1}))
    os.chmod(descriptor, 0o600)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning", timeout_graceful_shutdown=8)
