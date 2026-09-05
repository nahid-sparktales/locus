"""Receipt/accounting checks use synthetic processes, never release evidence."""

import copy
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import RunWalletSwiftFuzz as swift_runner  # noqa: E402
import WalletFuzzEvidence as evidence  # noqa: E402


@pytest.fixture
def campaign(tmp_path):
    source = {
        "revision": "a" * 40,
        "gitTree": "b" * 40,
        "treeSHA256": "c" * 64,
        "dirty": False,
        "locks": {name: "d" * 64 for name in evidence.LOCKS},
    }
    run, manifest = evidence.new_run(
        tmp_path,
        "swift",
        source,
        {"compilerSHA256": "e" * 64},
        ["address", swift_runner.SWIFT_COVERAGE],
        ["evm_decoder"],
    )
    paths = []
    for kind, cpu, start, end in (("replay", 2.0, "00", "05"), ("fuzz", 10.0, "10", "30")):
        phase = run / "evm_decoder" / kind
        (phase / "corpus").mkdir(parents=True)
        (phase / "artifacts").mkdir()
        (phase / "corpus/seed").write_bytes(b"fixture")
        (phase / "process.log").write_text(
            "#12 DONE cov: 42 ft: 55\nstat::number_of_executed_units: 12\n"
        )
        metrics = {
            "runID": manifest["runID"],
            "chunkID": str(uuid.uuid4()),
            "target": "evm_decoder",
            "phase": kind,
            "sourceRevision": source["revision"],
            "processCPUSeconds": cpu,
            "iterations": 12,
            "result": 0,
        }
        evidence.immutable_json(phase / "metrics.json", metrics)
        binary = {"LocusTests": "f" * 64}
        evidence.finish_receipt(
            run,
            manifest,
            phase,
            target="evm_decoder",
            kind=kind,
            chunk_id=metrics["chunkID"],
            started_at=f"2026-01-01T00:00:{start}.000000Z",
            ended_at=f"2026-01-01T00:00:{end}.000000Z",
            binary=binary,
            binary_after=binary,
            corpus_before=evidence.directory_digest(phase / "corpus"),
            result=0,
            metrics=metrics,
            source_after=source,
            requested_seconds=60,
        )
        paths.append(phase / "receipt.json")
    return tmp_path, paths


def aggregate(paths, cpu=10):
    return evidence.aggregate(paths, "a" * 40, cpu, ["swift/evm_decoder"])


def alter(path, update):
    receipt = json.loads(path.read_text())
    receipt.pop("receiptSHA256")
    update(receipt)
    receipt["receiptSHA256"] = evidence.digest(receipt)
    path.write_bytes(evidence.canonical(receipt))


def test_counts_only_fuzz_cpu_not_replay_or_wall_budget(campaign):
    root, paths = campaign
    assert aggregate(paths)["targetCPUSeconds"] == {"swift/evm_decoder": 10}
    assert aggregate(paths)["releaseApproval"] is False
    assert set(evidence.discover_receipts([root])) == set(paths)
    with pytest.raises(ValueError, match="Insufficient"):
        aggregate(paths, 11)


def test_phase_and_run_files_are_immutable(campaign):
    _, paths = campaign
    with pytest.raises(FileExistsError):
        evidence.immutable_json(paths[0], {})
    with pytest.raises(FileExistsError):
        evidence.immutable_json(paths[0].parents[2] / "run.json", {})


def test_duplicate_receipt_does_not_double_cpu(campaign):
    _, paths = campaign
    with pytest.raises(ValueError, match="Duplicate"):
        aggregate([*paths, paths[1]])


def test_fuzz_requires_own_replay(campaign):
    _, paths = campaign
    with pytest.raises(ValueError, match="replay"):
        aggregate([paths[1]])


def test_discovery_rejects_incomplete_run(campaign):
    root, paths = campaign
    paths[0].unlink()
    with pytest.raises(ValueError, match="Incomplete"):
        evidence.discover_receipts([root])


def test_discovery_rejects_build_failure_without_receipts(campaign):
    root, _ = campaign
    evidence.new_run(root, "rust", {}, {}, ["address"], ["evm_ffi"])
    with pytest.raises(ValueError, match="Incomplete"):
        evidence.discover_receipts([root])


@pytest.mark.parametrize(
    "change",
    [
        lambda value: value["source"].update(revision="b" * 40),
        lambda value: value["source"].update(dirty=True),
        lambda value: value["sourceAfter"].update(treeSHA256="d" * 64),
        lambda value: value.update(status="failed"),
        lambda value: value.update(findings=True),
        lambda value: value.update(result=1),
        lambda value: value.update(toolchain={}),
        lambda value: value.update(binary={}),
        lambda value: value.update(binaryAfter={"other": "a" * 64}),
        lambda value: value.update(flags=[]),
        lambda value: value.update(targetCPUSeconds=-1),
        lambda value: value.update(targetCPUSeconds=True),
        lambda value: value.update(iterations=0),
        lambda value: value.update(startedAt="2026-01-01T00:00:10Z"),
        lambda value: value.update(endedAt="2025-01-01T00:00:10.000000Z"),
        lambda value: value.update(endedAt="2999-01-01T00:00:10.000000Z"),
        lambda value: value.update(corpusBeforeSHA256="0" * 64),
        lambda value: value.update(corpusAfterSHA256="0" * 64),
    ],
)
def test_rejects_semantically_invalid_resealed_receipts(campaign, change):
    _, paths = campaign
    alter(paths[1], change)
    with pytest.raises(ValueError):
        aggregate(paths)


def test_rejects_log_tampering(campaign):
    _, paths = campaign
    (paths[1].parent / "process.log").write_text("replacement")
    with pytest.raises(ValueError, match="changed"):
        aggregate(paths)


def test_rejects_missing_completion_metrics(campaign):
    _, paths = campaign
    (paths[1].parent / "metrics.json").unlink()
    with pytest.raises(FileNotFoundError):
        aggregate(paths)


def test_rejects_stale_target_metrics_even_when_file_hash_is_updated(campaign):
    _, paths = campaign
    metrics = paths[1].parent / "metrics.json"
    value = json.loads(metrics.read_text())
    value["chunkID"] = str(uuid.uuid4())
    metrics.write_bytes(evidence.canonical(value))
    alter(
        paths[1],
        lambda receipt: receipt["files"].update({"metrics.json": evidence.sha256(metrics)}),
    )
    with pytest.raises(ValueError, match="completion metrics"):
        aggregate(paths)


def test_rejects_late_unrecorded_crash_input(campaign):
    _, paths = campaign
    (paths[1].parent / "artifacts/crash-input").write_bytes(b"crash")
    with pytest.raises(ValueError, match="Unrecorded"):
        aggregate(paths)


def test_failure_receipt_never_counts_despite_return_zero(campaign):
    _, paths = campaign
    receipt = json.loads(paths[1].read_text())
    phase = paths[1].parent
    paths[1].unlink()
    (phase / "process.log").write_text("ERROR: AddressSanitizer: heap-buffer-overflow\n")
    manifest = json.loads((phase.parents[1] / "run.json").read_text())
    result = evidence.finish_receipt(
        phase.parents[1],
        manifest,
        phase,
        target="evm_decoder",
        kind="fuzz",
        chunk_id=receipt["chunkID"],
        started_at=receipt["startedAt"],
        ended_at=receipt["endedAt"],
        binary=receipt["binary"],
        binary_after=receipt["binary"],
        corpus_before=receipt["corpusBeforeSHA256"],
        result=0,
        metrics=json.loads((phase / "metrics.json").read_text()),
        source_after=receipt["sourceAfter"],
        requested_seconds=60,
    )
    assert result["status"] == "failed"
    with pytest.raises(ValueError, match="finding"):
        aggregate(paths)


def test_swift_flag_has_required_edge_mode_and_preserves_test_configuration():
    assert swift_runner.SWIFT_COVERAGE == "-sanitize-coverage=edge,trace-pc-guard,trace-cmp"
    original = {
        "TestConfigurations": [
            {
                "TestTargets": [
                    {
                        "BlueprintName": "LocusTests",
                        "EnvironmentVariables": {"existing": "retained"},
                    },
                    {"BlueprintName": "LocusUITests"},
                ]
            }
        ]
    }
    value = copy.deepcopy(original)
    assert swift_runner.configure_tests(value, {"LOCUS_FUZZ_PHASE": "replay"}) == 1
    target = value["TestConfigurations"][0]["TestTargets"][0]
    assert target["EnvironmentVariables"] == {"existing": "retained", "LOCUS_FUZZ_PHASE": "replay"}
    assert "LOCUS_FUZZ_PHASE" not in str(original)


def test_source_identity_rejects_untracked_and_tracked_dirty_tree(tmp_path, monkeypatch):
    def git(*args):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True)

    git("init", "-q")
    (tmp_path / "source").write_text("first")
    git("add", "source")
    git(
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "commit",
        "-qm",
        "fixture",
    )
    original = evidence.require_source(tmp_path)
    (tmp_path / "untracked").write_text("untracked")
    monkeypatch.delenv("LOCUS_FUZZ_ALLOW_DIRTY", raising=False)
    with pytest.raises(ValueError, match="clean"):
        evidence.require_source(tmp_path)
    monkeypatch.setenv("LOCUS_FUZZ_ALLOW_DIRTY", "1")
    dirty = evidence.require_source(tmp_path)
    assert dirty["dirty"] and dirty["treeSHA256"] != original["treeSHA256"]
    (tmp_path / "source").write_text("changed")
    assert evidence.source_identity(tmp_path)["treeSHA256"] != dirty["treeSHA256"]


def test_materialized_targets_have_distinct_public_metadata_seed(tmp_path):
    subprocess.run(
        [sys.executable, str(ROOT / "Tools/WalletFuzzCorpus.py"), str(tmp_path)],
        check=True,
        capture_output=True,
    )
    assert {path.name for path in tmp_path.iterdir()} == {
        target for values in evidence.TARGETS.values() for target in values
    }
    metadata = list((tmp_path / "metadata").iterdir())
    assert len(metadata) == 1
    assert json.loads(metadata[0].read_text())["canonicalID"] == "eip155:11155111/slip44:60"
    assert evidence.directory_digest(tmp_path / "metadata") != evidence.directory_digest(
        tmp_path / "connections"
    )


def test_distinct_chunk_ids_do_not_hide_overlapping_cpu_claims(campaign):
    root, paths = campaign
    original_run = paths[0].parents[2]
    next_id = str(uuid.uuid4())
    copied_run = root / "runs" / next_id
    shutil.copytree(original_run, copied_run)
    manifest_path = copied_run / "run.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["runID"] = next_id
    manifest_path.write_bytes(evidence.canonical(manifest))
    copied_paths = []
    for original_path in paths:
        path = copied_run / original_path.relative_to(original_run)
        receipt = json.loads(path.read_text())
        metrics_path = path.parent / "metrics.json"
        metrics = json.loads(metrics_path.read_text())
        metrics.update(runID=next_id, chunkID=str(uuid.uuid4()))
        metrics_path.write_bytes(evidence.canonical(metrics))
        receipt.pop("receiptSHA256")
        receipt.update(
            runID=next_id,
            chunkID=metrics["chunkID"],
            runManifestSHA256=evidence.sha256(manifest_path),
        )
        receipt["files"]["metrics.json"] = evidence.sha256(metrics_path)
        receipt["receiptSHA256"] = evidence.digest(receipt)
        path.write_bytes(evidence.canonical(receipt))
        copied_paths.append(path)
    with pytest.raises(ValueError, match="Overlapping"):
        aggregate([*paths, *copied_paths], 20)


def test_missing_lockfile_identity_is_not_accepted_as_a_different_campaign(campaign):
    _, paths = campaign
    alter(paths[1], lambda receipt: receipt["source"]["locks"].pop(evidence.LOCKS[0]))
    with pytest.raises(ValueError):
        aggregate(paths)
