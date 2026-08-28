"""System health, tool, permission, service, and configuration routes."""

from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException

from .. import __version__
from ..capabilities import snapshot as capability_snapshot
from ..chat_service import AgentBusyError, ChatService
from ..config import (
    MAX_ITERATIONS_CEILING,
    MINIMUM_CONTEXT_WINDOW,
    context_window,
    non_negative_int,
    save_config,
)
from ..core import AgentCore
from ..devserver import DevServerError
from ..ollama import OllamaError
from .dependencies import get_service
from .providers import chatgpt_account_payload

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def _busy_http() -> HTTPException:
    return HTTPException(409, "agent is busy — interrupt the current turn first")


def health(service: ServiceDependency) -> dict[str, Any]:
    if service.core.provider == "chatgpt":
        state = chatgpt_account_payload(service)
        reachable = state["status"] == "signed_in"
        error = None if reachable else state.get("message") or "ChatGPT sign-in is required"
    else:
        try:
            service.core.client.check()
            reachable = True
            error = None
        except OllamaError as exc:
            reachable = False
            error = str(exc)
    return {
        "ok": True,
        "version": __version__,
        # `ollama` remains the compatibility field for backend reachability,
        # whichever provider currently owns model execution.
        "ollama": reachable,
        "host": service.core.host,
        "model": service.core.model,
        "error": error,
        "provider": service.core.provider,
        "capabilities": capability_snapshot(),
    }


def list_tools(service: ServiceDependency) -> dict[str, Any]:
    registry = service.core.tool_registry
    registry.refresh()
    return {"tools": registry.metadata()}


def background_service_list(service: ServiceDependency) -> dict[str, Any]:
    """List task-independent servers, watchers, and workers owned by Locus."""
    return {"services": service.dev_servers.status()}


def background_service_start(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        raw_port = body.get("port")
        port = int(raw_port) if raw_port not in (None, "") else None
        if port is not None and not 1 <= port <= 65_535:
            raise DevServerError("port must be between 1 and 65535")
        result = service.dev_servers.start(
            command=str(body.get("command") or ""),
            cwd=str(body.get("cwd") or "") or service.core.execution_path,
            port=port,
            name=str(body.get("name") or ""),
            # A direct user action has no chat turn to cancel it.
            should_stop=None,
        )
        return {"ok": True, "service": result}
    except (DevServerError, ValueError) as exc:
        raise HTTPException(422, str(exc)) from exc


def background_service_stop(
    name: str,
    service: ServiceDependency,
) -> dict[str, Any]:
    stopped = service.dev_servers.stop(name)
    if not stopped:
        raise HTTPException(404, "background service not found or no longer running")
    return {"ok": True, "stopped": stopped}


def get_permissions(service: ServiceDependency) -> dict[str, Any]:
    return service.core.perms.state()


def set_permissions(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    try:
        with service.state_mutation():
            mode = str(body.get("mode") or "").strip()
            if mode:
                if mode not in ("ask", "accept_edits", "bypass"):
                    raise HTTPException(422, "mode must be ask, accept_edits or bypass")
                service.core.perms.set_mode(mode)
                service.core.config["permission_mode"] = mode
            if body.get("reset"):
                service.core.perms.reset()
                service.core.config["permission_mode"] = "ask"
            save_config(service.core.config)
            service.queue_event({"type": "session_info", **service.core.session_info()})
            return service.core.perms.state()
    except AgentBusyError as exc:
        raise _busy_http() from exc


def _config_state(core: AgentCore) -> dict[str, Any]:
    return {
        "model": core.model,
        "host": core.host,
        "cwd": core.cwd,
        "max_iterations": core.max_iterations,
        # 0 means "follow the environment"; session_info contains the window
        # that setting resolved to for the current model.
        "context_window": context_window(core.config.get("context_window")),
        "terminal_shell": str(core.config.get("terminal_shell") or ""),
        "terminal_login_shell": bool(core.config.get("terminal_login_shell", True)),
        "session_info": core.session_info(),
    }


def get_config(service: ServiceDependency) -> dict[str, Any]:
    return _config_state(service.core)


def post_config(
    service: ServiceDependency,
    body: dict[str, Any] = Body(default_factory=dict),
) -> dict[str, Any]:
    # Reserve mutable state before applying fields because model and workspace
    # changes both have persistent side effects.
    try:
        with service.state_mutation():
            return _apply_config(service, body)
    except AgentBusyError as exc:
        raise _busy_http() from exc


def _apply_config(service: ChatService, body: dict[str, Any]) -> dict[str, Any]:
    """Apply config after atomically reserving mutable state."""
    terminal_shell: str | None = None
    terminal_login_shell: bool | None = None
    if "terminal_shell" in body:
        raw_shell = body.get("terminal_shell")
        if not isinstance(raw_shell, str) or len(raw_shell) > 4_096:
            raise HTTPException(422, "terminal_shell must be a string")
        terminal_shell = raw_shell.strip()
    if "terminal_login_shell" in body:
        raw_login_shell = body.get("terminal_login_shell")
        if not isinstance(raw_login_shell, bool):
            raise HTTPException(422, "terminal_login_shell must be true or false")
        terminal_login_shell = raw_login_shell
    model = str(body.get("model") or "").strip()
    cwd = str(body.get("cwd") or "").strip()
    if model:
        service.core.set_model(model)
    if cwd:
        try:
            service.core.set_cwd(cwd)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
    if "context_window" in body:
        requested = body.get("context_window")
        resolved = context_window(requested)
        if resolved <= 0 and non_negative_int(requested) > 0:
            raise HTTPException(
                422,
                f"context_window must be at least {MINIMUM_CONTEXT_WINDOW} tokens, "
                "or 0 to let Ollama size the window",
            )
        service.core.config["context_window"] = resolved
        service.core.refresh_context_limit()
        save_config(service.core.config)
        service.emit({"type": "session_info", **service.core.session_info()})
    if "max_iterations" in body:
        requested = body.get("max_iterations")
        resolved = non_negative_int(requested)
        if resolved <= 0 or resolved > MAX_ITERATIONS_CEILING:
            raise HTTPException(
                422,
                f"max_iterations must be between 1 and {MAX_ITERATIONS_CEILING}",
            )
        service.core.max_iterations = resolved
        service.core.config["max_iterations"] = resolved
        save_config(service.core.config)
        service.emit({"type": "session_info", **service.core.session_info()})
    terminal_changed = False
    if terminal_shell is not None:
        service.core.config["terminal_shell"] = terminal_shell
        terminal_changed = True
    if terminal_login_shell is not None:
        service.core.config["terminal_login_shell"] = terminal_login_shell
        terminal_changed = True
    if terminal_changed:
        save_config(service.core.config)
    return _config_state(service.core)


def reload_project_context(service: ServiceDependency) -> dict[str, Any]:
    """Reload AGENTS.md-compatible project context after an editor save."""
    try:
        with service.state_mutation():
            service.core.reload_context()
            service.core.reset_system_message()
            service.queue_event({"type": "session_info", **service.core.session_info()})
            return {
                "ok": True,
                "file": (
                    service.core.project_context[0]
                    if service.core.project_context
                    else None
                ),
            }
    except AgentBusyError as exc:
        raise _busy_http() from exc


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/health", health, methods=["GET"])
    router.add_api_route("/api/tools", list_tools, methods=["GET"])
    router.add_api_route("/api/services", background_service_list, methods=["GET"])
    router.add_api_route("/api/services", background_service_start, methods=["POST"])
    router.add_api_route(
        "/api/services/{name}", background_service_stop, methods=["DELETE"]
    )
    router.add_api_route("/api/permissions", get_permissions, methods=["GET"])
    router.add_api_route("/api/permissions", set_permissions, methods=["POST"])
    router.add_api_route("/api/config", get_config, methods=["GET"])
    router.add_api_route("/api/config", post_config, methods=["POST"])
    router.add_api_route("/api/context/reload", reload_project_context, methods=["POST"])
