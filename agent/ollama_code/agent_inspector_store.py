"""Read projections for the contextual Agent inspector.

History is scoped in SQL, before pagination. Stable compound cursors keep
equal-time arrivals addressable, and aggregates describe retained history.
Execution links survive a delivery retry clearing its current run pointer.
"""
from __future__ import annotations

import base64
import json
import math
from typing import Any


class AgentInspectorStore:
    def agent_history_page(
        self, kind: str, agent_id: str, *, cursor: str = "", limit: int = 30
    ) -> dict[str, Any]:
        if kind not in {"event", "schedule"}:
            raise ValueError("unknown agent kind")
        table, owner, timestamp = (
            ("event_deliveries", "trigger_id", "received_at") if kind == "event"
            else ("schedule_occurrences", "schedule_id", "scheduled_for")
        )
        effective = self._inspector_effective_state_sql()
        joins = (
            " LEFT JOIN runs ON runs.id=items.run_id"
            " LEFT JOIN automation_executions workflow ON workflow.occurrence_id=items.id"
            f" AND workflow.automation_kind='{kind}'"
            " LEFT JOIN runs active_run ON active_run.id=workflow.current_run_id"
        )
        bounded = max(1, min(int(limit), 100))
        values: list[Any] = [agent_id]
        condition = ""
        if cursor:
            try:
                decoded = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
                if (not isinstance(decoded, list) or len(decoded) != 5
                        or decoded[:2] != [kind, agent_id]
                        or not isinstance(decoded[2], (float, int))
                        or not math.isfinite(decoded[2])
                        or not isinstance(decoded[3], (float, int))
                        or not math.isfinite(decoded[3])
                        or not isinstance(decoded[4], str)):
                    raise ValueError()
                condition = f" AND (items.{timestamp}, items.created_at, items.id) < (?, ?, ?)"
                values.extend(decoded[2:])
            except (ValueError, TypeError, UnicodeError) as exc:
                raise ValueError("invalid history cursor") from exc
        with self._lock, self._connect(readonly=True) as connection:
            connection.execute("BEGIN")
            counts = connection.execute(
                f"SELECT {effective} AS effective_state, COUNT(*) AS count FROM {table} items"
                + joins + f" WHERE items.{owner}=?"
                " GROUP BY effective_state", (agent_id,),
            ).fetchall()
            rows = connection.execute(
                f"SELECT items.*, {effective} AS effective_state, workflow.id AS workflow_execution_id FROM {table} items"
                + joins + f" WHERE items.{owner}=?" + condition
                + f" ORDER BY items.{timestamp} DESC, items.created_at DESC, items.id DESC LIMIT ?",
                (*values, bounded + 1),
            ).fetchall()
        has_more = len(rows) > bounded
        visible = rows[:bounded]
        items = []
        for row in visible:
            item = self._event_delivery_row(row) if kind == "event" else self._occurrence_row(row)
            item["state"] = row["effective_state"]
            if kind == "event":
                item["run_state"] = row["effective_state"]
            items.append(item)
        next_cursor = None
        if has_more and visible:
            row = visible[-1]
            next_cursor = base64.urlsafe_b64encode(json.dumps(
                [kind, agent_id, row[timestamp], row["created_at"], row["id"]]
            ).encode()).decode()
        by_state = {row["effective_state"]: row["count"] for row in counts}
        return {
            "deliveries" if kind == "event" else "occurrences": items,
            "total": sum(by_state.values()), "counts": by_state,
            "next_cursor": next_cursor,
            "workflow_execution_ids": {row["id"]: row["workflow_execution_id"] for row in visible
                                       if row["workflow_execution_id"] is not None},
        }

    @staticmethod
    def _inspector_effective_state_sql() -> str:
        return (
            "CASE WHEN workflow.state='awaiting_run' THEN COALESCE(active_run.state, 'running')"
            " WHEN workflow.state IS NOT NULL THEN workflow.state"
            " WHEN items.state='queued' AND runs.state IS NOT NULL"
            " THEN runs.state ELSE items.state END"
        )

    def inspector_item_context(self, kind: str, item_id: str) -> dict[str, Any]:
        table = "event_deliveries" if kind == "event" else "schedule_occurrences"
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                f"SELECT {self._inspector_effective_state_sql()} AS state,"
                " items.state AS delivery_state,"
                " CASE WHEN workflow.id IS NULL AND runs.id IS NULL THEN NULL ELSE "
                + self._inspector_effective_state_sql() + " END AS execution_state,"
                f" workflow.id AS workflow_execution_id FROM {table} items"
                " LEFT JOIN runs ON runs.id=items.run_id"
                " LEFT JOIN automation_executions workflow ON workflow.occurrence_id=items.id"
                " AND workflow.automation_kind=?"
                " LEFT JOIN runs active_run ON active_run.id=workflow.current_run_id WHERE items.id=?",
                (kind, item_id),
            ).fetchone()
        return dict(row) if row is not None else {}

    def schedule_occurrence(self, occurrence_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect(readonly=True) as connection:
            row = connection.execute(
                "SELECT occurrences.*, runs.state AS run_state FROM schedule_occurrences occurrences"
                " LEFT JOIN runs ON runs.id=occurrences.run_id WHERE occurrences.id=?",
                (occurrence_id,),
            ).fetchone()
        if row is None:
            return None
        result = self._occurrence_row(row)
        if result["state"] == "queued" and row["run_state"]:
            result["state"] = row["run_state"]
        return result

    def inspector_execution_links(self, kind: str, item_id: str) -> list[dict[str, Any]]:
        """Every retained attempt, including workflow steps and cleared retry pointers."""
        if kind not in {"event", "schedule"}:
            raise ValueError("unknown agent kind")
        with self._lock, self._connect(readonly=True) as connection:
            rows = connection.execute(
                "SELECT links.run_id, links.attempt, links.created_at, runs.state, runs.session_id, runs.retry_parent_id"
                " FROM agent_execution_links links LEFT JOIN runs ON runs.id=links.run_id"
                " WHERE links.kind=? AND links.item_id=? ORDER BY links.created_at, links.run_id",
                (kind, item_id),
            ).fetchall()
            workflow = connection.execute(
                "SELECT a.run_id, a.attempt, a.started_at AS created_at, r.state, r.session_id, r.retry_parent_id"
                " FROM automation_step_attempts a JOIN automation_executions e ON e.id=a.execution_id"
                " LEFT JOIN runs r ON r.id=a.run_id WHERE e.automation_kind=?"
                " AND e.occurrence_id=? AND a.run_id IS NOT NULL ORDER BY a.started_at, a.run_id",
                (kind, item_id),
            ).fetchall()
        by_id = {row["run_id"]: dict(row) for row in [*rows, *workflow]}
        return sorted(by_id.values(), key=lambda item: (item["created_at"] or 0, item["run_id"]))
