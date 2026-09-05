"""The fixture inventory is source verification, never chain execution proof."""

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "VerifyWalletLocalFixtures.py"
SPEC = importlib.util.spec_from_file_location("wallet_local_fixtures", SCRIPT)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class WalletLocalFixtureVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="locus-fixture-verifier-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "Fixtures"
        shutil.copytree(ROOT / "Tools" / "Fixtures", self.directory)

    def read(self, name):
        return json.loads((self.directory / name).read_text())

    def write(self, name, value):
        (self.directory / name).write_text(json.dumps(value))

    def update_catalog(self, transform):
        catalog = self.read("scenarios.json")
        transform(catalog)
        self.write("scenarios.json", catalog)
        lock = self.read("local-fixtures.lock.json")
        lock["sourceSHA256"]["scenarios.json"] = hashlib.sha256(
            (self.directory / "scenarios.json").read_bytes()
        ).hexdigest()
        self.write("local-fixtures.lock.json", lock)

    def test_current_source_identities_pass_but_live_evidence_remains_blocked(self):
        blockers = VERIFIER.verify(self.directory)
        self.assertIn("evm.uniswap.v2.one-and-multihop", blockers)
        self.assertIn("solana.core.plugin-free", blockers)
        self.assertIn("sui.coin.stateful", blockers)
        self.assertIn("compiled-fixture-artifacts", blockers)

    def test_readiness_cli_fails_even_when_input_hashes_pass(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--directory", str(self.directory), "--require-ready"],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("input hashes verified", result.stdout)
        self.assertIn("BLOCKED", result.stdout)

    def test_source_mutation_invalidates_identity(self):
        with (self.directory / "EVM" / "StatefulAssets.sol").open("a") as output:
            output.write("\n// changed fixture input\n")
        with self.assertRaisesRegex(ValueError, "input changed"):
            VERIFIER.verify(self.directory)

    def test_paths_cannot_escape_fixture_root(self):
        lock = self.read("local-fixtures.lock.json")
        lock["sourceSHA256"]["../outside"] = "0" * 64
        self.write("local-fixtures.lock.json", lock)
        with self.assertRaisesRegex(ValueError, "Invalid local fixture source identity"):
            VERIFIER.verify(self.directory)

    def test_local_sources_cannot_claim_production_authority(self):
        lock = self.read("local-fixtures.lock.json")
        lock["productionAuthority"] = True
        self.write("local-fixtures.lock.json", lock)
        with self.assertRaisesRegex(ValueError, "authority"):
            VERIFIER.verify(self.directory)

    def test_rehashed_catalog_cannot_claim_execution_evidence(self):
        self.update_catalog(lambda catalog: catalog.update(evidenceStatus="passed"))
        with self.assertRaisesRegex(ValueError, "cannot supply execution evidence"):
            VERIFIER.verify(self.directory)

    def test_duplicate_scenarios_are_rejected(self):
        self.update_catalog(lambda catalog: catalog["scenarios"].append(catalog["scenarios"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            VERIFIER.verify(self.directory)

    def test_implemented_scenario_must_name_a_test(self):
        def mutate(catalog):
            scenario = next(row for row in catalog["scenarios"] if row["implementation"] == "implemented")
            scenario.pop("test")
        self.update_catalog(mutate)
        with self.assertRaisesRegex(ValueError, "identify a test"):
            VERIFIER.verify(self.directory)

    def test_tool_identity_must_be_a_real_digest_shape(self):
        lock = self.read("local-fixtures.lock.json")
        lock["tools"]["sui"]["archiveSHA256"] = {"macos-arm64": "799000...f613"}
        self.write("local-fixtures.lock.json", lock)
        with self.assertRaisesRegex(ValueError, "tool archive identity"):
            VERIFIER.verify(self.directory)

    def test_nonempty_placeholder_is_not_a_compiled_artifact(self):
        lock = self.read("local-fixtures.lock.json")
        lock["compiledFixtureArtifacts"] = ["compiled"]
        self.write("local-fixtures.lock.json", lock)
        with self.assertRaisesRegex(ValueError, "compiled fixture artifact identity"):
            VERIFIER.verify(self.directory)

    def test_compiled_artifact_must_bind_locked_sources_and_file_bytes(self):
        lock = self.read("local-fixtures.lock.json")
        lock["compiledFixtureArtifacts"] = [{
            "path": "EVM/StatefulAssets.sol", "sha256": "0" * 64,
            "compilerTool": "solc", "sourcePaths": ["EVM/StatefulAssets.sol"],
        }]
        self.write("local-fixtures.lock.json", lock)
        with self.assertRaisesRegex(ValueError, "Compiled fixture artifact changed"):
            VERIFIER.verify(self.directory)


if __name__ == "__main__":
    unittest.main()
