#!/usr/bin/env python3
"""Run unchanged libFuzzer in a dedicated, instrumented Debug process."""

import os
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path

from WalletFuzzEvidence import (
    FINDING,
    ROOT,
    TARGETS,
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
    VERSION_SECONDS,
    phase_deadline,
    run_bounded,
)
from WalletSwiftFuzzWorker import (
    EXECUTION_MODEL,
    read_record,
    seed_hashes,
    validate_phase,
)
from WalletTestExecution import execution_lock

# Do not re-instrument the runtime. Swift supports ASan and coverage; undefined
# behavior instrumentation applies only to applicable compiled C/C++ objects.
SWIFT_COVERAGE = "-sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp"


def run(arguments: list[str], **kwargs):
    return run_bounded(arguments, cwd=ROOT, check=True, **kwargs)


def worker_environment(phase: Path, context: dict, seconds: int) -> dict[str, str]:
    # Do not inherit provider credentials, app launch flags or loader overrides.
    environment = {
        key: os.environ[key]
        for key in ("PATH", "TMPDIR", "LANG", "LC_ALL", "SYSTEMROOT")
        if key in os.environ
    }
    environment.update(
        {
            "LOCUS_FUZZ_TARGET": context["target"],
            "LOCUS_FUZZ_SECONDS": str(seconds),
            "LOCUS_FUZZ_REPLAY": "1" if context["phase"] == "replay" else "0",
            "LOCUS_FUZZ_PHASE": context["phase"],
            "LOCUS_FUZZ_RUN_ID": context["runID"],
            "LOCUS_FUZZ_CHUNK_ID": context["chunkID"],
            "LOCUS_FUZZ_CORPUS": str(phase / "corpus"),
            "LOCUS_FUZZ_ARTIFACTS": str(phase / "artifacts"),
            "LOCUS_FUZZ_RECEIPT": str(phase / "worker-metrics.json"),
            "LOCUS_FUZZ_REVISION": context["sourceRevision"],
            "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1",
            "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
        }
    )
    return environment


def bundle_identity(app: Path) -> dict[str, str]:
    """Bind resources and code, permitting framework links only inside the app."""
    root = app.resolve(strict=True)
    identities = {}
    for item in sorted(app.rglob("*")):
        if item.is_symlink() and not item.resolve(strict=True).is_relative_to(root):
            raise ValueError("Fuzz bundle contains an escaping symbolic link")
        if item.is_file():
            identities[item.relative_to(app).as_posix()] = sha256(item)
    if not identities:
        raise ValueError("Missing dedicated fuzz host")
    return identities


def inspect_host(app: Path, derived: Path, output: Path, context: dict) -> Path:
    executable = app / "Contents/MacOS/WalletFuzzHost"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (
        info.get("CFBundleIdentifier") != "io.sparktales.locus.wallet-fuzz-host"
        or info.get("CFBundleExecutable") != "WalletFuzzHost"
    ):
        raise ValueError("Unexpected fuzz host identity")
    forbidden = (
        "WalletSigner",
        "WalletRecovery",
        ".xctest",
        "wallet-connectors",
        "connector.bundle",
        "wallet-activation",
        "agent-runtime",
    )
    if any(any(name in str(path) for name in forbidden) for path in app.rglob("*")):
        raise ValueError("Fuzz host contains production/test embedding")
    if any(key.startswith("LOCUS_") or key.startswith("SU") for key in info):
        raise ValueError("Fuzz host contains production configuration")
    inventories = {}
    for name, arguments in {
        "symbols": ["xcrun", "nm", str(executable)],
        "load-commands": ["xcrun", "otool", "-L", str(executable)],
        "sections": ["xcrun", "otool", "-l", str(executable)],
    }.items():
        result = run(
            arguments,
            timeout=VERSION_SECONDS,
            timeout_receipt=output / f"{name}-timeout.json",
            context=context,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        inventories[name] = result.stdout
        with (output / f"{name}.txt").open("x") as stream:
            stream.write(result.stdout)
    symbols = inventories["symbols"]
    if (
        "LLVMFuzzerRunDriver" not in symbols
        or "WalletDappTransactionDecoder" not in symbols
        or "__asan" not in symbols
        or "sancov" not in inventories["sections"]
    ):
        raise ValueError("Fuzz host lacks engine, production decoder, ASan or coverage")
    if "XCTest" in inventories["load-commands"] or "locus_wallet_signer_" in symbols:
        raise ValueError("Fuzz host links a test host or signer core")
    # The engine/startup also has coverage. Inspect the actual production
    # decoder object separately, so their counters cannot satisfy this check.
    objects = list(
        (
            derived
            / "Build/Intermediates.noindex/Locus.build/Debug/WalletFuzzHost.build/Objects-normal"
        ).glob("*/WalletDappTransactionDecoder.o")
    )
    if not objects:
        raise ValueError("Missing production decoder instrumentation object")
    decoder_objects = {}
    for item in objects:
        sections = run(
            ["xcrun", "otool", "-l", str(item)],
            timeout=VERSION_SECONDS,
            timeout_receipt=output / f"decoder-{item.parent.name}-timeout.json",
            context=context,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
        if "__sancov_cntrs" not in sections or "__sancov_pcs" not in sections:
            raise ValueError("Production decoder lacks coverage counters or PC table")
        name = f"decoder-{item.parent.name}-sections.txt"
        with (output / name).open("x") as stream:
            stream.write(sections)
        decoder_objects[item.parent.name] = {
            "objectSHA256": sha256(item),
            "sectionsSHA256": sha256(output / name),
        }
    immutable_json(
        output / "host-audit.json",
        {
            "executionModel": EXECUTION_MODEL,
            "binary": bundle_identity(app),
            "inventories": {
                name: sha256(output / f"{name}.txt") for name in inventories
            },
            "swiftInstrumentation": ["address", SWIFT_COVERAGE],
            "productionDecoderObjects": decoder_objects,
            "cxxInstrumentation": ["undefined (applicable compiled C/C++ only)"],
            "leakDetection": "unavailable on this platform; not claimed",
        },
    )
    return executable


def invoke_worker(
    executable: Path,
    phase: Path,
    context: dict,
    seconds: int,
    *,
    self_test: str | None = None,
):
    arguments = [str(executable)] + (["--self-test", self_test] if self_test else [])
    environment = worker_environment(phase, context, seconds)
    if self_test == "fixtures":
        environment["LOCUS_FUZZ_FIXTURE_RECEIPT"] = str(phase / "fixtures.json")
    immutable_json(
        phase / "invocation.json",
        {
            **context,
            "executionModel": EXECUTION_MODEL,
            "command": arguments,
            "environment": environment,
            "seedSHA256": seed_hashes(phase / "corpus"),
            "seedCorpusSHA256": directory_digest(phase / "corpus"),
            "executableSHA256": sha256(executable),
        },
    )
    invocation_digest = sha256(phase / "invocation.json")
    with (phase / "process.log").open("x") as log:
        process = run_bounded(
            arguments,
            cwd=phase,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=2
            if self_test == "hang"
            else phase_deadline(context["phase"], seconds),
            timeout_receipt=phase / "timeout.json",
            context=context,
        )
    immutable_json(
        phase / "invocation-result.json",
        {
            **context,
            "executionModel": EXECUTION_MODEL,
            "invocationSHA256": invocation_digest,
            "processID": process.process_id,
            "result": process.returncode,
            "timedOut": process.timed_out,
        },
    )
    return process


def validated_metrics(phase: Path, context: dict) -> dict:
    log = (phase / "process.log").read_text(errors="replace")
    findings = bool(FINDING.search(log)) or any((phase / "artifacts").iterdir())
    return validate_phase(phase, context, log, findings)


def verify_failure_controls(executable: Path, run_path: Path, manifest: dict) -> None:
    """Real process controls never earn corpus/campaign credit."""
    results = []
    for mode in ("early-exit", "crash", "hang", "missing-metrics", "sanitizer"):
        phase = run_path / "self-tests" / mode
        phase.mkdir(parents=True, exist_ok=False)
        (phase / "artifacts").mkdir()
        shutil.copytree(run_path / "seeds/evm_decoder", phase / "corpus")
        context = {
            "runID": manifest["runID"],
            "chunkID": str(uuid.uuid4()),
            "target": "evm_decoder",
            "phase": "replay",
            "sourceRevision": manifest["source"]["revision"],
        }
        process = invoke_worker(executable, phase, context, 1, self_test=mode)
        if mode in ("early-exit", "missing-metrics") and (
            process.returncode != 0 or process.timed_out
        ):
            raise ValueError("Ordinary-exit control did not reach its intended exit")
        if (
            mode == "early-exit"
            and read_record(phase / "worker-metrics.json").get("iterations") != 0
        ):
            raise ValueError("Early-exit control unexpectedly exercised the driver")
        if mode == "missing-metrics" and (phase / "worker-metrics.json").exists():
            raise ValueError(
                "Missing-metrics control unexpectedly emitted observations"
            )
        if mode == "hang" and not process.timed_out:
            raise ValueError("Hang control did not reach the supervisor deadline")
        if mode == "crash" and (process.returncode == 0 or process.timed_out):
            raise ValueError("Crash control did not terminate abnormally")
        if mode == "sanitizer" and (
            process.returncode == 0
            or process.timed_out
            or "ERROR: AddressSanitizer: heap-buffer-overflow"
            not in (phase / "process.log").read_text(errors="replace")
        ):
            raise ValueError(
                "ASan negative control did not detect its injected finding"
            )
        try:
            validated_metrics(phase, context)
        except (OSError, ValueError, KeyError):
            results.append(
                {"mode": mode, "rejected": True, "result": process.returncode}
            )
        else:
            raise ValueError(f"Fuzz failure control {mode} was incorrectly accepted")
    immutable_json(
        run_path / "self-tests/result.json",
        {
            "executionModel": EXECUTION_MODEL,
            "results": results,
            "campaignCredit": False,
            "releaseApproval": False,
        },
    )


def verify_decoder_fixtures(executable: Path, run_path: Path, manifest: dict) -> None:
    phase = run_path / "self-tests/fixtures"
    phase.mkdir(parents=True, exist_ok=False)
    (phase / "artifacts").mkdir()
    shutil.copytree(run_path / "seeds/evm_decoder", phase / "corpus")
    context = {
        "runID": manifest["runID"],
        "chunkID": str(uuid.uuid4()),
        "target": "evm_decoder",
        "phase": "replay",
        "sourceRevision": manifest["source"]["revision"],
    }
    process = invoke_worker(executable, phase, context, 1, self_test="fixtures")
    if process.returncode != 0 or process.timed_out:
        raise ValueError("Deterministic production decoder success self-test failed")
    report = read_record(phase / "fixtures.json")
    expected_reads = {
        "solana.core-standalone": 0,
        "solana.native-transfer": 0,
        "solana.spl-existing-ata": 2,
        "solana.spl-new-ata": 1,
        "solana.v0-native-lookup": 1,
        "sui.coin": 1,
        "sui.native-transfer": 0,
        "sui.public-object": 1,
    }
    expected_report = {
        "schemaVersion": 1,
        "runID": context["runID"],
        "chunkID": context["chunkID"],
        "sourceRevision": context["sourceRevision"],
        "processID": process.process_id,
        "passedBranches": sorted(expected_reads),
        "readCounts": expected_reads,
    }
    if report != expected_report or (phase / "worker-metrics.json").exists():
        raise ValueError(
            "Incomplete, stale or unexpected deterministic fixture receipt"
        )
    if FINDING.search((phase / "process.log").read_text(errors="replace")) or any(
        (phase / "artifacts").iterdir()
    ):
        raise ValueError("Deterministic fixtures reported a finding")
    immutable_json(
        phase / "verification.json",
        {
            "fixtureReceiptSHA256": sha256(phase / "fixtures.json"),
            "invocationSHA256": sha256(phase / "invocation.json"),
            "observedResultSHA256": sha256(phase / "invocation-result.json"),
            "campaignCredit": False,
            "releaseApproval": False,
        },
    )


def main_locked() -> None:
    seconds = int(os.environ.get("LOCUS_FUZZ_SECONDS", "60"))
    if not 1 <= seconds <= 86400:
        raise SystemExit("LOCUS_FUZZ_SECONDS must be 1...86400 wall seconds per chunk")
    targets = (
        [os.environ["LOCUS_FUZZ_TARGET"]]
        if os.environ.get("LOCUS_FUZZ_TARGET")
        else list(TARGETS["swift"])
    )
    if not set(targets).issubset(TARGETS["swift"]):
        raise SystemExit("Unknown Swift fuzz target")
    output = Path(
        os.environ.get("LOCUS_FUZZ_OUTPUT", ROOT / "build/wallet-fuzz-swift")
    ).resolve()
    derived = Path(
        os.environ.get(
            "LOCUS_FUZZ_DERIVED_DATA", output / "DerivedData-Host-Debug-ASan"
        )
    ).resolve()
    source = require_source()
    startup_failures = output / "runs" / f"startup-{uuid.uuid4()}"

    def tool_output(arguments, operation):
        return run(
            arguments,
            timeout=VERSION_SECONDS,
            timeout_receipt=startup_failures / f"{operation}-timeout.json",
            context={"language": "swift", "operation": operation, "source": source},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout

    llvm = Path(os.environ.get("LOCUS_FUZZ_LLVM_PREFIX", "/opt/homebrew/opt/llvm@21"))
    compiler = llvm / "bin/clang"
    version = tool_output([str(compiler), "--version"], "clang-version")
    if "clang version 21.1.8" not in version:
        raise SystemExit(
            "Install reviewed test-only llvm@21 21.1.8 or set LOCUS_FUZZ_LLVM_PREFIX"
        )
    runtimes = list(
        (llvm / "lib/clang").glob("*/lib/darwin/libclang_rt.fuzzer_no_main_osx.a")
    )
    if len(runtimes) != 1:
        raise SystemExit("Expected one libFuzzer no-main runtime")
    flags = [
        "address",
        "undefined",
        SWIFT_COVERAGE,
        "LOCUS_WALLET_FUZZ_HOST",
        EXECUTION_MODEL,
        "Debug",
        "-max_len=16384",
        "-timeout=10",
        "-rss_limit_mb=4096",
    ]
    swift = Path(tool_output(["xcrun", "--find", "swiftc"], "swift-location").strip())
    toolchain = {
        "clangVersion": version,
        "clangSHA256": sha256(compiler),
        "fuzzerRuntimeSHA256": sha256(runtimes[0]),
        "swiftSHA256": sha256(swift),
        "swiftVersion": tool_output([str(swift), "--version"], "swift-version"),
        "xcodeVersion": tool_output(["xcodebuild", "-version"], "xcode-version"),
    }
    build_args = [
        "-project",
        "Locus.xcodeproj",
        "-scheme",
        "WalletFuzzHost",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(derived),
        "-enableAddressSanitizer",
        "YES",
        "-enableUndefinedBehaviorSanitizer",
        "YES",
        "CODE_SIGN_IDENTITY=-",
        "DEVELOPMENT_TEAM=",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LOCUS_DIRECT_DOWNLOAD LOCUS_WALLET_FUZZ_HOST",
        f"OTHER_SWIFT_FLAGS=$(inherited) {SWIFT_COVERAGE}",
        f"OTHER_LDFLAGS=$(inherited) {runtimes[0]} -lc++",
    ]
    if require_source() != source:
        raise SystemExit("Source changed during fuzz toolchain identification")
    run_path, manifest = new_run(output, "swift", source, toolchain, flags, targets)
    run(
        ["python3", "Tools/WalletFuzzCorpus.py", str(run_path / "seeds")],
        timeout=CORPUS_SECONDS,
        timeout_receipt=run_path / "corpus-timeout.json",
        context={"runID": manifest["runID"], "operation": "corpus", "source": source},
    )
    with (run_path / "build.log").open("x") as log:
        run(
            ["xcodebuild", "build", *build_args],
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=BUILD_SECONDS,
            timeout_receipt=run_path / "build-timeout.json",
            context={
                "runID": manifest["runID"],
                "operation": "build",
                "source": source,
            },
        )
    if source_identity() != source:
        raise SystemExit("Source or dependency identities changed during fuzz build")
    app = derived / "Build/Products/Debug/WalletFuzzHost.app"
    executable = inspect_host(
        app, derived, run_path, {"runID": manifest["runID"], "operation": "host-audit"}
    )
    binary = bundle_identity(app)
    verify_failure_controls(executable, run_path, manifest)
    verify_decoder_fixtures(executable, run_path, manifest)
    for target in targets:
        for kind in ("replay", "fuzz"):
            phase = run_path / target / kind
            phase.mkdir(parents=True, exist_ok=False)
            (phase / "artifacts").mkdir()
            shutil.copytree(run_path / "seeds" / target, phase / "corpus")
            corpus_before = directory_digest(phase / "corpus")
            context = {
                "runID": manifest["runID"],
                "chunkID": str(uuid.uuid4()),
                "target": target,
                "phase": kind,
                "sourceRevision": source["revision"],
            }
            start = utc_now()
            process = invoke_worker(executable, phase, context, seconds)
            end = utc_now()
            try:
                metrics = validated_metrics(phase, context)
            except (OSError, ValueError, KeyError) as error:
                metrics = None
                immutable_json(
                    phase / "validation-failure.json", {"reason": str(error)}
                )
            else:
                immutable_json(phase / "metrics.json", metrics)
            receipt = finish_receipt(
                run_path,
                manifest,
                phase,
                target=target,
                kind=kind,
                chunk_id=context["chunkID"],
                started_at=start,
                ended_at=end,
                binary=binary,
                binary_after=bundle_identity(app),
                corpus_before=corpus_before,
                result=process.returncode,
                metrics=metrics,
                source_after=source_identity(),
                requested_seconds=seconds if kind == "fuzz" else 0,
            )
            if receipt["status"] != "passed":
                raise SystemExit(f"Swift fuzz {target}/{kind} failed; retained {phase}")
            print(
                f"Completed {target}/{kind}: {receipt['iterations']} inputs; "
                f"{receipt['targetCPUSeconds']:.3f} target CPU seconds",
                flush=True,
            )


def main() -> None:
    with execution_lock(timeout=600):
        main_locked()


if __name__ == "__main__":
    main()
