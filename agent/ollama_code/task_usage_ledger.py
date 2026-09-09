"""Idempotent whole-task accounting; absence of measurement is never zero cost."""
from __future__ import annotations

import json
import time
import uuid
from decimal import Decimal

from .task_state import encoded
from .usage_ledger import UsageLimitError


def initialize_schema(db):
    db.executescript("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS task_usage (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, run_id TEXT NOT NULL,
            stage TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL,
            started_at REAL NOT NULL, ended_at REAL
        );
        CREATE INDEX IF NOT EXISTS task_usage_task ON task_usage(task_id, started_at);
        CREATE TABLE IF NOT EXISTS task_limits (task_id TEXT PRIMARY KEY, amount TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS task_spans (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, run_id TEXT NOT NULL,
            kind TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL
        );
        UPDATE schema_meta SET version=19 WHERE singleton=1;
        COMMIT;
    """)


def _amount(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str, Decimal)):
        raise UsageLimitError("A cost must be a nonnegative finite number.")
    try:
        number = Decimal(str(value))
    except Exception as exc:
        raise UsageLimitError("A cost must be a nonnegative finite number.") from exc
    if not number.is_finite() or number < 0:
        raise UsageLimitError("A cost must be a nonnegative finite number.")
    return number


def response_usage(response):
    raw = (getattr(response, "provider_fields", {}) or {}).get("usage")
    if isinstance(raw, dict):
        return dict(raw)
    prompt, output = getattr(response, "prompt_eval_count", 0), getattr(response, "eval_count", 0)
    return {"input_tokens": prompt, "output_tokens": output} if prompt or output else {}


def cost_for(usage: dict, rates: dict) -> Decimal | None:
    if not usage:
        return None
    if not ({"input_tokens", "output_tokens"} <= usage.keys() or "tool_units" in usage or "image_units" in usage):
        return None
    if any((usage.get("server_tool_use") or {}).values()):
        return None  # Server-side tool charges have not been priced here.
    total = Decimal(0)
    # Adapters normalize cache reads/writes separately. Do not add reasoning
    # tokens to output: providers generally include them in output totals.
    for category in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                     "cache_creation_5m_input_tokens", "cache_creation_1h_input_tokens",
                     "cache_creation_input_tokens", "tool_units", "image_units"):
        count = usage.get(category)
        if count is None:
            continue
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise UsageLimitError("Provider usage contains an invalid count.")
        if count:
            rate = rates.get(category)
            if rate is None:
                return None
            total += Decimal(count) * _amount(rate) / Decimal(1_000_000)
    return total


class UsageLedger:
    def __init__(self, journal):
        self.journal, self.runs = journal, journal.runs

    def set_limit(self, amount):
        with self.runs._connect() as db:
            if amount is None:
                db.execute("DELETE FROM task_limits WHERE task_id=?", (self.journal.task_id,))
            else:
                db.execute("INSERT INTO task_limits VALUES(?,?) ON CONFLICT(task_id) DO UPDATE SET amount=excluded.amount",
                           (self.journal.task_id, str(_amount(amount))))

    def reserve(self, *, provider: str, model: str, stage: str, rates: dict | None = None,
                upper_bound=None, metering: str | None = None, identifier: str = "",
                max_calls_per_run: int | None = None, deadline: float | None = None):
        category = metering or ("subscription" if provider == "chatgpt" else "local" if provider == "ollama" else "metered")
        if category not in {"subscription", "local", "metered"}:
            raise UsageLimitError("The operation's metering class is unavailable.")
        if rates is not None and not isinstance(rates, dict):
            raise UsageLimitError("Pricing must contain category rates and provenance.")
        identifier = identifier or uuid.uuid4().hex
        payload = {"provider": provider, "model": model, "metering": category,
                   "rates": rates or {}, "reservation": str(_amount(upper_bound)) if upper_bound is not None else None,
                   "cost": None, "usage": {}, "pricing_source": (rates or {}).get("source", "configured per-million rates"),
                   "pricing_recorded_at": time.time(), "currency": "USD"}
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute("SELECT task_id,stage,payload,run_id FROM task_usage WHERE id=?", (identifier,)).fetchone()
            if existing:
                original = json.loads(existing[2])
                if existing[0] != self.journal.task_id or existing[1] != stage or existing[3] != self.journal.run_id or any(original.get(k) != payload[k] for k in ("provider", "model", "rates", "reservation", "metering")):
                    raise UsageLimitError("Usage identity belongs to another request.")
                return identifier
            if deadline is not None and time.time() >= deadline:
                raise UsageLimitError("This scenario has no remaining time allowance.")
            if max_calls_per_run is not None and db.execute("SELECT COUNT(*) FROM task_usage WHERE task_id=? AND run_id=?",
                    (self.journal.task_id, self.journal.run_id)).fetchone()[0] >= max_calls_per_run:
                raise UsageLimitError("This scenario has no remaining call allowance.")
            limit = db.execute("SELECT amount FROM task_limits WHERE task_id=?", (self.journal.task_id,)).fetchone()
            if limit and category == "metered":
                prior = [json.loads(r[0]) for r in db.execute("SELECT payload FROM task_usage WHERE task_id=?", (self.journal.task_id,))]
                if upper_bound is None or any(p["metering"] == "metered" and p.get("cost") is None for p in prior):
                    raise UsageLimitError("The task estimate limit needs priced operations and reconciled prior usage.")
                consumed = sum((_amount(p["cost"]) for p in prior if p.get("cost") is not None), Decimal(0))
                if consumed + _amount(upper_bound) > _amount(limit[0]):
                    raise UsageLimitError("The cumulative task estimate limit would be exceeded.")
            db.execute("INSERT INTO task_usage VALUES(?,?,?,?,'pending',?,?,NULL)",
                       (identifier, self.journal.task_id, self.journal.run_id, stage, encoded(payload), time.time()))
        return identifier

    def settle(self, identifier: str, usage: dict, *, model_calls: int | None = 1, reported_cost=None):
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM task_usage WHERE id=? AND task_id=?", (identifier, self.journal.task_id)).fetchone()
            if not row:
                raise UsageLimitError("Usage was not reserved for this task.")
            payload = json.loads(row["payload"])
            reported = str(_amount(reported_cost).normalize()) if reported_cost is not None else None
            if row["state"] != "pending":
                if payload.get("usage") != usage or payload.get("model_calls") != model_calls or payload.get("reported_cost") != reported:
                    raise UsageLimitError("Settled usage cannot be overwritten; reconcile it explicitly.")
                return
            amount = _amount(reported_cost) if reported_cost is not None else cost_for(usage, payload["rates"]) if payload["metering"] == "metered" else None
            payload.update(usage=usage, cost=str(amount) if amount is not None else None, model_calls=model_calls, reported_cost=reported)
            db.execute("UPDATE task_usage SET state='settled',payload=?,ended_at=? WHERE id=?", (encoded(payload), time.time(), identifier))

    def reconcile(self, identifier: str, *, amount, note: str):
        if not isinstance(note, str) or not note.strip():
            raise UsageLimitError("Record the evidence used to reconcile interrupted usage.")
        with self.runs._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM task_usage WHERE id=? AND task_id=?", (identifier, self.journal.task_id)).fetchone()
            if not row:
                raise UsageLimitError("Usage entry not found.")
            payload = json.loads(row[0])
            value = _amount(amount)
            if payload.get("cost") is not None and value < _amount(payload["cost"]):
                raise UsageLimitError("Reconciliation cannot reduce recorded spend.")
            payload.update(cost=str(value), reconciliation=note.strip()[:8000], reconciled_at=time.time())
            # Reconciliation is not the end of provider execution. Preserve an
            # observed end, or leave it unknown after an interrupted dispatch.
            db.execute("UPDATE task_usage SET state='reconciled',payload=? WHERE id=?", (encoded(payload), identifier))

    def span(self, identifier: str, kind: str, *, finish=False):
        with self.runs._connect() as db:
            if finish:
                db.execute("UPDATE task_spans SET ended_at=COALESCE(ended_at,?) WHERE id=? AND task_id=?", (time.time(), identifier, self.journal.task_id))
            else:
                db.execute("INSERT OR IGNORE INTO task_spans VALUES(?,?,?,?,?,NULL)", (identifier, self.journal.task_id, self.journal.run_id, kind, time.time()))

    def summary(self):
        with self.runs._connect(readonly=True) as db:
            entries = [{"id": r["id"], "stage": r["stage"], "state": r["state"],
                        "started_at": r["started_at"], "ended_at": r["ended_at"], **json.loads(r["payload"])}
                       for r in db.execute("SELECT * FROM task_usage WHERE task_id=? ORDER BY started_at", (self.journal.task_id,))]
            spans = [dict(r) for r in db.execute("SELECT * FROM task_spans WHERE task_id=? ORDER BY started_at", (self.journal.task_id,))]
            limit = db.execute("SELECT amount FROM task_limits WHERE task_id=?", (self.journal.task_id,)).fetchone()
        known = [e for e in entries if e.get("cost") is not None]
        unknown = [e for e in entries if e["metering"] == "metered" and e.get("cost") is None]
        spans.extend({"id": e["id"], "kind": "tool" if e["stage"] in {"images", "tools"} else "model", "stage": e["stage"], "started_at": e["started_at"], "ended_at": e["ended_at"]} for e in entries)
        with self.runs._connect(readonly=True) as db:
            acceptance = db.execute("SELECT MAX(created_at) FROM task_observations WHERE task_id=? AND kind='accepted'", (self.journal.task_id,)).fetchone()[0]
            latest_run = db.execute("SELECT MAX(r.created_at) FROM runs r JOIN task_links l ON l.owner='run:'||r.id WHERE l.task_id=?", (self.journal.task_id,)).fetchone()[0]
            started = db.execute("SELECT MIN(r.created_at) FROM runs r JOIN task_links l ON l.owner='run:'||r.id WHERE l.task_id=?", (self.journal.task_id,)).fetchone()[0]
            goal_accepted = db.execute("SELECT MAX(g.updated_at) FROM goals g JOIN task_links l ON l.owner='session:'||g.session_id WHERE l.task_id=? AND g.status='completed'", (self.journal.task_id,)).fetchone()[0]
            capsule_accepted = db.execute("SELECT MAX(c.updated_at) FROM capsule_attempts c JOIN task_links l ON l.owner='capsule:'||c.capsule_id WHERE l.task_id=? AND json_extract(c.payload,'$.state')='completed'", (self.journal.task_id,)).fetchone()[0]
        acceptance = max((v for v in (acceptance, goal_accepted, capsule_accepted) if v), default=None)
        if acceptance and latest_run and acceptance < latest_run:
            acceptance = None
        return {"known_subtotal": float(sum((_amount(e["cost"]) for e in known), Decimal(0))),
                "known_subtotal_decimal": str(sum((_amount(e["cost"]) for e in known), Decimal(0))),
                "coverage": "partial" if unknown or any(e["state"] == "pending" for e in entries) else "complete" if entries else "unknown",
                "unknown_entries": len(unknown), "pending_entries": sum(e["state"] == "pending" for e in entries),
                "subscription_entries": sum(e["metering"] == "subscription" for e in entries),
                "local_entries": sum(e["metering"] == "local" for e in entries),
                "usage_coverage": "complete" if entries and all(e["usage"] for e in entries) else "partial" if entries else "unknown",
                "elapsed_seconds": max((acceptance or time.time()) - started, 0) if started else None,
                "accepted_at": acceptance,
                "limit": float(limit[0]) if limit else None, "entries": entries, "spans": spans}


def request_bound(client, rates, input_bound, output_bound):
    if not isinstance(output_bound, int) or output_bound <= 0:
        return None
    reservation_rates = dict(rates)
    if getattr(client, "auth_style", "") == "anthropic":
        candidates = [rates.get(k) for k in ("input_tokens", "cache_creation_5m_input_tokens", "cache_creation_1h_input_tokens")]
        reservation_rates["input_tokens"] = max(_amount(v) for v in candidates) if all(v is not None for v in candidates) else None
    return cost_for({"input_tokens": input_bound, "output_tokens": output_bound}, reservation_rates)


def reserve_core(core, *, stage=None, messages=None):
    journal = getattr(core, "task_journal", None)
    if journal is None or core.identity_mode:
        return None
    from .pricing import estimate_rates
    configured = core.config.get("usage_rates") or {}
    rates = estimate_rates(core.model, core.client, configured if any(v is not None for k, v in configured.items() if k.endswith("tokens")) else None)
    stage = stage or getattr(core, "task_usage_stage", None) or ("planning" if core.agent_mode in {"plan", "grill"} else "execution")
    # Reserve a conservative UTF-8 input bound and the actual requested output
    # bound; absent output/rate information must remain unenforceable.
    maximum = (core.chat_options() or {}).get("num_predict")
    bound = None
    if isinstance(maximum, int) and maximum > 0 and messages is not None:
        bound = request_bound(core.client, rates, len(encoded([messages, core.tool_registry.schemas()]).encode()) + 4096, maximum)
    ledger = UsageLedger(journal)
    return ledger, ledger.reserve(provider=core.provider, model=core.model, stage=stage, rates=rates, upper_bound=bound)


def settle_core(reservation, response):
    if reservation:
        ledger, identifier = reservation
        ledger.settle(identifier, response_usage(response))


def native_accounted(core, call, kwargs, *, baseline=(0, 0), stage=None):
    reservation = reserve_core(core, stage=stage)
    if not reservation:
        return call(**kwargs)
    ledger, identifier = reservation
    original = kwargs.get("event_handler")
    highest = list(baseline)
    origin = list(baseline)
    observed = False

    def observe(event):
        nonlocal observed
        if event.get("method") == "thread/tokenUsage/updated":
            total = ((event.get("params") or {}).get("tokenUsage") or {}).get("total") or {}
            if "inputTokens" in total and "outputTokens" in total:
                values = [max(int(total[k]), 0) for k in ("inputTokens", "outputTokens")]
                if not observed and any(values[i] < origin[i] for i in range(2)):
                    origin[:] = [0, 0]
                    highest[:] = [0, 0]
                highest[:] = [max(highest[i], values[i]) for i in range(2)]
                observed = True
        if original:
            original(event)
    result = call(**{**kwargs, "event_handler": observe})
    usage = {"input_tokens": highest[0] - origin[0], "output_tokens": highest[1] - origin[1]} if observed else {}
    ledger.settle(identifier, usage, model_calls=None)
    return result
