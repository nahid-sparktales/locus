"""Cleanup is restricted to the exact generated app and test bundle."""

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def invoke(build, *, experimental=False, **overrides):
    app = "Locus Experimental.app" if experimental else "Locus.app"
    environment = os.environ | {
        "TARGET_BUILD_DIR": str(build),
        "PLUGINS_FOLDER_PATH": f"{app}/Contents/PlugIns",
        "FULL_PRODUCT_NAME": app,
        "TARGET_NAME": "Locus",
        "CONFIGURATION": "ReleaseExperimental" if experimental else "Release",
        "LOCUS_TEST_ACTION": "0",
    }
    return subprocess.run(
        ["/bin/zsh", str(ROOT / "Tools/CleanStaleBuildProducts.sh")],
        env=environment | overrides,
        capture_output=True,
        text=True,
        timeout=10,
    )


@pytest.mark.parametrize("experimental", [False, True])
def test_cleanup_removes_only_generated_test_bundle(tmp_path, experimental):
    app = "Locus Experimental.app" if experimental else "Locus.app"
    plugins = tmp_path / app / "Contents/PlugIns"
    tests = plugins / "LocusTests.xctest"
    tests.mkdir(parents=True)
    (tests / "synthetic-test").write_text("disposable fixture")
    kept = plugins / "Other.xctest"
    kept.mkdir()
    result = invoke(tmp_path, experimental=experimental)
    assert result.returncode == 0, result.stderr
    assert not tests.exists()
    assert kept.is_dir()


@pytest.mark.parametrize(
    "overrides",
    [
        {"CONFIGURATION": "Release"},
        {"TARGET_NAME": "LocusMAS"},
        {"FULL_PRODUCT_NAME": "Other.app"},
        {"PLUGINS_FOLDER_PATH": "../Locus Experimental.app/Contents/PlugIns"},
        {"TARGET_BUILD_DIR": "/"},
        {"TARGET_BUILD_DIR": ""},
    ],
)
def test_experimental_cleanup_rejects_mismatched_or_broad_targets(tmp_path, overrides):
    tests = tmp_path / "Locus Experimental.app/Contents/PlugIns/LocusTests.xctest"
    tests.mkdir(parents=True)
    assert invoke(tmp_path, experimental=True, **overrides).returncode == 1
    assert tests.is_dir()


def test_cleanup_rejects_symlinked_product_without_touching_destination(tmp_path):
    build = tmp_path / "build"
    build.mkdir()
    actual = tmp_path / "retained.app"
    tests = actual / "Contents/PlugIns/LocusTests.xctest"
    tests.mkdir(parents=True)
    (build / "Locus Experimental.app").symlink_to(actual, target_is_directory=True)
    assert invoke(build, experimental=True).returncode == 1
    assert tests.is_dir()


def test_active_test_action_preserves_its_bundle(tmp_path):
    tests = tmp_path / "Locus Experimental.app/Contents/PlugIns/LocusTests.xctest"
    tests.mkdir(parents=True)
    assert invoke(tmp_path, experimental=True, LOCUS_TEST_ACTION="1").returncode == 0
    assert tests.is_dir()
