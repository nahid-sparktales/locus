"""UI accounting tests inspect synthetic xcresult JSON; no app is launched."""

import copy
import json
import sys
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
