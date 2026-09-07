"""Durable optional questions, independent of the executing model's tool call.

The store is the resolution authority. A client renders its clock and drafts;
it never chooses a default itself. No worker or timer thread is owned here:
the attached transport and model boundaries call ``tick``.
"""
from __future__ import annotations

import copy
import json
import re
import sqlite3
import threading
import time
import uuid
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from . import paths

QUESTION_VERSION = 1
QUESTION_TIMEOUT_MS = 60_000
EDITING_LEASE_MS = 15_000
OPEN_STATUSES = {"pending", "suspended"}
_SECRET_QUESTION = re.compile(
    r"password|passwd|credential|api[\s_-]*key|private[\s_-]*key|seed[\s_-]*phrase"
    r"|card[\s_-]*number|cvv|social[\s_-]*security", re.IGNORECASE,
)


class QuestionError(ValueError):
    """A stale or invalid question action, safe to show to the client."""


def _text(value: Any, limit: int, *, required: bool = False) -> str:
    if not isinstance(value, str):
        value = ""
    value = value.strip()
    if len(value) > limit or (required and not value):
        raise QuestionError("Question text is missing or too long.")
    return value


def normalize_questions(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw = payload.get("questions")
    if not isinstance(raw, list) or not 1 <= len(raw) <= 3:
        raise QuestionError("Ask one to three optional questions in a batch.")
    result = []
    question_ids: set[str] = set()
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise QuestionError("Each question must be an object.")
        body = _text(item.get("question"), 1_000, required=True)
        if _SECRET_QUESTION.search(body):
            raise QuestionError("Never ask for credentials or payment details in a question.")
        identifier = _text(item.get("id") or f"q{index + 1}", 80, required=True)
        if identifier in question_ids:
            raise QuestionError("Question identifiers must be unique.")
        question_ids.add(identifier)
        options = []
        labels: set[str] = set()
        option_ids: set[str] = set()
        raw_options = item.get("options", [])
        if not isinstance(raw_options, list) or len(raw_options) > 4 or len(raw_options) == 1:
            raise QuestionError("Provide two to four options, or a free-text question.")
        for offset, option in enumerate(raw_options):
            if not isinstance(option, dict):
                raise QuestionError("Each option must be an object.")
            label = _text(option.get("label"), 80, required=True)
            option_id = _text(option.get("id") or f"o{offset + 1}", 80, required=True)
            if label.casefold() in labels or option_id in option_ids:
                raise QuestionError("Option identifiers and labels must be unique.")
            labels.add(label.casefold())
            option_ids.add(option_id)
            options.append({"id": option_id, "label": label,
                            "description": _text(option.get("description"), 240)})
        recommended = item.get("recommended_option_ids", [])
        if not isinstance(recommended, list) or any(not isinstance(v, str) for v in recommended):
            raise QuestionError("Recommended options must use option identifiers.")
        # The public tool schema uses a recommendation label (or a text default
        # for a free-text question). Freeze that into stable option identifiers
        # so every provider and client displays exactly the same default.
        recommendation = _text(item.get("recommendation", item.get("recommended")), 4_000)
        if not recommended and recommendation and options:
            recommended = [o["id"] for o in options if o["label"] == recommendation]
            if not recommended:
                raise QuestionError("The recommendation must match a displayed choice label.")
        recommended = list(dict.fromkeys(recommended))
        multi = item.get("multi_select") is True and len(options) > 1
        recommended_text = _text(item.get("recommended_text"), 4_000)
        if not options and not recommended_text:
            recommended_text = recommendation
        if any(value not in option_ids for value in recommended) \
                or (not multi and len(recommended) > 1):
            raise QuestionError("The recommendation must match the displayed choices.")
        if not recommended and not recommended_text:
            raise QuestionError("Every optional question needs an explicit displayed recommendation.")
        result.append({"id": identifier, "header": _text(item.get("header"), 24),
                       "question": body, "multi_select": multi, "options": options,
                       "recommended_option_ids": recommended,
                       "recommended_text": recommended_text, "answer": None})
    return result


class QuestionService:
    def __init__(
        self, path: Path | None = None, *, owner_id: str | None = None,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] | None = None,
    ) -> None:
        self.path = path or paths.APP_DIR / "questions.sqlite3"
        self.owner_id = owner_id or uuid.uuid4().hex
        self.clock = clock
        self.monotonic = monotonic or (time.monotonic if clock is time.time else clock)
        self._guard = threading.RLock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS questions (
                    request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                    status TEXT NOT NULL, updated_at REAL NOT NULL, payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS questions_session ON questions(session_id, status);
                CREATE UNIQUE INDEX IF NOT EXISTS one_open_question ON questions(session_id)
                    WHERE status IN ('pending', 'suspended');
                CREATE TABLE IF NOT EXISTS question_deliveries (
                    delivery_id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
                    session_id TEXT NOT NULL, status TEXT NOT NULL, payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS question_responses (
                    request_id TEXT NOT NULL, response_id TEXT NOT NULL, payload TEXT NOT NULL,
                    PRIMARY KEY(request_id, response_id)
                );
            """)
        self.path.chmod(0o600)

    @contextmanager
    def _db(self) -> Iterator[sqlite3.Connection]:
        with self._guard:
            db = sqlite3.connect(self.path, timeout=10)
            db.row_factory = sqlite3.Row
            try:
                db.execute("PRAGMA busy_timeout=10000")
                db.execute("BEGIN IMMEDIATE")
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise
            finally:
                db.close()

    def _load(self, db: sqlite3.Connection, request_id: str, session_id: str) -> dict[str, Any]:
        row = db.execute("SELECT payload FROM questions WHERE request_id=? AND session_id=?",
                         (request_id, session_id)).fetchone()
        if row is None:
            raise QuestionError("That question does not belong to this chat.")
        return json.loads(row[0])

    def _save(self, db: sqlite3.Connection, request: dict[str, Any]) -> None:
        db.execute("""INSERT INTO questions VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET status=excluded.status,
            updated_at=excluded.updated_at, payload=excluded.payload""",
                   (request["request_id"], request["session_id"], request["status"],
                    request["updated_at"], json.dumps(request, ensure_ascii=False)))

    def _accrue(self, request: dict[str, Any]) -> None:
        now = self.monotonic()
        if request["status"] != "pending" or request["owner_id"] != self.owner_id:
            return
        previous = request.get("clock_tick", now)
        request["clock_tick"] = now
        elapsed = max(0.0, (now - previous) * 1_000)
        leases = request["editing_leases"]
        paused_for = max(leases.values(), default=0.0)
        request["remaining_ms"] = round(max(
            0.0, request["remaining_ms"] - max(0.0, elapsed - paused_for)
        ), 3)
        request["editing_leases"] = {
            client: ttl - elapsed for client, ttl in leases.items() if ttl > elapsed
        }
        request["updated_at"] = self.clock()

    def _public(self, request: dict[str, Any]) -> dict[str, Any]:
        result = copy.deepcopy(request)
        result.pop("owner_id", None)
        result.pop("clock_tick", None)
        result["paused"] = bool(result.pop("editing_leases", {})) or result["status"] == "suspended"
        result["deadline_at"] = (
            self.clock() + result["remaining_ms"] / 1_000
            if result["status"] == "pending" and not result["paused"] else None
        )
        return result

    def create(self, session_id: str, run_id: str, tool_id: str,
               payload: dict[str, Any]) -> dict[str, Any]:
        questions = normalize_questions(payload)
        if not session_id:
            raise QuestionError("Optional questions require a root chat.")
        now = self.clock()
        request = {"request_id": uuid.uuid4().hex, "session_id": session_id,
                   "run_id": run_id, "tool_id": tool_id, "status": "pending", "revision": 1,
                   "questions": questions, "remaining_ms": float(QUESTION_TIMEOUT_MS),
                   "created_at": now, "updated_at": now, "owner_id": self.owner_id,
                   "clock_tick": self.monotonic(),
                   "editing_leases": {}, "delivery_id": None,
                   "delivery_status": None, "applied_at": None}
        with self._db() as db:
            if db.execute("SELECT 1 FROM questions WHERE session_id=? AND status IN ('pending','suspended')",
                          (session_id,)).fetchone():
                raise QuestionError("This chat already has a pending question batch. Continue independent work.")
            self._save(db, request)
        return self._public(request)

    def supersede(self, session_id: str, request_id: str, reason: str) -> dict[str, Any]:
        """Withdraw an irrelevant open batch without inventing any answers."""
        reason = _text(reason, 1_000, required=True)
        with self._db() as db:
            request = self._load(db, request_id, session_id)
            if request["status"] == "superseded":
                return self._public(request)
            if request["status"] not in OPEN_STATUSES:
                raise QuestionError("That question already has an outcome and cannot be superseded.")
            request.update(status="superseded", superseded_reason=reason,
                           editing_leases={}, updated_at=self.clock(),
                           revision=request["revision"] + 1)
            self._save(db, request)
        return self._public(request)

    @staticmethod
    def _answer(question: dict[str, Any], raw: dict[str, Any], source: str) -> dict[str, Any]:
        selected = raw.get("selected", [])
        if not isinstance(selected, list) or any(not isinstance(v, str) for v in selected) or len(selected) > 4:
            raise QuestionError("Selected answers must be a list of displayed choices.")
        choices = {o["id"]: o for o in question["options"]}
        by_label = {o["label"]: o["id"] for o in question["options"]}
        ids = list(dict.fromkeys(value if value in choices else by_label.get(value, "") for value in selected))
        if any(value not in choices for value in ids) or (not question["multi_select"] and len(ids) > 1):
            raise QuestionError("Choose only the displayed options allowed by this question.")
        text = _text(raw.get("text", ""), 4_000)
        if not ids and not text:
            raise QuestionError("Choose an answer, type one, or use Skip.")
        return {"id": question["id"], "selected": [choices[value]["label"] for value in ids],
                "selected_option_ids": ids, "text": text, "source": source}

    def _resolve(self, db: sqlite3.Connection, request: dict[str, Any], source: str) -> None:
        for question in request["questions"]:
            if question["answer"] is None:
                question["answer"] = self._answer(question, {
                    "selected": question["recommended_option_ids"], "text": question["recommended_text"],
                }, source)
        status = {"user": "answered", "skip": "skipped", "timeout": "defaulted"}[source]
        request.update(status=status, editing_leases={}, updated_at=self.clock(),
                       revision=request["revision"] + 1)
        delivery_id = f"question:{request['request_id']}"
        request.update(delivery_id=delivery_id, delivery_status="accepted")
        text = [f"Locus optional-question outcome (request {request['request_id']}; source={source})."]
        for question in request["questions"]:
            answer = question["answer"]
            text.append(f"Q: {question['question']}")
            rendered = "; ".join(answer["selected"] + ([answer["text"]] if answer["text"] else []))
            if answer["source"] == "user":
                text.append(f"User answer: {rendered}")
            else:
                text.append(f"Displayed recommendation applied ({answer['source']}): {rendered}. No user answer or approval was received for this question.")
        text.append("Continue the existing task using these decisions. This outcome does not grant tool permissions or approval for external actions.")
        delivery = {"delivery_id": delivery_id, "request_id": request["request_id"],
                    "session_id": request["session_id"], "run_id": request["run_id"],
                    "source": source, "text": "\n".join(text), "status": "accepted",
                    "accepted_at": self.clock(), "applied_at": None}
        db.execute("INSERT INTO question_deliveries VALUES (?, ?, ?, ?, ?)",
                   (delivery_id, request["request_id"], request["session_id"], "accepted",
                    json.dumps(delivery, ensure_ascii=False)))

    def _expire(self, db: sqlite3.Connection, request: dict[str, Any]) -> None:
        if request["status"] == "pending" and request["owner_id"] == self.owner_id \
                and request["remaining_ms"] <= 0:
            self._resolve(db, request, "timeout")

    def respond(self, session_id: str, request_id: str, action: str,
                answers: Any = None, *, response_id: str = "", revision: int | None = None) -> dict[str, Any]:
        response_id = _text(response_id or uuid.uuid4().hex, 160, required=True)
        with self._db() as db:
            old = db.execute("SELECT payload FROM question_responses WHERE request_id=? AND response_id=?",
                             (request_id, response_id)).fetchone()
            if old is not None:
                # Authenticate session ownership before replaying an idempotent acknowledgement.
                request = self._load(db, request_id, session_id)
                self._accrue(request)
                self._expire(db, request)
                self._save(db, request)
                # Acceptance belongs to the original response, while the card
                # may since have defaulted, been applied, or changed its clock.
                return {**json.loads(old[0]), "request": self._public(request)}
            request = self._load(db, request_id, session_id)
            self._accrue(request)
            self._expire(db, request)
            error = None
            if request["status"] != "pending":
                error = "That question is no longer accepting answers. Send your text as a follow-up."
            elif request["owner_id"] != self.owner_id:
                error = "That question belongs to an earlier runtime. Resume it before answering."
            elif revision is not None and revision != request["revision"]:
                error = "The question changed on another device. Review the current choices."
            if error is None:
                if action not in {"answer", "skip"}:
                    raise QuestionError("Choose Answer or Skip.")
                if action == "skip" and answers:
                    raise QuestionError("Submit partial answers before skipping the remaining questions.")
                if action == "answer":
                    if not isinstance(answers, list) or not 1 <= len(answers) <= len(request["questions"]):
                        raise QuestionError("Provide one or more question answers.")
                    by_id = {q["id"]: q for q in request["questions"]}
                    normalized = {}
                    for raw in answers:
                        if not isinstance(raw, dict) or raw.get("id") not in by_id or raw["id"] in normalized:
                            raise QuestionError("Answer identifiers must identify distinct questions in this batch.")
                        if by_id[raw["id"]]["answer"] is not None:
                            raise QuestionError("That question was already answered. Send changes as a follow-up.")
                        normalized[raw["id"]] = self._answer(by_id[raw["id"]], raw, "user")
                    for identifier, answer in normalized.items():
                        by_id[identifier]["answer"] = answer
                    request["revision"] += 1
                if action == "skip" or all(q["answer"] is not None for q in request["questions"]):
                    self._resolve(db, request, "skip" if action == "skip" else "user")
            request["updated_at"] = self.clock()
            self._save(db, request)
            result = {"request_id": request_id, "response_id": response_id,
                      "accepted": error is None, "request": self._public(request)}
            if error:
                result["error"] = error
            db.execute("INSERT INTO question_responses VALUES (?, ?, ?)",
                       (request_id, response_id, json.dumps(result, ensure_ascii=False)))
        return result

    def editing(self, session_id: str, request_id: str, editor_id: str, active: bool) -> dict[str, Any]:
        editor_id = _text(editor_id, 160, required=True)
        with self._db() as db:
            request = self._load(db, request_id, session_id)
            self._accrue(request)
            self._expire(db, request)
            if request["status"] == "pending" and request["owner_id"] == self.owner_id:
                if active:
                    if editor_id not in request["editing_leases"] and len(request["editing_leases"]) >= 16:
                        raise QuestionError("Too many editors are answering this question.")
                    request["editing_leases"][editor_id] = float(EDITING_LEASE_MS)
                else:
                    request["editing_leases"].pop(editor_id, None)
            self._save(db, request)
        return self._public(request)

    def tick(self, session_id: str) -> list[dict[str, Any]]:
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? AND status='pending'",
                              (session_id,)).fetchall()
            for row in rows:
                request = json.loads(row[0])
                self._accrue(request)
                self._expire(db, request)
                self._save(db, request)
        return self.snapshot(session_id)

    def pending_session_ids(self) -> list[str]:
        """Live clocks owned by this service, including a temporarily hidden chat."""
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE status='pending'").fetchall()
            return list(dict.fromkeys(request["session_id"] for row in rows
                                      if (request := json.loads(row[0]))["owner_id"] == self.owner_id))

    def release_editing(self, session_id: str) -> None:
        """A disconnected surface stops pausing time; its root keeps working."""
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? AND status='pending'",
                              (session_id,)).fetchall()
            for row in rows:
                request = json.loads(row[0])
                if request["owner_id"] != self.owner_id:
                    continue
                self._accrue(request)
                request["editing_leases"] = {}
                self._expire(db, request)
                self._save(db, request)

    def snapshot(self, session_id: str) -> list[dict[str, Any]]:
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? ORDER BY updated_at DESC LIMIT 12",
                              (session_id,)).fetchall()
            return [self._public(json.loads(row[0])) for row in rows]

    def recover_session(self, session_id: str) -> None:
        """Suspend another process's clock; elapsed downtime is never consent."""
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? AND status IN ('pending','suspended')",
                              (session_id,)).fetchall()
            for row in rows:
                request = json.loads(row[0])
                if request["owner_id"] == self.owner_id:
                    continue
                request.update(status="suspended", owner_id=self.owner_id, editing_leases={},
                               updated_at=self.clock(), revision=request["revision"] + 1)
                request["clock_tick"] = self.monotonic()
                self._save(db, request)

    def stop(self, session_id: str, *, suspend: bool = False) -> None:
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? AND status IN ('pending','suspended')",
                              (session_id,)).fetchall()
            for row in rows:
                request = json.loads(row[0])
                self._accrue(request)
                request.update(status="suspended" if suspend else "cancelled", editing_leases={},
                               revision=request["revision"] + 1, updated_at=self.clock())
                self._save(db, request)
            # Accepted but unapplied decisions cannot restart a stopped run.
            if not suspend:
                for row in db.execute("SELECT payload FROM question_deliveries WHERE session_id=? AND status='accepted'",
                                      (session_id,)).fetchall():
                    delivery = json.loads(row[0])
                    delivery["status"] = "cancelled"
                    db.execute("UPDATE question_deliveries SET status='cancelled',payload=? WHERE delivery_id=?",
                               (json.dumps(delivery), delivery["delivery_id"]))
                    request = self._load(db, delivery["request_id"], session_id)
                    request["delivery_status"] = "cancelled"
                    request["updated_at"] = self.clock()
                    self._save(db, request)

    def resume(self, session_id: str, run_id: str) -> None:
        if not run_id:
            raise QuestionError("Resume the task before restarting this question.")
        with self._db() as db:
            rows = db.execute("SELECT payload FROM questions WHERE session_id=? AND status='suspended'",
                              (session_id,)).fetchall()
            for row in rows:
                request = json.loads(row[0])
                request.setdefault("origin_run_id", request["run_id"])
                request.update(status="pending", run_id=run_id, owner_id=self.owner_id,
                               editing_leases={}, updated_at=self.clock(), revision=request["revision"] + 1)
                request["clock_tick"] = self.monotonic()
                self._save(db, request)
            # Explicit task resumption rebinds the durable outbox to this
            # attempt. Keep native send evidence so the provider can reconcile
            # a possibly accepted message before sending anything again.
            for row in db.execute("SELECT payload FROM question_deliveries WHERE session_id=? AND status='accepted'",
                                  (session_id,)).fetchall():
                delivery = json.loads(row[0])
                delivery.setdefault("origin_run_id", delivery["run_id"])
                delivery["run_id"] = run_id
                db.execute("UPDATE question_deliveries SET payload=? WHERE delivery_id=?",
                           (json.dumps(delivery), delivery["delivery_id"]))
                request = self._load(db, delivery["request_id"], session_id)
                request.setdefault("origin_run_id", request["run_id"])
                request["run_id"] = run_id
                request["updated_at"] = self.clock()
                self._save(db, request)

    def pending_deliveries(self, session_id: str, run_id: str | None = None) -> list[dict[str, Any]]:
        with self._db() as db:
            records = [json.loads(row[0]) for row in db.execute(
                "SELECT payload FROM question_deliveries WHERE session_id=? AND status='accepted' ORDER BY rowid",
                (session_id,),
            )]
        return [record for record in records if run_id is None or record["run_id"] == run_id]

    def mark_applied(self, session_id: str, delivery_id: str) -> bool:
        with self._db() as db:
            row = db.execute("SELECT payload FROM question_deliveries WHERE delivery_id=? AND session_id=?",
                             (delivery_id, session_id)).fetchone()
            if row is None:
                return False
            delivery = json.loads(row[0])
            if delivery["status"] == "applied":
                return True
            if delivery["status"] != "accepted":
                return False
            delivery.update(status="applied", applied_at=self.clock())
            db.execute("UPDATE question_deliveries SET status='applied',payload=? WHERE delivery_id=?",
                       (json.dumps(delivery), delivery_id))
            request = self._load(db, delivery["request_id"], session_id)
            request.update(delivery_status="applied", applied_at=delivery["applied_at"], updated_at=self.clock())
            self._save(db, request)
        return True

    def mark_native_delivery_sent(self, session_id: str, delivery_id: str,
                                  thread_id: str, client_id: str) -> bool:
        """Write intent before the RPC: a crash must trigger reconciliation."""
        thread_id = _text(thread_id, 200, required=True)
        client_id = _text(client_id, 200, required=True)
        with self._db() as db:
            row = db.execute("SELECT payload FROM question_deliveries WHERE delivery_id=? AND session_id=? AND status='accepted'",
                             (delivery_id, session_id)).fetchone()
            if row is None:
                return False
            delivery = json.loads(row[0])
            previous = delivery.get("native_attempt")
            if previous and (previous["thread_id"] != thread_id or previous["client_id"] != client_id):
                raise QuestionError("A previous provider delivery must be reconciled before retrying.")
            delivery["native_attempt"] = previous or {
                "thread_id": thread_id, "client_id": client_id, "attempted_at": self.clock(),
            }
            db.execute("UPDATE question_deliveries SET payload=? WHERE delivery_id=?",
                       (json.dumps(delivery), delivery_id))
        return True

    def clear_native_delivery_attempt(self, session_id: str, delivery_id: str) -> bool:
        """Clear intent only after the transport proves the RPC was not sent."""
        with self._db() as db:
            row = db.execute("SELECT payload FROM question_deliveries WHERE delivery_id=? AND session_id=? AND status='accepted'",
                             (delivery_id, session_id)).fetchone()
            if row is None:
                return False
            delivery = json.loads(row[0])
            delivery.pop("native_attempt", None)
            db.execute("UPDATE question_deliveries SET payload=? WHERE delivery_id=?",
                       (json.dumps(delivery), delivery_id))
        return True
