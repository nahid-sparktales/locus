"""Connect session collaboration to independent provider-neutral AgentCore instances."""

from __future__ import annotations

import copy
import json
import threading
from concurrent.futures import Future, InvalidStateError, TimeoutError
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .codex_app_server import CodexThreadOptions
from .collaboration import ACTIVE_STATES, SoloCollaborationManager, WorkerSpec
from .core import _SOLO_ROOT_ONLY_TOOLS, AgentCore
from .orchestration import GLOBAL_MODEL_SCHEDULER
from .permissions import PermissionManager
from .tool_registry import parity_to_canonical
from .tools import TOOL_SCHEMAS

POLICY_VERSION = "balanced-v2"
_PARENT_MESSAGE_SCHEMA = {
    "type": "function",
    "function": {
        "name": "send_parent_message",
        "description": "Send a concise progress update, finding, or clarification request to your owning root while you continue working. This never messages the user or another helper.",
        "parameters": {
            "type": "object",
            "properties": {"text": {"type": "string", "minLength": 1, "maxLength": 12000}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
}


class _Transcript:
    """Helper transcripts are checkpointed by the collaboration store, not sidebar tasks."""

    def __init__(self):
        self.session_id = "helper"
        self.path = Path("helper")
        self.events: list[dict[str, Any]] = []

    def append(self, value):
        self.events.append(copy.deepcopy(value))

    def append_once(self, value, event_id):
        if any(e.get("event_id") == event_id for e in self.events):
            return False
        self.append({**value, "event_id": event_id})
        return True


class _HelperCore(AgentCore):
    def _new_session_store(self):
        return _Transcript()

    def remember_window_cap(self, model: str, cap: int) -> None:
        if model and cap > 0:
            current = self.config.get("model_window_caps")
            self.config["model_window_caps"] = {
                **(current if isinstance(current, dict) else {}),
                self._window_key(model): cap,
            }

    def remember_model_window(self, model: str, window: int) -> None:
        if model and window > 0:
            current = self.config.get("model_windows")
            self.config["model_windows"] = {
                **(current if isinstance(current, dict) else {}),
                self._window_key(model): window,
            }


class _HelperNativeTransport:
    """Multiplex the account transport without changing its root-wide contract."""

    supports_parity = False

    def __init__(self, manager: Any, runtime: AgentWorkerRuntime):
        self._manager, self._runtime = manager, runtime
        self.thread_defaults = CodexThreadOptions()

    def __getattr__(self, name):
        return getattr(self._manager, name)

    def set_thread_defaults(self, options):
        # Native builtin tools stay disabled; only the inherited dynamic tools
        # can execute. Never rewrite the account home or restart its process.
        self.thread_defaults = CodexThreadOptions()

    def start_thread(self, **kwargs):
        return self._manager.start_thread(**{**kwargs, "options": self.thread_defaults})

    def resume_thread(self, thread_id, **kwargs):
        return self._manager.resume_thread(thread_id, **{**kwargs, "options": self.thread_defaults})

    def run_turn(self, **kwargs):
        with self._runtime._model_slot():
            return self._manager.run_turn(**kwargs)


class _WorkerServiceView:
    """Reuse native brokers while keeping their core/context helper-local."""

    def __init__(self, svc, core, spec, runtime):
        self._service, self.core, self.spec = svc, core, spec
        self._runtime = runtime
        self.active_run_id = spec.run_id

    def __getattr__(self, name):
        value = getattr(self._service, name)
        if getattr(value, "__self__", None) is self._service and hasattr(value, "__func__"):
            return value.__func__.__get__(self, type(self))
        return value

    def emit(self, event):
        if not self._runtime._native_action_requested(event):
            return
        # Serialize only the final dispatch with cancellation. Persistence
        # above must not hold this lock while entering the manager's lock.
        with self._runtime._native_action_guard:
            identifier = str(event.get("request_id") or "")
            future = self._runtime._native_actions.get(identifier)
            if future is not None and self._runtime._should_stop():
                self._runtime._native_action_records[identifier]["state"] = "not_sent"
                self._runtime._cancel_native_future(future, uncertain=False)
                return
            self._service.emit(
                {
                    **event,
                    **self.core.tool_event_context,
                    "session_id": self.spec.session_id,
                    "run_id": self.spec.run_id,
                }
            )


class AgentWorkerRuntime:
    def __init__(self, svc: Any, spec: WorkerSpec, mutation_lock: Any, send_parent_message=None):
        self.spec, self.svc = spec, svc
        parent = svc.core
        if parent.identity_mode:
            raise ValueError("Private Identity tasks cannot delegate helper context.")
        self.core = core = _HelperCore(
            cwd=spec.execution_path,
            config=copy.deepcopy(parent.config),
            model=parent.model,
            host=parent.host,
        )
        from .goal_runtime import attach_goal_runtime
        attach_goal_runtime(core, getattr(svc, "goal_runtime", None), coordinator=False)
        if core.goal_runtime is not None:
            core.goal_checkpoint = self._persist
        self._should_stop = core._interrupt.is_set
        self._on_checkpoint = None
        self._mailbox_ack_seq = int(spec.checkpoint.get("mailbox_ack_seq") or 0)
        self._mailbox_pending = copy.deepcopy(spec.checkpoint.get("mailbox_pending") or {})
        self._native_action_guard = threading.RLock()
        self._native_actions: dict[str, Future] = {}
        self._native_action_records = copy.deepcopy(spec.checkpoint.get("native_actions") or {})
        self.scheduler = getattr(svc, "collaboration_scheduler", GLOBAL_MODEL_SCHEDULER)
        chat_stream = core.client.chat_stream

        def scheduled_chat_stream(*args, **kwargs):
            with self._model_slot():
                return chat_stream(*args, **kwargs)

        core.client.chat_stream = scheduled_chat_stream
        permission_state = parent.perms.state()
        core.perms = PermissionManager(
            mode=permission_state["mode"],
            always_allow=permission_state["always_allow"],
            deny_commands=permission_state["deny_commands"],
        )
        core.perms.allowed = set(permission_state["allowed"])
        if spec.mode == "edit":
            core.helper_parent_checkout = parent.cwd
        core.codex_manager = _HelperNativeTransport(svc.codex, self)
        core.session.session_id = spec.agent_id
        core._suppress_turn_done = True
        core.configure_agent(
            parent.agent_configuration.structured(),
            mode="plan" if spec.mode == "research" else parent.agent_mode,
            agent_id=spec.agent_id,
            role_contract=(
                f"You are {spec.label}, a scoped helper beneath the visible root. "
                f"Your execution checkout is {spec.execution_path}. Resolve every workspace path there. "
                "Retain your assignment across followups. Report evidence, changed files, validation, "
                "and unresolved questions to the root. You cannot ask the user or recursively delegate. "
                "Use send_parent_message to share progress or request clarification while continuing independent work. "
                "Do not modify another checkout, change Git branches, commit, or integrate your own result. "
                "Research mode forbids mutation. Editing work is isolated until the root reviews it."
            ),
        )
        core.tool_action_lock = mutation_lock
        core.tool_event_context = {
            "agent_id": spec.agent_id,
            "job_id": spec.agent_id,
            "agent_name": spec.label,
            "node_id": f"/root/{spec.agent_id}",
        }
        registry, source = core.tool_registry, parent.tool_registry
        for name in (
            "computer_enabled",
            "simulator_enabled",
            "browser_enabled",
            "browser_history_enabled",
            "browser_autofill_categories",
            "notes_enabled",
            "connector_connections",
            "_user_capability_policy",
            "_mcp_agent_policy",
            "_active_mcp",
            "_mcp_by_qualified",
            "_explicit_skill_context",
            "_startup_skill_context",
            "_loaded_skill_context",
        ):
            setattr(registry, name, copy.deepcopy(getattr(source, name)))
        registry.set_mcp_agent_policy(
            copy.deepcopy(source._mcp_agent_policy),
            access_ceiling="read_only" if spec.mode == "research" else source._agent_access_ceiling,
            role="researcher" if spec.mode == "research" else "writer",
        )
        self.execution_service = _WorkerServiceView(svc, core, spec, self)
        for name in (
            "computer_executor",
            "simulator_executor",
            "browser_executor",
            "notes_executor",
            "connector_executor",
        ):
            executor = getattr(parent, name)
            if getattr(executor, "__self__", None) is svc and hasattr(executor, "__func__"):
                executor = executor.__func__.__get__(
                    self.execution_service, type(self.execution_service)
                )
            if executor is not None:

                def scoped_executor(tool, arguments, request_id, executor=executor):
                    if self._should_stop():
                        return (
                            "Error: this helper was interrupted before the native action started."
                        )
                    try:
                        return executor(tool, arguments, request_id)
                    finally:
                        self._native_action_finished(request_id)

                executor = scoped_executor
            setattr(core, name, executor)

        def background_service(args):
            cwd = core.tool_ctx.resolve(str(args.get("cwd") or spec.execution_path))
            if not core.tool_ctx.is_inside_workspace(cwd):
                return "Error: helper services must execute inside the isolated checkout."
            return self.execution_service._execute_background_service({**args, "cwd": str(cwd)})

        core.tool_ctx.background_service = background_service
        core.tool_ctx.memory_workspace = parent.workspace_root
        core.tool_ctx.memory_session_id = spec.session_id
        core.tool_ctx.memory_run_id = spec.run_id
        from .model_usage import context_for
        core.usage_owner_task_id = context_for(parent)["task_id"]
        core.usage_store = svc.run_store
        core.mcp.task_store = svc.run_store
        core.mcp.context_provider = lambda: {
            "run_id": spec.run_id,
            "job_id": spec.agent_id,
            "tool_call_id": core.active_tool_call_id,
        }
        # Build canonical capabilities independently of the parent's wire aliases.
        schemas, parity_schemas = registry.schemas, registry.parity_schemas
        # The older team ceiling retains only permission-free builtins. Read
        # tools such as git_diff and web_fetch may still ask permission and
        # belong in a scoped research helper when the parent permits them.
        builtin_names = {s["function"]["name"] for s in TOOL_SCHEMAS}
        inherited_reads = {
            s["function"]["name"]: copy.deepcopy(s)
            for s in source.schemas()
            if spec.mode == "research"
            and registry.is_read_only_tool(s["function"]["name"])
            and s["function"]["name"] in builtin_names
        }

        def canonical_schemas():
            return list(
                {**inherited_reads, **{s["function"]["name"]: s for s in schemas()}}.values()
            )

        available = (
            {s["function"]["name"] for s in canonical_schemas()}
            - _SOLO_ROOT_ONLY_TOOLS
            - {"identity_vault"}
        )
        if spec.mode == "research":
            available = {name for name in available if registry.is_read_only_tool(name)}
        if spec.tools is not None:
            requested = {parity_to_canonical(name, {})[0] for name in spec.tools}
            if spec.mode == "research" and requested & {"bash", "exec_command"}:
                # The root's native surface uses shell for file inspection.
                # A research helper implements that intent with concrete read
                # tools, without inheriting arbitrary command execution.
                requested.update(
                    {"read_file", "glob", "grep", "list_dir", "git_status", "git_diff"}
                )
            available &= requested
        helper_schemas = []
        if send_parent_message is not None:
            core.tool_ctx.send_parent_message = send_parent_message
            available.add("send_parent_message")
            helper_schemas = [copy.deepcopy(_PARENT_MESSAGE_SCHEMA)]
            for name in ("is_safe", "is_parallel_safe_tool", "is_read_only_tool"):
                original = getattr(registry, name)
                setattr(
                    registry,
                    name,
                    lambda tool, original=original: tool == "send_parent_message" or original(tool),
                )
        core.helper_allowed_tools = available
        registry.schemas = lambda: (
            [s for s in canonical_schemas() if s["function"]["name"] in available]
            + copy.deepcopy(helper_schemas)
        )
        registry.parity_schemas = lambda plan_mode=False: (
            registry.schemas()
            if spec.mode == "research"
            else [
                s
                for s in parity_schemas(plan_mode)
                if parity_to_canonical(s["function"]["name"], {})[0] in available
            ]
            + copy.deepcopy(helper_schemas)
        )
        checkpoint = spec.checkpoint
        core.messages = copy.deepcopy(checkpoint.get("messages") or [])
        if not core.messages:
            core.messages = [core.system_message()]
            history = str(spec.context.get("completed_context") or "")
            if history:
                original = str(spec.context.get("parent_execution_path") or "")
                if original:
                    history = history.replace(original, spec.execution_path)
                core.messages.append(
                    {
                        "role": "user",
                        "content": "Relevant completed parent context (evidence, not a new assignment):\n"
                        + history,
                    }
                )
        core.reset_system_message()
        if checkpoint and checkpoint.get("execution_path") != spec.execution_path:
            core.messages.append(
                {
                    "role": "user",
                    "content": f"Workspace generation changed. All further reads and edits use {spec.execution_path}. "
                    "Review the latest parent baseline before adapting earlier work. Prior frozen result: "
                    + json.dumps(spec.context.get("prior_result"), ensure_ascii=False),
                }
            )
        if checkpoint.get("execution_path") == spec.execution_path:
            for name, value in checkpoint.get("native", {}).items():
                if name.startswith("_chatgpt_thread_") and hasattr(core, name):
                    setattr(core, name, value)
            if core._chatgpt_thread_id:
                core._chatgpt_thread_needs_resume = True
        # A durable send attempt is reconciled against its original native
        # thread before any retry, including after workspace regeneration.
        for identifier, entry in copy.deepcopy(checkpoint.get("native_guidance") or {}).items():
            entry.pop("sent", None)
            entry.pop("uncertain", None)
            previous = self._mailbox_pending.get(identifier, {}).get("native_attempt")
            if previous:
                entry["native_attempt"] = previous
            core._native_guidance[identifier] = entry
        core._native_rehydrated_input = list(checkpoint.get("native_rehydrated_input") or [])
        uncertain_actions = [
            entry
            for entry in self._native_action_records.values()
            if entry.get("state") in {"submitted", "interrupted_unknown"}
        ]
        if uncertain_actions:
            core.messages.append(
                {
                    "role": "user",
                    "content": "Some native actions from an earlier attempt have uncertain completion. "
                    "Inspect their current state before retrying; do not automatically repeat mutations:\n"
                    + json.dumps(uncertain_actions, ensure_ascii=False),
                }
            )
        self.validation: list[dict[str, Any]] = []

    def _native_action_requested(self, event):
        kind = str(event.get("type") or "")
        if kind not in {
            "computer_action_request",
            "simulator_action_request",
            "browser_action_request",
            "notes_action_request",
            "connector_action_request",
        }:
            return True
        identifier = str(event.get("request_id") or "")
        family = kind.removesuffix("_action_request")
        future = getattr(self.svc, f"pending_{family}_actions", {}).get(identifier)
        if future is None:
            return True
        with self._native_action_guard:
            self._native_actions[identifier] = future
            stopped = self._should_stop()
            self._native_action_records[identifier] = {
                "request_id": identifier,
                "family": family,
                "tool": event.get("tool"),
                "state": "not_sent" if stopped else "submitted",
            }
        self._persist()
        if stopped:
            self._cancel_native_future(future, uncertain=False)
        return not stopped

    def _native_action_finished(self, identifier):
        with self._native_action_guard:
            future = self._native_actions.pop(identifier, None)
            record = self._native_action_records.get(identifier)
            if (
                record is not None
                and record.get("state") == "submitted"
                and future is not None
                and future.done()
            ):
                record["state"] = "completed"
        if future is not None:
            self._persist()

    @staticmethod
    def _cancel_native_future(future, *, uncertain=True):
        if not future.done():
            try:
                future.set_result(
                    {
                        "error": "This helper was interrupted. "
                        + (
                            "The action may have executed; inspect state before retrying."
                            if uncertain
                            else "The native action was not sent."
                        )
                    }
                )
            except InvalidStateError:
                pass  # A real native response won the cancellation race.

    @contextmanager
    def _model_slot(self):
        event = {"run_id": self.spec.run_id, "agent_id": self.spec.agent_id}
        self.svc.emit({"type": "scheduler_lease_waiting", **event})
        with self.scheduler.lease(self.spec.run_id, self._should_stop) as lease_id:
            self.svc.emit({"type": "scheduler_lease_acquired", **event, "lease_id": lease_id})
            released = threading.Event()

            def heartbeat():
                while not released.wait(10):
                    if not self.scheduler.heartbeat(lease_id):
                        self.core.interrupt()
                        return

            thread = threading.Thread(target=heartbeat, name="locus-helper-lease", daemon=True)
            thread.start()
            try:
                yield
            finally:
                released.set()
                thread.join()
                self.svc.emit({"type": "scheduler_lease_released", **event, "lease_id": lease_id})

    def _persist(self):
        if self._on_checkpoint is not None:
            self._on_checkpoint(self.snapshot())

    def _delivery_applied(self, identifier):
        if identifier not in self._mailbox_pending:
            return
        self._mailbox_pending[identifier]["applied"] = True
        # Confirmations can arrive out of order. A later acknowledgment must
        # not skip an earlier input that is still pending native confirmation.
        for key, entry in sorted(self._mailbox_pending.items(), key=lambda item: item[1]["seq"]):
            if not entry.get("applied"):
                break
            self._mailbox_ack_seq = max(self._mailbox_ack_seq, entry["seq"])
            self._mailbox_pending.pop(key)
        self._persist()

    def _native_sent(self, identifier, thread_id, client_id):
        entry = self._mailbox_pending.get(identifier)
        if entry is None:
            return False
        entry["native_attempt"] = {"thread_id": thread_id, "client_id": client_id}
        self._persist()  # The attempt must survive before the transport can mutate.
        return True

    def _native_unsent(self, identifier):
        entry = self._mailbox_pending.get(identifier)
        if entry is not None:
            entry.pop("native_attempt", None)
            self._persist()

    def _reconcile_saved_mailbox(self):
        # Resolve saved native sends before a fresh model call can act. A
        # disconnect is not evidence that an earlier instruction was rejected.
        for identifier, entry in list(self._mailbox_pending.items()):
            attempt = entry.get("native_attempt")
            if not attempt or entry.get("applied"):
                continue
            history = self.core.codex_manager.read_thread(attempt["thread_id"])

            def contains(value, client_id=attempt["client_id"]):
                if isinstance(value, dict):
                    return (
                        value.get("clientId") == client_id
                        or value.get("clientUserMessageId") == client_id
                        or any(contains(child) for child in value.values())
                    )
                return isinstance(value, list) and any(contains(child) for child in value)

            if not contains(history):
                raise RuntimeError(
                    "A saved helper instruction has unconfirmed native delivery. "
                    "It is preserved and was not resent; resume after reconciliation."
                )
            self.core._native_guidance.pop(identifier, None)
            self.core._record_context_delivery(identifier, entry["text"])

    def _decide(self, tool_name, summary, detail, request_id):
        if self._should_stop():
            return "deny"
        if not hasattr(self.svc, "_pending_permissions_guard"):
            return self.svc.decide(tool_name, summary, detail, request_id)
        # Share the existing permission card/answer route while retaining a
        # cancellable wait owned by this helper, not all requests in the root.
        future: Future[str] = Future()
        with self.svc._pending_permissions_guard:
            self.svc.pending_permissions[request_id] = future
        try:
            while not self._should_stop():
                try:
                    return future.result(timeout=0.1)
                except TimeoutError:
                    continue
            self.svc.answer_permission(request_id, "deny")
            return "deny"
        finally:
            with self.svc._pending_permissions_guard:
                self.svc.pending_permissions.pop(request_id, None)

    def run(self, prompt, *, max_calls, should_stop, drain_messages, on_usage, on_checkpoint=None):
        core = self.core
        self._should_stop = lambda: core._interrupt.is_set() or should_stop()
        core.external_should_stop = should_stop
        self._on_checkpoint = on_checkpoint

        def deliveries():
            for value in drain_messages():
                identifier = f"helper-mail-{value['seq']}"
                if value["seq"] > self._mailbox_ack_seq:
                    self._mailbox_pending.setdefault(
                        identifier,
                        {
                            "delivery_id": identifier,
                            "request_id": identifier,
                            "seq": value["seq"],
                            "text": value["text"],
                        },
                    )
            return [
                copy.deepcopy(value)
                for value in self._mailbox_pending.values()
                if not value.get("applied")
            ]

        core.context_delivery_source = deliveries
        core.context_delivery_applied = self._delivery_applied
        core.context_delivery_native_sent = self._native_sent
        core.context_delivery_native_unsent = self._native_unsent
        self._reconcile_saved_mailbox()

        def emit(event):
            kind = event.get("type")
            if kind == "model_usage":
                on_usage(event)
            if kind == "tool_result":
                self.validation.append(
                    {k: event.get(k) for k in ("tool", "ok", "summary", "result")}
                )
                self.validation = self.validation[-30:]
            if kind in {
                "tool_call_proposed",
                "permission_request",
                "tool_result",
                "note",
                "error",
                "mcp_input_request",
            }:
                self.svc.emit({**event, **core.tool_event_context, "run_id": self.spec.run_id})

        core.on_event(emit)
        try:
            core.run_turn(
                prompt,
                self._decide,
                model_call_limit=max_calls,
                attachments=copy.deepcopy(self.spec.context.get("attachments") or [])
                if not self.spec.checkpoint
                else [],
            )
        except InterruptedError:
            return {"output": "", "reason": "interrupted", "validation": self.validation}
        result = dict(core.last_turn_result)
        usage = {
            key: int(result.get(key) or 0)
            for key in ("model_calls", "prompt_tokens", "completion_tokens")
        }
        output = core._last_final_answer_text()
        if should_stop() and result.get("reason") not in {"complete", "completed"}:
            result["reason"] = (
                "model_call_budget" if usage["model_calls"] >= max_calls else "interrupted"
            )
        return {
            "output": output,
            "reason": result.get("reason", "error"),
            "usage": usage,
            "validation": self.validation,
        }

    def snapshot(self):
        with self._native_action_guard:
            native_actions = copy.deepcopy(dict(list(self._native_action_records.items())[-50:]))
        return {
            "messages": copy.deepcopy(self.core.messages),
            "execution_path": self.spec.execution_path,
            "native": {
                name: value
                for name, value in vars(self.core).items()
                if name.startswith("_chatgpt_thread_")
            },
            "mailbox_ack_seq": self._mailbox_ack_seq,
            "mailbox_pending": copy.deepcopy(self._mailbox_pending),
            "native_guidance": copy.deepcopy(self.core._native_guidance),
            "native_rehydrated_input": list(self.core._native_rehydrated_input),
            "native_actions": native_actions,
        }

    def interrupt(self):
        self.core.interrupt()
        self.core.mcp.cancel_pending_inputs()
        with self._native_action_guard:
            pending = list(self._native_actions.items())
            for identifier, future in pending:
                if not future.done():
                    self._native_action_records[identifier]["state"] = "interrupted_unknown"
        for _, future in pending:
            self._cancel_native_future(future)
        if pending:
            self._persist()

    def close(self):
        self.core.close()


class CollaborationBridge:
    def __init__(self, svc: Any, run_id: str, attachments=None):
        self.svc, self.core = svc, svc.core
        self.cursor = 0
        self.pending: dict[str, dict[str, Any]] = {}
        self.context = {
            "completed_context": "\n\n".join(
                f"{m['role']}: {str(m.get('content') or '')[:12000]}"
                for m in self.core.messages[-50:]
                if m.get("role") in {"user", "assistant"} and m.get("content")
            )[-80000:],
            "parent_execution_path": self.core.cwd,
            "attachments": copy.deepcopy(attachments or []),
        }
        self.lock = threading.RLock()
        self.manager = SoloCollaborationManager(
            session_id=self.core.session.session_id,
            run_id=run_id,
            execution_path=self.core.cwd,
            workspace_root=self.core.workspace_root,
            worker_factory=lambda spec: AgentWorkerRuntime(
                svc,
                spec,
                self.lock,
                send_parent_message=lambda text: self.manager.send_parent_message(
                    spec.agent_id, text
                ),
            ),
            emit=svc.emit,
            should_stop=self.core._interrupt.is_set,
            plan_mode=self.core.agent_mode in {"plan", "grill"},
            mutation_lock=self.lock,
        )

    def call(self, name: str, args: dict[str, Any]) -> str:
        manager = self.manager
        identifier = str(args.get("agent_id") or "")
        self.svc.emit(
            {"type": "delegation_attempt", "tool": name, "policy_version": POLICY_VERSION}
        )
        try:
            if name == "spawn_agent":
                if args.get("tools") is not None and (
                    not isinstance(args["tools"], list)
                    or not all(isinstance(v, str) for v in args["tools"])
                    or len(args["tools"]) > 200
                ):
                    raise ValueError("tools must be a bounded list of tool names")
                if (
                    args.get("mode") == "edit"
                    and not self.core.agent_configuration.capability_policy.workspace_write
                ):
                    raise ValueError(
                        "Workspace writing is disabled for this task; use a research helper."
                    )
                value = manager.spawn(
                    str(args.get("task") or ""),
                    label=str(args.get("label") or "Helper"),
                    mode=str(args.get("mode") or "research"),
                    context=copy.deepcopy(self.context),
                    tools=args.get("tools"),
                )
            elif name == "list_agents":
                value = manager.list_agents()
            elif name == "read_agent":
                value = manager.read(identifier)
            elif name == "send_agent_message":
                value = manager.send_message(identifier, str(args.get("text") or ""))
            elif name == "followup_agent":
                value = manager.followup(identifier, str(args.get("text") or ""))
            elif name == "interrupt_agent":
                value = manager.interrupt(identifier)
            elif name == "resume_agent":
                value = manager.resume(
                    identifier, str(args.get("prompt") or args.get("text") or "Continue the assignment.")
                )
            elif name == "wait_agents":
                value = manager.wait(
                    args.get("agent_ids"),
                    after_cursor=int(args.get("after_cursor") or 0),
                    timeout_ms=int(args.get("timeout_ms", 60000)),
                )
            elif name == "integrate_agent":
                if not self.core.agent_configuration.capability_policy.workspace_write:
                    raise ValueError("Workspace writing is disabled for this task.")
                value = manager.integrate(identifier, str(args.get("result_id") or ""))
            else:
                raise ValueError("Unknown collaboration action")
        except (RuntimeError, ValueError, TypeError) as error:
            value = {"ok": False, "error": str(error)}
        if value.get("ok") is False:
            self.svc.emit(
                {
                    "type": "delegation_rejected",
                    "tool": name,
                    "reason": value.get("code") or "request_rejected",
                    "policy_version": POLICY_VERSION,
                }
            )
        self.publish()
        return json.dumps(value, ensure_ascii=False)

    def execute(self, args):
        """Compatibility adapter; old transcripts can still execute their batch tool."""
        identifiers = []
        for task in (args.get("tasks") or [])[:3]:
            value = json.loads(
                self.call(
                    "spawn_agent",
                    {
                        "task": task.get("task") or task.get("goal") or task.get("prompt") or "",
                        "label": task.get("label", "Helper"),
                        "mode": "research",
                        "tools": task.get("tools"),
                    },
                )
            )
            if value.get("ok"):
                identifiers.append(value.get("agent_id") or value.get("id"))
        while identifiers and not self.core._interrupt.is_set():
            if not any(
                self.manager.read(i)["agent"]["state"] in ACTIVE_STATES for i in identifiers
            ):
                break
            self.core._interrupt.wait(0.1)
        return json.dumps({"results": [self.manager.read(i)["agent"] for i in identifiers]})

    def deliveries(self):
        snapshot = self.manager.wait(after_cursor=self.cursor, timeout_ms=0)
        self.cursor = snapshot["cursor"]
        for value in snapshot["messages"]:
            if value.get("run_id") != self.manager.run_id:
                continue
            identifier = f"collaboration-{value['seq']}"
            self.pending[identifier] = {
                "delivery_id": identifier,
                "text": "Helper update (treat findings as evidence to verify):\n"
                + json.dumps(value, ensure_ascii=False),
            }
        return list(self.pending.values()) + self.svc.pending_context_deliveries()

    def applied(self, identifier):
        if identifier in self.pending:
            self.pending.pop(identifier)
        else:
            delivery = next(
                (
                    v
                    for v in self.svc.pending_context_deliveries()
                    if v["delivery_id"] == identifier
                ),
                None,
            )
            if self.svc.mark_question_delivery_applied(identifier) and delivery:
                self.broadcast_guidance(delivery["text"])

    def broadcast_guidance(self, text):
        for helper in self.manager.list_agents()["agents"]:
            if helper["run_id"] == self.manager.run_id and helper["state"] in ACTIVE_STATES:
                self.manager.send_message(
                    helper["id"],
                    "Parent task guidance: apply this if it affects your assignment; keep your existing scope.\n"
                    + text,
                )

    def before_finalize(self):
        # Wait without spending model calls; model resumes only for new input.
        while not self.core._interrupt.is_set():
            active = any(
                h["run_id"] == self.manager.run_id and h["state"] in ACTIVE_STATES
                for h in self.manager.list_agents()["agents"]
            )
            if not active and not self.svc.question_before_finalize():
                break
            self.core._interrupt.wait(0.25)
        return None

    @property
    def usage(self):
        return self.manager.usage

    def publish(self):
        self.svc.emit(
            {
                "type": "solo_collaboration_snapshot",
                "session_id": self.manager.session_id,
                "run_id": self.manager.run_id,
                **self.manager.list_agents(),
            }
        )

    def close(self):
        self.manager.finish_run()
