"""Compatibility imports for Locus runtime composition.

Execution mechanics are maintained only by the locus-runtime distribution.
Retained until product callers have migrated to runtime_host.
"""
import asyncio  # Kept for existing instrumentation of the shared asyncio module.

from locus_runtime.contracts import DECISION_EVENTS, NATIVE_EVENTS, TURN_COMMANDS
from locus_runtime.supervisor import Worker

from .runtime_host import CONFIG_PATHS, LocusWorkerDriver, RuntimeSupervisor, main

__all__ = ["CONFIG_PATHS", "DECISION_EVENTS", "NATIVE_EVENTS", "TURN_COMMANDS",
           "LocusWorkerDriver", "RuntimeSupervisor", "Worker", "asyncio", "main"]

if __name__ == "__main__":
    main()
