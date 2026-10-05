"""Locus profile paths for package-owned writer fencing and process leases."""
from __future__ import annotations

from pathlib import Path

from locus_memory.migrations import ownership
from locus_memory.models import PartitionRef


def ownership_state(app_dir: Path | str, edition: str) -> str:
    return ownership.ownership_state(
        Path(app_dir) / "memory-engine", PartitionRef(edition.lower(), "default"),
    )


def assert_legacy_writer(app_dir: Path | str, edition: str) -> None:
    ownership.assert_legacy_writer(
        Path(app_dir) / "memory-engine", PartitionRef(edition.lower(), "default"),
    )


def profile_lease(app_dir: Path | str, *, exclusive: bool = False):
    return ownership.profile_lease(Path(app_dir) / ".memory-runtime.lock", exclusive=exclusive)
