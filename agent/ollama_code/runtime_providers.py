"""Locus child-environment policy for runtime-owned local model processes."""
from locus_runtime.providers import RuntimeProviders as _RuntimeProviders

from .proxy import sanitized_child_environment


class RuntimeProviders(_RuntimeProviders):
    def __init__(self, runtime):
        super().__init__(runtime.private, environment=sanitized_child_environment)
