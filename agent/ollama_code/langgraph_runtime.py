"""Built-in LangGraph workflow registry and execution engine.

The module deliberately uses LangGraph's low-level ``StateGraph`` API.  Locus
continues to own provider clients, tool schemas, permissions, transcripts and
UI events; LangGraph supplies scheduling and durable checkpoints only.
"""
from __future__ import annotations

import hashlib
import json
import operator
import os
import re
import sqlite3
import threading
import time
import uuid
from collections.abc import Callable, Iterable
from contextlib import closing
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Any, TypedDict

from .ollama import OllamaClient
from .paths import APP_DIR
from .permissions import build_preview
from .remote import RemoteClient
from .tools import EDIT_TOOLS, SAFE_TOOLS, execute_tool

try:  # The source tree remains usable before the bundled runtime is prepared.
    from langgraph.checkpoint.sqlite import SqliteSaver
    from langgraph.constants import END, START
    from langgraph.graph import StateGraph
    from langgraph.types import Command, interrupt

    LANGGRAPH_AVAILABLE = True
    LANGGRAPH_IMPORT_ERROR = ""
except Exception as exc:  # noqa: BLE001 - surfaced through /api/langgraph
    SqliteSaver = StateGraph = Command = None  # type: ignore[assignment]
    START = "__start__"
    END = "__end__"
    interrupt = None  # type: ignore[assignment]
    LANGGRAPH_AVAILABLE = False
    LANGGRAPH_IMPORT_ERROR = str(exc)


SCHEMA_VERSION = 1
MAX_DEFINITION_BYTES = 1024 * 1024
MAX_NODES = 64
MAX_EDGES = 256
MAX_PARALLEL_BRANCHES = 16
MAX_STEPS = 200
DEFAULT_STEPS = 80
MAX_PROMPT_CHARS = 32_000
NODE_TYPES = {
    "input", "memory", "model", "supervisor", "agent", "router",
    "tool_set", "approval", "join", "final",
}
MODES = {"plan", "build"}
RECOVERABLE_STATUSES = {
    "awaiting_credentials", "waiting_permission", "waiting_review",
    "interrupted", "uncertain",
}
ACTIVE_STATUSES = {
    "awaiting_credentials", "waiting_permission", "waiting_review", "running",
}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
ROUTE_OPERATIONS = {"equals", "contains", "exists", "success", "failure"}

NODE_PORTS: dict[str, tuple[list[dict[str, Any]], list[dict[str, Any]]]] = {
    "input": ([], [{"id": "out", "type": "state"}]),
    "memory": ([{"id": "in", "type": "state"}], [{"id": "out", "type": "context"}]),
    "model": ([{"id": "in", "type": "any"}], [{"id": "out", "type": "text"}]),
    "supervisor": ([{"id": "in", "type": "any"}], [{"id": "out", "type": "route"}]),
    "agent": (
        [{"id": "in", "type": "any"}, {"id": "tool_results", "type": "tool_results"}],
        [
            {"id": "out", "type": "text"},
            {"id": "tools", "type": "tool_calls"},
            {"id": "final", "type": "text"},
        ],
    ),
    "router": ([{"id": "in", "type": "any"}], [{"id": "out", "type": "route"}]),
    "tool_set": (
        [{"id": "in", "type": "tool_calls"}],
        [{"id": "out", "type": "tool_results"}],
    ),
    "approval": ([{"id": "in", "type": "any"}], [{"id": "out", "type": "approval"}]),
    "join": ([{"id": "in", "type": "any", "multiple": True}], [{"id": "out", "type": "context"}]),
    "final": ([{"id": "in", "type": "any"}], [{"id": "out", "type": "text"}]),
}


class WorkflowError(ValueError):
    """A workflow definition, trust decision or run request is invalid."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode()).hexdigest()


def _slug(value: str) -> str:
    candidate = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:80]
    return candidate or "workflow"


def _merge_dict(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    return {**(left or {}), **(right or {})}


class WorkflowState(TypedDict, total=False):
    goal: str
    mode: str
    run_id: str
    session_id: str
    base_messages: list[dict[str, Any]]
    outputs: Annotated[dict[str, Any], _merge_dict]
    pending_actions: Annotated[dict[str, Any], _merge_dict]
    approvals: Annotated[dict[str, Any], _merge_dict]
    usage: Annotated[dict[str, Any], _merge_dict]
    errors: Annotated[list[dict[str, Any]], operator.add]
    final: str


def _node(
    node_id: str,
    node_type: str,
    label: str,
    x: float,
    y: float,
    **config: Any,
) -> dict[str, Any]:
    input_ports, output_ports = NODE_PORTS[node_type]
    return {
        "id": node_id,
        "type": node_type,
        "label": label,
        "position": {"x": x, "y": y},
        "config": config,
        "input_ports": deepcopy(input_ports),
        "output_ports": deepcopy(output_ports),
    }


def _edge(source: str, target: str, source_port: str = "out", target_port: str = "in") -> dict[str, Any]:
    return {
        "id": f"{source}-{target}",
        "source": source,
        "source_port": source_port,
        "target": target,
        "target_port": target_port,
    }


def builtin_templates() -> list[dict[str, Any]]:
    """Return fresh editable templates; callers may safely mutate them."""
    single = {
        "schema_version": 1,
        "id": "builtin-single-agent",
        "slug": "single-agent",
        "name": "Single Agent",
        "description": "A durable LangGraph version of Locus's standard agent loop.",
        "supported_modes": ["plan", "build"],
        "revision": 1,
        "nodes": [
            _node("input", "input", "Input", 40, 180),
            _node("memory", "memory", "Workspace memory", 230, 180),
            _node("agent", "agent", "Locus agent", 440, 110, prompt="Complete the user's request.", tools=[]),
            _node("tools", "tool_set", "Tools", 440, 270, tools=[]),
            _node("final", "final", "Final answer", 690, 180, prompt="Give the user a concise, complete final answer."),
        ],
        "edges": [
            _edge("input", "memory"), _edge("memory", "agent"),
            _edge("agent", "tools", "tools", "in"),
            _edge("tools", "agent", "out", "tool_results"),
            _edge("agent", "final", "final", "in"),
        ],
        "settings": {"max_steps": 80, "failure_policy": "fail"},
    }
    planner = {
        "schema_version": 1,
        "id": "builtin-planner-team",
        "slug": "planner-team",
        "name": "Planner Team",
        "description": "A supervisor fans out to architecture, testing and risk specialists.",
        "supported_modes": ["plan"],
        "revision": 1,
        "nodes": [
            _node("input", "input", "Input", 30, 230),
            _node("memory", "memory", "Project context", 210, 230),
            _node("supervisor", "supervisor", "Planning supervisor", 390, 230, prompt="Delegate to every useful specialist."),
            _node("architecture", "agent", "Architecture", 600, 70, prompt="Analyze architecture and implementation seams.", tools=["read_file", "glob", "grep", "list_dir"]),
            _node("testing", "agent", "Testing", 600, 230, prompt="Design verification and regression coverage.", tools=["read_file", "glob", "grep", "list_dir"]),
            _node("risks", "agent", "Risks", 600, 390, prompt="Find safety, migration and compatibility risks.", tools=["read_file", "glob", "grep", "list_dir"]),
            _node("join", "join", "Merge findings", 830, 230),
            _node("final", "final", "Implementation plan", 1030, 230, prompt="Produce a decision-complete implementation plan."),
        ],
        "edges": [
            _edge("input", "memory"), _edge("memory", "supervisor"),
            _edge("supervisor", "architecture"), _edge("supervisor", "testing"),
            _edge("supervisor", "risks"), _edge("architecture", "join"),
            _edge("testing", "join"), _edge("risks", "join"), _edge("join", "final"),
        ],
        "settings": {"max_steps": 80, "failure_policy": "fail"},
    }
    builder = {
        "schema_version": 1,
        "id": "builtin-builder-team",
        "slug": "builder-team",
        "name": "Builder Team",
        "description": "Parallel implementation and review specialists with permission-aware tools.",
        "supported_modes": ["build"],
        "revision": 1,
        "nodes": [
            _node("input", "input", "Input", 30, 230),
            _node("memory", "memory", "Project context", 190, 230),
            _node("supervisor", "supervisor", "Build supervisor", 360, 230, prompt="Delegate implementation and review work."),
            _node("implementation", "agent", "Implementation", 570, 100, prompt="Implement the requested change completely.", tools=[]),
            _node("review", "agent", "Review", 570, 360, prompt="Review the proposed implementation and identify gaps.", tools=["read_file", "glob", "grep", "list_dir", "git_diff"]),
            _node("tools", "tool_set", "Workspace tools", 790, 100, tools=[]),
            _node("approval", "approval", "Review completion", 790, 360, prompt="Review the team output before final synthesis."),
            _node("join", "join", "Merge work", 990, 230),
            _node("final", "final", "Final summary", 1190, 230, prompt="Summarize completed work and verification."),
        ],
        "edges": [
            _edge("input", "memory"), _edge("memory", "supervisor"),
            _edge("supervisor", "implementation"), _edge("supervisor", "review"),
            _edge("implementation", "tools", "tools", "in"),
            _edge("tools", "implementation", "out", "tool_results"),
            _edge("implementation", "join", "final", "in"),
            _edge("review", "approval"), _edge("approval", "join"), _edge("join", "final"),
        ],
        "settings": {"max_steps": 120, "failure_policy": "fail"},
    }
    return deepcopy([single, planner, builder])


class WorkflowRegistry:
    """Discovers, validates and atomically stores global and project workflows."""

    def __init__(self, cwd: str, root: Path | None = None) -> None:
        self.root = (root or APP_DIR / "langgraph").expanduser()
        self.global_dir = self.root / "workflows"
        self.trust_path = self.root / "trust.json"
        self.cwd = str(Path(cwd).expanduser())
        self._lock = threading.RLock()
        self.global_dir.mkdir(parents=True, exist_ok=True)

    def set_cwd(self, cwd: str) -> None:
        self.cwd = str(Path(cwd).expanduser())

    @property
    def project_dir(self) -> Path:
        return Path(self.cwd) / ".locus" / "workflows"

    def _read_json(self, path: Path) -> dict[str, Any]:
        try:
            if path.stat().st_size > MAX_DEFINITION_BYTES:
                raise WorkflowError(f"{path.name} exceeds the 1 MB workflow limit")
            value = json.loads(path.read_text(encoding="utf-8"))
        except WorkflowError:
            raise
        except (OSError, json.JSONDecodeError) as exc:
            raise WorkflowError(f"cannot read {path.name}: {exc}") from exc
        if not isinstance(value, dict):
            raise WorkflowError(f"{path.name} must contain a JSON object")
        return value

    @staticmethod
    def _path_is_confined(path: Path, root: Path) -> bool:
        try:
            resolved_root = root.resolve()
            resolved = path.resolve()
            return resolved == resolved_root or resolved_root in resolved.parents
        except (OSError, RuntimeError):
            return False

    def _discover_dir(self, directory: Path, scope: str) -> list[dict[str, Any]]:
        if not directory.is_dir():
            return []
        found: list[dict[str, Any]] = []
        for path in sorted(directory.glob("*.json")):
            if path.is_symlink() or not self._path_is_confined(path, directory):
                continue
            try:
                definition = self._read_json(path)
                validated = validate_workflow(definition)
                found.append({
                    **validated,
                    "scope": scope,
                    "path": str(path),
                    "digest": _digest(validated),
                    "valid": True,
                    "errors": [],
                })
            except WorkflowError as exc:
                found.append({
                    "id": f"invalid-{_digest(str(path))[:12]}",
                    "slug": path.stem,
                    "name": path.stem,
                    "scope": scope,
                    "path": str(path),
                    "digest": "",
                    "valid": False,
                    "errors": [str(exc)],
                    "nodes": [],
                    "edges": [],
                    "supported_modes": [],
                    "revision": 0,
                })
        return found

    def _trust(self) -> dict[str, dict[str, Any]]:
        try:
            value = json.loads(self.trust_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def _write_trust(self, value: dict[str, dict[str, Any]]) -> None:
        self._atomic_json(self.trust_path, value)

    def list(self) -> list[dict[str, Any]]:
        """Effective catalog: built-ins, globals, then project overrides by slug."""
        with self._lock:
            effective: dict[str, dict[str, Any]] = {}
            for definition in builtin_templates():
                validated = validate_workflow(definition)
                effective[validated["slug"]] = {
                    **validated,
                    "scope": "builtin",
                    "path": "",
                    "digest": _digest(validated),
                    "valid": True,
                    "trusted": True,
                    "errors": [],
                    "capabilities": workflow_capabilities(validated),
                }
            for item in self._discover_dir(self.global_dir, "global"):
                item["trusted"] = True
                item["capabilities"] = workflow_capabilities(item) if item["valid"] else {}
                effective[item["slug"]] = item
            trust = self._trust()
            workspace_key = str(Path(self.cwd).resolve())
            for item in self._discover_dir(self.project_dir, "project"):
                item["capabilities"] = workflow_capabilities(item) if item["valid"] else {}
                entry = trust.get(workspace_key, {}).get(item["slug"], "")
                if isinstance(entry, dict):
                    trusted_digest = str(entry.get("digest") or "")
                    previous_capabilities = entry.get("capabilities") or {}
                else:  # Tolerate the original digest-only trust file.
                    trusted_digest = str(entry or "")
                    previous_capabilities = {}
                item["trusted"] = bool(item["digest"] and trusted_digest == item["digest"])
                if not item["trusted"]:
                    item["capability_diff"] = capability_diff(
                        previous_capabilities,
                        item["capabilities"],
                    )
                effective[item["slug"]] = item
            return sorted(effective.values(), key=lambda item: (item["scope"] != "builtin", item["name"].lower()))

    def get(self, workflow_id_or_slug: str, *, require_trust: bool = False) -> dict[str, Any]:
        match = next(
            (item for item in self.list() if item.get("id") == workflow_id_or_slug or item.get("slug") == workflow_id_or_slug),
            None,
        )
        if match is None:
            raise WorkflowError(f"workflow not found: {workflow_id_or_slug}")
        if not match.get("valid"):
            raise WorkflowError(str((match.get("errors") or ["workflow is invalid"])[0]))
        if require_trust and not match.get("trusted"):
            raise WorkflowError("trust this project workflow before running it")
        return match

    def save(self, definition: dict[str, Any], scope: str = "global") -> dict[str, Any]:
        if scope not in {"global", "project"}:
            raise WorkflowError("scope must be global or project")
        validated = validate_workflow(definition)
        directory = self.global_dir if scope == "global" else self.project_dir
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{validated['slug']}.json"
        if path.is_symlink() or not self._path_is_confined(path.parent, directory):
            raise WorkflowError("workflow path escapes its storage directory")
        with self._lock:
            self._atomic_json(path, validated)
        return self.get(validated["id"])

    def delete(self, workflow_id_or_slug: str) -> None:
        item = self.get(workflow_id_or_slug)
        if item["scope"] == "builtin":
            raise WorkflowError("built-in templates cannot be deleted; duplicate one first")
        path = Path(str(item.get("path") or ""))
        root = self.global_dir if item["scope"] == "global" else self.project_dir
        if path.is_symlink() or not self._path_is_confined(path, root):
            raise WorkflowError("workflow path escapes its storage directory")
        try:
            path.unlink()
        except OSError as exc:
            raise WorkflowError(f"could not delete workflow: {exc}") from exc

    def trust(self, workflow_id_or_slug: str, digest: str) -> dict[str, Any]:
        item = self.get(workflow_id_or_slug)
        if item["scope"] != "project":
            return item
        if not digest or digest != item["digest"]:
            raise WorkflowError("the workflow changed; review its current digest")
        workspace_key = str(Path(self.cwd).resolve())
        with self._lock:
            trust = self._trust()
            trust.setdefault(workspace_key, {})[item["slug"]] = {
                "digest": digest,
                "capabilities": item.get("capabilities") or workflow_capabilities(item),
                "trusted_at": _utc_now(),
            }
            self._write_trust(trust)
        return self.get(workflow_id_or_slug)

    @staticmethod
    def _atomic_json(path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        payload = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
        if len(payload.encode()) > MAX_DEFINITION_BYTES and path.suffix == ".json":
            raise WorkflowError("workflow exceeds the 1 MB definition limit")
        try:
            temporary.write_text(payload, encoding="utf-8")
            os.chmod(temporary, 0o600)
            temporary.replace(path)
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass


def validate_workflow(raw: dict[str, Any]) -> dict[str, Any]:
    """Return a normalized workflow or raise a user-facing validation error."""
    if not isinstance(raw, dict):
        raise WorkflowError("workflow must be an object")
    version = raw.get("schema_version")
    if version != SCHEMA_VERSION:
        raise WorkflowError(f"unsupported workflow schema {version!r}; expected {SCHEMA_VERSION}")
    workflow_id = str(raw.get("id") or uuid.uuid4())[:120]
    name = " ".join(str(raw.get("name") or "Untitled Workflow").split())[:120]
    slug = str(raw.get("slug") or _slug(name)).lower()
    if not SLUG_RE.fullmatch(slug):
        raise WorkflowError("slug must contain lowercase letters, numbers, and hyphens")
    modes = raw.get("supported_modes") or ["plan", "build"]
    if not isinstance(modes, list) or not modes or any(mode not in MODES for mode in modes):
        raise WorkflowError("supported_modes must contain plan, build, or both")
    nodes = raw.get("nodes")
    edges = raw.get("edges")
    if not isinstance(nodes, list) or not nodes:
        raise WorkflowError("workflow needs nodes")
    if not isinstance(edges, list):
        raise WorkflowError("workflow edges must be an array")
    if len(nodes) > MAX_NODES:
        raise WorkflowError(f"workflow has more than {MAX_NODES} nodes")
    if len(edges) > MAX_EDGES:
        raise WorkflowError(f"workflow has more than {MAX_EDGES} edges")
    normalized_nodes: list[dict[str, Any]] = []
    ids: set[str] = set()
    input_ids: list[str] = []
    final_ids: list[str] = []
    for index, raw_node in enumerate(nodes):
        if not isinstance(raw_node, dict):
            raise WorkflowError(f"node {index + 1} must be an object")
        node_id = str(raw_node.get("id") or "")
        if not node_id or len(node_id) > 100 or node_id in ids:
            raise WorkflowError(f"node {index + 1} has a missing, duplicate, or oversized id")
        ids.add(node_id)
        node_type = str(raw_node.get("type") or "")
        if node_type not in NODE_TYPES:
            raise WorkflowError(f"node {node_id} has unsupported type {node_type!r}")
        if node_type == "input":
            input_ids.append(node_id)
        if node_type == "final":
            final_ids.append(node_id)
        config = raw_node.get("config") or {}
        if not isinstance(config, dict):
            raise WorkflowError(f"node {node_id} config must be an object")
        forbidden = {"python", "module", "import", "hook", "shell", "command"} & set(config)
        if forbidden:
            raise WorkflowError(f"node {node_id} contains executable configuration: {sorted(forbidden)[0]}")
        prompt = str(config.get("prompt") or "")
        if len(prompt) > MAX_PROMPT_CHARS:
            raise WorkflowError(f"node {node_id} prompt exceeds {MAX_PROMPT_CHARS:,} characters")
        if any(key.lower() in {"api_key", "token", "password", "secret"} for key in config):
            raise WorkflowError(f"node {node_id} may not contain credentials")
        try:
            retry_count = int(config.get("retry_count") or 0)
        except (TypeError, ValueError) as exc:
            raise WorkflowError(f"node {node_id} retry_count must be a number") from exc
        if retry_count < 0 or retry_count > 2:
            raise WorkflowError(f"node {node_id} retry_count must be between 0 and 2")
        if retry_count:
            config = {**config, "retry_count": retry_count}
        if node_type == "router":
            rules = config.get("rules") or []
            if not isinstance(rules, list):
                raise WorkflowError(f"router {node_id} rules must be an array")
            normalized_rules: list[dict[str, Any]] = []
            for rule_index, rule in enumerate(rules):
                if not isinstance(rule, dict):
                    raise WorkflowError(f"router {node_id} rule {rule_index + 1} must be an object")
                operation = str(rule.get("operation") or "contains")
                if operation not in ROUTE_OPERATIONS:
                    raise WorkflowError(f"router {node_id} uses unsupported operation {operation!r}")
                target = str(rule.get("target") or "")
                if not target:
                    raise WorkflowError(f"router {node_id} rule {rule_index + 1} needs a target")
                normalized_rules.append({
                    "operation": operation,
                    "path": str(rule.get("path") or "outputs")[:200],
                    "value": deepcopy(rule.get("value")),
                    "target": target,
                })
            config = {**config, "rules": normalized_rules}
        position = raw_node.get("position") or {}
        default_inputs, default_outputs = NODE_PORTS[node_type]
        input_ports = _normalize_ports(raw_node.get("input_ports"), default_inputs, node_id, "input")
        output_ports = _normalize_ports(raw_node.get("output_ports"), default_outputs, node_id, "output")
        normalized_nodes.append({
            "id": node_id,
            "type": node_type,
            "label": " ".join(str(raw_node.get("label") or node_type.replace("_", " ").title()).split())[:100],
            "position": {
                "x": float(position.get("x") or 0) if isinstance(position, dict) else 0,
                "y": float(position.get("y") or 0) if isinstance(position, dict) else 0,
            },
            "config": deepcopy(config),
            "input_ports": input_ports,
            "output_ports": output_ports,
        })
    if len(input_ids) != 1:
        raise WorkflowError("workflow must contain exactly one Input node")
    if not final_ids:
        raise WorkflowError("workflow must contain at least one Final Answer node")
    normalized_edges: list[dict[str, Any]] = []
    seen_edges: set[str] = set()
    outgoing: dict[str, list[str]] = {node_id: [] for node_id in ids}
    ports = {
        node["id"]: {
            "input": {port["id"]: port["type"] for port in node["input_ports"]},
            "output": {port["id"]: port["type"] for port in node["output_ports"]},
        }
        for node in normalized_nodes
    }
    for index, raw_edge in enumerate(edges):
        if not isinstance(raw_edge, dict):
            raise WorkflowError(f"edge {index + 1} must be an object")
        source = str(raw_edge.get("source") or raw_edge.get("from_node") or "")
        target = str(raw_edge.get("target") or raw_edge.get("to_node") or "")
        if source not in ids or target not in ids:
            raise WorkflowError(f"edge {index + 1} references an unknown node")
        edge_id = str(raw_edge.get("id") or f"{source}-{target}-{index}")[:140]
        if edge_id in seen_edges:
            raise WorkflowError(f"duplicate edge id {edge_id}")
        seen_edges.add(edge_id)
        outgoing[source].append(target)
        source_port = str(raw_edge.get("source_port") or "out")[:60]
        target_port = str(raw_edge.get("target_port") or "in")[:60]
        if source_port not in ports[source]["output"]:
            raise WorkflowError(f"edge {edge_id} references unknown output port {source_port!r}")
        if target_port not in ports[target]["input"]:
            raise WorkflowError(f"edge {edge_id} references unknown input port {target_port!r}")
        source_type = ports[source]["output"][source_port]
        target_type = ports[target]["input"][target_port]
        if "any" not in {source_type, target_type} and source_type != target_type:
            raise WorkflowError(
                f"edge {edge_id} cannot connect {source_type} to {target_type}"
            )
        condition = raw_edge.get("condition")
        if condition is not None:
            condition = _normalize_route_condition(condition, edge_id)
        normalized_edges.append({
            "id": edge_id,
            "source": source,
            "source_port": source_port,
            "target": target,
            "target_port": target_port,
            **({"condition": condition} if condition is not None else {}),
        })
    if max((len(targets) for targets in outgoing.values()), default=1) > MAX_PARALLEL_BRANCHES:
        raise WorkflowError(f"workflow can fan out to more than {MAX_PARALLEL_BRANCHES} branches")
    node_by_id = {node["id"]: node for node in normalized_nodes}
    for edge in normalized_edges:
        if "condition" in edge and node_by_id[edge["source"]]["type"] not in {"router", "supervisor", "agent"}:
            raise WorkflowError(f"edge {edge['id']} conditions require a Router, Supervisor, or Agent source")
    for node in normalized_nodes:
        if node["type"] != "router":
            continue
        for rule in node["config"].get("rules") or []:
            if rule["target"] not in outgoing[node["id"]]:
                raise WorkflowError(
                    f"router {node['id']} rule target {rule['target']!r} is not an outgoing edge"
                )
    reachable: set[str] = set()
    pending = list(input_ids)
    while pending:
        current = pending.pop()
        if current in reachable:
            continue
        reachable.add(current)
        pending.extend(outgoing[current])
    unreachable = ids - reachable
    if unreachable:
        raise WorkflowError(f"unreachable node: {sorted(unreachable)[0]}")
    if not any(node_id in reachable for node_id in final_ids):
        raise WorkflowError("no Final Answer node is reachable from Input")
    settings = raw.get("settings") or {}
    if not isinstance(settings, dict):
        raise WorkflowError("settings must be an object")
    try:
        max_steps = int(settings.get("max_steps") or DEFAULT_STEPS)
    except (TypeError, ValueError) as exc:
        raise WorkflowError("max_steps must be a number") from exc
    if max_steps < 1 or max_steps > MAX_STEPS:
        raise WorkflowError(f"max_steps must be between 1 and {MAX_STEPS}")
    failure_policy = str(settings.get("failure_policy") or "fail")
    if failure_policy not in {"fail", "continue"}:
        raise WorkflowError("failure_policy must be fail or continue")
    return {
        "schema_version": 1,
        "id": workflow_id,
        "slug": slug,
        "name": name,
        "description": str(raw.get("description") or "")[:1000],
        "supported_modes": list(dict.fromkeys(modes)),
        "revision": max(int(raw.get("revision") or 1), 1),
        "nodes": normalized_nodes,
        "edges": normalized_edges,
        "settings": {"max_steps": max_steps, "failure_policy": failure_policy},
    }


def _normalize_ports(
    raw: Any,
    defaults: list[dict[str, Any]],
    node_id: str,
    direction: str,
) -> list[dict[str, Any]]:
    values = deepcopy(defaults) if raw is None else raw
    if not isinstance(values, list):
        raise WorkflowError(f"node {node_id} {direction} ports must be an array")
    ports: list[dict[str, Any]] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, dict):
            raise WorkflowError(f"node {node_id} has a malformed {direction} port")
        port_id = str(value.get("id") or "")[:60]
        port_type = str(value.get("type") or "any")[:60]
        if not port_id or port_id in seen or not re.fullmatch(r"[A-Za-z0-9_-]+", port_id):
            raise WorkflowError(f"node {node_id} has an invalid or duplicate {direction} port")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", port_type):
            raise WorkflowError(f"node {node_id} has an invalid {direction} port type")
        seen.add(port_id)
        ports.append({"id": port_id, "type": port_type, "multiple": bool(value.get("multiple", False))})
    return ports


def _normalize_route_condition(raw: Any, edge_id: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise WorkflowError(f"edge {edge_id} condition must be an object")
    operation = str(raw.get("operation") or raw.get("operator") or "")
    if operation not in ROUTE_OPERATIONS:
        raise WorkflowError(f"edge {edge_id} uses unsupported route operation {operation!r}")
    return {
        "operation": operation,
        "path": str(raw.get("path") or "outputs")[:200],
        **({"value": deepcopy(raw.get("value"))} if "value" in raw else {}),
    }


def workflow_capabilities(definition: dict[str, Any]) -> dict[str, Any]:
    tools: set[str] = set()
    accounts: set[str] = set()
    models: set[str] = set()
    prompts = 0
    prompt_material: list[dict[str, str]] = []
    for node in definition.get("nodes") or []:
        config = node.get("config") or {}
        tools.update(str(item) for item in config.get("tools") or [])
        binding = config.get("model_binding") or {}
        account_id = str(binding.get("account_id") or "")
        model = str(binding.get("model") or "")
        if account_id:
            accounts.add(account_id)
        if account_id or model:
            models.add(f"{account_id or 'inherited'}:{model or 'default'}")
        prompt = str(config.get("prompt") or "")
        prompts += len(prompt)
        if prompt:
            prompt_material.append({"node": str(node.get("id") or ""), "prompt": prompt})
    mutation_names = EDIT_TOOLS | {"bash", "web_fetch"}
    return {
        "node_count": len(definition.get("nodes") or []),
        "edge_count": len(definition.get("edges") or []),
        "parallel_width": min(_estimated_width(definition), MAX_PARALLEL_BRANCHES),
        "tools": sorted(tools),
        "provider_account_ids": sorted(accounts),
        "models": sorted(models),
        "may_mutate": not tools or bool(tools & mutation_names) or any(name.startswith("mcp__") for name in tools),
        "prompt_characters": prompts,
        "prompt_digest": _digest(prompt_material),
    }


def capability_diff(previous: Any, current: Any) -> dict[str, Any]:
    """Return a model-readable trust diff without exposing full workflow prompts."""
    before = previous if isinstance(previous, dict) else {}
    after = current if isinstance(current, dict) else {}

    def set_diff(key: str) -> tuple[list[str], list[str]]:
        old = {str(item) for item in before.get(key) or []}
        new = {str(item) for item in after.get(key) or []}
        return sorted(new - old), sorted(old - new)

    tools_added, tools_removed = set_diff("tools")
    models_added, models_removed = set_diff("models")
    accounts_added, accounts_removed = set_diff("provider_account_ids")
    old_width = int(before.get("parallel_width") or 0)
    new_width = int(after.get("parallel_width") or 0)
    old_mutates = bool(before.get("may_mutate", False))
    new_mutates = bool(after.get("may_mutate", False))
    prompts_changed = not before or before.get("prompt_digest") != after.get("prompt_digest")
    return {
        "first_trust": not bool(before),
        "prompts_changed": prompts_changed,
        "tools_added": tools_added,
        "tools_removed": tools_removed,
        "models_added": models_added,
        "models_removed": models_removed,
        "provider_accounts_added": accounts_added,
        "provider_accounts_removed": accounts_removed,
        "mutation_before": old_mutates,
        "mutation_after": new_mutates,
        "parallel_width_before": old_width,
        "parallel_width_after": new_width,
        "changed": bool(
            prompts_changed or tools_added or tools_removed or models_added or models_removed
            or accounts_added or accounts_removed or old_mutates != new_mutates
            or old_width != new_width
        ),
    }


def _estimated_width(definition: dict[str, Any]) -> int:
    outgoing: dict[str, int] = {}
    for edge in definition.get("edges") or []:
        source = str(edge.get("source") or "")
        outgoing[source] = outgoing.get(source, 0) + 1
    return max([1, *outgoing.values()])


class GraphRunStore:
    """SQLite run ledger kept separate from LangGraph's checkpoint tables."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = (root or APP_DIR / "langgraph").expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self.path = self.root / "runs.sqlite"
        self.checkpoint_path = self.root / "checkpoints.sqlite"
        self._lock = threading.RLock()
        self._setup()
        self._recover_abandoned_runs()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=10, check_same_thread=False)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=10000")
        return connection

    def _setup(self) -> None:
        with self._lock, closing(self._connect()) as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    workflow_id TEXT NOT NULL,
                    workflow_digest TEXT NOT NULL,
                    workflow_json TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    status TEXT NOT NULL,
                    state_json TEXT NOT NULL DEFAULT '{}',
                    error TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS node_events (
                    event_id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL,
                    node_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    payload_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS side_effects (
                    effect_id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL,
                    node_id TEXT NOT NULL,
                    tool TEXT NOT NULL,
                    preview TEXT NOT NULL,
                    status TEXT NOT NULL,
                    result TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status, updated_at);
                CREATE INDEX IF NOT EXISTS idx_events_run ON node_events(run_id, created_at);
                CREATE INDEX IF NOT EXISTS idx_effects_run ON side_effects(run_id, created_at);
                """
            )
            db.commit()
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def _recover_abandoned_runs(self) -> None:
        with self._lock, closing(self._connect()) as db:
            running = db.execute("SELECT id FROM runs WHERE status = 'running'").fetchall()
            for row in running:
                uncertain = db.execute(
                    "SELECT 1 FROM side_effects WHERE run_id = ? AND status = 'started' LIMIT 1",
                    (row["id"],),
                ).fetchone()
                db.execute(
                    "UPDATE runs SET status = ?, error = ?, updated_at = ? WHERE id = ?",
                    (
                        "uncertain" if uncertain else "interrupted",
                        "A side effect may have completed before the backend stopped." if uncertain else "The backend stopped during this run.",
                        _utc_now(),
                        row["id"],
                    ),
                )
            db.commit()

    def create(self, *, run_id: str, session_id: str, workflow: dict[str, Any], mode: str, goal: str, status: str) -> dict[str, Any]:
        now = _utc_now()
        sanitized = validate_workflow(workflow)
        with self._lock, closing(self._connect()) as db:
            db.execute(
                "INSERT INTO runs(id,session_id,workflow_id,workflow_digest,workflow_json,mode,goal,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (run_id, session_id, sanitized["id"], _digest(sanitized), json.dumps(sanitized), mode, goal, status, now, now),
            )
            db.commit()
        return self.get(run_id)

    def update(self, run_id: str, *, status: str | None = None, state: dict[str, Any] | None = None, error: str | None = None) -> dict[str, Any]:
        fields = ["updated_at = ?"]
        values: list[Any] = [_utc_now()]
        if status is not None:
            fields.append("status = ?")
            values.append(status)
        if state is not None:
            fields.append("state_json = ?")
            values.append(json.dumps(state, default=str))
        if error is not None:
            fields.append("error = ?")
            values.append(error[:4000])
        values.append(run_id)
        with self._lock, closing(self._connect()) as db:
            db.execute(f"UPDATE runs SET {', '.join(fields)} WHERE id = ?", values)
            if db.total_changes == 0:
                raise WorkflowError(f"graph run not found: {run_id}")
            db.commit()
        return self.get(run_id)

    def get(self, run_id: str) -> dict[str, Any]:
        with self._lock, closing(self._connect()) as db:
            row = db.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
            if row is None:
                raise WorkflowError(f"graph run not found: {run_id}")
            events = db.execute(
                "SELECT event_id,node_id,status,payload_json,created_at FROM node_events WHERE run_id = ? ORDER BY created_at",
                (run_id,),
            ).fetchall()
            effects = db.execute(
                "SELECT effect_id,node_id,tool,preview,status,result,created_at,updated_at FROM side_effects WHERE run_id = ? ORDER BY created_at",
                (run_id,),
            ).fetchall()
        item = dict(row)
        item["workflow"] = json.loads(item.pop("workflow_json"))
        item["state"] = json.loads(item.pop("state_json") or "{}")
        item["events"] = [
            {**dict(event), "payload": json.loads(event["payload_json"] or "{}")}
            for event in events
        ]
        for event in item["events"]:
            event.pop("payload_json", None)
        item["side_effects"] = [dict(effect) for effect in effects]
        return item

    def list(self, session_id: str = "", recoverable_only: bool = False, limit: int = 100) -> list[dict[str, Any]]:
        clauses: list[str] = []
        values: list[Any] = []
        if session_id:
            clauses.append("session_id = ?")
            values.append(session_id)
        if recoverable_only:
            placeholders = ",".join("?" for _ in RECOVERABLE_STATUSES)
            clauses.append(f"status IN ({placeholders})")
            values.extend(sorted(RECOVERABLE_STATUSES))
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        values.append(max(1, min(limit, 500)))
        with self._lock, closing(self._connect()) as db:
            rows = db.execute(
                f"SELECT id,session_id,workflow_id,workflow_digest,mode,goal,status,state_json,error,created_at,updated_at FROM runs {where} ORDER BY updated_at DESC LIMIT ?",
                values,
            ).fetchall()
            output: list[dict[str, Any]] = []
            for row in rows:
                item = dict(row)
                item["state"] = json.loads(item.pop("state_json") or "{}")
                item["side_effects"] = [
                    dict(effect) for effect in db.execute(
                        "SELECT effect_id,node_id,tool,preview,status,result,created_at,updated_at "
                        "FROM side_effects WHERE run_id = ? ORDER BY created_at",
                        (item["id"],),
                    ).fetchall()
                ]
                output.append(item)
        return output

    def active(self) -> dict[str, Any] | None:
        for run in self.list(limit=20):
            if run["status"] in ACTIVE_STATUSES:
                return run
        return None

    def event(self, run_id: str, node_id: str, status: str, payload: dict[str, Any] | None = None, event_id: str = "") -> str:
        event_id = event_id or uuid.uuid4().hex
        with self._lock, closing(self._connect()) as db:
            db.execute(
                "INSERT OR IGNORE INTO node_events(event_id,run_id,node_id,status,payload_json,created_at) VALUES(?,?,?,?,?,?)",
                (event_id, run_id, node_id, status, json.dumps(payload or {}, default=str), _utc_now()),
            )
            db.commit()
        return event_id

    def begin_effect(self, run_id: str, node_id: str, tool: str, preview: str, effect_id: str) -> None:
        now = _utc_now()
        with self._lock, closing(self._connect()) as db:
            db.execute(
                "INSERT OR IGNORE INTO side_effects(effect_id,run_id,node_id,tool,preview,status,created_at,updated_at) VALUES(?,?,?,?,?,'started',?,?)",
                (effect_id, run_id, node_id, tool, preview[:4000], now, now),
            )
            db.commit()

    def finish_effect(self, effect_id: str, result: str, status: str = "completed") -> None:
        with self._lock, closing(self._connect()) as db:
            db.execute(
                "UPDATE side_effects SET status = ?, result = ?, updated_at = ? WHERE effect_id = ?",
                (status, result[:30_000], _utc_now(), effect_id),
            )
            db.commit()

    def effect(self, effect_id: str) -> dict[str, Any] | None:
        with self._lock, closing(self._connect()) as db:
            row = db.execute(
                "SELECT effect_id,run_id,node_id,tool,preview,status,result,created_at,updated_at "
                "FROM side_effects WHERE effect_id = ?",
                (effect_id,),
            ).fetchone()
        return dict(row) if row else None

    def resolve_uncertain(self, run_id: str, action: str) -> dict[str, Any]:
        run = self.get(run_id)
        if run["status"] != "uncertain":
            raise WorkflowError("this graph run does not have an uncertain side effect")
        if action not in {"skip", "retry"}:
            raise WorkflowError("uncertain side effects can only be skipped or explicitly retried")
        candidates = [effect for effect in run["side_effects"] if effect["status"] == "started"]
        if not candidates:
            raise WorkflowError("no unresolved side effect was found")
        effect = candidates[0]
        next_status = "skipped" if action == "skip" else "retry_authorized"
        result = (
            "Skipped after restart because the outcome could not be verified."
            if action == "skip"
            else "The user explicitly authorized a retry after reviewing the uncertain outcome."
        )
        self.finish_effect(effect["effect_id"], result, next_status)
        self.update(run_id, status="interrupted", error=result)
        return self.get(run_id)

    def discard(self, run_id: str) -> None:
        run = self.get(run_id)
        if run["status"] == "running":
            raise WorkflowError("stop the graph run before discarding it")
        with self._lock, closing(self._connect()) as db:
            db.execute("DELETE FROM node_events WHERE run_id = ?", (run_id,))
            db.execute("DELETE FROM side_effects WHERE run_id = ?", (run_id,))
            db.execute("DELETE FROM runs WHERE id = ?", (run_id,))
            db.commit()
        self._delete_checkpoint_threads([run_id])

    def discard_sessions(self, session_ids: Iterable[str]) -> int:
        """Remove graph history alongside conversations explicitly moved to trash."""
        ids = sorted({str(session_id) for session_id in session_ids if session_id})
        if not ids:
            return 0
        placeholders = ",".join("?" for _ in ids)
        with self._lock, closing(self._connect()) as db:
            run_ids = [
                str(row["id"])
                for row in db.execute(
                    f"SELECT id FROM runs WHERE session_id IN ({placeholders})",
                    ids,
                ).fetchall()
            ]
            for run_id in run_ids:
                db.execute("DELETE FROM node_events WHERE run_id = ?", (run_id,))
                db.execute("DELETE FROM side_effects WHERE run_id = ?", (run_id,))
                db.execute("DELETE FROM runs WHERE id = ?", (run_id,))
            db.commit()
        self._delete_checkpoint_threads(run_ids)
        return len(run_ids)

    def prune(self) -> int:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat(timespec="seconds")
        with self._lock, closing(self._connect()) as db:
            keep = {
                row["id"] for row in db.execute(
                    "SELECT id FROM runs WHERE status = 'completed' ORDER BY updated_at DESC LIMIT 50"
                )
            }
            candidates = db.execute(
                "SELECT id FROM runs WHERE status = 'completed' AND updated_at < ?",
                (cutoff,),
            ).fetchall()
            doomed = [row["id"] for row in candidates if row["id"] not in keep]
            for run_id in doomed:
                db.execute("DELETE FROM node_events WHERE run_id = ?", (run_id,))
                db.execute("DELETE FROM side_effects WHERE run_id = ?", (run_id,))
                db.execute("DELETE FROM runs WHERE id = ?", (run_id,))
            db.commit()
        self._delete_checkpoint_threads(doomed)
        return len(doomed)

    def _delete_checkpoint_threads(self, run_ids: Iterable[str]) -> None:
        ids = [str(run_id) for run_id in run_ids if run_id]
        if not ids or not LANGGRAPH_AVAILABLE or not self.checkpoint_path.exists():
            return
        connection = sqlite3.connect(self.checkpoint_path, check_same_thread=False)
        try:
            saver = SqliteSaver(connection)
            for run_id in ids:
                saver.delete_thread(run_id)
        finally:
            connection.close()


class SideEffectCoordinator:
    """Serializes commands, writes and external mutations across graph branches."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._next_ticket = 0
        self._serving = 0

    def run(self, mutating: bool, call: Callable[[], str]) -> str:
        if not mutating:
            return call()
        with self._condition:
            ticket = self._next_ticket
            self._next_ticket += 1
            while ticket != self._serving:
                self._condition.wait()
        try:
            return call()
        finally:
            with self._condition:
                self._serving += 1
                self._condition.notify_all()


class ClassicEngine:
    """Adapter that keeps the established AgentCore loop as a selectable engine."""

    name = "classic"

    def __init__(self, core: Any) -> None:
        self.core = core

    def run_turn(self, *args: Any, **kwargs: Any) -> None:
        self.core._run_classic_turn(*args, **kwargs)


class LangGraphEngine:
    """Compile and execute validated workflows against an existing AgentCore."""

    def __init__(self, core: Any, root: Path | None = None) -> None:
        # LangGraph's local primitives do not require LangSmith. Preserve an
        # explicit operator choice, but keep all tracing off by default.
        os.environ.setdefault("LANGSMITH_TRACING", "false")
        os.environ.setdefault("LANGCHAIN_TRACING_V2", "false")
        self.core = core
        self.registry = WorkflowRegistry(core.cwd, root)
        self.runs = GraphRunStore(root)
        self.side_effects = SideEffectCoordinator()
        self._credentials: dict[str, dict[str, dict[str, Any]]] = {}
        self._pending_decisions: dict[str, dict[str, str]] = {}
        self._active_run_id = ""
        self._guard = threading.RLock()

    @property
    def available(self) -> bool:
        return LANGGRAPH_AVAILABLE

    @property
    def active_run_id(self) -> str:
        active = self.runs.active()
        return str(active.get("id") or "") if active else ""

    def snapshot(self) -> dict[str, Any]:
        return {
            "available": self.available,
            "version": self._package_version("langgraph"),
            "checkpoint_version": self._package_version("langgraph-checkpoint-sqlite"),
            "error": LANGGRAPH_IMPORT_ERROR,
            "limits": {
                "nodes": MAX_NODES,
                "edges": MAX_EDGES,
                "parallel_branches": MAX_PARALLEL_BRANCHES,
                "steps": MAX_STEPS,
                "definition_bytes": MAX_DEFINITION_BYTES,
            },
            "active_run": self.runs.active(),
            "recoverable_runs": self.runs.list(recoverable_only=True),
        }

    @staticmethod
    def _package_version(name: str) -> str:
        try:
            from importlib.metadata import version

            return version(name)
        except Exception:  # noqa: BLE001
            return ""

    def required_accounts(self, workflow: dict[str, Any]) -> list[str]:
        return list(workflow_capabilities(workflow).get("provider_account_ids") or [])

    def start(
        self,
        goal: str,
        mode: str,
        workflow_id: str,
        decider: Any = None,
        *,
        credentials: list[dict[str, Any]] | None = None,
        existing_run_id: str = "",
    ) -> dict[str, Any]:
        if not self.available:
            raise WorkflowError(f"LangGraph is unavailable: {LANGGRAPH_IMPORT_ERROR}")
        if mode not in MODES:
            raise WorkflowError("LangGraph runs require Plan or Build mode")
        workflow = self.registry.get(workflow_id, require_trust=True)
        if mode not in workflow["supported_modes"]:
            raise WorkflowError(f"{workflow['name']} does not support {mode.title()} mode")
        current = self.runs.active()
        if current and current.get("id") != existing_run_id:
            raise WorkflowError("another graph run is active")
        run_id = existing_run_id or uuid.uuid4().hex
        supplied = {
            str(item.get("account_id") or ""): self._sanitize_credential(item)
            for item in credentials or []
            if isinstance(item, dict) and item.get("account_id")
        }
        self._credentials.setdefault(run_id, {}).update(supplied)
        missing = [account for account in self.required_accounts(workflow) if account not in self._credentials[run_id]]
        if not existing_run_id:
            self.core._turn_allows_tools = True
            self.core._last_turn_allowed_tools = True
            self.core._interrupt.clear()
            self.core.tool_ctx.read_files.clear()
            self.core.reload_context()
            self.core.reset_system_message()
            self.core.tool_registry.begin_turn(goal, self.core.cwd)
            self.core._last_user_message = goal
            self.core._add_message(
                {"role": "user", "content": goal},
                event_id=f"graph:{run_id}:user",
            )
            self.runs.create(
                run_id=run_id,
                session_id=self.core.session.session_id,
                workflow=workflow,
                mode=mode,
                goal=goal,
                status="awaiting_credentials" if missing else "running",
            )
            self.runs.update(run_id, state={"tool_schema_snapshot": self._tool_schema_snapshot()})
            self.core._emit({
                "type": "graph_run_started",
                "run_id": run_id,
                "workflow_id": workflow["id"],
                "workflow_name": workflow["name"],
                "workflow_digest": workflow["digest"],
                "mode": mode,
            })
        if missing:
            saved_state = dict(self.runs.get(run_id).get("state") or {})
            saved_state["required_account_ids"] = missing
            self.runs.update(run_id, status="awaiting_credentials", state=saved_state)
            self.core._emit({
                "type": "graph_credentials_required",
                "run_id": run_id,
                "account_ids": missing,
            })
            return self.runs.get(run_id)
        if existing_run_id:
            self._prepare_run_context(self.runs.get(run_id))
        return self._execute(run_id, workflow, goal, mode, decider=decider)

    def _tool_schema_snapshot(self) -> dict[str, dict[str, Any]]:
        snapshot: dict[str, dict[str, Any]] = {}
        for schema in self.core.tool_registry.schemas():
            function = schema.get("function") or {}
            name = str(function.get("name") or "")
            if name:
                snapshot[name] = {
                    "digest": _digest(schema),
                    "schema": deepcopy(schema),
                }
        return snapshot

    def _prepare_run_context(self, run: dict[str, Any]) -> None:
        """Restore only the foreground state needed to resume a durable run."""
        session_id = str(run.get("session_id") or "")
        if session_id and self.core.session.session_id != session_id:
            try:
                self.core.resume_session(session_id)
            except (FileNotFoundError, ValueError) as exc:
                raise WorkflowError("the conversation linked to this workflow run is unavailable") from exc
        self.registry.set_cwd(self.core.cwd)
        self.core._turn_allows_tools = True
        self.core._last_turn_allowed_tools = True
        self.core._interrupt.clear()
        self.core.tool_ctx.read_files.clear()
        self.core.reload_context()
        self.core.reset_system_message()
        self.core.tool_registry.begin_turn(str(run.get("goal") or ""), self.core.cwd)
        self.core._last_user_message = str(run.get("goal") or "")

    def provide_credentials(self, run_id: str, credentials: list[dict[str, Any]], decider: Any = None) -> dict[str, Any]:
        run = self.runs.get(run_id)
        if run["status"] != "awaiting_credentials":
            raise WorkflowError("this graph run is not waiting for credentials")
        return self.start(
            run["goal"], run["mode"], run["workflow_id"], decider,
            credentials=credentials, existing_run_id=run_id,
        )

    @staticmethod
    def _sanitize_credential(item: dict[str, Any]) -> dict[str, Any]:
        allowed = {
            "account_id", "provider", "base_url", "model", "api_key", "auth_style",
            "lists_models", "context_window", "account_label", "host",
        }
        return {key: item[key] for key in allowed if key in item}

    def record_decision(self, run_id: str, request_id: str, decision: str, decider: Any = None) -> tuple[bool, dict[str, Any] | None]:
        run = self.runs.get(run_id)
        active = self.runs.active()
        if active and active["id"] != run_id:
            raise WorkflowError("another graph run is active")
        state = dict(run.get("state") or {})
        pending = list(state.get("pending_interrupts") or [])
        target = next((item for item in pending if item.get("request_id") == request_id), None)
        if target is None:
            return False, None
        allowed = {"once", "always", "deny"} if target.get("kind") == "tool_permission" else {"approve", "reject"}
        if decision not in allowed:
            decision = "deny" if target.get("kind") == "tool_permission" else "reject"
        decisions = dict(state.get("interrupt_decisions") or {})
        decisions[str(target["interrupt_id"])] = decision
        state["interrupt_decisions"] = decisions
        unanswered = [item for item in pending if str(item.get("interrupt_id")) not in decisions]
        self.runs.update(run_id, state=state)
        if unanswered:
            self._emit_interrupt(run_id, unanswered[0])
            return True, None
        self._prepare_run_context(run)
        result = self._execute(
            run_id, run["workflow"], run["goal"], run["mode"],
            decider=decider, resume=decisions,
        )
        return True, result

    def resume(self, run_id: str, decider: Any = None) -> dict[str, Any]:
        run = self.runs.get(run_id)
        active = self.runs.active()
        if active and active["id"] != run_id:
            raise WorkflowError("another graph run is active")
        if run["status"] not in RECOVERABLE_STATUSES:
            raise WorkflowError("this graph run is not recoverable")
        current = validate_workflow(run["workflow"])
        if _digest(current) != run["workflow_digest"]:
            raise WorkflowError("the saved workflow snapshot no longer matches its digest")
        if run["status"] == "uncertain":
            raise WorkflowError(
                "this run has an uncertain external side effect; inspect it and explicitly discard or retry it"
            )
        missing = [account for account in self.required_accounts(current) if account not in self._credentials.get(run_id, {})]
        if missing:
            self.runs.update(run_id, status="awaiting_credentials", state={**run["state"], "required_account_ids": missing})
            self.core._emit({"type": "graph_credentials_required", "run_id": run_id, "account_ids": missing})
            return self.runs.get(run_id)
        state = run.get("state") or {}
        pending = list(state.get("pending_interrupts") or [])
        if pending:
            unanswered = [item for item in pending if str(item.get("interrupt_id")) not in (state.get("interrupt_decisions") or {})]
            if unanswered:
                self._emit_interrupt(run_id, unanswered[0])
                return run
        self._prepare_run_context(run)
        return self._execute(run_id, current, run["goal"], run["mode"], decider=decider, resume=state.get("interrupt_decisions") or None)

    def discard(self, run_id: str) -> None:
        was_active = self.active_run_id == run_id
        self.runs.discard(run_id)
        self._credentials.pop(run_id, None)
        if was_active:
            self.core.tool_registry.end_turn()
            self.core._turn_allows_tools = True

    def interrupt_active(self) -> bool:
        active = self.runs.active()
        if not active:
            return False
        was_running = active["status"] == "running"
        self.core.interrupt()
        state = dict(active.get("state") or {})
        decisions = dict(state.get("interrupt_decisions") or {})
        for pending in state.get("pending_interrupts") or []:
            interrupt_id = str(pending.get("interrupt_id") or "")
            if interrupt_id and interrupt_id not in decisions:
                decisions[interrupt_id] = (
                    "deny" if pending.get("kind") == "tool_permission" else "reject"
                )
        if decisions:
            state["interrupt_decisions"] = decisions
        self.runs.update(
            active["id"],
            status="interrupted",
            error="Stopped by the user.",
            state=state,
        )
        self.core._emit({"type": "graph_run_state", "run_id": active["id"], "status": "interrupted"})
        if not was_running:
            self.core.tool_registry.end_turn()
            self.core._turn_allows_tools = True
            self._credentials.pop(active["id"], None)
            self.core._emit({"type": "turn_done", "reason": "interrupted", "duration_ms": 0, "run_id": active["id"]})
        return True

    def _execute(
        self,
        run_id: str,
        workflow: dict[str, Any],
        goal: str,
        mode: str,
        *,
        decider: Any = None,
        resume: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        started = time.monotonic()
        self._active_run_id = run_id
        saved_state = dict(self.runs.get(run_id).get("state") or {})
        persisted = {
            "tool_schema_snapshot": saved_state.get("tool_schema_snapshot") or self._tool_schema_snapshot(),
        }
        self.runs.update(run_id, status="running", state=persisted)
        self.core._emit({"type": "graph_run_state", "run_id": run_id, "status": "running"})
        connection = sqlite3.connect(self.runs.checkpoint_path, check_same_thread=False)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=10000")
        saver = SqliteSaver(connection)
        config = {
            "configurable": {"thread_id": run_id},
            "recursion_limit": int(workflow.get("settings", {}).get("max_steps") or DEFAULT_STEPS),
            "max_concurrency": MAX_PARALLEL_BRANCHES,
        }
        interrupts: list[dict[str, Any]] = []
        try:
            graph = self._compile(workflow, run_id, mode, decider, saver)
            initial: Any
            if resume:
                initial = Command(resume=resume)
            else:
                initial = WorkflowState(
                    goal=goal,
                    mode=mode,
                    run_id=run_id,
                    session_id=self.core.session.session_id,
                    base_messages=deepcopy(self.core.messages[:-1]),
                    outputs={}, pending_actions={}, approvals={}, usage={}, errors=[], final="",
                )
            for chunk in graph.stream(initial, config=config, stream_mode="updates"):
                if self.core._interrupt.is_set():
                    raise WorkflowError("workflow stopped by the user")
                if not isinstance(chunk, dict):
                    continue
                raw_interrupts = chunk.get("__interrupt__") or ()
                for item in raw_interrupts:
                    value = item.value if hasattr(item, "value") else {}
                    payload = dict(value) if isinstance(value, dict) else {"message": str(value)}
                    interrupt_id = str(getattr(item, "id", "") or payload.get("request_id") or uuid.uuid4().hex)
                    payload["interrupt_id"] = interrupt_id
                    payload["request_id"] = str(payload.get("request_id") or interrupt_id)
                    interrupts.append(payload)
            if interrupts:
                state = {
                    "pending_interrupts": interrupts,
                    "interrupt_decisions": {},
                    "tool_schema_snapshot": persisted["tool_schema_snapshot"],
                }
                kind = str(interrupts[0].get("kind") or "review")
                status = "waiting_permission" if kind == "tool_permission" else "waiting_review"
                self.runs.update(run_id, status=status, state=state)
                self.core._emit({"type": "graph_run_state", "run_id": run_id, "status": status})
                self._emit_interrupt(run_id, interrupts[0])
                return self.runs.get(run_id)
            snapshot = graph.get_state(config)
            values = dict(snapshot.values or {}) if snapshot is not None else {}
            final = str(values.get("final") or "")
            if final:
                self.core._add_message(
                    {"role": "assistant", "content": final},
                    event_id=f"graph:{run_id}:final",
                )
            self.runs.update(run_id, status="completed", state={
                "usage": values.get("usage") or {},
                "final": final,
                "tool_schema_snapshot": persisted["tool_schema_snapshot"],
            })
            self.core._emit({"type": "graph_run_state", "run_id": run_id, "status": "completed"})
            self.core._emit({
                "type": "turn_done", "reason": "complete", "run_id": run_id,
                "duration_ms": max(int((time.monotonic() - started) * 1000), 0),
            })
            self.core._emit_info()
            self.runs.prune()
            return self.runs.get(run_id)
        except Exception as exc:  # noqa: BLE001 - graph errors are user-visible run failures
            if self.core._interrupt.is_set():
                status = "interrupted"
                reason = "interrupted"
            else:
                status = "failed"
                reason = "error"
            message = self._redact(str(exc), run_id)
            self.runs.update(run_id, status=status, error=message)
            self.core._emit({"type": "error", "message": message, "run_id": run_id})
            self.core._emit({"type": "graph_run_state", "run_id": run_id, "status": status, "error": message})
            self.core._emit({"type": "turn_done", "reason": reason, "run_id": run_id, "duration_ms": max(int((time.monotonic() - started) * 1000), 0)})
            return self.runs.get(run_id)
        finally:
            connection.close()
            if self.runs.get(run_id)["status"] not in ACTIVE_STATUSES:
                self.core.tool_registry.end_turn()
                self.core._turn_allows_tools = True
                self._credentials.pop(run_id, None)
            self._active_run_id = ""

    def _compile(self, workflow: dict[str, Any], run_id: str, mode: str, decider: Any, saver: Any) -> Any:
        builder = StateGraph(WorkflowState)
        nodes = {str(node["id"]): node for node in workflow["nodes"]}
        outgoing: dict[str, list[dict[str, Any]]] = {node_id: [] for node_id in nodes}
        incoming: dict[str, list[str]] = {node_id: [] for node_id in nodes}
        for edge in workflow["edges"]:
            outgoing[edge["source"]].append(edge)
            incoming[edge["target"]].append(edge["source"])
        for node_id, node in nodes.items():
            builder.add_node(node_id, self._node_callable(node, run_id, mode, decider))
        input_id = next(node_id for node_id, node in nodes.items() if node["type"] == "input")
        builder.add_edge(START, input_id)
        joined_targets = {
            node_id for node_id, node in nodes.items()
            if node["type"] == "join" and len(incoming[node_id]) > 1
        }
        for node_id, node in nodes.items():
            targets = [edge["target"] for edge in outgoing[node_id]]
            if node["type"] in {"supervisor", "router", "agent"} and len(targets) > 1:
                builder.add_conditional_edges(
                    node_id,
                    self._route_callable(node_id, node, outgoing[node_id]),
                    {target: target for target in targets},
                )
                continue
            for target in targets:
                if target in joined_targets:
                    continue
                builder.add_edge(node_id, target)
            if not targets and node["type"] == "final":
                builder.add_edge(node_id, END)
        for target in joined_targets:
            builder.add_edge(incoming[target], target)
        return builder.compile(checkpointer=saver)

    def _node_callable(self, node: dict[str, Any], run_id: str, mode: str, decider: Any) -> Callable[[WorkflowState], dict[str, Any]]:
        def call(state: WorkflowState) -> dict[str, Any]:
            node_id = str(node["id"])
            label = str(node["label"])
            started = time.monotonic()
            node_type = str(node["type"])
            retryable = node_type in {"memory", "model", "supervisor", "agent", "router", "join", "final"}
            retries = int((node.get("config") or {}).get("retry_count") or 0) if retryable else 0
            result: dict[str, Any] | None = None
            for attempt in range(retries + 1):
                self.runs.event(run_id, node_id, "running", {"label": label, "attempt": attempt + 1})
                self.core._emit({
                    "type": "graph_node_state", "run_id": run_id, "node_id": node_id,
                    "agent": label, "status": "running", "attempt": attempt + 1,
                })
                try:
                    result = self._execute_node(node, state, run_id, mode, decider)
                    break
                except Exception as exc:  # noqa: BLE001
                    error = self._redact(str(exc), run_id)
                    if attempt < retries and not self.core._interrupt.is_set():
                        self.runs.event(run_id, node_id, "retrying", {"error": error, "attempt": attempt + 1})
                        self.core._emit({
                            "type": "graph_node_state", "run_id": run_id, "node_id": node_id,
                            "agent": label, "status": "retrying", "error": error, "attempt": attempt + 1,
                        })
                        continue
                    self.runs.event(run_id, node_id, "failed", {"error": error, "attempt": attempt + 1})
                    self.core._emit({
                        "type": "graph_node_state", "run_id": run_id, "node_id": node_id,
                        "agent": label, "status": "failed", "error": error, "attempt": attempt + 1,
                    })
                    if self._workflow(run_id).get("settings", {}).get("failure_policy") == "continue":
                        return {"outputs": {node_id: {"error": error}}, "errors": [{"node_id": node_id, "error": error}]}
                    raise
            assert result is not None
            duration = max(int((time.monotonic() - started) * 1000), 0)
            self.runs.event(run_id, node_id, "completed", {"duration_ms": duration})
            self.core._emit({
                "type": "graph_node_state", "run_id": run_id, "node_id": node_id,
                "agent": label, "status": "completed", "duration_ms": duration,
            })
            return result

        return call

    def _execute_node(self, node: dict[str, Any], state: WorkflowState, run_id: str, mode: str, decider: Any) -> dict[str, Any]:
        node_id = str(node["id"])
        node_type = str(node["type"])
        config = dict(node.get("config") or {})
        if node_type == "input":
            return {"outputs": {node_id: state.get("goal", "")}}
        if node_type == "memory":
            context = self._memory_text(state)
            return {"outputs": {node_id: context[-MAX_PROMPT_CHARS:]}}
        if node_type in {"model", "supervisor", "agent", "final"}:
            return self._model_node(node, state, run_id, mode)
        if node_type == "router":
            routes = self._evaluate_routes(config.get("rules") or [], state)
            return {"outputs": {node_id: {"routes": routes}}}
        if node_type == "tool_set":
            return self._tool_node(node, state, run_id, mode, decider)
        if node_type == "approval":
            payload = {
                "kind": "review", "run_id": run_id, "node_id": node_id,
                "title": node.get("label") or "Review workflow",
                "message": str(config.get("prompt") or "Review this workflow step before continuing."),
                "summary": self._outputs_text(state)[-4000:],
                "request_id": f"review-{run_id[:8]}-{node_id}",
            }
            decision = interrupt(payload)
            if str(decision) != "approve":
                raise WorkflowError("workflow review was rejected")
            return {"approvals": {node_id: "approved"}, "outputs": {node_id: "Approved"}}
        if node_type == "join":
            return {"outputs": {node_id: self._outputs_text(state)[-MAX_PROMPT_CHARS:]}}
        raise WorkflowError(f"unsupported node type: {node_type}")

    def _model_node(self, node: dict[str, Any], state: WorkflowState, run_id: str, mode: str) -> dict[str, Any]:
        node_id = str(node["id"])
        node_type = str(node["type"])
        config = dict(node.get("config") or {})
        client, model, context_limit = self._provider_for(node, run_id)
        system = self.core.system_message().get("content", "")
        prompt = str(config.get("prompt") or "")
        if mode == "plan":
            prompt += "\nThis is a Plan run. Do not request writes, commands, or external mutations."
        if node_type == "supervisor":
            allowed = [edge["target"] for edge in self._workflow(run_id)["edges"] if edge["source"] == node_id]
            prompt += f"\nChoose every useful next node from this exact list and finish with JSON only: {json.dumps(allowed)}"
        messages = [
            {"role": "system", "content": f"{system}\n\nWorkflow role: {prompt}"},
            {"role": "user", "content": f"Goal:\n{state.get('goal', '')}\n\nAvailable workflow results:\n{self._outputs_text(state)}"},
        ]
        requested_tools = [str(name) for name in config.get("tools") or []]
        schemas = self._schemas_for(requested_tools, mode, run_id) if node_type == "agent" else []
        content_parts: list[str] = []
        thinking_parts: list[str] = []
        final_node = node_type == "final"
        if final_node:
            self.core._emit({"type": "message_start", "run_id": run_id, "node_id": node_id, "agent": node["label"]})

        def on_token(token: str) -> None:
            content_parts.append(token)
            event = {
                "run_id": run_id, "node_id": node_id, "agent": node["label"],
                "text": token, "model": model, "context_limit": context_limit,
                "final_node": final_node,
            }
            if final_node:
                self.core._emit({"type": "token", **event})
            else:
                self.core._emit({"type": "graph_node_token", **event})

        def on_thinking(text: str) -> None:
            thinking_parts.append(text)
            self.core._emit({"type": "thinking", "text": text, "run_id": run_id, "node_id": node_id, "agent": node["label"]})

        response = client.chat_stream(
            model=model,
            messages=messages,
            tools=schemas,
            on_token=on_token,
            should_stop=self.core._interrupt.is_set,
            on_thinking=on_thinking,
            options=self.core.chat_options() if client is self.core.client else {},
        )
        if final_node:
            self.core._emit({"type": "message_end", "run_id": run_id, "node_id": node_id, "agent": node["label"]})
        content = response.content or "".join(content_parts)
        usage = {
            "prompt_tokens": int(response.prompt_eval_count or 0),
            "completion_tokens": int(response.eval_count or 0),
            "model": model,
            "context_limit": context_limit,
        }
        self.core._emit({
            "type": "graph_node_token",
            "run_id": run_id,
            "node_id": node_id,
            "agent": node["label"],
            "text": "",
            "model": model,
            "context_limit": context_limit,
            "prompt_tokens": usage["prompt_tokens"],
            "completion_tokens": usage["completion_tokens"],
            "final_node": final_node,
        })
        self.core.total_prompt_tokens += usage["prompt_tokens"]
        self.core.total_completion_tokens += usage["completion_tokens"]
        update: dict[str, Any] = {"outputs": {node_id: content}, "usage": {node_id: usage}}
        if response.tool_calls:
            update["pending_actions"] = {
                node_id: [
                    {"id": call.call_id or uuid.uuid4().hex, "name": call.name, "arguments": call.arguments}
                    for call in response.tool_calls
                ]
            }
        if node_type == "supervisor":
            update["outputs"] = {node_id: {"text": content, "routes": self._parse_routes(content)}}
        if final_node:
            update["final"] = content
        return update

    def _tool_node(self, node: dict[str, Any], state: WorkflowState, run_id: str, mode: str, decider: Any) -> dict[str, Any]:
        node_id = str(node["id"])
        allowed = {str(name) for name in (node.get("config") or {}).get("tools") or []}
        results: list[dict[str, Any]] = []
        cleared: dict[str, Any] = {}
        for source, actions in dict(state.get("pending_actions") or {}).items():
            if not isinstance(actions, list):
                continue
            for action in actions:
                name = str(action.get("name") or "")
                if allowed and name not in allowed:
                    results.append({"tool": name, "result": "Error: tool is not enabled by this Tool Set."})
                    continue
                arguments = action.get("arguments") if isinstance(action.get("arguments"), dict) else {}
                result = self._run_graph_tool(run_id, node_id, mode, name, arguments, str(action.get("id") or ""))
                results.append({"tool": name, "result": result})
            cleared[str(source)] = []
        return {"outputs": {node_id: results}, "pending_actions": cleared}

    def _run_graph_tool(self, run_id: str, node_id: str, mode: str, name: str, arguments: dict[str, Any], action_id: str) -> str:
        initial_info = self.core.tool_registry.tool_info(name) or {"origin": "builtin"}
        initial_read_only = self._is_read_only(name, initial_info)
        if mode == "plan" and not initial_read_only:
            return "Error: Plan workflows cannot run writes, commands, or untrusted external tools."
        call_id = action_id or uuid.uuid4().hex[:10]
        effect_id = hashlib.sha256(
            f"{run_id}:{node_id}:{call_id}:{name}:{json.dumps(arguments, sort_keys=True)}".encode()
        ).hexdigest()

        def authorize_and_execute() -> str:
            # This block runs at the head of the FIFO side-effect queue. Tool
            # metadata, previews, policy and schema trust are deliberately
            # refreshed here rather than when the model first proposed a call.
            info = self.core.tool_registry.tool_info(name) or {"origin": "builtin"}
            read_only = self._is_read_only(name, info)
            if read_only != initial_read_only:
                return "Error: tool capabilities changed while this workflow was running; propose the call again."
            summary, detail = build_preview(name, arguments, self.core.tool_ctx)
            blocked = self.core.perms.blocked_reason(name, arguments)
            if blocked:
                return f"Error: {blocked}."
            permission_key = name
            schema_digest = str(info.get("schema_digest") or "")
            fingerprint = str(info.get("server_fingerprint") or "")
            if schema_digest or fingerprint:
                material = f"{fingerprint}:{schema_digest}"
                permission_key = f"{name}@{hashlib.sha256(material.encode()).hexdigest()[:24]}"
            auto = self.core.tool_registry.is_safe(name) or self.core.perms.is_auto_allowed(
                permission_key,
                inside_workspace=self._inside_workspace(name, arguments),
            )
            snapshot = (self.runs.get(run_id).get("state") or {}).get("tool_schema_snapshot") or {}
            saved_schema = snapshot.get(name)
            saved_digest = str(
                saved_schema.get("digest") if isinstance(saved_schema, dict) else saved_schema or ""
            )
            live_schema = next(
                (
                    schema for schema in self.core.tool_registry.schemas()
                    if str((schema.get("function") or {}).get("name") or "") == name
                ),
                None,
            )
            schema_changed = bool(saved_digest and (
                live_schema is None or _digest(live_schema) != saved_digest
            ))
            if schema_changed:
                auto = False
                detail = f"{detail}\n\nCapability changed since this run started; approval is required again."
            metadata = {
                key: value for key, value in info.items()
                if key in {
                    "origin", "server_id", "server_name", "annotations",
                    "schema_digest", "server_fingerprint", "approval_mode",
                } and value is not None
            }
            previous_effect = self.runs.effect(effect_id)
            self.core._emit({
                "type": "tool_call_proposed", "id": call_id, "tool": name,
                "summary": summary, "detail": detail,
                "auto": auto or bool(previous_effect and previous_effect["status"] == "skipped"),
                "capability_changed": schema_changed,
                "run_id": run_id, "node_id": node_id, **metadata,
            })
            if previous_effect and previous_effect["status"] == "skipped":
                result = str(previous_effect.get("result") or "Skipped uncertain side effect.")
                self.core._emit({
                    "type": "tool_result", "id": call_id, "tool": name, "summary": summary,
                    "result": result, "ok": True, "denied": False, "skipped": True,
                    "run_id": run_id, "node_id": node_id, **metadata,
                })
                return result
            if previous_effect and previous_effect["status"] in {"completed", "failed"}:
                result = str(previous_effect.get("result") or "The side effect already finished before recovery.")
                self.core._emit({
                    "type": "tool_result", "id": call_id, "tool": name, "summary": summary,
                    "result": result, "ok": previous_effect["status"] == "completed",
                    "denied": False, "recovered": True,
                    "run_id": run_id, "node_id": node_id, **metadata,
                })
                return result
            if previous_effect and previous_effect["status"] == "started":
                raise WorkflowError(
                    f"the outcome of {name} is uncertain; inspect it before choosing skip or retry"
                )
            if not auto:
                payload = {
                    "kind": "tool_permission", "run_id": run_id, "node_id": node_id,
                    "tool": name, "summary": summary, "detail": detail,
                    "request_id": f"perm-{run_id[:8]}-{call_id}",
                    "tool_call_id": call_id,
                    "permission_key": permission_key,
                }
                decision = str(interrupt(payload))
                if decision == "always":
                    self.core.perms.allow_tool(permission_key)
                if decision not in {"once", "always"}:
                    result = f"Permission denied: the user did not allow running {name}."
                    self.core._emit({
                        "type": "tool_result", "id": call_id, "tool": name, "summary": summary,
                        "result": result, "ok": False, "denied": True,
                        "run_id": run_id, "node_id": node_id, **metadata,
                    })
                    return result
            if not read_only:
                self.runs.begin_effect(run_id, node_id, name, detail, effect_id)
            result = (
                execute_tool(name, arguments, self.core.tool_ctx)
                if info.get("origin") == "builtin"
                else self.core.tool_registry.execute(name, arguments, self.core.tool_ctx)
            )
            if not read_only:
                self.runs.finish_effect(effect_id, result, "completed" if not result.startswith("Error") else "failed")
            self.core._emit({
                "type": "tool_result", "id": call_id, "tool": name, "summary": summary,
                "result": result, "ok": not result.startswith("Error"), "denied": False,
                "run_id": run_id, "node_id": node_id, **metadata,
            })
            return result

        return self.side_effects.run(not initial_read_only, authorize_and_execute)

    def _provider_for(self, node: dict[str, Any], run_id: str) -> tuple[Any, str, int]:
        binding = (node.get("config") or {}).get("model_binding") or {}
        account_id = str(binding.get("account_id") or "")
        requested_model = str(binding.get("model") or "")
        if not account_id:
            return self.core.client, requested_model or self.core.model, self.core.context_limit
        credential = self._credentials.get(run_id, {}).get(account_id)
        if credential is None:
            raise WorkflowError(f"provider credentials are missing for account {account_id}")
        provider = str(credential.get("provider") or "remote")
        model = requested_model or str(credential.get("model") or "")
        context_limit = int(credential.get("context_window") or 0)
        if provider == "ollama":
            return OllamaClient(str(credential.get("host") or self.core.host)), model, context_limit
        client = RemoteClient(
            base_url=str(credential.get("base_url") or ""),
            api_key=str(credential.get("api_key") or ""),
            model=model,
            auth_style=str(credential.get("auth_style") or ""),
            lists_models=bool(credential.get("lists_models", True)),
        )
        return client, model, context_limit

    def _schemas_for(self, requested: list[str], mode: str, run_id: str) -> list[dict[str, Any]]:
        snapshot = (self.runs.get(run_id).get("state") or {}).get("tool_schema_snapshot") or {}
        schemas = [
            deepcopy(value["schema"])
            for value in snapshot.values()
            if isinstance(value, dict) and isinstance(value.get("schema"), dict)
        ]
        if not schemas:  # Tolerate runs created by the digest-only preview implementation.
            current = self.core.tool_registry.schemas()
            schemas = [
                schema for schema in current
                if not snapshot or snapshot.get(str((schema.get("function") or {}).get("name"))) == _digest(schema)
            ]
        if requested:
            schemas = [schema for schema in schemas if str((schema.get("function") or {}).get("name")) in requested]
        if mode == "plan":
            schemas = [
                schema for schema in schemas
                if self._is_read_only(
                    str((schema.get("function") or {}).get("name")),
                    self.core.tool_registry.tool_info(str((schema.get("function") or {}).get("name"))) or {"origin": "builtin"},
                )
            ]
        return schemas

    @staticmethod
    def _is_read_only(name: str, info: dict[str, Any]) -> bool:
        if info.get("origin") == "builtin":
            return name in SAFE_TOOLS or name in {"git_status", "git_diff", "search_extension_tools", "load_skill", "read_skill_file"}
        annotations = info.get("annotations") or {}
        return bool(annotations.get("readOnlyHint") or annotations.get("read_only")) and not bool(
            annotations.get("openWorldHint") or annotations.get("open_world")
        )

    def _inside_workspace(self, name: str, arguments: dict[str, Any]) -> bool:
        path = arguments.get("path")
        if name == "glob" and not path:
            path = arguments.get("pattern")
        if not isinstance(path, str) or not path.strip():
            return True
        return self.core.tool_ctx.is_inside_workspace(self.core.tool_ctx.resolve(path))

    def _route_callable(self, node_id: str, node: dict[str, Any], edges: list[dict[str, Any]]) -> Callable[[WorkflowState], list[str] | str]:
        targets = [str(edge["target"]) for edge in edges]

        def route(state: WorkflowState) -> list[str] | str:
            output = dict(state.get("outputs") or {}).get(node_id)
            selected: list[str] = []
            if isinstance(output, dict):
                selected = [str(item) for item in output.get("routes") or [] if str(item) in targets]
            if node.get("type") == "agent":
                pending = dict(state.get("pending_actions") or {}).get(node_id) or []
                tool_targets = [edge["target"] for edge in edges if edge.get("source_port") == "tools"]
                final_targets = [edge["target"] for edge in edges if edge.get("source_port") != "tools"]
                selected = tool_targets if pending else final_targets
            conditional_targets = {
                str(edge["target"])
                for edge in edges
                if "condition" not in edge or self._condition_matches(edge["condition"], state)
            }
            if any("condition" in edge for edge in edges):
                selected = [target for target in (selected or targets) if target in conditional_targets]
            return selected or targets[:1]

        return route

    @staticmethod
    def _condition_matches(condition: dict[str, Any], state: WorkflowState) -> bool:
        operation = str(condition.get("operation") or "")
        outputs = state.get("outputs") or {}
        current: Any = outputs
        path = str(condition.get("path") or "outputs")
        if path not in {"", "outputs"}:
            for part in path.removeprefix("outputs.").split("."):
                if isinstance(current, dict) and part in current:
                    current = current[part]
                else:
                    current = None
                    break
        value = condition.get("value")
        if operation == "equals":
            return current == value
        if operation == "contains":
            return str(value or "").lower() in json.dumps(current, default=str).lower()
        if operation == "exists":
            return current is not None
        if operation == "success":
            return not state.get("errors")
        return bool(state.get("errors"))

    @staticmethod
    def _evaluate_routes(rules: Iterable[Any], state: WorkflowState) -> list[str]:
        outputs = state.get("outputs") or {}
        selected: list[str] = []
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            operation = str(rule.get("operation") or "contains")
            value = rule.get("value")
            target = str(rule.get("target") or "")
            path = str(rule.get("path") or "outputs")
            current: Any = outputs
            if path not in {"", "outputs"}:
                for part in path.removeprefix("outputs.").split("."):
                    if not part:
                        continue
                    if isinstance(current, dict) and part in current:
                        current = current[part]
                    else:
                        current = None
                        break
            current_text = json.dumps(current, default=str).lower()
            matched = (
                (operation == "contains" and str(value or "").lower() in current_text)
                or (operation == "equals" and current == value)
                or (operation == "exists" and current is not None)
                or (operation == "success" and not state.get("errors"))
                or (operation == "failure" and bool(state.get("errors")))
            )
            if matched and target:
                selected.append(target)
        return selected

    @staticmethod
    def _parse_routes(content: str) -> list[str]:
        try:
            value = json.loads(content[content.find("["): content.rfind("]") + 1])
        except (ValueError, json.JSONDecodeError):
            return []
        return [str(item) for item in value] if isinstance(value, list) else []

    @staticmethod
    def _outputs_text(state: WorkflowState) -> str:
        return json.dumps(state.get("outputs") or {}, ensure_ascii=False, indent=2, default=str)[-MAX_PROMPT_CHARS:]

    def _memory_text(self, state: WorkflowState) -> str:
        messages = state.get("base_messages") or []
        conversation = "\n".join(
            f"{message.get('role', 'message')}: {str(message.get('content') or '')}"
            for message in messages[-20:]
        )
        project = ""
        if self.core.project_context:
            project = f"\n{self.core.project_context[0]}:\n{self.core.project_context[1]}"
        return f"Conversation:\n{conversation}\nProject context:{project}\nGoal:\n{state.get('goal', '')}"

    def _workflow(self, run_id: str) -> dict[str, Any]:
        return self.runs.get(run_id)["workflow"]

    def _emit_interrupt(self, run_id: str, payload: dict[str, Any]) -> None:
        if payload.get("kind") == "tool_permission":
            self.core._emit({
                "type": "permission_request",
                "request_id": payload["request_id"],
                "id": payload.get("tool_call_id") or payload["request_id"],
                "tool": payload.get("tool") or "tool",
                "summary": payload.get("summary") or "Tool permission",
                "detail": payload.get("detail") or "",
                "preview": {"summary": payload.get("summary") or "", "detail": payload.get("detail") or ""},
                "run_id": run_id,
                "node_id": payload.get("node_id") or "",
            })
        else:
            self.core._emit({
                "type": "graph_review_request",
                "request_id": payload["request_id"],
                "run_id": run_id,
                "node_id": payload.get("node_id") or "",
                "title": payload.get("title") or "Review workflow",
                "message": payload.get("message") or "",
                "summary": payload.get("summary") or "",
            })

    def _redact(self, text: str, run_id: str) -> str:
        output = text
        for credential in self._credentials.get(run_id, {}).values():
            key = str(credential.get("api_key") or "")
            if key:
                output = output.replace(key, "[redacted]")
        return output[:4000]
