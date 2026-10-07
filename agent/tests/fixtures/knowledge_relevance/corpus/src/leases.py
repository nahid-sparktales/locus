"""Lease bookkeeping for Harbor's shared execution host."""
from dataclasses import dataclass


@dataclass(frozen=True)
class WorkerLease:
    owner: str
    expires_at: float
    revision: int


def claim_worker_lease(current, owner, now, ttl=90):
    """Claim an expired lease or renew the same owner's active lease."""
    if current and current.owner != owner and current.expires_at > now:
        raise RuntimeError("lease_busy")
    revision = current.revision + 1 if current else 1
    return WorkerLease(owner=owner, expires_at=now + ttl, revision=revision)


def release_worker_lease(current, owner, expected_revision):
    if current.owner != owner or current.revision != expected_revision:
        raise RuntimeError("lease_conflict")
    return None
