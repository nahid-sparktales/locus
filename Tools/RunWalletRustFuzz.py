#!/usr/bin/env python3
"""Build pinned Rust fuzzers once, then account only direct target-process CPU."""

import os
import resource
import shutil
import subprocess
import uuid
from pathlib import Path

from WalletFuzzEvidence import (
    ROOT,
    TARGETS,
    coverage,
    directory_digest,
    finish_receipt,
    immutable_json,
    new_run,
    require_source,
    sha256,
    source_identity,
    utc_now,
)
from WalletFuzzProcess import (
    BUILD_SECONDS,
    CORPUS_SECONDS,
    FETCH_SECONDS,
    VERSION_SECONDS,
    phase_deadline,
    run_bounded,
)
from WalletRustFuzzerDependency import verify as verify_fuzzer_dependency
from WalletTestExecution import execution_lock

NIGHTLY = "nightly-2026-09-01"


def main_locked():
    seconds = int(os.environ.get("LOCUS_FUZZ_SECONDS", "60"))
    if not 1 <= seconds <= 86400:
        raise SystemExit("LOCUS_FUZZ_SECONDS must be 1...86400 wall seconds per chunk")
    targets = (
        [os.environ["LOCUS_FUZZ_TARGET"]]
        if os.environ.get("LOCUS_FUZZ_TARGET")
        else list(TARGETS["rust"])
    )
    if not set(targets).issubset(TARGETS["rust"]):
        raise SystemExit("Unknown Rust fuzz target")
    source = require_source()
    fuzzer_dependency = verify_fuzzer_dependency()
    output = Path(
        os.environ.get("LOCUS_FUZZ_OUTPUT", ROOT / "build/wallet-fuzz-rust")
    ).resolve()
    startup_failures = output / "runs" / f"startup-{uuid.uuid4()}"

    def tool_output(arguments, operation):
        return run_bounded(
            arguments,
            check=True,
            timeout=VERSION_SECONDS,
            timeout_receipt=startup_failures / f"{operation}-timeout.json",
            context={"language": "rust", "operation": operation, "source": source},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout

    version = tool_output(["cargo", "fuzz", "--version"], "cargo-fuzz-version").strip()
    if version != "cargo-fuzz 0.13.2":
        raise SystemExit("Install cargo-fuzz 0.13.2 with --locked")
    rustc = Path(
        tool_output(
            ["rustup", "which", "--toolchain", NIGHTLY, "rustc"], "rust-location"
        ).strip()
    )
    rust_version = tool_output([str(rustc), "-vV"], "rust-version")
    triple = next(
        line.removeprefix("host: ")
        for line in rust_version.splitlines()
        if line.startswith("host: ")
    )
    cargo_fuzz = Path(shutil.which("cargo-fuzz") or "")
    toolchain = {
        "rustVersion": rust_version,
        "rustSHA256": sha256(rustc),
        "nightly": NIGHTLY,
        "cargoFuzzVersion": version,
        "cargoFuzzSHA256": sha256(cargo_fuzz),
        "targetTriple": triple,
        "libfuzzerDependency": fuzzer_dependency,
    }
    # cargo-fuzz's reviewed defaults are optimized + debug assertions/overflow
    # checks. Rust ASan is not claimed as UBSan instrumentation.
    flags = [
        "--sanitizer=address",
        "--debug-assertions",
        "--target=" + triple,
        "cargo-fuzz-default-coverage",
        "-max_len=16384",
        "-timeout=10",
        "-rss_limit_mb=4096",
    ]
    run_path, manifest = new_run(output, "rust", source, toolchain, flags, targets)
    build_cache = Path(
        os.environ.get(
            "LOCUS_FUZZ_RUST_TARGET_DIR", ROOT / "WalletSignerCore/fuzz/target"
        )
    ).resolve()
    environment = os.environ | {
        "CARGO_NET_OFFLINE": "true",
        "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1:detect_leaks=1",
    }
    core = ROOT / "WalletSignerCore"
    with execution_lock(timeout=600):
        run_bounded(
            [
                "cargo",
                f"+{NIGHTLY}",
                "fetch",
                "--locked",
                "--manifest-path",
                "fuzz/Cargo.toml",
            ],
            cwd=core,
            check=True,
            timeout=FETCH_SECONDS,
            timeout_receipt=run_path / "fetch-timeout.json",
            context={
                "runID": manifest["runID"],
                "operation": "fetch",
                "source": source,
            },
        )
        run_bounded(
            ["python3", "Tools/WalletFuzzCorpus.py", str(run_path / "seeds")],
            cwd=ROOT,
            check=True,
            timeout=CORPUS_SECONDS,
            timeout_receipt=run_path / "corpus-timeout.json",
            context={
                "runID": manifest["runID"],
                "operation": "corpus",
                "source": source,
            },
        )
        for target in targets:
            with (run_path / f"build-{target}.log").open("x") as log:
                run_bounded(
                    [
                        "cargo",
                        f"+{NIGHTLY}",
                        "fuzz",
                        "build",
                        "--sanitizer",
                        "address",
                        "--debug-assertions",
                        "--target",
                        triple,
                        "--target-dir",
                        str(build_cache),
                        target,
                    ],
                    cwd=core,
                    env=environment,
                    check=True,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=BUILD_SECONDS,
                    timeout_receipt=run_path / f"build-{target}-timeout.json",
                    context={
                        "runID": manifest["runID"],
                        "operation": "build",
                        "target": target,
                        "source": source,
                    },
                )
            if source_identity() != source:
                raise SystemExit(
                    "Source or dependency identities changed during fuzz build"
                )
            executable = build_cache / triple / "release" / target
            binary = {target: sha256(executable)}
            for kind in ("replay", "fuzz"):
                phase = run_path / target / kind
                phase.mkdir(parents=True, exist_ok=False)
                (phase / "artifacts").mkdir()
                shutil.copytree(run_path / "seeds" / target, phase / "corpus")
                corpus_before = directory_digest(phase / "corpus")
                chunk_id = str(uuid.uuid4())
                start = utc_now()
                # No cargo/compiler child is included in these measurements.
                # This runner owns exactly one direct subprocess in this scope.
                before = resource.getrusage(resource.RUSAGE_CHILDREN)
                with (phase / "process.log").open("x") as log:
                    process = run_bounded(
                        [
                            str(executable),
                            str(phase / "corpus"),
                            "-runs=0"
                            if kind == "replay"
                            else f"-max_total_time={seconds}",
                            "-timeout=10",
                            "-max_len=16384",
                            "-rss_limit_mb=4096",
                            "-print_final_stats=1",
                            f"-artifact_prefix={phase / 'artifacts'}/",
                        ],
                        cwd=core,
                        env=environment,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                        timeout=phase_deadline(kind, seconds),
                        timeout_receipt=phase / "timeout.json",
                        context={
                            "runID": manifest["runID"],
                            "chunkID": chunk_id,
                            "target": target,
                            "phase": kind,
                            "source": source,
                        },
                    )
                result = process.returncode
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                end = utc_now()
                stats = coverage((phase / "process.log").read_text(errors="replace"))
                metrics = {
                    "runID": manifest["runID"],
                    "chunkID": chunk_id,
                    "phase": kind,
                    "target": target,
                    "sourceRevision": source["revision"],
                    "result": result,
                    "iterations": stats["executedUnits"],
                    "processCPUSeconds": (after.ru_utime + after.ru_stime)
                    - (before.ru_utime + before.ru_stime),
                }
                immutable_json(phase / "metrics.json", metrics)
                receipt = finish_receipt(
                    run_path,
                    manifest,
                    phase,
                    target=target,
                    kind=kind,
                    chunk_id=chunk_id,
                    started_at=start,
                    ended_at=end,
                    binary=binary,
                    binary_after={target: sha256(executable)},
                    corpus_before=corpus_before,
                    result=result,
                    metrics=metrics,
                    source_after=source_identity(),
                    requested_seconds=seconds if kind == "fuzz" else 0,
                )
                if (
                    sha256(executable) != binary[target]
                    or receipt["status"] != "passed"
                ):
                    raise SystemExit(
                        f"Rust fuzz {target}/{kind} failed; retained {phase}"
                    )
                print(
                    f"Completed {target}/{kind}: {metrics['iterations']} inputs; {metrics['processCPUSeconds']:.3f} target CPU seconds"
                )


def main():
    with execution_lock(timeout=600):
        main_locked()


if __name__ == "__main__":
    main()
