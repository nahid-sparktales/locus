"""Locus defaults and standing user authorization for automatic memory saving."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from locus_memory.policies import MemoryPolicy as PackageMemoryPolicy


@dataclass(frozen=True)
class MemoryPolicy(PackageMemoryPolicy):
    auto_save_enabled: bool = True
    native_codex_enabled: bool = True

    @classmethod
    def parse(cls, value: Any) -> MemoryPolicy:
        raw = dict(value) if isinstance(value, dict) else {}
        raw.setdefault("native_codex_enabled", True)
        parsed = PackageMemoryPolicy.parse(raw)
        return cls(**parsed.__dict__, auto_save_enabled=bool(raw.get("auto_save_enabled", True)))
