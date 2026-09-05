#!/usr/bin/env python3
"""Run one native UI profile serially; never label a subset as the full matrix."""

import argparse
import json
import os
import plistlib
import re
import subprocess
import uuid
from pathlib import Path

from WalletFuzzEvidence import (
    ROOT,
    digest,
    directory_digest,
    immutable_json,
    sha256,
    source_identity,
    utc_now,
)
from WalletTestExecution import execution_lock, run_locked

CONFIG = ROOT / "Config/LocusUITestMatrix.json"


def profiles(config: dict) -> dict:
    return {
        f"{size}-{appearance.lower()}-{mode}": {
            "size": geometry,
            "appearance": appearance,
            "accessibility": settings,
        }
        for size, geometry in config["sizes"].items()
        for appearance in config["appearances"]
        for mode, settings in config["accessibilityModes"].items()
    }


def source_tests(root: Path = ROOT) -> list[str]:
    identifiers = []
    for path in sorted((root / "LocusUITests").glob("*.swift")):
        source = path.read_text()
        classes = re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source)
        methods = re.findall(r"^\s*func\s+(test\w+)\s*\(\s*\)", source, re.MULTILINE)
        if methods and len(classes) != 1:
            raise ValueError(
                "UI inventory requires one explicit XCTestCase per source file"
            )
        identifiers.extend(f"{classes[0]}/{method}" for method in methods)
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Duplicate UI test identifiers")
    return sorted(identifiers)


def validate_environment(actual: dict, profile: dict, os_major: int, config: dict):
    if os_major not in config["supportedOSMajors"] or actual["osMajor"] != os_major:
        raise ValueError(
            "Requested macOS version does not match this Mac; profile was not run"
        )
    if actual["runningLocus"]:
        raise ValueError(
            "Locus is already running; close it before starting an isolated UI session"
        )
    if any(
        actual[key] != profile["accessibility"][key]
        for key in ("increaseContrast", "reduceMotion")
    ):
        raise ValueError(
            "Native accessibility settings do not match the selected profile; no settings were changed"
        )
    if (
        actual["screenWidth"] < profile["size"]["width"]
        or actual["screenHeight"] < profile["size"]["height"]
    ):
        raise ValueError("Display is too small for the exact requested window profile")


def configure(value: object, environment: dict, tests: list[str]) -> int:
    count = 0
    if isinstance(value, dict):
        if value.get("BlueprintName") == "LocusUITests":
            if value.get("SkipTestIdentifiers"):
                raise ValueError("Supplied xctestrun excludes required UI tests")
            value.setdefault("EnvironmentVariables", {}).update(environment)
            value["OnlyTestIdentifiers"] = tests
            count += 1
        for child in value.values():
            count += configure(child, environment, tests)
    elif isinstance(value, list):
        for child in value:
            count += configure(child, environment, tests)
    return count


def validate_results(
    summary: dict, tree: dict, requested: list[str], os_major: int
) -> dict:
    cases = []

    def visit(node):
        if node.get("nodeType") == "Repetition":
            raise ValueError("Retried/repeated UI tests cannot satisfy a clean profile")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "").removesuffix("()")
            cases.append((identifier, node.get("result")))
        for child in node.get("children", []):
            visit(child)

    for node in tree.get("testNodes", []):
        visit(node)
    identifiers = [identifier for identifier, _ in cases]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Duplicate/retried UI test results")
    if set(identifiers) != set(requested):
        raise ValueError(
            f"Missing/unexpected UI tests: missing={sorted(set(requested) - set(identifiers))}; unexpected={sorted(set(identifiers) - set(requested))}"
        )
    if any(result != "Passed" for _, result in cases):
        raise ValueError(
            "Skipped, failed, expected-failure or unknown UI results block the profile"
        )
    if (
        summary.get("result") != "Passed"
        or summary.get("passedTests") != len(requested)
        or summary.get("totalTestCount") != len(requested)
        or any(
            summary.get(key) != 0
            for key in ("failedTests", "skippedTests", "expectedFailures")
        )
    ):
        raise ValueError("UI result summary does not match every requested test")
    devices = tree.get("devices", [])
    if len(devices) != 1 or int(devices[0]["osVersion"].split(".")[0]) != os_major:
        raise ValueError("Results came from a different or multiple operating systems")
    return {
        "requested": len(requested),
        "passed": len(cases),
        "skipped": 0,
        "failed": 0,
        "retried": 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os-major", required=True, type=int)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="Local smoke only; never release matrix evidence",
    )
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    config = json.loads(CONFIG.read_text())
    profile = profiles(config).get(args.profile)
    if profile is None:
        parser.error("Unknown profile: " + ", ".join(profiles(config)))
    tests = source_tests()
    if len(tests) < config["minimumFullSuiteTests"]:
        raise SystemExit(
            "UI source inventory unexpectedly shrank below the full-suite floor"
        )
    with execution_lock(timeout=600):
        actual = json.loads(
            run_locked(
                ["xcrun", "swift", "Tools/LocusUITestEnvironment.swift"],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        validate_environment(actual, profile, args.os_major, config)
        if args.preflight_only:
            print(
                json.dumps(
                    {
                        "profile": args.profile,
                        "preflight": actual,
                        "requestedTests": tests,
                        "executed": False,
                    },
                    sort_keys=True,
                )
            )
            return
        source = source_identity()
        if source["dirty"] and not args.allow_dirty:
            raise SystemExit("UI release evidence requires a clean source revision")
        run = args.output.resolve() / str(uuid.uuid4())
        run.mkdir(parents=True, exist_ok=False)
        started_at = utc_now()
        environment = os.environ | {"LOCUS_BUNDLE_MODE": "skip"}
        derived = args.derived_data.resolve()
        build = [
            "xcodebuild",
            "build-for-testing",
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
            "-parallel-testing-enabled",
            "NO",
            "-only-testing:LocusUITests",
            "CODE_SIGN_IDENTITY=-",
            "DEVELOPMENT_TEAM=",
            "LOCUS_WALLET_SIGNER_ENTITLEMENTS=Config/WalletSignerAdHoc.entitlements",
            "LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements",
        ]
        immutable_json(
            run / "request.json",
            {
                "schemaVersion": 1,
                "source": source,
                "profile": args.profile,
                "profileDefinition": profile,
                "profileScope": config["profileScope"],
                "matrixSHA256": sha256(CONFIG),
                "osMajor": args.os_major,
                "preflight": actual,
                "requestedTests": tests,
                "buildCommand": build,
                "startedAt": started_at,
                "releaseEligible": not source["dirty"],
            },
        )
        status, error, result, counts = "failed", None, -1, None
        configured = None
        registered_app = None
        try:
            with (run / "build.log").open("x") as log:
                run_locked(
                    build,
                    cwd=ROOT,
                    env=environment,
                    check=True,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            generated = list((derived / "Build/Products").glob("*.xctestrun"))
            if len(generated) != 1:
                raise ValueError(
                    "Expected one exact generated xctestrun in dedicated UI DerivedData"
                )
            configuration = plistlib.loads(generated[0].read_bytes())
            test_environment = {
                "LOCUS_UI_TESTING_MATRIX_PROFILE": args.profile,
                "LOCUS_UI_TESTING_WINDOW_WIDTH": str(profile["size"]["width"]),
                "LOCUS_UI_TESTING_WINDOW_HEIGHT": str(profile["size"]["height"]),
                "LOCUS_UI_TESTING_APPEARANCE": profile["appearance"],
                "LOCUS_UI_TESTING_EXPECT_CONTRAST": "1"
                if profile["accessibility"]["increaseContrast"]
                else "0",
                "LOCUS_UI_TESTING_EXPECT_MOTION": "1"
                if profile["accessibility"]["reduceMotion"]
                else "0",
            }
            if configure(configuration, test_environment, tests) != 1:
                raise ValueError("Expected one exact LocusUITests configuration")
            configured = generated[0].parent / f"locus-ui-{run.name}.xctestrun"
            with configured.open("xb") as stream:
                plistlib.dump(configuration, stream)
            app = derived / "Build/Products/Debug/Locus.app"
            products = derived / "Build/Products/Debug"
            runner = products / "LocusUITests-Runner.app"
            if not runner.is_dir():
                raise ValueError("Missing exact UI runner application")
            binary = {
                path.relative_to(products).as_posix(): sha256(path)
                for bundle in (app, runner)
                for path in bundle.rglob("*")
                if path.is_file()
                and (path.suffix == ".dylib" or path.parent.name == "MacOS")
            }
            immutable_json(
                run / "build-identity.json",
                {
                    "xctestrunSHA256": sha256(configured),
                    "binaries": binary,
                    "sourceBefore": source,
                    "sourceAfterBuild": source_identity(),
                    "xcodeVersion": subprocess.check_output(
                        ["xcodebuild", "-version"], text=True
                    ),
                },
            )
            if source_identity() != source:
                raise ValueError("Source changed during UI build")
            run_locked(
                [
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    "-f",
                    str(app),
                ],
                check=True,
            )
            registered_app = app
            with (run / "test.log").open("x") as log:
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
                        "-test-iterations",
                        "1",
                        "-only-testing:LocusUITests",
                        "-resultBundlePath",
                        str(run / "results.xcresult"),
                    ],
                    cwd=ROOT,
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                ).returncode
            results = {}
            for name in ("summary", "tests"):
                results[name] = json.loads(
                    run_locked(
                        [
                            "xcrun",
                            "xcresulttool",
                            "get",
                            "test-results",
                            name,
                            "--path",
                            str(run / "results.xcresult"),
                            "--compact",
                        ],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout
                )
                immutable_json(run / f"{name}.json", results[name])
            counts = validate_results(
                results["summary"], results["tests"], tests, args.os_major
            )
            if result != 0 or source_identity() != source:
                raise ValueError("UI process failed or source changed during tests")
            if any(
                sha256(products / name) != expected for name, expected in binary.items()
            ):
                raise ValueError("App or UI runner binary changed during tests")
            status = "passed"
        except (OSError, ValueError, subprocess.SubprocessError) as failure:
            error = str(failure)
        finally:
            if configured is not None:
                configured.unlink(missing_ok=True)
            if registered_app is not None:
                # Only undo the transient registration this invocation added.
                # The installed original app is never unregistered or killed.
                run_locked(
                    [
                        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-u",
                        str(registered_app),
                    ],
                    check=False,
                )
            receipt = {
                "schemaVersion": 1,
                "status": status,
                "error": error,
                "result": result,
                "profile": args.profile,
                "osMajor": args.os_major,
                "counts": counts,
                "source": source,
                "startedAt": started_at,
                "endedAt": utc_now(),
                "releaseEligible": not source["dirty"],
                "fullMatrixComplete": False,
                "resultBundleSHA256": directory_digest(run / "results.xcresult")
                if (run / "results.xcresult").is_dir()
                else None,
                "files": {
                    path.relative_to(run).as_posix(): sha256(path)
                    for path in run.iterdir()
                    if path.is_file()
                },
            }
            receipt["receiptSHA256"] = digest(receipt)
            immutable_json(run / "receipt.json", receipt)
        if status != "passed":
            raise SystemExit(
                f"UI profile incomplete: {error}; evidence retained at {run}"
            )
        print(
            f"Passed {len(tests)} requested UI tests for macOS {args.os_major}/{args.profile}; not a full matrix claim. Evidence: {run}"
        )


if __name__ == "__main__":
    main()
