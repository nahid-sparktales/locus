"""Independent rollout gates for the orchestration platform.

Packaged builds enable the additive features by default.  Support and test
builds can disable one stage without changing settings or stored data by
setting its ``LOCUS_CAPABILITY_*`` environment variable to a false value.
"""
from __future__ import annotations

import os

CAPABILITY_ENV = {
    "durable_runs": "LOCUS_CAPABILITY_DURABLE_RUNS",
    "recovery_controls": "LOCUS_CAPABILITY_RECOVERY_CONTROLS",
    "evaluations": "LOCUS_CAPABILITY_EVALUATIONS",
    "adaptive_routing": "LOCUS_CAPABILITY_ADAPTIVE_ROUTING",
    "workspace_knowledge": "LOCUS_CAPABILITY_WORKSPACE_KNOWLEDGE",
    "modern_mcp": "LOCUS_CAPABILITY_MODERN_MCP",
    "browser": "LOCUS_CAPABILITY_BROWSER",
    "transcript_search": "LOCUS_CAPABILITY_TRANSCRIPT_SEARCH",
}


def enabled(name: str) -> bool:
    variable = CAPABILITY_ENV.get(name)
    if variable is None:
        return False
    return os.environ.get(variable, "1").strip().lower() not in {
        "0", "false", "no", "off", "disabled",
    }


def snapshot() -> dict[str, bool]:
    return {name: enabled(name) for name in CAPABILITY_ENV}


__all__ = ["CAPABILITY_ENV", "enabled", "snapshot"]
