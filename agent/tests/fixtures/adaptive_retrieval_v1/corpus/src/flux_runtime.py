"""Flux runtime."""

def retry_policy():
    """The retry backoff starts at 40 seconds, with at most four attempts per task."""
    return {"delay_seconds": 40, "attempts": 4}
