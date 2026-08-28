"""Workspace source-control inspection routes and handlers."""

from typing import Annotated, Any

from fastapi import APIRouter, Depends

from .. import gitinfo
from ..chat_service import ChatService
from .dependencies import get_service

ServiceDependency = Annotated[ChatService, Depends(get_service)]


def git_status(
    service: ServiceDependency,
    untracked: str = "normal",
) -> dict[str, Any]:
    """Return working-tree status without blocking the event loop.

    This is deliberately synchronous so Starlette runs it in a threadpool.
    It remains available while an agent turn is editing the workspace.
    """
    return gitinfo.status(service.core.cwd, untracked=untracked)


def git_diff(
    path: str,
    service: ServiceDependency,
    staged: bool = False,
    context: int = 3,
    max_bytes: int = gitinfo.MAX_DIFF_BYTES,
) -> dict[str, Any]:
    """Return a bounded unified diff for one workspace-relative file."""
    return gitinfo.file_diff(
        service.core.cwd,
        path=path,
        staged=staged,
        context=context,
        max_bytes=max(1_000, min(max_bytes, gitinfo.MAX_DIFF_BYTES)),
    )


def register_routes(router: APIRouter) -> None:
    router.add_api_route("/api/git/status", git_status, methods=["GET"])
    router.add_api_route("/api/git/diff", git_diff, methods=["GET"])
