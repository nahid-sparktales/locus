"""Run, orchestration, task, usage, and MCP task routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/mcp/tasks", handlers.mcp_task_list, methods=["GET"])
    router.add_api_route(
        "/api/mcp/tasks/{task_id}/lookup", handlers.mcp_task_lookup, methods=["POST"]
    )
    router.add_api_route(
        "/api/mcp/tasks/{task_id}/cancel", handlers.mcp_task_cancel, methods=["POST"]
    )
    router.add_api_route("/api/usage/summary", handlers.usage_summary, methods=["GET"])
    router.add_api_route("/api/runs", handlers.orchestration_list, methods=["GET"])
    router.add_api_route("/api/orchestrations", handlers.orchestration_list, methods=["GET"])
    router.add_api_route("/api/runs/queue", handlers.run_queue, methods=["POST"])
    router.add_api_route("/api/runs/{run_id}/queue", handlers.run_queue_update, methods=["PATCH"])
    router.add_api_route("/api/runs/{run_id}/retry", handlers.run_retry, methods=["POST"])
    router.add_api_route("/api/runs/{run_id}", handlers.orchestration_detail, methods=["GET"])
    router.add_api_route(
        "/api/orchestrations/{run_id}", handlers.orchestration_detail, methods=["GET"]
    )
    router.add_api_route("/api/runs/{run_id}", handlers.orchestration_update, methods=["PATCH"])
    router.add_api_route(
        "/api/orchestrations/{run_id}", handlers.orchestration_update, methods=["PATCH"]
    )
    router.add_api_route(
        "/api/runs/{run_id}/events", handlers.orchestration_events, methods=["GET"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/events", handlers.orchestration_events, methods=["GET"]
    )
    router.add_api_route(
        "/api/runs/{run_id}/export", handlers.orchestration_export, methods=["GET"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/export", handlers.orchestration_export, methods=["GET"]
    )
    router.add_api_route("/api/runs/{run_id}/otlp", handlers.orchestration_otlp, methods=["POST"])
    router.add_api_route(
        "/api/orchestrations/{run_id}/otlp", handlers.orchestration_otlp, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/pause", handlers.orchestration_pause, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/cancel", handlers.orchestration_cancel, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/discard", handlers.orchestration_discard, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/reconcile-worker-exit",
        handlers.orchestration_reconcile_worker_exit,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/dispatch-decision",
        handlers.orchestration_dispatch_decision,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/resume", handlers.orchestration_resume, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/run-with-locus",
        handlers.orchestration_run_with_locus,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/recovery-assessment",
        handlers.orchestration_recovery_assessment,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/jobs/{job_id}/retry",
        handlers.orchestration_retry_job,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/agents/{node_id:path}/stop",
        handlers.orchestration_stop_agent_branch,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/agents/{node_id:path}/retry",
        handlers.orchestration_retry_agent_branch,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/jobs/{job_id}/reassign",
        handlers.orchestration_reassign_job,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/replay", handlers.orchestration_replay, methods=["POST"]
    )
    router.add_api_route(
        "/api/orchestrations/{run_id}/duplicate", handlers.orchestration_duplicate, methods=["POST"]
    )
    router.add_api_route("/api/tasks/{task_id}", handlers.task_detail, methods=["GET"])
    router.add_api_route(
        "/api/tasks/{task_id}/landing/preflight", handlers.task_landing_preflight, methods=["GET"]
    )
    router.add_api_route(
        "/api/tasks/{task_id}/checks", handlers.task_landing_checks, methods=["POST"]
    )
    router.add_api_route("/api/runs/{run_id}/cancel", handlers.run_cancel, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/landing", handlers.task_land, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/apply", handlers.task_apply, methods=["POST"])
    router.add_api_route(
        "/api/tasks/{task_id}/branch", handlers.task_create_branch, methods=["POST"]
    )
    router.add_api_route("/api/tasks/{task_id}/snapshot", handlers.task_snapshot, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}/restore", handlers.task_restore, methods=["POST"])
    router.add_api_route("/api/tasks/{task_id}", handlers.task_cleanup, methods=["DELETE"])
