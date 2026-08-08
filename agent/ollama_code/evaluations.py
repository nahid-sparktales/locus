"""Local evaluation definitions and deterministic grading."""
from __future__ import annotations

import json
import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from .orchestration import OrchestrationBudget, OrchestrationError
from .runstore import RunStore, sanitize_event
from .worktrees import TaskCheckoutStore, WorktreeError

MAX_CASES = 100
MAX_ASSERTIONS = 100
ASSERTION_KINDS = {
    "command", "path_exists", "path_absent", "file_exact", "file_contains",
    "file_regex", "changed_paths_allowed", "changed_paths_forbidden",
    "json_value", "json_schema", "output_contains", "output_regex",
}


class EvaluationError(ValueError):
    pass


class EvaluationStore:
    def __init__(self, run_store: RunStore) -> None:
        self.run_store = run_store

    def list_suites(self, workspace: str = "") -> list[dict[str, Any]]:
        with self.run_store._connect(readonly=True) as connection:  # noqa: SLF001
            if workspace:
                rows = connection.execute(
                    "SELECT payload_json FROM evaluation_suites WHERE workspace_root=? ORDER BY updated_at DESC",
                    (str(Path(workspace).expanduser().resolve()),),
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT payload_json FROM evaluation_suites ORDER BY updated_at DESC"
                ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def get_suite(self, suite_id: str) -> dict[str, Any] | None:
        with self.run_store._connect(readonly=True) as connection:  # noqa: SLF001
            row = connection.execute(
                "SELECT payload_json FROM evaluation_suites WHERE id=?", (suite_id,)
            ).fetchone()
        return json.loads(row[0]) if row else None

    def save_suite(self, value: dict[str, Any], suite_id: str = "") -> dict[str, Any]:
        suite = validate_suite(value, suite_id=suite_id)
        if self.run_store.read_only:
            raise EvaluationError("the run database is read-only")
        previous = self.get_suite(suite["id"])
        self._ensure_fixed_fixtures(suite, previous)
        now = time.time()
        with self.run_store._connect() as connection:  # noqa: SLF001
            connection.execute(
                """INSERT INTO evaluation_suites(
                    id, name, workspace_root, payload_json, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,
                    workspace_root=excluded.workspace_root, payload_json=excluded.payload_json,
                    updated_at=excluded.updated_at""",
                (suite["id"], suite["name"], suite["workspace_root"],
                 json.dumps(suite, ensure_ascii=False), now, now),
            )
        self._cleanup_removed_fixtures(previous, suite)
        return suite

    def delete_suite(self, suite_id: str) -> bool:
        if self.run_store.read_only:
            return False
        suite = self.get_suite(suite_id)
        with self.run_store._connect() as connection:  # noqa: SLF001
            deleted = connection.execute(
                "DELETE FROM evaluation_suites WHERE id=?", (suite_id,)
            ).rowcount == 1
        if deleted:
            self._cleanup_removed_fixtures(suite, None)
        return deleted

    def _ensure_fixed_fixtures(
        self, suite: dict[str, Any], previous: dict[str, Any] | None,
    ) -> None:
        workspace = str(suite["workspace_root"])
        if not _is_git_workspace(workspace):
            return
        owned_ids = _fixture_ids(previous)
        for case in suite["cases"]:
            fixture = case.get("baseline_fixture")
            existing_id = str(fixture.get("task_id") or "") if isinstance(fixture, dict) else ""
            existing = TaskCheckoutStore.load(existing_id) if existing_id else None
            if (
                existing_id in owned_ids
                and existing is not None
                and Path(existing.workspace_root).resolve() == Path(workspace)
            ):
                case["baseline_fixture"] = _fixture_value(existing)
                continue
            task_id = f"eval-fixture-{uuid.uuid4().hex}"
            fixture_task = TaskCheckoutStore.create(workspace, task_id)
            case["baseline_fixture"] = _fixture_value(fixture_task)

    @staticmethod
    def _cleanup_removed_fixtures(
        previous: dict[str, Any] | None, current: dict[str, Any] | None
    ) -> None:
        for task_id in _fixture_ids(previous) - _fixture_ids(current):
            try:
                TaskCheckoutStore.cleanup(task_id)
            except WorktreeError:
                pass

    def start_result(self, suite_id: str, case_id: str, run_id: str) -> str:
        identifier = uuid.uuid4().hex
        with self.run_store._connect() as connection:  # noqa: SLF001
            connection.execute(
                """INSERT INTO evaluation_results(
                    id, suite_id, case_id, run_id, state, payload_json, created_at
                ) VALUES(?, ?, ?, ?, 'running', '{}', ?)""",
                (identifier, suite_id, case_id, run_id, time.time()),
            )
        return identifier

    def finish_result(self, result_id: str, value: dict[str, Any]) -> dict[str, Any]:
        safe = sanitize_event(value)
        state = str(safe.get("state") or "failed")
        with self.run_store._connect() as connection:  # noqa: SLF001
            connection.execute(
                """UPDATE evaluation_results SET state=?, payload_json=?, completed_at=?
                   WHERE id=?""",
                (state, json.dumps(safe, ensure_ascii=False), time.time(), result_id),
            )
        return {"id": result_id, **safe}

    def results(self, suite_id: str) -> list[dict[str, Any]]:
        with self.run_store._connect(readonly=True) as connection:  # noqa: SLF001
            rows = connection.execute(
                """SELECT id, case_id, run_id, state, payload_json, created_at, completed_at
                   FROM evaluation_results WHERE suite_id=? ORDER BY created_at DESC""",
                (suite_id,),
            ).fetchall()
        output = []
        for row in rows:
            value = json.loads(row["payload_json"] or "{}")
            output.append({
                "id": row["id"], "case_id": row["case_id"], "run_id": row["run_id"],
                "state": row["state"], "created_at": row["created_at"],
                "completed_at": row["completed_at"], **value,
            })
        return output

    def expired_successful_task_ids(self, *, older_than_days: int = 7) -> list[str]:
        """Return disposable successful fixtures eligible for local cleanup."""
        cutoff = time.time() - max(older_than_days, 1) * 86_400
        with self.run_store._connect(readonly=True) as connection:  # noqa: SLF001
            rows = connection.execute(
                """SELECT r.payload_json, s.payload_json AS suite_json
                   FROM evaluation_results r
                   JOIN evaluation_suites s ON s.id = r.suite_id
                   WHERE r.state='passed' AND r.completed_at IS NOT NULL
                     AND r.completed_at < ?""",
                (cutoff,),
            ).fetchall()
        task_ids: list[str] = []
        for row in rows:
            result = json.loads(row["payload_json"] or "{}")
            suite = json.loads(row["suite_json"] or "{}")
            task_id = str(result.get("task_id") or "")
            if task_id and not bool(suite.get("pinned")):
                task_ids.append(task_id)
        return sorted(set(task_ids))


def validate_suite(value: Any, *, suite_id: str = "") -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvaluationError("evaluation suite must be an object")
    identifier = suite_id or str(value.get("id") or uuid.uuid4().hex)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", identifier):
        raise EvaluationError("evaluation suite id is invalid")
    name = str(value.get("name") or "").strip()[:160]
    workspace = Path(str(value.get("workspace_root") or "")).expanduser().resolve()
    if not name or not workspace.is_dir():
        raise EvaluationError("evaluation suite needs a name and existing workspace")
    raw_cases = value.get("cases")
    if not isinstance(raw_cases, list) or not raw_cases or len(raw_cases) > MAX_CASES:
        raise EvaluationError(f"evaluation suite needs 1...{MAX_CASES} cases")
    cases = [validate_case(case) for case in raw_cases]
    if len({case["id"] for case in cases}) != len(cases):
        raise EvaluationError("evaluation case ids must be unique")
    return {
        "id": identifier, "name": name, "workspace_root": str(workspace),
        "description": str(value.get("description") or "")[:4_000],
        "tags": _tags(value.get("tags")), "read_only_mcp": bool(value.get("read_only_mcp")),
        "pinned": bool(value.get("pinned")), "cases": cases,
    }


def validate_case(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvaluationError("evaluation cases must be objects")
    identifier = str(value.get("id") or uuid.uuid4().hex)
    prompt = str(value.get("prompt") or "").strip()[:240_000]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", identifier) or not prompt:
        raise EvaluationError("each evaluation case needs a valid id and prompt")
    raw_assertions = value.get("assertions") or []
    if not isinstance(raw_assertions, list) or len(raw_assertions) > MAX_ASSERTIONS:
        raise EvaluationError("evaluation assertions are malformed or exceed the limit")
    mode = str(value.get("mode") or "write")
    target = str(value.get("target") or "team")
    if mode not in {"write", "read_only"}:
        raise EvaluationError("evaluation case mode must be write or read_only")
    if target not in {"solo", "team"}:
        raise EvaluationError("evaluation case target must be solo or team")
    budget_value: dict[str, int] | None = None
    if value.get("budget") is not None:
        try:
            budget = OrchestrationBudget.parse(value.get("budget"))
        except OrchestrationError as exc:
            raise EvaluationError(str(exc)) from exc
        budget_value = {
            "max_jobs": budget.max_jobs,
            "max_rounds": budget.max_rounds,
            "max_model_calls": budget.max_model_calls,
            "max_concurrent_calls": budget.max_concurrent_calls,
            "max_metered_tokens": budget.max_metered_tokens,
        }
    assertions = []
    for raw in raw_assertions:
        if not isinstance(raw, dict) or str(raw.get("kind") or "") not in ASSERTION_KINDS:
            raise EvaluationError("evaluation assertion kind is unknown")
        assertions.append({
            "id": str(raw.get("id") or uuid.uuid4().hex),
            "kind": str(raw["kind"]), "path": str(raw.get("path") or "")[:1_000],
            "value": raw.get("value"), "command": str(raw.get("command") or "")[:65_536],
            "required": bool(raw.get("required", True)),
            "timeout_seconds": min(max(_integer(raw.get("timeout_seconds"), 120), 1), 600),
        })
    return {
        "id": identifier, "name": str(value.get("name") or identifier)[:160], "prompt": prompt,
        "tags": _tags(value.get("tags")), "mode": mode,
        "target": target,
        "team_id": str(value.get("team_id") or ""),
        "timeout_seconds": min(max(_integer(value.get("timeout_seconds"), 1_800), 30), 7_200),
        "budget": budget_value,
        "assertions": assertions, "rubric": str(value.get("rubric") or "")[:16_000],
        "judge_profile_id": str(value.get("judge_profile_id") or ""),
        "passing_score": min(max(_integer(value.get("passing_score"), 80), 0), 100),
        "baseline_fixture": sanitize_event(value.get("baseline_fixture"))
        if isinstance(value.get("baseline_fixture"), dict) else None,
    }


def grade_case(case: dict[str, Any], checkout: str, output: str, changed_paths: list[str]) -> dict[str, Any]:
    root = Path(checkout).resolve()
    assertions = []
    hard_failed = False
    for spec in case.get("assertions") or []:
        started = time.monotonic()
        passed, detail = _grade_assertion(spec, root, output, changed_paths)
        required = bool(spec.get("required", True))
        if required and not passed:
            hard_failed = True
        assertions.append({
            "id": spec.get("id"), "kind": spec.get("kind"), "passed": passed,
            "required": required, "detail": detail[:4_000],
            "duration_ms": max(int((time.monotonic() - started) * 1_000), 0),
        })
    return {
        "deterministic_passed": not hard_failed,
        "assertions": assertions,
        "changed_paths": changed_paths[:5_000],
    }


def _grade_assertion(
    spec: dict[str, Any], root: Path, output: str, changed_paths: list[str]
) -> tuple[bool, str]:
    kind = str(spec.get("kind") or "")
    target = _safe_target(root, str(spec.get("path") or "")) if spec.get("path") else None
    value = spec.get("value")
    if kind == "command":
        command = str(spec.get("command") or "")
        if not command:
            return False, "Command is empty."
        try:
            result = subprocess.run(
                ["/bin/zsh", "-lc", command], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=int(spec.get("timeout_seconds") or 120), check=False,
            )
            detail = f"exit {result.returncode}\n{result.stdout[-3_000:]}"
            return result.returncode == int(value or 0), detail
        except subprocess.TimeoutExpired:
            return False, "Command timed out."
    if kind == "path_exists":
        return bool(target and target.exists()), f"Checked {spec.get('path')}"
    if kind == "path_absent":
        return bool(target and not target.exists()), f"Checked {spec.get('path')}"
    if kind in {"file_exact", "file_contains", "file_regex", "json_value", "json_schema"}:
        if target is None or not target.is_file() or target.stat().st_size > 8 * 1024 * 1024:
            return False, "Target file is missing or too large."
        text = target.read_text(encoding="utf-8", errors="replace")
        if kind == "file_exact":
            return text == str(value or ""), "Compared exact file content."
        if kind == "file_contains":
            return str(value or "") in text, "Searched file content."
        if kind == "file_regex":
            try:
                return re.search(str(value or ""), text, flags=re.MULTILINE) is not None, "Matched regex."
            except re.error as exc:
                return False, f"Invalid regex: {exc}"
        try:
            document = json.loads(text)
        except json.JSONDecodeError as exc:
            return False, f"Invalid JSON: {exc}"
        if kind == "json_value":
            expected = value if isinstance(value, dict) else {"pointer": "", "equals": value}
            actual = _json_pointer(document, str(expected.get("pointer") or ""))
            return actual == expected.get("equals"), f"Observed {actual!r}."
        valid, detail = _minimal_schema(document, value if isinstance(value, dict) else {})
        return valid, detail
    if kind in {"changed_paths_allowed", "changed_paths_forbidden"}:
        patterns = [str(item) for item in value] if isinstance(value, list) else [str(value or "")]
        matches = [path for path in changed_paths if any(_path_matches(path, pattern) for pattern in patterns)]
        if kind == "changed_paths_forbidden":
            return not matches, "Forbidden matches: " + ", ".join(matches)
        outside = [path for path in changed_paths if not any(_path_matches(path, pattern) for pattern in patterns)]
        return not outside, "Outside allowed paths: " + ", ".join(outside)
    if kind == "output_contains":
        return str(value or "") in output, "Searched model output."
    if kind == "output_regex":
        try:
            return re.search(str(value or ""), output, flags=re.MULTILINE) is not None, "Matched output regex."
        except re.error as exc:
            return False, f"Invalid regex: {exc}"
    return False, "Unsupported assertion."


def _safe_target(root: Path, relative: str) -> Path:
    target = (root / relative).resolve()
    if target != root and root not in target.parents:
        raise EvaluationError("evaluation assertion path escaped the checkout")
    return target


def _path_matches(path: str, pattern: str) -> bool:
    import fnmatch

    return fnmatch.fnmatch(path, pattern) or path == pattern.rstrip("/")


def _json_pointer(value: Any, pointer: str) -> Any:
    current = value
    for raw in pointer.strip("/").split("/") if pointer else []:
        part = raw.replace("~1", "/").replace("~0", "~")
        current = current[int(part)] if isinstance(current, list) else current[part]
    return current


def _minimal_schema(value: Any, schema: dict[str, Any], path: str = "$") -> tuple[bool, str]:
    expected = schema.get("type")
    types = {
        "object": dict, "array": list, "string": str, "number": (int, float),
        "integer": int, "boolean": bool, "null": type(None),
    }
    if expected in types and (isinstance(value, bool) and expected in {"number", "integer"}
                              or not isinstance(value, types[expected])):
        return False, f"{path} is not {expected}."
    if isinstance(value, dict):
        missing = [key for key in schema.get("required") or [] if key not in value]
        if missing:
            return False, f"{path} is missing: {', '.join(missing)}"
        for key, child in (schema.get("properties") or {}).items():
            if key in value and isinstance(child, dict):
                valid, detail = _minimal_schema(value[key], child, f"{path}.{key}")
                if not valid:
                    return valid, detail
    return True, "JSON matches the requested schema subset."


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [item for item in results if item.get("state") in {"passed", "failed"}]
    latencies = sorted(int(item.get("duration_ms") or 0) for item in completed)
    scores = [float(item["rubric_score"]) for item in completed
              if item.get("rubric_score") is not None]
    return {
        "cases": len(completed),
        "passed": sum(1 for item in completed if item.get("state") == "passed"),
        "pass_rate": (sum(1 for item in completed if item.get("state") == "passed") / len(completed))
        if completed else 0,
        "average_rubric_score": sum(scores) / len(scores) if scores else None,
        "median_latency_ms": latencies[len(latencies) // 2] if latencies else 0,
        "p95_latency_ms": latencies[min(int(len(latencies) * 0.95), len(latencies) - 1)]
        if latencies else 0,
        "model_calls": sum(int(item.get("model_calls") or 0) for item in completed),
        "prompt_tokens": sum(int(item.get("prompt_tokens") or 0) for item in completed),
        "completion_tokens": sum(int(item.get("completion_tokens") or 0) for item in completed),
        "estimated_cost": sum(float(item.get("estimated_cost") or 0) for item in completed),
    }


def compare_results(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Aggregate repeatable Solo/team configurations without exposing providers."""
    groups: dict[str, list[dict[str, Any]]] = {}
    for result in results:
        target = str(result.get("target") or "unknown")
        team_id = str(result.get("team_id") or "")
        key = target if target == "solo" else f"team:{team_id or 'default'}"
        groups.setdefault(key, []).append(result)
    output: list[dict[str, Any]] = []
    for configuration, values in sorted(groups.items()):
        metrics = summarize_results(values)
        categories: dict[str, int] = {}
        for value in values:
            category = str(value.get("failure_category") or "")
            if category:
                categories[category] = categories.get(category, 0) + 1
        output.append({
            "configuration": configuration,
            **metrics,
            "retries": sum(int(value.get("retries") or 0) for value in values),
            "failure_categories": categories,
        })
    return output


def _tags(value: Any) -> list[str]:
    return sorted({str(item).strip().lower()[:40] for item in value or [] if str(item).strip()})[:24]


def _integer(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _is_git_workspace(workspace: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=workspace, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=10, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _fixture_value(task: Any) -> dict[str, str]:
    return {
        "task_id": str(task.id),
        "workspace_root": str(task.workspace_root),
        "baseline_tree": str(task.baseline_tree),
        "baseline_commit": str(task.baseline_commit),
    }


def _fixture_ids(suite: dict[str, Any] | None) -> set[str]:
    if not suite:
        return set()
    return {
        str(fixture.get("task_id") or "")
        for case in suite.get("cases") or []
        if isinstance(case, dict)
        for fixture in [case.get("baseline_fixture")]
        if isinstance(fixture, dict) and str(fixture.get("task_id") or "")
    }


__all__ = [
    "ASSERTION_KINDS", "EvaluationError", "EvaluationStore", "compare_results", "grade_case",
    "summarize_results", "validate_case", "validate_suite",
]
