"""Workspace source-control inspection routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/git/status", handlers.git_status, methods=["GET"])
    router.add_api_route("/api/git/diff", handlers.git_diff, methods=["GET"])
