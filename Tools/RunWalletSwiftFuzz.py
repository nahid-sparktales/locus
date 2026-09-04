#!/usr/bin/env python3
"""Run app-hosted libFuzzer against the real Swift module in an isolated Debug build."""
import json
import os
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("evm_decoder", "solana_decoder", "sui_decoder", "connections",
           "namespaces", "authorization", "metadata", "quote_math")


def run(arguments: list[str], **kwargs: object) -> None:
    subprocess.run(arguments, cwd=ROOT, check=True, **kwargs)


def configure_tests(value: object, environment: dict[str, str]) -> int:
    count = 0
    if isinstance(value, dict):
        if value.get("BlueprintName") == "LocusTests" or "LocusTests.xctest" in str(value.get("TestBundlePath", "")):
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
    if seconds <= 0:
        raise SystemExit("LOCUS_FUZZ_SECONDS must be positive")
    targets = [os.environ["LOCUS_FUZZ_TARGET"]] if os.environ.get("LOCUS_FUZZ_TARGET") else list(TARGETS)
    if not set(targets).issubset(TARGETS):
        raise SystemExit("Unknown Swift fuzz target")
    output = Path(os.environ.get("LOCUS_FUZZ_OUTPUT", ROOT / "build/wallet-fuzz-swift")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    derived = output / "DerivedData-Debug-ASan"
    # Xcode omits libFuzzer itself; this test-only runtime must be LLVM 21.1.8.
    llvm = Path(os.environ.get("LOCUS_FUZZ_LLVM_PREFIX", "/opt/homebrew/opt/llvm@21"))
    version = subprocess.check_output([str(llvm / "bin/clang"), "--version"], text=True)
    if "clang version 21.1.8" not in version:
        raise SystemExit("Install reviewed test-only llvm@21 21.1.8 or set LOCUS_FUZZ_LLVM_PREFIX")
    runtimes = list((llvm / "lib/clang").glob("*/lib/darwin/libclang_rt.fuzzer_no_main_osx.a"))
    if len(runtimes) != 1:
        raise SystemExit("Expected one libFuzzer no-main runtime")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    if os.environ.get("LOCUS_FUZZ_REQUIRE_CLEAN") == "1" and dirty:
        raise SystemExit("Candidate fuzz evidence requires a clean source revision")
    run(["python3", "Tools/WalletFuzzCorpus.py", str(output / "corpus")])
    environment = os.environ | {"LOCUS_BUNDLE_MODE": "skip"}
    build_args = ["-project", "Locus.xcodeproj", "-scheme", "Locus", "-configuration", "Debug",
                  "-destination", "platform=macOS", "-derivedDataPath", str(derived),
                  "-enableAddressSanitizer", "YES", "-enableUndefinedBehaviorSanitizer", "YES",
                  "-only-testing:LocusTests/WalletLibFuzzerTests",
                  "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
                  "LOCUS_WALLET_SIGNER_ENTITLEMENTS=Config/WalletSignerAdHoc.entitlements",
                  "LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements",
                  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LOCUS_DIRECT_DOWNLOAD LOCUS_LIBFUZZER",
                  "OTHER_SWIFT_FLAGS=$(inherited) -sanitize-coverage=trace-pc-guard,trace-cmp",
                  f"OTHER_LDFLAGS=$(inherited) {runtimes[0]} -lc++"]
    run(["xcodebuild", "build-for-testing", *build_args], env=environment)
    test_runs = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(test_runs) != 1:
        raise SystemExit("Expected one generated xctestrun for the isolated fuzz build")
    original = plistlib.loads(test_runs[0].read_bytes())
    for target in targets:
        artifacts = output / "artifacts" / target
        artifacts.mkdir(parents=True, exist_ok=True)
        receipt = output / f"{target}.json"
        for phase, limit in (("replay", "1"), ("fuzz", str(seconds))):
            # Reload the generated test settings for each target; no shared derived state.
            configuration = plistlib.loads(plistlib.dumps(original))
            count = configure_tests(configuration, {
                "LOCUS_FUZZ_TARGET": target, "LOCUS_FUZZ_SECONDS": limit,
                "LOCUS_FUZZ_REPLAY": "1" if phase == "replay" else "0",
                "LOCUS_FUZZ_CORPUS": str(output / "corpus" / target),
                "LOCUS_FUZZ_ARTIFACTS": str(artifacts), "LOCUS_FUZZ_RECEIPT": str(receipt),
                "LOCUS_FUZZ_REVISION": revision,
                "ASAN_OPTIONS": "halt_on_error=1:abort_on_error=1",
                "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1",
            })
            if count != 1:
                raise SystemExit("Expected one LocusTests configuration")
            test_runs[0].write_bytes(plistlib.dumps(configuration))
            with (output / f"{target}-{phase}.log").open("w") as log:
                run(["xcodebuild", "test-without-building", "-xctestrun", str(test_runs[0]),
                     "-destination", "platform=macOS", "-only-testing:LocusTests/WalletLibFuzzerTests"],
                    env=environment, stdout=log, stderr=subprocess.STDOUT)
            if not receipt.is_file():
                raise SystemExit("Fuzzer process produced no completion receipt")
        result = json.loads(receipt.read_text())
        result["sourceDirty"] = dirty
        result["llvmVersion"] = "21.1.8"
        result["requestedWallSeconds"] = seconds
        receipt.write_text(json.dumps(result, sort_keys=True) + "\n")
        print(f"Completed Swift libFuzzer {target}: {result['iterations']} inputs")


if __name__ == "__main__":
    main()
