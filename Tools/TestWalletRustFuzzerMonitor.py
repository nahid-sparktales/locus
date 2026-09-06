#!/usr/bin/env python3
"""Opt-in serialized synthetic engine controls; never campaign/release credit.

This compiles the exact reviewed C++ engine with host Clang ASan/LSan. Real
Rust targets still require separate replay/smoke with their pinned toolchain.
"""

import argparse
import json
import os
import subprocess
from pathlib import Path

from WalletFuzzEvidence import ROOT, FINDING, immutable_json, sha256, source_identity
from WalletRustFuzzerDependency import VENDOR, verify
from WalletTestExecution import execution_lock, run_locked


def validate_compiler_version(version: str):
    if not version.splitlines() or version.splitlines()[0] != "Homebrew clang version 21.1.8":
        raise ValueError("Engine controls require explicitly reviewed Homebrew Clang 21.1.8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    identity = verify()
    source = source_identity()
    if not args.compiler.is_absolute():
        raise SystemExit("Select the reviewed compiler with an absolute path")
    clang = args.compiler.resolve(strict=True)
    compiler_version = subprocess.check_output([str(clang), "--version"], text=True)
    validate_compiler_version(compiler_version)
    runtime_dir = Path(subprocess.check_output([str(clang), "-print-runtime-dir"], text=True).strip())
    runtime = runtime_dir / "libclang_rt.asan_osx_dynamic.dylib"
    runtime_sha256 = sha256(runtime)
    preflight_source = ROOT / "WalletSignerCore/fuzz/controls/sanitizer_preflight.cpp"
    preflight_sha256 = sha256(preflight_source)
    engine = VENDOR / "libfuzzer-sys-0.4.13/libfuzzer"
    fixture = ROOT / "WalletSignerCore/fuzz/controls/rss_monitor_controls.cpp"
    fixture_sha256 = sha256(fixture)
    compiler_sha256 = sha256(clang)
    immutable_json(output / "invocation.json", {
        "source": source, "dependency": identity, "compilerVersion": compiler_version,
        "compilerSHA256": compiler_sha256, "runtimeSHA256": runtime_sha256,
        "fixtureSHA256": fixture_sha256, "preflightSHA256": preflight_sha256,
        "campaignCredit": False, "releaseApproval": False,
    })
    executable = output / "monitor-controls"
    results = []
    with execution_lock(timeout=600):
        preflight = output / "sanitizer-preflight"
        with (output / "preflight.log").open("x") as log:
            run_locked([str(clang), "-fsanitize=address", str(preflight_source), "-o", str(preflight)],
                       check=True, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            try:
                result = run_locked([str(preflight)], env=os.environ | {
                    "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1:detect_leaks=1",
                }, stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
            except subprocess.TimeoutExpired:
                result = "preflight-timeout"
        preflight_passed = result == 0 and not FINDING.search((output / "preflight.log").read_text())
        immutable_json(output / "preflight.json", {
            "result": result, "passed": preflight_passed, "controlsExecuted": False,
            "binarySHA256": sha256(preflight), "logSHA256": sha256(output / "preflight.log"),
        })
        if not preflight_passed:
            raise SystemExit("Sanitizer runtime preflight failed; no engine controls executed")
        with (output / "build.log").open("x") as log:
            fixture_object = output / "controls.o"
            run_locked([
                str(clang), "-std=c++17", "-g", "-O1", "-fno-omit-frame-pointer",
                "-fsanitize=fuzzer-no-link,address", "-c", str(fixture),
                "-o", str(fixture_object),
            ], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            run_locked([
                str(clang), "-std=c++17", "-g", "-O1", "-fno-omit-frame-pointer",
                "-fsanitize=address", "-pthread", *map(str, sorted(engine.glob("*.cpp"))),
                str(fixture_object), "-o", str(executable),
            ], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        for mode, expected in (
            ("clean", None), ("leak", "LeakSanitizer"),
            ("crash", "libFuzzer: deadly signal"),
            ("timeout", "libFuzzer: timeout"), ("rss", "libFuzzer: out-of-memory"),
        ):
            phase = output / mode
            phase.mkdir()
            # Exact fixed synthetic file input; no user data or target corpus.
            seed = phase / "seed"
            seed.write_bytes(b"synthetic monitor control")
            environment = os.environ | {
                "LOCUS_RUST_MONITOR_CONTROL": mode,
                "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1:detect_leaks=1",
            }
            with (phase / "process.log").open("x") as log:
                try:
                    result = run_locked([
                        str(executable), str(seed), "-runs=1", "-detect_leaks=1",
                        "-timeout=1" if mode == "timeout" else "-timeout=10",
                        "-rss_limit_mb=128" if mode == "rss" else "-rss_limit_mb=4096",
                        "-malloc_limit_mb=1024", "-print_final_stats=1",
                        f"-artifact_prefix={phase}/",
                    ], env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=20).returncode
                except subprocess.TimeoutExpired:
                    result = "harness-timeout"
            text = (phase / "process.log").read_text(errors="replace")
            passed = result == 0 and not FINDING.search(text) if expected is None else (
                isinstance(result, int) and result != 0 and expected in text
            )
            results.append({"mode": mode, "result": result, "expectedFinding": expected,
                            "expectedOutcomeObserved": passed, "logSHA256": sha256(phase / "process.log")})
    receipt = {"schemaVersion": 1, "source": source, "sourceAfter": source_identity(),
               "dependency": identity, "compilerSHA256": compiler_sha256,
               "compilerVersion": compiler_version, "runtimeSHA256": runtime_sha256,
               "fixtureSHA256": fixture_sha256,
               "binarySHA256": sha256(executable), "controls": results,
               "campaignCredit": False, "releaseApproval": False}
    receipt["controlInputsUnchanged"] = (
        verify() == identity and sha256(fixture) == fixture_sha256
        and sha256(clang) == compiler_sha256
        and sha256(runtime) == runtime_sha256 and sha256(preflight_source) == preflight_sha256
    )
    immutable_json(output / "controls.json", receipt)
    print(json.dumps({"output": str(output), "controls": results}, sort_keys=True))
    if not receipt["controlInputsUnchanged"] or not all(item["expectedOutcomeObserved"] for item in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
