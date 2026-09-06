"""Only isolated copies of public fuzz-engine inputs are mutated by these tests."""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Tools"))
import WalletRustFuzzerDependency as dependency  # noqa: E402
from TestWalletRustFuzzerMonitor import validate_compiler_version  # noqa: E402
from WalletFuzzEvidence import directory_digest  # noqa: E402


class RustFuzzerDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="locus-fuzzer-input-test-")
        self.addCleanup(self.temporary.cleanup)
        self.vendor = Path(shutil.copytree(dependency.VENDOR, Path(self.temporary.name) / "vendor"))

    def test_exact_pinned_archive_patch_tree_and_licenses_verify(self):
        identity = dependency.verify(environment={})
        self.assertEqual(identity["version"], "0.4.13")
        self.assertEqual(identity["archiveSHA256"], dependency.ARCHIVE_SHA256)
        self.assertEqual(len(identity["licenses"]), 3)

    def assert_changed_input_rejected(self, relative, message):
        with (self.vendor / relative).open("ab") as stream:
            stream.write(b"\ninvalid fixture change\n")
        with self.assertRaisesRegex(ValueError, message):
            dependency.verify(self.vendor, environment={})

    def test_changed_archive_is_rejected(self):
        self.assert_changed_input_rejected("upstream/libfuzzer-sys-0.4.13.crate", "archive digest")

    def test_changed_patch_is_rejected(self):
        self.assert_changed_input_rejected("patches/rss-monitor-shutdown.patch", "patch digest")

    def test_changed_driver_is_rejected(self):
        self.assert_changed_input_rejected("libfuzzer-sys-0.4.13/libfuzzer/FuzzerDriver.cpp", "patched tree")

    def test_changed_license_is_rejected(self):
        self.assert_changed_input_rejected("upstream/compiler-rt-LICENSE.TXT", "license digest")

    def test_matching_tree_digest_cannot_hide_an_unreviewed_source_change(self):
        crate = self.vendor / "libfuzzer-sys-0.4.13"
        with (crate / "libfuzzer/FuzzerLoop.cpp").open("ab") as stream:
            stream.write(b"\n// synthetic unreviewed change\n")
        manifest_path = self.vendor / "provenance.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["patchedTreeSHA256"] = directory_digest(crate)
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "Unexpected Rust fuzzer source modification"):
            dependency.verify(self.vendor, environment={})

    def test_unreviewed_runtime_override_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "custom libFuzzer override"):
            dependency.verify(environment={"CUSTOM_LIBFUZZER_PATH": "/synthetic/other.a"})

    def test_control_compiler_preflight_rejects_apple_or_unreviewed_versions(self):
        validate_compiler_version("Homebrew clang version 21.1.8\nTarget: synthetic")
        for version in ("", "Apple clang version 17.0.0", "Homebrew clang version 22.1.0"):
            with self.assertRaisesRegex(ValueError, "explicitly reviewed"):
                validate_compiler_version(version)


if __name__ == "__main__":
    unittest.main()
