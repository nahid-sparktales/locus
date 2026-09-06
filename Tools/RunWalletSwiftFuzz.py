#!/usr/bin/env python3
"""Run app-hosted libFuzzer with immutable, target-CPU-accounted receipts."""

import json
import os
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path

from WalletFuzzEvidence import (
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
from WalletTestExecution import execution_lock

# LLVM 21 libFuzzer rejects the old trace-pc-guard callbacks at process startup.
# Register inline counters together with their PC table, retaining edge mode
# and comparison tracing. The linked runtime itself is not re-instrumented.
SWIFT_COVERAGE = "-sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp"


def run(arguments: list[str], **kwargs):
    return run_bounded(arguments, cwd=ROOT, check=True, **kwargs)


def retain_test_configuration(configured: Path, phase: Path, context: dict) -> str:
    """Retain exactly the bytes invoked at their original relative-path base."""
    content = configured.read_bytes()
    retained = phase / "invoked.xctestrun"
    with retained.open("xb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    identity = sha256(retained)
    immutable_json(
        phase / "invocation.json",
        {
            **context,
            "xctestrunSHA256": identity,
            "invokedPath": str(configured),
            "retainedPath": retained.name,
            "relativePathBase": str(configured.parent),
        },
    )
    return identity


def configure_tests(value: object, environment: dict[str, str]) -> int:
    count = 0
    if isinstance(value, dict):
        if value.get("BlueprintName") == "LocusTests" or "LocusTests.xctest" in str(
            value.get("TestBundlePath", "")
        ):
            value.setdefault("EnvironmentVariables", {}).update(environment)
            count += 1
        for child in value.values():
            count += configure_tests(child, environment)
    elif isinstance(value, list):
        for child in value:
            count += configure_tests(child, environment)
    return count


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
    # Isolated from normal Debug, Release and MAS. Reused across chunks only
    # while holding the shared lock; never upload this heavyweight cache.
    derived = Path(
        os.environ.get("LOCUS_FUZZ_DERIVED_DATA", output / "DerivedData-Debug-ASan")
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
        "LOCUS_LIBFUZZER",
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
    environment = os.environ | {"LOCUS_BUNDLE_MODE": "skip"}
    build_args = [
        "-project",
        "Locus.xcodeproj",
        "-scheme",
        "Locus",
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
        "-only-testing:LocusTests/WalletLibFuzzerTests",
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGN_IDENTITY=-",
        "DEVELOPMENT_TEAM=",
        "LOCUS_WALLET_SIGNER_ENTITLEMENTS=Config/WalletSignerAdHoc.entitlements",
        "LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LOCUS_DIRECT_DOWNLOAD LOCUS_LIBFUZZER",
        f"OTHER_SWIFT_FLAGS=$(inherited) {SWIFT_COVERAGE}",
        f"OTHER_LDFLAGS=$(inherited) {runtimes[0]} -lc++",
    ]
    with execution_lock(timeout=600):
        # A queued run binds the source only after obtaining its execution slot;
        # edits while another test session runs must not create a stale request.
        if require_source() != source:
            raise SystemExit("Source changed during fuzz toolchain identification")
        run_path, manifest = new_run(output, "swift", source, toolchain, flags, targets)
        run(
            ["python3", "Tools/WalletFuzzCorpus.py", str(run_path / "seeds")],
            timeout=CORPUS_SECONDS,
            timeout_receipt=run_path / "corpus-timeout.json",
            context={
                "runID": manifest["runID"],
                "operation": "corpus",
                "source": source,
            },
        )
        with (run_path / "build.log").open("x") as log:
            run(
                ["xcodebuild", "build-for-testing", *build_args],
                env=environment,
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
            raise SystemExit(
                "Source or dependency identities changed during fuzz build"
            )
        products = derived / "Build/Products"
        test_runs = [
            item
            for item in products.glob("*.xctestrun")
            if not item.name.startswith("wallet-fuzz-")
        ]
        if len(test_runs) != 1:
            raise SystemExit("Expected one generated xctestrun for isolated fuzz build")
        original = plistlib.loads(test_runs[0].read_bytes())
        app = products / "Debug/Locus.app/Contents"
        binaries = [
            app / "MacOS/Locus",
            app / "PlugIns/LocusTests.xctest/Contents/MacOS/LocusTests",
        ]
        # New Xcode may put shipping Swift code in Locus.debug.dylib.
        binaries.extend(app.rglob("*.dylib"))
        binary = {
            item.relative_to(app).as_posix(): sha256(item)
            for item in sorted(set(binaries))
        }
        for target in targets:
            for kind in ("replay", "fuzz"):
                phase = run_path / target / kind
                phase.mkdir(parents=True, exist_ok=False)
                (phase / "artifacts").mkdir()
                shutil.copytree(run_path / "seeds" / target, phase / "corpus")
                corpus_before = directory_digest(phase / "corpus")
                chunk_id = str(uuid.uuid4())
                configuration = plistlib.loads(plistlib.dumps(original))
                count = configure_tests(
                    configuration,
                    {
                        "LOCUS_FUZZ_TARGET": target,
                        "LOCUS_FUZZ_SECONDS": str(seconds),
                        "LOCUS_FUZZ_REPLAY": "1" if kind == "replay" else "0",
                        "LOCUS_FUZZ_PHASE": kind,
                        "LOCUS_FUZZ_RUN_ID": manifest["runID"],
                        "LOCUS_FUZZ_CHUNK_ID": chunk_id,
                        "LOCUS_FUZZ_CORPUS": str(phase / "corpus"),
                        "LOCUS_FUZZ_ARTIFACTS": str(phase / "artifacts"),
                        "LOCUS_FUZZ_RECEIPT": str(phase / "metrics.json"),
                        "LOCUS_FUZZ_REVISION": source["revision"],
                        "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1",
                        "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
                    },
                )
                if count != 1:
                    raise SystemExit("Expected one LocusTests configuration")
                # Preserve relative test paths without replacing the generated
                # settings or another phase's unique invocation.
                configured = products / f"wallet-fuzz-{chunk_id}.xctestrun"
                with configured.open("xb") as stream:
                    plistlib.dump(configuration, stream)
                invocation = {
                    "runID": manifest["runID"],
                    "chunkID": chunk_id,
                    "target": target,
                    "phase": kind,
                    "source": source,
                }
                configured_digest = retain_test_configuration(
                    configured, phase, invocation
                )
                start = utc_now()
                try:
                    with (phase / "process.log").open("x") as log:
                        process = run_bounded(
                            [
                                "xcodebuild",
                                "test-without-building",
                                "-xctestrun",
                                str(configured),
                                "-destination",
                                "platform=macOS",
                                "-parallel-testing-enabled",
                                "NO",
                                "-resultBundlePath",
                                str(run_path / "results" / f"{target}-{kind}.xcresult"),
                                "-only-testing:LocusTests/WalletLibFuzzerTests",
                            ],
                            cwd=ROOT,
                            env=environment,
                            stdout=log,
                            stderr=subprocess.STDOUT,
                            timeout=phase_deadline(kind, seconds),
                            timeout_receipt=phase / "timeout.json",
                            context=invocation,
                        )
                    try:
                        observed_configuration_digest = sha256(configured)
                    except OSError:
                        observed_configuration_digest = None
                    configuration_unchanged = (
                        observed_configuration_digest == configured_digest
                    )
                    immutable_json(
                        phase / "invocation-result.json",
                        {
                            **invocation,
                            "xctestrunSHA256": observed_configuration_digest,
                            "configurationUnchanged": configuration_unchanged,
                        },
                    )
                finally:
                    configured.unlink(missing_ok=True)
                end = utc_now()
                result = process.returncode
                try:
                    metrics = json.loads((phase / "metrics.json").read_text())
                except (OSError, ValueError):
                    metrics = None
                if process.timed_out or not configuration_unchanged:
                    # Keep any emitted target metrics untouched, but never use
                    # them as completion evidence for an incomplete invocation.
                    metrics = None
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
                    binary_after={
                        item.relative_to(app).as_posix(): sha256(item)
                        for item in sorted(set(binaries))
                    },
                    corpus_before=corpus_before,
                    result=result,
                    metrics=metrics,
                    source_after=source_identity(),
                    requested_seconds=seconds if kind == "fuzz" else 0,
                )
                if receipt["status"] != "passed":
                    raise SystemExit(
                        f"Swift fuzz {target}/{kind} failed; retained {phase}"
                    )
                print(
                    f"Completed {target}/{kind}: {receipt['iterations']} inputs; {receipt['targetCPUSeconds']:.3f} target CPU seconds"
                )


def main() -> None:
    with execution_lock(timeout=600):
        main_locked()


if __name__ == "__main__":
    main()
