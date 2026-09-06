"""Cleanup is restricted to the exact generated app and test bundle."""

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def invoke(build, *, target="Locus", experimental=False, **overrides):
    app = f"{target}{' Experimental' if experimental else ''}.app"
    if target == "LocusMAS":
        app = "Locus.app"
    environment = os.environ | {
        "TARGET_BUILD_DIR": str(build),
        "PLUGINS_FOLDER_PATH": f"{app}/Contents/PlugIns",
        "FULL_PRODUCT_NAME": app,
        "TARGET_NAME": target,
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


@pytest.mark.parametrize(
    ("target", "experimental", "app", "test_bundle"),
    [
        ("Locus", False, "Locus.app", "LocusTests.xctest"),
        ("LocusMAS", False, "Locus.app", "LocusTests.xctest"),
        ("LocusX", False, "LocusX.app", "LocusXTests.xctest"),
        ("LocusX", True, "LocusX Experimental.app", "LocusXTests.xctest"),
    ],
)
def test_cleanup_removes_only_generated_test_bundle(tmp_path, target, experimental, app, test_bundle):
    plugins = tmp_path / app / "Contents/PlugIns"
    tests = plugins / test_bundle
    tests.mkdir(parents=True)
    (tests / "synthetic-test").write_text("disposable fixture")
    kept = plugins / "Other.xctest"
    kept.mkdir()
    other_edition = plugins / ("LocusTests.xctest" if target == "LocusX" else "LocusXTests.xctest")
    other_edition.mkdir()
    result = invoke(tmp_path, target=target, experimental=experimental)
    assert result.returncode == 0, result.stderr
    assert not tests.exists()
    assert kept.is_dir()
    assert other_edition.is_dir()


@pytest.mark.parametrize(
    "overrides",
    [
        {"CONFIGURATION": "Release"},
        {"TARGET_NAME": "Locus"},
        {"TARGET_NAME": "LocusMAS"},
        {"FULL_PRODUCT_NAME": "Other.app"},
        {"PLUGINS_FOLDER_PATH": "../LocusX Experimental.app/Contents/PlugIns"},
        {"TARGET_BUILD_DIR": "/"},
        {"TARGET_BUILD_DIR": ""},
    ],
)
def test_experimental_cleanup_rejects_mismatched_or_broad_targets(tmp_path, overrides):
    tests = tmp_path / "LocusX Experimental.app/Contents/PlugIns/LocusXTests.xctest"
    tests.mkdir(parents=True)
    assert invoke(tmp_path, target="LocusX", experimental=True, **overrides).returncode == 1
    assert tests.is_dir()


def test_cleanup_rejects_symlinked_product_without_touching_destination(tmp_path):
    build = tmp_path / "build"
    build.mkdir()
    actual = tmp_path / "retained.app"
    tests = actual / "Contents/PlugIns/LocusXTests.xctest"
    tests.mkdir(parents=True)
    (build / "LocusX Experimental.app").symlink_to(actual, target_is_directory=True)
    assert invoke(build, target="LocusX", experimental=True).returncode == 1
    assert tests.is_dir()


def test_active_test_action_preserves_its_bundle(tmp_path):
    tests = tmp_path / "LocusX Experimental.app/Contents/PlugIns/LocusXTests.xctest"
    tests.mkdir(parents=True)
    assert invoke(tmp_path, target="LocusX", experimental=True, LOCUS_TEST_ACTION="1").returncode == 0
    assert tests.is_dir()
