"""Dedicated-host receipt validation with files only; no host/fuzzer is launched."""

import json
import shutil
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import WalletFuzzEvidence as evidence  # noqa: E402
import WalletSwiftFuzzWorker as worker  # noqa: E402

REVISION = "a" * 40
BINARY = {"Contents/MacOS/WalletFuzzHost": "f" * 64}
FINAL_STATISTICS = (
    "number_of_executed_units: 12",
    "average_exec_per_sec: 1",
    "new_units_added: 0",
    "slowest_unit_time_sec: 0",
    "peak_rss_mb: 42",
)
COMPLETE_LOG = "#12 DONE cov: 42 ft: 55\n" + "".join(
    f"stat::{statistic}\n" for statistic in FINAL_STATISTICS
)


def write_json(path, value):
    path.write_bytes(evidence.canonical(value))


def update_json(path, **changes):
    value = json.loads(path.read_bytes())
    value.update(changes)
    write_json(path, value)


@pytest.fixture
def host_run(tmp_path):
    source = {
        "revision": REVISION,
        "gitTree": "b" * 40,
        "treeSHA256": "c" * 64,
        "dirty": False,
        "locks": {name: "d" * 64 for name in evidence.LOCKS},
    }
    run, manifest = evidence.new_run(
        tmp_path, "swift", source, {"compilerSHA256": "e" * 64},
        ["address", "edge,inline-8bit-counters,pc-table,trace-cmp", worker.EXECUTION_MODEL],
        ["evm_decoder"],
    )
    seeds = run / "seeds/evm_decoder"
    seeds.mkdir(parents=True)
    (seeds / "first").write_bytes(b"public fixture one")
    (seeds / "second").write_bytes(b"public fixture two")
    corpus_before = evidence.directory_digest(seeds)
    for kind, cpu in (("replay", 2.0), ("fuzz", 10.0)):
        phase = run / "evm_decoder" / kind
        phase.mkdir(parents=True)
        shutil.copytree(seeds, phase / "corpus")
        (phase / "artifacts").mkdir()
        (phase / "process.log").write_text(COMPLETE_LOG)
        identity = {
            "runID": manifest["runID"], "chunkID": str(uuid.uuid4()),
            "target": "evm_decoder", "phase": kind, "sourceRevision": REVISION,
        }
        invocation = {
            **identity, "executionModel": worker.EXECUTION_MODEL,
            "executableSHA256": BINARY["Contents/MacOS/WalletFuzzHost"],
            "seedSHA256": worker.seed_hashes(seeds), "seedCorpusSHA256": corpus_before,
        }
        write_json(run / f"{kind}-expected.json", invocation)
        write_json(phase / "invocation.json", invocation)
        write_json(phase / "invocation-result.json", {
            **identity, "executionModel": worker.EXECUTION_MODEL,
            "invocationSHA256": evidence.sha256(phase / "invocation.json"),
            "processID": 4212, "result": 0, "timedOut": False,
        })
        metrics = {
            **identity, "schemaVersion": 1, "processID": 4212,
            "processCPUSeconds": cpu, "iterations": 12,
            "observedSeedSHA256": invocation["seedSHA256"],
        }
        write_json(phase / "worker-metrics.json", metrics)
        write_json(phase / "metrics.json", {
            **metrics, "result": 0, "executionModel": worker.EXECUTION_MODEL,
        })
    return run


def finish(run, kind="fuzz", *, result=0, caller_metrics=None):
    manifest = json.loads((run / "run.json").read_bytes())
    phase = run / "evm_decoder" / kind
    invocation = json.loads((run / f"{kind}-expected.json").read_bytes())
    metrics = json.loads((phase / "metrics.json").read_bytes()) if (phase / "metrics.json").is_file() else None
    return evidence.finish_receipt(
        run, manifest, phase, target="evm_decoder", kind=kind,
        chunk_id=invocation["chunkID"],
        started_at=f"2026-01-01T00:00:{'00' if kind == 'replay' else '10'}.000000Z",
        ended_at=f"2026-01-01T00:00:{'05' if kind == 'replay' else '30'}.000000Z",
        binary=BINARY, binary_after=BINARY,
        corpus_before=invocation["seedCorpusSHA256"], result=result,
        metrics=caller_metrics if caller_metrics is not None else metrics,
        source_after=manifest["source"], requested_seconds=60,
    )


def receipt_paths(run):
    return [run / "evm_decoder" / kind / "receipt.json" for kind in ("replay", "fuzz")]


def aggregate(run, paths=None):
    return evidence.aggregate(paths or receipt_paths(run), REVISION, 10, ["swift/evm_decoder"])


def reseal(phase, **changes):
    """Model edits that defeat file-hash-only checks, never a signed authority."""
    path = phase / "receipt.json"
    value = json.loads(path.read_bytes())
    value.pop("receiptSHA256")
    value.update(changes)
    value["files"] = {
        entry.relative_to(phase).as_posix(): evidence.sha256(entry)
        for entry in sorted(phase.rglob("*"))
        if entry.is_file() and entry != path
    }
    value["receiptSHA256"] = evidence.digest(value)
    write_json(path, value)


CASES = (
    "premature-zero-exit", "missing-worker-metrics", "missing-normalized-metrics", "missing-invocation",
    "missing-observed-result", "crash", "sanitizer", "timeout", "false-timeout", "retained-timeout",
    "nonzero-exit", "boolean-exit", "wrong-pid", "missing-pid", "boolean-pid",
    "stale-worker-identity", "stale-observed-identity", "stale-invocation-identity",
    "invocation-hash", "unreviewed-execution-model", "worker-pass-claim",
    "worker-result-claim", "normalized-cpu", "normalized-extra-claim",
    "normalized-boolean-schema", "boolean-worker-schema", "inconsistent-iterations",
    "negative-cpu", "boolean-cpu", "zero-iterations", "boolean-iterations",
    "missing-done", "duplicate-done", "wrong-final-units", "no-coverage",
    "duplicate-stat", "malformed-stat", "unknown-seed-observation",
    "missing-seeds", "changed-seed-bytes", "renamed-seed", "linked-seed",
    "linked-seeds-directory", "extra-seed", "wrong-invocation-seeds",
    "wrong-seed-corpus", "wrong-executable",
    *(f"missing-stat-{statistic.split(':')[0]}" for statistic in FINAL_STATISTICS),
)


def corrupt(run, case, kind="fuzz"):
    phase = run / "evm_decoder" / kind
    log = phase / "process.log"
    invocation = phase / "invocation.json"
    observed = phase / "invocation-result.json"
    metrics = phase / "worker-metrics.json"
    normalized = phase / "metrics.json"
    seeds = run / "seeds/evm_decoder"
    if case == "premature-zero-exit":
        log.write_text("INFO: Seed: 42\n")
    elif case == "missing-worker-metrics":
        metrics.unlink()
    elif case == "missing-invocation":
        invocation.unlink()
    elif case == "missing-normalized-metrics":
        normalized.unlink()
    elif case == "missing-observed-result":
        observed.unlink()
    elif case == "crash":
        (phase / "artifacts/crash-public-input").write_bytes(b"fixture")
    elif case == "sanitizer":
        log.write_text(COMPLETE_LOG + "SUMMARY: UndefinedBehaviorSanitizer: overflow\n")
    elif case in ("timeout", "false-timeout"):
        update_json(observed, timedOut=True if case == "timeout" else 0)
    elif case == "retained-timeout":
        write_json(phase / "timeout.json", {"timedOut": True})
    elif case in ("nonzero-exit", "boolean-exit"):
        update_json(observed, result=9 if case == "nonzero-exit" else False)
    elif case in ("wrong-pid", "missing-pid", "boolean-pid"):
        update_json(observed, processID={"wrong-pid": 123, "missing-pid": None, "boolean-pid": True}[case])
    elif case.startswith("stale-"):
        record = {"stale-worker-identity": metrics, "stale-observed-identity": observed,
                  "stale-invocation-identity": invocation}[case]
        update_json(record, sourceRevision="0" * 40)
    elif case == "invocation-hash":
        update_json(observed, invocationSHA256="0" * 64)
    elif case == "unreviewed-execution-model":
        update_json(observed, executionModel="unrelated-process")
    elif case in ("worker-pass-claim", "worker-result-claim"):
        update_json(metrics, **({"status": "passed"} if case == "worker-pass-claim" else {"result": 0}))
    elif case == "normalized-cpu":
        update_json(normalized, processCPUSeconds=9.0)
    elif case == "normalized-extra-claim":
        update_json(normalized, status="passed")
    elif case == "normalized-boolean-schema":
        update_json(normalized, schemaVersion=True)
    elif case == "boolean-worker-schema":
        update_json(metrics, schemaVersion=True)
        update_json(normalized, schemaVersion=True)
    elif case == "inconsistent-iterations":
        update_json(metrics, iterations=13)
    elif case in ("negative-cpu", "boolean-cpu"):
        update_json(metrics, processCPUSeconds=-1 if case == "negative-cpu" else True)
    elif case in ("zero-iterations", "boolean-iterations"):
        update_json(metrics, iterations=0 if case == "zero-iterations" else True)
    elif case == "missing-done":
        log.write_text(COMPLETE_LOG.split("\n", 1)[1])
    elif case == "duplicate-done":
        log.write_text(COMPLETE_LOG + "#12 DONE cov: 42 ft: 55\n")
    elif case == "wrong-final-units":
        log.write_text(COMPLETE_LOG.replace("executed_units: 12", "executed_units: 11"))
    elif case == "no-coverage":
        log.write_text(COMPLETE_LOG.replace("cov: 42", "cov: 0"))
    elif case == "duplicate-stat":
        log.write_text(COMPLETE_LOG + "stat::peak_rss_mb: 42\n")
    elif case == "malformed-stat":
        log.write_text(COMPLETE_LOG.replace("peak_rss_mb: 42", "peak_rss_mb: nan"))
    elif case == "unknown-seed-observation":
        update_json(metrics, observedSeedSHA256=["0" * 64])
    elif case == "missing-seeds":
        shutil.rmtree(seeds)
    elif case == "changed-seed-bytes":
        (seeds / "first").write_bytes(b"changed")
    elif case == "renamed-seed":
        (seeds / "first").rename(seeds / "renamed")
    elif case == "linked-seed":
        original = seeds / "first"
        moved = run / "moved-seed"
        original.rename(moved)
        original.symlink_to(moved)
    elif case == "linked-seeds-directory":
        original = run / "seeds"
        moved = run / "moved-seeds"
        original.rename(moved)
        original.symlink_to(moved, target_is_directory=True)
    elif case == "extra-seed":
        (seeds / "extra").write_bytes(b"unplanned")
    elif case == "wrong-invocation-seeds":
        update_json(invocation, seedSHA256=["0" * 64])
    elif case == "wrong-seed-corpus":
        update_json(invocation, seedCorpusSHA256="0" * 64)
    elif case == "wrong-executable":
        update_json(invocation, executableSHA256="0" * 64)
    elif case.startswith("missing-stat-"):
        missing = case.removeprefix("missing-stat-")
        log.write_text("".join(line + "\n" for line in COMPLETE_LOG.splitlines()
                               if not line.startswith(f"stat::{missing}:")))
    else:
        raise AssertionError(case)
    if case in ("wrong-invocation-seeds", "wrong-seed-corpus", "wrong-executable"):
        update_json(observed, invocationSHA256=evidence.sha256(invocation))


def test_dedicated_host_counts_only_verified_fuzz_cpu(host_run):
    for kind in ("replay", "fuzz"):
        receipt = finish(host_run, kind)
        assert receipt["status"] == "passed"
        assert receipt["completionValidation"] == "verified"
    report = aggregate(host_run)
    assert report["targetCPUSeconds"] == {"swift/evm_decoder": 10.0}
    assert report["releaseApproval"] is False


@pytest.mark.parametrize("case", CASES)
def test_finish_preserves_invalid_host_evidence_without_cpu_credit(host_run, case):
    corrupt(host_run, case)
    receipt = finish(host_run)
    assert receipt["status"] == "failed"
    assert receipt["completionValidation"] == "failed"
    assert receipt["targetCPUSeconds"] == 0
    assert (host_run / "evm_decoder/fuzz/receipt.json").is_file()


@pytest.mark.parametrize("case", CASES)
def test_aggregation_independently_rejects_resealed_invalid_host_evidence(host_run, case):
    for kind in ("replay", "fuzz"):
        finish(host_run, kind)
    corrupt(host_run, case)
    phase = host_run / "evm_decoder/fuzz"
    reseal(phase, coverage=evidence.coverage((phase / "process.log").read_text()))
    with pytest.raises((ValueError, FileNotFoundError)):
        aggregate(host_run)


def test_replay_requires_every_retained_seed_even_with_complete_stats(host_run):
    phase = host_run / "evm_decoder/replay"
    value = json.loads((phase / "worker-metrics.json").read_bytes())
    value["observedSeedSHA256"] = value["observedSeedSHA256"][:1]
    write_json(phase / "worker-metrics.json", value)
    write_json(phase / "metrics.json", {**value, "result": 0, "executionModel": worker.EXECUTION_MODEL})
    assert finish(host_run, "replay")["status"] == "failed"


def test_caller_cannot_substitute_metrics_after_retained_validation(host_run):
    metrics = json.loads((host_run / "evm_decoder/fuzz/metrics.json").read_bytes())
    metrics["processCPUSeconds"] = 600
    receipt = finish(host_run, caller_metrics=metrics)
    assert receipt["status"] == "failed"
    assert receipt["targetCPUSeconds"] == 0


@pytest.mark.parametrize("result", [1, -9, False])
def test_supervisor_result_must_match_real_success(host_run, result):
    receipt = finish(host_run, result=result)
    assert receipt["status"] == "failed"
    assert receipt["targetCPUSeconds"] == 0


def test_duplicate_dedicated_host_receipts_never_double_count(host_run):
    for kind in ("replay", "fuzz"):
        finish(host_run, kind)
    paths = receipt_paths(host_run)
    with pytest.raises(ValueError, match="Duplicate"):
        aggregate(host_run, [*paths, paths[1]])


def test_changed_invocation_is_rejected_without_resealing(host_run):
    for kind in ("replay", "fuzz"):
        finish(host_run, kind)
    update_json(host_run / "evm_decoder/fuzz/invocation.json", extra="tampered")
    with pytest.raises(ValueError, match="changed"):
        aggregate(host_run)


@pytest.mark.parametrize("record", ["invocation.json", "invocation-result.json", "worker-metrics.json"])
@pytest.mark.parametrize("field", worker.IDENTITY_FIELDS)
def test_every_observation_binds_each_invocation_identity(host_run, record, field):
    for kind in ("replay", "fuzz"):
        finish(host_run, kind)
    phase = host_run / "evm_decoder/fuzz"
    update_json(phase / record, **{field: "stale-or-substituted"})
    if record == "invocation.json":
        update_json(phase / "invocation-result.json", invocationSHA256=evidence.sha256(phase / record))
    reseal(phase)
    with pytest.raises(ValueError, match="identity"):
        aggregate(host_run)


def test_matching_substituted_seed_observations_still_require_original_corpus(host_run):
    for kind in ("replay", "fuzz"):
        finish(host_run, kind)
    seeds = host_run / "seeds/evm_decoder"
    (seeds / "first").write_bytes(b"substituted public fixture")
    for kind in ("replay", "fuzz"):
        phase = host_run / "evm_decoder" / kind
        hashes = worker.seed_hashes(seeds)
        update_json(phase / "invocation.json", seedSHA256=hashes)
        update_json(phase / "invocation-result.json", invocationSHA256=evidence.sha256(phase / "invocation.json"))
        update_json(phase / "worker-metrics.json", observedSeedSHA256=hashes)
        update_json(phase / "metrics.json", observedSeedSHA256=hashes)
        reseal(phase)
    with pytest.raises(ValueError, match="corpus identity"):
        aggregate(host_run)


def test_legacy_rust_receipts_do_not_require_dedicated_host_records(tmp_path):
    source = {
        "revision": REVISION, "gitTree": "b" * 40, "treeSHA256": "c" * 64,
        "dirty": False, "locks": {name: "d" * 64 for name in evidence.LOCKS},
    }
    run, manifest = evidence.new_run(
        tmp_path, "rust", source, {"compilerSHA256": "e" * 64}, ["address"], ["evm_ffi"],
    )
    paths = []
    for kind, start, end in (("replay", "00", "05"), ("fuzz", "10", "30")):
        phase = run / "evm_ffi" / kind
        (phase / "corpus").mkdir(parents=True)
        (phase / "artifacts").mkdir()
        (phase / "corpus/seed").write_bytes(b"public Rust fixture")
        (phase / "process.log").write_text(COMPLETE_LOG)
        metrics = {
            "runID": manifest["runID"], "chunkID": str(uuid.uuid4()), "target": "evm_ffi",
            "phase": kind, "sourceRevision": REVISION, "processCPUSeconds": 2 if kind == "replay" else 10,
            "iterations": 12, "result": 0,
        }
        write_json(phase / "metrics.json", metrics)
        receipt = evidence.finish_receipt(
            run, manifest, phase, target="evm_ffi", kind=kind, chunk_id=metrics["chunkID"],
            started_at=f"2026-01-01T00:00:{start}.000000Z",
            ended_at=f"2026-01-01T00:00:{end}.000000Z",
            binary={"evm_ffi": "f" * 64}, binary_after={"evm_ffi": "f" * 64},
            corpus_before=evidence.directory_digest(phase / "corpus"), result=0,
            metrics=metrics, source_after=source, requested_seconds=60,
        )
        assert receipt["status"] == "passed"
        assert "completionValidation" not in receipt
        paths.append(phase / "receipt.json")
    assert evidence.aggregate(paths, REVISION, 10, ["rust/evm_ffi"])["targetCPUSeconds"] == {"rust/evm_ffi": 10}
