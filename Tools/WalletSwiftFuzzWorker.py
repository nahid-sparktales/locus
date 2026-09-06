"""Validate a dedicated fuzz worker; process cleanup alone is not completion."""

import hashlib
import json
import math
import re
from pathlib import Path

EXECUTION_MODEL = "wallet-fuzz-host-v1"
MAXIMUM_SEED_BYTES = 16_384
MAXIMUM_SEEDS = 2_048
MAXIMUM_METRICS_BYTES = 1_048_576
IDENTITY_FIELDS = ("runID", "chunkID", "target", "phase", "sourceRevision")


def read_record(path: Path) -> dict:
    if (
        path.is_symlink()
        or not path.is_file()
        or path.stat().st_size > MAXIMUM_METRICS_BYTES
    ):
        raise ValueError("Missing, linked or oversized worker record")
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError("Worker record must be an object")
    return value


def seed_hashes(directory: Path) -> list[str]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Missing or linked seed corpus")
    entries = sorted(directory.iterdir())
    if not 1 <= len(entries) <= MAXIMUM_SEEDS:
        raise ValueError("Seed corpus exceeds its count bound or is empty")
    result = set()
    for entry in entries:
        if (
            entry.is_symlink()
            or not entry.is_file()
            or entry.stat().st_size > MAXIMUM_SEED_BYTES
        ):
            raise ValueError("Invalid or oversized corpus seed")
        result.add(hashlib.sha256(entry.read_bytes()).hexdigest())
    return sorted(result)


def validate_phase(phase: Path, expected: dict, log: str, findings: bool) -> dict:
    """Recheck retained observations, never infer success from an exit hook."""
    invocation = read_record(phase / "invocation.json")
    observed = read_record(phase / "invocation-result.json")
    worker = read_record(phase / "worker-metrics.json")
    if any(
        record.get("executionModel") != EXECUTION_MODEL
        for record in (invocation, observed)
    ):
        raise ValueError("Unknown worker execution model")
    for field in IDENTITY_FIELDS:
        if any(
            record.get(field) != expected[field]
            for record in (invocation, observed, worker)
        ):
            raise ValueError("Worker invocation identity mismatch")
    invocation_hash = hashlib.sha256(
        (phase / "invocation.json").read_bytes()
    ).hexdigest()
    if observed.get("invocationSHA256") != invocation_hash:
        raise ValueError("Worker invocation changed")
    if (
        type(observed.get("result")) is not int
        or observed["result"] != 0
        or observed.get("timedOut") is not False
        or findings
    ):
        raise ValueError("Worker failed, timed out or reported a finding")
    pid = observed.get("processID")
    if (
        type(pid) is not int
        or pid <= 0
        or type(worker.get("processID")) is not int
        or worker["processID"] != pid
    ):
        raise ValueError("Completion is not from the observed worker process")
    if worker.get("schemaVersion") != 1 or "result" in worker or "status" in worker:
        raise ValueError("Provisional worker metrics may not claim a result")
    cpu = worker.get("processCPUSeconds")
    iterations = worker.get("iterations")
    if (
        type(cpu) not in (int, float)
        or not math.isfinite(cpu)
        or cpu < 0
        or type(iterations) is not int
        or iterations <= 0
    ):
        raise ValueError("Invalid worker CPU or iteration accounting")
    # Both the loop completion and final statistics must come from the engine.
    # An early exit(0) also invokes atexit, but cannot satisfy this evidence.
    done = re.findall(r"^#(\d+)\s+DONE\s+.*\bcov:\s*(\d+)", log, re.MULTILINE)
    units = re.findall(
        r"^stat::number_of_executed_units:\s*(\d+)\s*$", log, re.MULTILINE
    )
    if (
        len(done) != 1
        or len(units) != 1
        or int(done[0][0]) != int(units[0])
        or int(units[0]) != iterations
    ):
        raise ValueError("Incomplete or inconsistent libFuzzer completion statistics")
    if int(done[0][1]) <= 0:
        raise ValueError("Missing production coverage")
    seeds = invocation.get("seedSHA256")
    seen = worker.get("observedSeedSHA256")
    for values in (seeds, seen):
        if (
            not isinstance(values, list)
            or len(values) > MAXIMUM_SEEDS
            or any(
                not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
                for value in values
            )
            or values != sorted(set(values))
        ):
            raise ValueError("Malformed seed observation")
    if not seeds or not set(seen).issubset(seeds):
        raise ValueError("Unknown or absent seed observations")
    if expected["phase"] == "replay" and seen != seeds:
        raise ValueError("Replay did not exercise every retained seed")
    # Only the supervisor's observed termination supplies the result field.
    return {**worker, "result": observed["result"], "executionModel": EXECUTION_MODEL}
