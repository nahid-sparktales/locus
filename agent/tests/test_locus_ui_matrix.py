"""UI accounting tests inspect synthetic xcresult JSON; no app is launched."""

import copy
import json
import plistlib
import subprocess
import sys
from contextlib import nullcontext
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import RunLocusUIMatrix as matrix  # noqa: E402


@pytest.fixture
def result_fixture():
    requested = matrix.source_tests()
    summary = {
        "result": "Passed",
        "passedTests": len(requested),
        "totalTestCount": len(requested),
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
    }
    tree = {
        "devices": [{"osVersion": "15.7"}],
        "testNodes": [
            {
                "nodeType": "UI test bundle",
                "children": [
                    {"nodeType": "Test Case", "nodeIdentifier": name + "()", "result": "Passed"}
                    for name in requested
                ],
            }
        ],
    }
    return requested, summary, tree


def test_full_suite_inventory_captures_more_than_140_requested_ids(result_fixture):
    requested, summary, tree = result_fixture
    assert len(requested) >= 140
    assert "LocusUITests/testWalletPhantomConfirmationExplainsLocusApprovalAndCancels" in requested
    assert matrix.validate_results(summary, tree, requested, 15) == {
        "requested": len(requested),
        "passed": len(requested),
        "failed": 0,
        "skipped": 0,
        "retried": 0,
    }


@pytest.mark.parametrize(
    "change",
    [
        lambda summary, tree: tree["testNodes"][0]["children"].pop(),
        lambda summary, tree: tree["testNodes"][0]["children"].append(
            copy.deepcopy(tree["testNodes"][0]["children"][0])
        ),
        lambda summary, tree: tree["testNodes"][0]["children"][0].update(result="Skipped"),
        lambda summary, tree: tree["testNodes"][0]["children"][0].update(result="Failed"),
        lambda summary, tree: tree["testNodes"][0]["children"][0].update(result="Expected Failure"),
        lambda summary, tree: tree["testNodes"][0]["children"][0].update(result="unknown"),
        lambda summary, tree: tree["testNodes"][0]["children"][0].update(
            children=[{"nodeType": "Repetition", "result": "Passed"}]
        ),
        lambda summary, tree: summary.update(totalTestCount=1),
        lambda summary, tree: summary.update(passedTests=1),
        lambda summary, tree: summary.update(skippedTests=1),
        lambda summary, tree: summary.update(expectedFailures=1),
        lambda summary, tree: summary.update(failedTests=1),
        lambda summary, tree: tree["devices"][0].update(osVersion="26.4"),
    ],
)
def test_partial_skipped_retried_or_wrong_os_is_never_full_pass(result_fixture, change):
    requested, summary, tree = result_fixture
    change(summary, tree)
    with pytest.raises(ValueError):
        matrix.validate_results(summary, tree, requested, 15)


def test_matrix_has_16_profiles_and_all_four_accessibility_combinations():
    config = json.loads(matrix.CONFIG.read_text())
    profiles = matrix.profiles(config)
    assert config["supportedOSMajors"] == [14, 15, 26]
    assert len(profiles) == 16
    for size in config["sizes"]:
        for appearance in config["appearances"]:
            combinations = {
                tuple(profile["accessibility"].values())
                for key, profile in profiles.items()
                if key.startswith(f"{size}-{appearance.lower()}-")
            }
            assert combinations == {(False, False), (True, False), (False, True), (True, True)}


@pytest.mark.parametrize("contrast,motion,suffix", [
    (False, False, "standard"), (True, False, "contrast"),
    (False, True, "motion"), (True, True, "contrast-motion"),
])
def test_native_selection_records_actual_settings_without_mutating_them(contrast, motion, suffix):
    config = json.loads(matrix.CONFIG.read_text())
    actual = {"increaseContrast": contrast, "reduceMotion": motion}
    before = copy.deepcopy(actual)
    assert matrix.native_profile(config, "regular-light", actual) == f"regular-light-{suffix}"
    assert actual == before
    with pytest.raises(ValueError, match="exactly one"):
        matrix.native_profile(config, "unknown-size", actual)


@pytest.mark.parametrize(
    "change",
    [
        lambda value: value.update(osMajor=26),
        lambda value: value.update(increaseContrast=True),
        lambda value: value.update(reduceMotion=True),
        lambda value: value.update(screenWidth=700),
        lambda value: value.update(screenHeight=500),
        lambda value: value.update(
            runningLocus=[{"pid": "123", "path": "/Applications/Locus.app"}]
        ),
    ],
)
def test_preflight_fails_before_build_or_launch_on_wrong_native_conditions(change):
    config = json.loads(matrix.CONFIG.read_text())
    profile = matrix.profiles(config)["regular-light-standard"]
    actual = {
        "osMajor": 15,
        "screenWidth": 1400,
        "screenHeight": 900,
        "runningLocus": [],
        "increaseContrast": False,
        "reduceMotion": False,
    }
    matrix.validate_environment(actual, profile, 15, config)
    change(actual)
    with pytest.raises(ValueError):
        matrix.validate_environment(actual, profile, 15, config)


def test_exact_requested_ids_are_forwarded_without_silent_skips():
    tests = matrix.source_tests()
    value = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": "LocusUITests"}]}]}
    assert matrix.configure(value, {"LOCUS_UI_TESTING_APPEARANCE": "Dark"}, tests) == 1
    target = value["TestConfigurations"][0]["TestTargets"][0]
    assert target["OnlyTestIdentifiers"] == tests
    assert target["EnvironmentVariables"]["LOCUS_UI_TESTING_APPEARANCE"] == "Dark"
    target["SkipTestIdentifiers"] = tests[:1]
    with pytest.raises(ValueError, match="excludes"):
        matrix.configure(value, {}, tests)


def test_blocked_preflight_receipt_is_unique_immutable_and_never_coverage(tmp_path, monkeypatch):
    source = {"revision": "a" * 40, "dirty": False}
    monkeypatch.setattr(matrix, "source_identity", lambda: source)
    actual = {"screenWidth": 1024, "screenHeight": 768}
    request = dict(actual=actual, profile_name="regular-light-standard",
                   os_major=15, tests=["LocusUITests/testExample"], error="Display is too small")
    first = matrix.retain_preflight_failure(tmp_path, **request)
    before = (first / "receipt.json").read_bytes()
    second = matrix.retain_preflight_failure(tmp_path, **request)
    assert first != second
    assert (first / "receipt.json").read_bytes() == before
    receipt = json.loads(before)
    expected = receipt.pop("receiptSHA256")
    assert matrix.digest(receipt) == expected
    assert receipt["status"] == "blocked"
    assert receipt["phase"] == "preflight"
    assert receipt["source"] == source
    assert receipt["preflight"] == actual
    assert receipt["requestedTests"] == request["tests"]
    assert receipt["counts"] is None
    assert not receipt["executed"]
    assert not receipt["releaseEligible"]
    assert not receipt["fullMatrixComplete"]


def test_hosted_ci_requests_compact_profile_without_claiming_regular_coverage():
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    assert "--native-profile compact-light" in workflow
    assert "--native-profile regular-light" not in workflow
    assert "locus-ui-macos15-compact-light-native-" in workflow


def test_test_command_uses_one_default_execution_without_retries():
    configuration = Path("/tmp/exact-generated.xctestrun")
    results = Path("/tmp/unique-result.xcresult")
    command = matrix.test_command(configuration, results)
    assert command[:2] == ["xcodebuild", "test-without-building"]
    assert command[command.index("-xctestrun") + 1] == str(configuration)
    assert command[command.index("-resultBundlePath") + 1] == str(results)
    assert command[command.index("-parallel-testing-enabled") + 1] == "NO"
    assert "-only-testing:LocusUITests" in command
    assert not set(command).intersection({
        "-test-iterations", "-retry-tests-on-failure", "-run-tests-until-failure",
        "-test-repetition-relaunch-enabled",
    })


def test_retained_configuration_is_exact_immutable_and_records_original_relative_base(tmp_path):
    products = tmp_path / "Products"
    products.mkdir()
    configuration = products / "generated.xctestrun"
    contents = plistlib.dumps({"TestBundlePath": "__TESTROOT__/Debug/Synthetic.xctest"})
    configuration.write_bytes(contents)
    run = tmp_path / "evidence"
    run.mkdir()

    identity = matrix.retain_invoked_configuration(configuration, run)
    invocation = json.loads((run / "invocation.json").read_text())
    assert invocation["invokedPath"] == str(configuration)
    assert invocation["relativePathBase"] == str(products)
    assert invocation["xctestrunSHA256"] == identity == matrix.sha256(configuration)
    assert invocation["testCommand"] == matrix.test_command(configuration, run / "results.xcresult")
    configuration.unlink()
    assert (run / "invoked.xctestrun").read_bytes() == contents
    with pytest.raises(FileExistsError):
        matrix.retain_invoked_configuration(configuration, run)
    assert (run / "invoked.xctestrun").read_bytes() == contents


@pytest.mark.parametrize("failure", ["process", "malformed-json", "wrong-shape"])
def test_result_extraction_retains_tree_when_summary_extraction_fails(tmp_path, monkeypatch, failure):
    (tmp_path / "results.xcresult").mkdir()
    calls = []
    tree = {"testNodes": [{"nodeType": "Test Case", "result": "Failed"}]}

    def fake_run(command, **kwargs):
        calls.append(command[4])
        assert kwargs == {"check": True, "capture_output": True, "text": True}
        if command[4] == "summary":
            if failure == "process":
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0, "{" if failure == "malformed-json" else "[]")
        assert command[4] == "tests"
        return subprocess.CompletedProcess(command, 0, json.dumps(tree))

    monkeypatch.setattr(matrix, "run_locked", fake_run)
    results, errors = matrix.retain_result_details(tmp_path)
    assert calls == ["summary", "tests"]
    assert results == {"tests": tree}
    assert set(errors) == {"summary"}
    assert not (tmp_path / "summary.json").exists()
    assert json.loads((tmp_path / "tests.json").read_text()) == tree
    assert matrix.observed_counts(results) is None


def test_missing_result_bundle_never_invokes_extraction_or_claims_zero_tests(tmp_path, monkeypatch):
    def unexpected_command(*args, **kwargs):
        pytest.fail("A missing bundle must not invoke any process")

    monkeypatch.setattr(matrix, "run_locked", unexpected_command)
    results, errors = matrix.retain_result_details(tmp_path)
    assert results == {}
    assert errors == {"resultBundle": "No UI result bundle was produced"}
    assert matrix.observed_counts(results) is None


def test_observed_counts_do_not_coerce_missing_or_invalid_fields_to_zero():
    assert matrix.observed_counts({"summary": {
        "totalTestCount": 5, "passedTests": True, "failedTests": "1", "skippedTests": -1,
    }}) == {
        "totalTestCount": 5, "passedTests": None, "failedTests": None,
        "skippedTests": None, "expectedFailures": None,
    }


@pytest.mark.parametrize("failure", ["process", "malformed-json", "missing-fields"])
def test_preflight_command_failure_retains_blocked_unexecuted_receipt(tmp_path, monkeypatch, failure):
    calls = []
    source = {"revision": "a" * 40, "dirty": False}

    def fake_run(command, **kwargs):
        calls.append(command)
        assert command == ["xcrun", "swift", "Tools/LocusUITestEnvironment.swift"]
        if failure == "process":
            raise subprocess.CalledProcessError(1, command)
        return subprocess.CompletedProcess(command, 0, "{" if failure == "malformed-json" else "{}")

    monkeypatch.setattr(matrix, "run_locked", fake_run)
    monkeypatch.setattr(matrix, "execution_lock", lambda **kwargs: nullcontext())
    monkeypatch.setattr(matrix, "source_identity", lambda: source)
    monkeypatch.setattr(sys, "argv", [
        "RunLocusUIMatrix.py", "--os-major", "15", "--native-profile", "compact-light",
        "--derived-data", str(tmp_path / "never-built"), "--output", str(tmp_path / "evidence"),
    ])
    with pytest.raises(SystemExit, match="UI profile not run"):
        matrix.main()
    assert len(calls) == 1
    assert not (tmp_path / "never-built").exists()
    runs = list((tmp_path / "evidence").iterdir())
    assert len(runs) == 1
    receipt = json.loads((runs[0] / "receipt.json").read_text())
    expected = receipt.pop("receiptSHA256")
    assert matrix.digest(receipt) == expected
    assert receipt["status"] == "blocked"
    assert receipt["phase"] == "preflight"
    assert receipt["profile"] == "compact-light-unresolved"
    assert receipt["source"] == source
    assert receipt["counts"] is None
    assert not receipt["executed"]
    assert not receipt["releaseEligible"]
    assert not receipt["fullMatrixComplete"]


@pytest.fixture
def synthetic_matrix_runner(tmp_path, monkeypatch, result_fixture):
    """Replace every process/host interaction; exercise receipts with owned bytes only."""
    requested, summary, tree = result_fixture
    source = {"revision": "a" * 40, "dirty": False, "treeSHA256": "b" * 64}
    derived = tmp_path / "derived"
    output = tmp_path / "evidence"
    monkeypatch.setattr(matrix, "ROOT", tmp_path)
    monkeypatch.setattr(matrix, "source_tests", lambda: requested)
    monkeypatch.setattr(matrix, "source_identity", lambda: source)
    monkeypatch.setattr(matrix, "execution_lock", lambda **kwargs: nullcontext())
    monkeypatch.setattr(sys, "argv", [
        "RunLocusUIMatrix.py", "--os-major", "15", "--profile", "compact-light-standard",
        "--derived-data", str(derived), "--output", str(output),
    ])

    def fake_version(command, **kwargs):
        assert command == ["xcodebuild", "-version"]
        assert kwargs == {"text": True}
        return "Synthetic Xcode identity\n"

    monkeypatch.setattr(matrix.subprocess, "check_output", fake_version)

    def execute(*, exit_code=65, failed_case=True, bundle=True, build_error=False,
                extraction_error=False, configuration_drift=False, launch_error=False):
        calls = []
        invoked = {}
        if failed_case:
            summary.update(result="Failed", passedTests=len(requested) - 1, failedTests=1)
            tree["testNodes"][0]["children"][0]["result"] = "Failed"

        def fake_run(command, **kwargs):
            calls.append(command)
            if command == ["xcrun", "swift", "Tools/LocusUITestEnvironment.swift"]:
                return subprocess.CompletedProcess(command, 0, json.dumps({
                    "osMajor": 15, "screenWidth": 1400, "screenHeight": 900,
                    "runningLocus": [], "increaseContrast": False, "reduceMotion": False,
                }))
            if command[:2] == ["xcodebuild", "build-for-testing"]:
                if build_error:
                    raise subprocess.CalledProcessError(65, command)
                products = derived / "Build/Products"
                products.mkdir(parents=True)
                (products / "generated.xctestrun").write_bytes(plistlib.dumps({
                    "Target": {"BlueprintName": "LocusUITests", "TestBundlePath": "__TESTROOT__/Debug/Synthetic.xctest"},
                }))
                for name in ("Locus.app", "LocusUITests-Runner.app"):
                    executable = products / "Debug" / name / "Contents/MacOS/Synthetic"
                    executable.parent.mkdir(parents=True)
                    executable.write_bytes(b"synthetic bytes: never execute")
                return subprocess.CompletedProcess(command, 0)
            if command[0].endswith("/lsregister"):
                assert command[1] in ("-f", "-u")
                assert Path(command[2]) == derived / "Build/Products/Debug/Locus.app"
                return subprocess.CompletedProcess(command, 0)
            if command[:2] == ["xcodebuild", "test-without-building"]:
                configuration = Path(command[command.index("-xctestrun") + 1])
                invoked.update(path=configuration, contents=configuration.read_bytes(), command=command)
                if launch_error:
                    raise OSError("Synthetic launch failure")
                if bundle:
                    result = Path(command[command.index("-resultBundlePath") + 1])
                    result.mkdir()
                    (result / "synthetic-result").write_bytes(b"retained failed result")
                if configuration_drift:
                    configuration.write_bytes(b"changed after invocation")
                return subprocess.CompletedProcess(command, exit_code)
            if command[:4] == ["xcrun", "xcresulttool", "get", "test-results"]:
                if extraction_error and command[4] == "summary":
                    raise subprocess.CalledProcessError(1, command)
                assert command[4] in ("summary", "tests")
                value = summary if command[4] == "summary" else tree
                return subprocess.CompletedProcess(command, 0, json.dumps(value))
            pytest.fail(f"Unexpected command in fully synthetic fixture: {command}")

        monkeypatch.setattr(matrix, "run_locked", fake_run)
        passed = not any((exit_code, failed_case, not bundle, build_error, extraction_error,
                          configuration_drift, launch_error))
        if passed:
            matrix.main()
        else:
            with pytest.raises(SystemExit, match="UI profile incomplete"):
                matrix.main()
        runs = list(output.iterdir())
        assert len(runs) == 1
        run = runs[0]
        receipt = json.loads((run / "receipt.json").read_text())
        identity = receipt.pop("receiptSHA256")
        assert matrix.digest(receipt) == identity
        assert receipt["source"] == source
        assert not receipt["fullMatrixComplete"]
        assert receipt["status"] == ("passed" if passed else "failed")
        for name, expected in receipt["files"].items():
            assert matrix.sha256(run / name) == expected
        test_calls = [command for command in calls if command[:2] == ["xcodebuild", "test-without-building"]]
        assert len(test_calls) == (0 if build_error else 1)
        assert receipt["testInvocationAttempted"] == bool(test_calls)
        if invoked:
            assert not invoked["path"].exists()
            assert invoked["path"].parent == derived / "Build/Products"
            assert (run / "invoked.xctestrun").read_bytes() == invoked["contents"]
            assert receipt["xctestrunSHA256"] == matrix.sha256(run / "invoked.xctestrun")
            invocation = json.loads((run / "invocation.json").read_text())
            assert invocation["testCommand"] == invoked["command"]
            assert invocation["xctestrunSHA256"] == receipt["xctestrunSHA256"]
            assert plistlib.loads(invoked["contents"])["Target"]["OnlyTestIdentifiers"] == requested
        return run, receipt, calls

    return execute


@pytest.mark.parametrize("exit_code,failed_case", [(65, True), (65, False), (0, True), (0, False)])
def test_matrix_retains_failed_results_without_promoting_failure_to_pass(synthetic_matrix_runner, exit_code, failed_case):
    run, receipt, calls = synthetic_matrix_runner(exit_code=exit_code, failed_case=failed_case)
    assert (run / "summary.json").is_file()
    assert (run / "tests.json").is_file()
    assert [command[4] for command in calls if command[:2] == ["xcrun", "xcresulttool"]] == ["summary", "tests"]
    assert receipt["result"] == exit_code
    assert receipt["configurationUnchanged"]
    assert receipt["resultExtractionErrors"] == {}
    assert receipt["observedCounts"]["failedTests"] == int(failed_case)
    if exit_code or failed_case:
        assert receipt["counts"] is None
    else:
        assert receipt["counts"]["passed"] == receipt["observedCounts"]["totalTestCount"]
    if exit_code:
        assert "status 65" in receipt["error"]


@pytest.mark.parametrize("failure", ["build", "missing-bundle", "launch"])
def test_matrix_preserves_pre_result_failure_without_inventing_counts(synthetic_matrix_runner, failure):
    run, receipt, calls = synthetic_matrix_runner(
        build_error=failure == "build", bundle=False, launch_error=failure == "launch",
    )
    assert receipt["result"] == (65 if failure == "missing-bundle" else -1)
    assert receipt["counts"] is None
    assert receipt["observedCounts"] is None
    assert receipt["resultBundleSHA256"] is None
    assert receipt["resultExtractionErrors"] == {"resultBundle": "No UI result bundle was produced"}
    assert not any(command[:2] == ["xcrun", "xcresulttool"] for command in calls)
    assert (run / "invoked.xctestrun").exists() == (failure != "build")


def test_matrix_preserves_process_failure_and_other_results_on_partial_extraction(synthetic_matrix_runner):
    run, receipt, _ = synthetic_matrix_runner(extraction_error=True)
    assert "status 65" in receipt["error"]
    assert set(receipt["resultExtractionErrors"]) == {"summary"}
    assert not (run / "summary.json").exists()
    assert (run / "tests.json").exists()
    assert receipt["observedCounts"] is None


def test_matrix_rejects_incomplete_evidence_even_after_zero_process_exit(synthetic_matrix_runner):
    _, receipt, _ = synthetic_matrix_runner(exit_code=0, failed_case=False, extraction_error=True)
    assert "extraction is incomplete" in receipt["error"]
    assert receipt["counts"] is None


def test_matrix_rejects_configuration_identity_drift_and_keeps_original_bytes(synthetic_matrix_runner):
    _, receipt, _ = synthetic_matrix_runner(exit_code=0, failed_case=False, configuration_drift=True)
    assert "configuration changed" in receipt["error"]
    assert receipt["configurationUnchanged"] is False
    assert receipt["counts"] is None
