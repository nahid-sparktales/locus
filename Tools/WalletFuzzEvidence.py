#!/usr/bin/env python3
"""Immutable local fuzz receipts and strict, revision-bound campaign accounting.

Receipts are reproducible engineering evidence, not signed release approval. A
release reviewer must independently attribute the CI runner and resulting files.
Only completed fuzz phases count CPU time; replay and build time never count.
"""

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "swift": (
        "evm_decoder",
        "solana_decoder",
        "sui_decoder",
        "connections",
        "namespaces",
        "authorization",
        "metadata",
        "quote_math",
    ),
    "rust": ("evm_ffi", "solana_ffi", "sui_ffi", "authorization_ffi", "calldata_ffi"),
}
LOCKS = (
    "WalletSignerCore/Cargo.lock",
    "WalletSignerCore/fuzz/Cargo.lock",
    "WalletConnectionsWeb/package-lock.json",
    "Locus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "agent/requirements-runtime.lock",
)
FINDING = re.compile(
    r"ERROR: (?:AddressSanitizer|LeakSanitizer|libFuzzer)|SUMMARY: .*Sanitizer|"
    r"runtime error:|ThreadSanitizer:|libFuzzer: (?:deadly signal|timeout)|"
    r"ALARM: working on the last Unit|TEST (?:EXECUTE )?FAILED",
    re.IGNORECASE,
)


def canonical(value) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode()


def digest(value) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        result = hashlib.sha256()
        while block := stream.read(1024 * 1024):
            result.update(block)
        return result.hexdigest()


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def immutable_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(canonical(payload))
        stream.flush()
        os.fsync(stream.fileno())


def directory_digest(path: Path) -> str:
    entries = []
    for entry in sorted(path.rglob("*")):
        if entry.is_symlink():
            raise ValueError(f"Evidence directories may not contain symlinks: {entry}")
        if entry.is_file():
            entries.append([entry.relative_to(path).as_posix(), sha256(entry)])
    return digest(entries)


def source_identity(root: Path = ROOT) -> dict:
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root)

    entries = []
    for name in sorted(
        set(
            git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(
                b"\0"
            )
        )
        - {b""}
    ):
        relative = os.fsdecode(name)
        path = root / relative
        if path.is_symlink():
            identity = ["symlink", os.readlink(path)]
        elif path.is_file():
            identity = ["file", path.stat().st_mode & 0o777, sha256(path)]
        else:
            identity = ["missing"]
        entries.append([relative, *identity])
    return {
        "revision": git("rev-parse", "HEAD").decode().strip(),
        "gitTree": git("rev-parse", "HEAD^{tree}").decode().strip(),
        "treeSHA256": digest(entries),
        "dirty": bool(git("status", "--porcelain", "--untracked-files=all")),
        "locks": {
            name: sha256(root / name) for name in LOCKS if (root / name).is_file()
        },
    }


def require_source(root: Path = ROOT) -> dict:
    value = source_identity(root)
    # Dirty runs are useful development checks but can never be aggregated.
    if value["dirty"] and os.environ.get("LOCUS_FUZZ_ALLOW_DIRTY") != "1":
        raise ValueError(
            "Fuzz evidence requires clean source; LOCUS_FUZZ_ALLOW_DIRTY=1 is smoke-only"
        )
    return value


def new_run(
    output: Path,
    language: str,
    source: dict,
    toolchain: dict,
    flags: list[str],
    targets: list[str],
) -> tuple[Path, dict]:
    identifier = str(uuid.uuid4())
    path = output / "runs" / identifier
    path.mkdir(parents=True, exist_ok=False)
    manifest = {
        "schemaVersion": 1,
        "runID": identifier,
        "language": language,
        "targets": targets,
        "createdAt": utc_now(),
        "source": source,
        "toolchain": toolchain,
        "flags": flags,
        "hostID": os.environ.get("LOCUS_FUZZ_HOST_ID", os.uname().nodename),
        "cpuCount": os.cpu_count() or 1,
        "provenance": {
            key: os.environ[key]
            for key in (
                "GITHUB_REPOSITORY",
                "GITHUB_RUN_ID",
                "GITHUB_RUN_ATTEMPT",
                "GITHUB_SHA",
            )
            if key in os.environ
        },
    }
    immutable_json(path / "run.json", manifest)
    return path, manifest


def coverage(log: str) -> dict:
    values = [int(value) for value in re.findall(r"\bcov: (\d+)", log)]
    features = [int(value) for value in re.findall(r"\bft: (\d+)", log)]
    units = re.findall(r"stat::number_of_executed_units:\s*(\d+)", log)
    return {
        "edges": max(values, default=0),
        "features": max(features, default=0),
        "executedUnits": int(units[-1]) if units else 0,
    }


def finish_receipt(
    run: Path,
    manifest: dict,
    phase: Path,
    *,
    target: str,
    kind: str,
    chunk_id: str,
    started_at: str,
    ended_at: str,
    binary: dict,
    binary_after: dict,
    corpus_before: str,
    result: int,
    metrics: dict | None,
    source_after: dict,
    requested_seconds: int,
) -> dict:
    log = (phase / "process.log").read_text(errors="replace")
    stats = coverage(log)
    expected = {
        "runID": manifest["runID"],
        "chunkID": chunk_id,
        "phase": kind,
        "target": target,
        "sourceRevision": manifest["source"]["revision"],
    }
    metrics_valid = (
        isinstance(metrics, dict)
        and bool(metrics)
        and all(metrics.get(key) == value for key, value in expected.items())
    )
    cpu = metrics.get("processCPUSeconds", 0) if isinstance(metrics, dict) else 0
    iterations = metrics.get("iterations", 0) if isinstance(metrics, dict) else 0
    metrics_valid = (
        metrics_valid and isinstance(cpu, (int, float)) and not isinstance(cpu, bool)
    )
    metrics_valid = metrics_valid and math.isfinite(cpu) and cpu >= 0
    metrics_valid = metrics_valid and type(iterations) is int and iterations > 0
    metrics_valid = (
        metrics_valid and type(metrics.get("result")) is int and metrics["result"] == 0
    )
    findings = bool(FINDING.search(log)) or any((phase / "artifacts").iterdir())
    passed = (
        result == 0
        and metrics_valid
        and not findings
        and source_after == manifest["source"]
        and binary_after == binary
        and (kind == "replay" or stats["edges"] > 0)
    )
    files = {
        entry.relative_to(phase).as_posix(): sha256(entry)
        for entry in sorted(phase.rglob("*"))
        if entry.is_file()
    }
    payload = {
        "schemaVersion": 1,
        **expected,
        "language": manifest["language"],
        "startedAt": started_at,
        "endedAt": ended_at,
        "runManifestSHA256": sha256(run / "run.json"),
        "source": manifest["source"],
        "sourceAfter": source_after,
        "binary": binary,
        "binaryAfter": binary_after,
        "toolchain": manifest["toolchain"],
        "flags": manifest["flags"],
        "hostID": manifest["hostID"],
        "cpuCount": manifest["cpuCount"],
        "requestedWallSeconds": requested_seconds,
        "targetCPUSeconds": cpu if metrics_valid else 0,
        "cpuAccounting": "target-process-only",
        "iterations": iterations,
        "coverage": stats,
        "corpusBeforeSHA256": corpus_before,
        "corpusAfterSHA256": directory_digest(phase / "corpus"),
        "result": result,
        "findings": findings,
        "status": "passed" if passed else "failed",
        "files": files,
    }
    payload["receiptSHA256"] = digest(payload)
    immutable_json(phase / "receipt.json", payload)
    return payload


def _date(value: str) -> datetime:
    parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
        tzinfo=timezone.utc
    )
    if parsed.strftime("%Y-%m-%dT%H:%M:%S.%fZ") != value:
        raise ValueError("Noncanonical receipt date")
    return parsed


def aggregate(
    paths: list[Path],
    revision: str,
    required_cpu: float = 86400,
    required_targets: list[str] | None = None,
) -> dict:
    required_targets = required_targets or [
        f"{language}/{target}"
        for language, values in TARGETS.items()
        for target in values
    ]
    known_targets = {
        f"{language}/{target}"
        for language, values in TARGETS.items()
        for target in values
    }
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected an exact candidate source revision")
    if len(required_targets) != len(set(required_targets)) or not set(
        required_targets
    ).issubset(known_targets):
        raise ValueError("Invalid required target set")
    if not paths or required_cpu <= 0 or not math.isfinite(required_cpu):
        raise ValueError("Receipts and a positive CPU requirement are mandatory")
    totals = {target: 0.0 for target in required_targets}
    receipts, seen, identities, intervals, replays, fuzzes = (
        [],
        set(),
        {},
        {},
        set(),
        [],
    )
    source = None
    for path in paths:
        receipt = json.loads(path.read_text())
        claimed_digest = receipt.pop("receiptSHA256", None)
        if claimed_digest != digest(receipt) or receipt.get("schemaVersion") != 1:
            raise ValueError("Invalid receipt digest/schema")
        key = f"{receipt['language']}/{receipt['target']}"
        identifier = receipt["chunkID"]
        if str(uuid.UUID(identifier)) != identifier or identifier in seen:
            raise ValueError("Duplicate or invalid chunk ID")
        seen.add(identifier)
        if key not in totals or receipt["phase"] not in ("replay", "fuzz"):
            raise ValueError("Unexpected target or phase")
        if (
            receipt["status"] != "passed"
            or receipt["result"] != 0
            or receipt["findings"]
        ):
            raise ValueError("Failed chunk or sanitizer finding blocks campaign")
        current = receipt["source"]
        if (
            current["revision"] != revision
            or current["dirty"]
            or current != receipt["sourceAfter"]
        ):
            raise ValueError("Stale, dirty or changed source")
        if (
            set(current["locks"]) != set(LOCKS)
            or not receipt["binary"]
            or receipt["binary"] != receipt["binaryAfter"]
            or not receipt["toolchain"]
            or not receipt["flags"]
        ):
            raise ValueError(
                "Missing dependency, binary, toolchain or instrumentation identities"
            )
        if source is not None and source != current:
            raise ValueError("Source tree or dependency identities disagree")
        for value in [
            current["treeSHA256"],
            *current["locks"].values(),
            *receipt["binary"].values(),
            receipt["corpusBeforeSHA256"],
            receipt["corpusAfterSHA256"],
        ]:
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
                raise ValueError("Malformed evidence SHA-256 identity")
        if type(receipt["cpuCount"]) is not int or not 1 <= receipt["cpuCount"] <= 1024:
            raise ValueError("Invalid CPU topology bound")
        source = current
        identity = digest(
            {
                field: receipt[field]
                for field in ("binary", "toolchain", "flags", "corpusBeforeSHA256")
            }
        )
        if key in identities and identities[key] != identity:
            raise ValueError(
                "Target binary, corpus, flags or toolchain identities disagree"
            )
        identities[key] = identity
        phase = path.parent
        if phase.name != receipt["phase"] or phase.parent.name != receipt["target"]:
            raise ValueError("Receipt phase/target path mismatch")
        run = phase.parent.parent
        if (
            run.name != receipt["runID"]
            or sha256(run / "run.json") != receipt["runManifestSHA256"]
        ):
            raise ValueError("Missing or mismatched run manifest")
        manifest = json.loads((run / "run.json").read_text())
        if receipt["target"] not in manifest["targets"]:
            raise ValueError("Target was not planned for this run")
        for field in (
            "runID",
            "language",
            "source",
            "toolchain",
            "flags",
            "hostID",
            "cpuCount",
        ):
            if manifest[field] != receipt[field]:
                raise ValueError("Receipt does not match its run")
        if not {"process.log", "metrics.json"}.issubset(receipt["files"]):
            raise ValueError("Missing completion metrics/log")
        for relative, expected_hash in receipt["files"].items():
            entry = phase / relative
            if (
                entry.is_symlink()
                or not entry.resolve().is_relative_to(phase.resolve())
                or sha256(entry) != expected_hash
            ):
                raise ValueError("Missing, changed or escaped evidence file")
        actual_files = {
            entry.relative_to(phase).as_posix()
            for entry in phase.rglob("*")
            if entry.is_file()
        }
        if actual_files != set(receipt["files"]) | {"receipt.json"}:
            raise ValueError(
                "Unrecorded phase files, including possible crash evidence"
            )
        if directory_digest(phase / "corpus") != receipt["corpusAfterSHA256"]:
            raise ValueError("Corpus identity changed")
        log = (phase / "process.log").read_text(errors="replace")
        if (
            FINDING.search(log)
            or coverage(log) != receipt["coverage"]
            or any((phase / "artifacts").iterdir())
        ):
            raise ValueError("Sanitizer finding or altered coverage")
        metrics = json.loads((phase / "metrics.json").read_text())
        for field in (
            "runID",
            "chunkID",
            "phase",
            "target",
            "sourceRevision",
            "iterations",
            "result",
        ):
            if metrics.get(field) != receipt[field]:
                raise ValueError("Stale or mismatched target completion metrics")
        cpu = receipt["targetCPUSeconds"]
        start, end = _date(receipt["startedAt"]), _date(receipt["endedAt"])
        if end <= start or end > datetime.now(timezone.utc):
            raise ValueError("Invalid receipt interval")
        if (
            isinstance(cpu, bool)
            or not isinstance(cpu, (int, float))
            or not math.isfinite(cpu)
            or cpu < 0
            or metrics["processCPUSeconds"] != cpu
            or cpu > (end - start).total_seconds() * receipt["cpuCount"] + 1
            or receipt["cpuAccounting"] != "target-process-only"
            or receipt["iterations"] <= 0
        ):
            raise ValueError("Invalid target CPU accounting")
        replay_key = (receipt["runID"], key)
        if receipt["phase"] == "replay":
            if replay_key in replays:
                raise ValueError("Duplicate replay phase")
            replays.add(replay_key)
        else:
            if receipt["coverage"]["edges"] <= 0 or cpu <= 0:
                raise ValueError("Missing instrumented coverage or CPU")
            interval_key = (key, receipt["hostID"])
            for earlier_start, earlier_end in intervals.setdefault(interval_key, []):
                if start < earlier_end and earlier_start < end:
                    raise ValueError("Overlapping chunks on the same target/host")
            intervals[interval_key].append((start, end))
            fuzzes.append(replay_key)
            totals[key] += cpu
        receipts.append(claimed_digest)
    if not set(fuzzes).issubset(replays):
        raise ValueError("Every fuzz chunk requires its own successful corpus replay")
    if any(total < required_cpu for total in totals.values()):
        raise ValueError(f"Insufficient target CPU seconds: {totals}")
    return {
        "schemaVersion": 1,
        "source": source,
        "requiredCPUSecondsPerTarget": required_cpu,
        "targetCPUSeconds": totals,
        "receipts": sorted(receipts),
        "targetIdentities": identities,
        "status": "engineering-campaign-complete",
        "releaseApproval": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--required-cpu-seconds", type=float, default=86400)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()
    receipts = discover_receipts(args.roots)
    result = aggregate(receipts, args.revision, args.required_cpu_seconds)
    immutable_json(args.output, result)


def discover_receipts(roots: list[Path]) -> list[Path]:
    receipts = []
    for root in roots:
        manifests = sorted(root.glob("runs/*/run.json"))
        if not manifests:
            raise ValueError("Missing campaign run manifests")
        for path in manifests:
            manifest = json.loads(path.read_text())
            targets = manifest["targets"]
            if (
                not targets
                or len(targets) != len(set(targets))
                or not set(targets).issubset(TARGETS[manifest["language"]])
            ):
                raise ValueError("Invalid planned target set")
            expected = {
                path.parent / target / phase / "receipt.json"
                for target in targets
                for phase in ("replay", "fuzz")
            }
            if expected != set(path.parent.glob("*/*/receipt.json")):
                raise ValueError(
                    "Incomplete run: missing replay/fuzz receipt or unexpected phase"
                )
            receipts.extend(sorted(expected))
    return receipts


if __name__ == "__main__":
    main()
