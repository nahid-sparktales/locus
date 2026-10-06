"""Locus persistence adapter. Runtime tables and transactions belong to locus_runtime."""
from locus_runtime.storage import PrivateStore, identifier, initialize_schema
from locus_runtime.storage import RuntimeStore as _RuntimeStore

from .runstore import sanitize_event

__all__ = ["PrivateStore", "RuntimeStore", "identifier", "initialize_schema"]


class RuntimeStore(_RuntimeStore):
    def __init__(self, runs):
        # Transitional product-side handle for callers/tests; the package never sees RunStore.
        self.runs = runs
        super().__init__(runs.runtime_connection, sanitize=sanitize_event)
