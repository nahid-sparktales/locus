"""Service-owned schedules, workflow advancement and goal continuation."""
from __future__ import annotations

import asyncio
import time


class RuntimeAutomation:
    def __init__(self, runtime):
        self.runtime = runtime
        self.next_scan = 0.0
        self.polls = {}

    async def tick(self):
        runtime, now = self.runtime, time.time()
        if now < self.next_scan:
            return
        self.next_scan = now + 5
        runs = runtime.service.run_store
        from .api.event_triggers import delivery_dispatch
        from .api.schedules import _dispatch_schedule
        from .goals import GoalStore
        from .runtime_connectors import RuntimeConnectors

        for schedule in runs.schedules():
            if not schedule.get("enabled") or not schedule.get("next_run_at") or schedule["next_run_at"] > now:
                continue
            if runtime.controller_seen or runtime.store.automation_enabled("schedule", schedule["id"]):
                try:
                    result = await asyncio.to_thread(_dispatch_schedule, runtime.service, schedule["id"], trigger="due")
                    if result.get("run"):
                        await self.queue_run(result["run"], keep_running=runtime.store.automation_enabled("schedule", schedule["id"]))
                except Exception as exc:
                    runtime.store.append("runtime", {"type": "schedule_dispatch_error", "schedule_id": schedule["id"], "message": str(exc)[:500]})

        triggers = runs.event_triggers()
        for connection in runs.connector_connections():
            if not connection.get("enabled", True):
                continue
            allowed = runtime.controller_seen or any(
                trigger.get("connection_id") == connection["id"] and trigger.get("enabled")
                and runtime.store.automation_enabled("event", trigger["id"]) for trigger in triggers)
            previous = self.polls.get(connection["id"])
            if allowed and (not previous or previous.done()):
                if previous:
                    # Retrieve exceptions before replacing tasks.
                    previous.exception()
                self.polls[connection["id"]] = asyncio.create_task(RuntimeConnectors(runtime).poll(connection))

        for delivery in runs.pending_event_deliveries():
            keep = runtime.store.automation_enabled("event", delivery["trigger_id"])
            if runtime.controller_seen or keep:
                try:
                    result = await asyncio.to_thread(delivery_dispatch, delivery["id"], runtime.service)
                    if result.get("run"):
                        await self.queue_run(result["run"], keep_running=keep)
                except Exception as exc:
                    runtime.store.append("runtime", {"type": "event_dispatch_error", "delivery_id": delivery["id"], "message": str(exc)[:500]})

        goals = GoalStore(runs)
        for goal in goals.list(nonterminal=True):
            row = runtime.store.worker(goal["session_id"])
            keep = bool(row and row["keep_running"])
            if goal["status"] == "active" and (runtime.controller_seen or keep):
                claim = await asyncio.to_thread(goals.claim, goal["id"], goal["revision"])
                if claim.get("run"):
                    await self.queue_run(claim["run"], keep_running=keep)

        from .api.automation_workflows import (
            _queue_agent_action,
            _sync_origin,
            execution_complete_step,
        )
        for execution in runs.automation_executions(limit=100):
            keep = runtime.store.automation_enabled(execution["automation_kind"], execution["automation_id"])
            if not runtime.controller_seen and not keep:
                continue
            detail = runs.automation_execution(execution["id"])
            for attempt in (detail or {}).get("steps", (detail or {}).get("attempts", [])):
                run_id = attempt.get("run_id")
                run = runs.run(run_id) if run_id else None
                if run and attempt.get("state") in {"running", "dispatching"} and run["state"] in {"completed", "failed", "interrupted", "cancelled"}:
                    result = await asyncio.to_thread(execution_complete_step, execution["id"], runtime.service,
                                                    {"run_id": run_id, "result": self.workflow_result(run_id),
                                                     "error": "" if run["state"] == "completed" else "The agent step did not complete"})
                    if result.get("run"):
                        await self.queue_run(result["run"], keep_running=keep)
            if execution.get("state") in {"advancing", "awaiting_run"}:
                action = await asyncio.to_thread(runs.advance_automation_execution, execution["id"])
                result = _sync_origin(runtime.service, _queue_agent_action(runtime.service, action))
                if result.get("run"):
                    await self.queue_run(result["run"], keep_running=keep)

        # Runs queued through existing public APIs use the same admission queue.
        for run in runs.list_runs(limit=100):
            if run["state"] == "queued" and run.get("session_id"):
                row = runtime.store.worker(run["session_id"])
                keep = bool(row and row["keep_running"])
                if runtime.controller_seen or keep:
                    await self.queue_run(run, keep_running=keep)

    async def queue_run(self, run, *, keep_running=None):
        runtime = self.runtime
        session_id = run["session_id"]
        manifest = run.get("manifest") or {}
        workspace = run["workspace_root"]
        worker = await runtime.ensure_worker(session_id, workspace, keep_running=keep_running)
        saved = runtime.private.read()
        automation_configuration = saved.get(f"automation:schedule:{manifest.get('schedule_id', '')}") or saved.get(f"automation:event:{manifest.get('event_trigger_id', '')}") or {}
        if automation_configuration.get("agent_id"):
            from .sessions import SessionMeta
            SessionMeta.update(session_id, agent_profile_id=str(automation_configuration["agent_id"]))
        account = automation_configuration.get("provider") or saved.get(f"account:{manifest.get('provider_account_id', '')}")
        if automation_configuration.get("permissions") and not worker.active_command:
            await runtime.request(worker, "POST", "/api/permissions", automation_configuration["permissions"])
        if account and not worker.active_command:
            await runtime.request(worker, "POST", "/api/provider", account)
        command = {"type": "user_message", "text": run["request"], "mode": manifest.get("mode", "work"),
                   "run_id": run["id"], "request_id": run["id"]}
        for key in ("agent_config", "goal_id", "goal_revision", "workflow_outputs"):
            if key in manifest:
                command[key] = manifest[key]
        if run.get("run_kind") == "team":
            team = saved.get(f"team:{run.get('team_id', '')}")
            if not team:
                runtime.store.state(session_id, "waiting_for_locus")
                return
            command["team"] = {**team, "run_id": run["id"]}
        elif manifest.get("solo_swarm"):
            command["solo_swarm"] = {"enabled": True}
        runtime.enqueue(session_id, command)

    def workflow_result(self, run_id):
        with self.runtime.store.runs._connect(readonly=True) as db:
            row = db.execute("SELECT payload FROM runtime_events WHERE json_extract(payload,'$.run_id')=? AND json_extract(payload,'$.type')='turn_done' ORDER BY seq DESC LIMIT 1", (run_id,)).fetchone()
        if row:
            import json
            return json.loads(row[0]).get("workflow_result")
        return None

    async def close(self):
        for task in self.polls.values():
            task.cancel()
        await asyncio.gather(*self.polls.values(), return_exceptions=True)
