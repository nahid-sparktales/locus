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
    new_run,
    require_source,
    sha256,
    source_identity,
    utc_now,
)
from WalletTestExecution import execution_lock, run_locked

SWIFT_COVERAGE = "-sanitize-coverage=edge,trace-pc-guard,trace-cmp"


def run(arguments: list[str], **kwargs):
    return run_locked(arguments, cwd=ROOT, check=True, **kwargs)


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


def main() -> None:
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
    llvm = Path(os.environ.get("LOCUS_FUZZ_LLVM_PREFIX", "/opt/homebrew/opt/llvm@21"))
    compiler = llvm / "bin/clang"
    version = subprocess.check_output([str(compiler), "--version"], text=True)
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
    swift = Path(
        subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    )
    toolchain = {
        "clangVersion": version,
        "clangSHA256": sha256(compiler),
        "fuzzerRuntimeSHA256": sha256(runtimes[0]),
        "swiftSHA256": sha256(swift),
        "swiftVersion": subprocess.check_output([str(swift), "--version"], text=True),
        "xcodeVersion": subprocess.check_output(["xcodebuild", "-version"], text=True),
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
        source = require_source()
        run_path, manifest = new_run(output, "swift", source, toolchain, flags, targets)
        run(["python3", "Tools/WalletFuzzCorpus.py", str(run_path / "seeds")])
        with (run_path / "build.log").open("x") as log:
            run(
                ["xcodebuild", "build-for-testing", *build_args],
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
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
                start = utc_now()
                try:
                    with (phase / "process.log").open("x") as log:
                        result = run_locked(
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
                        ).returncode
                finally:
                    configured.unlink(missing_ok=True)
                end = utc_now()
                try:
                    metrics = json.loads((phase / "metrics.json").read_text())
                except (OSError, ValueError):
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


if __name__ == "__main__":
    main()
