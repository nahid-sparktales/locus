"""The dispatcher ships usable content without its original source checkout.

These tests can also run with plain Python when the server dependencies are absent.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "agent/ollama_code/builtin_skills/agent-dispatcher"


class DispatcherBundleTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((PACK / "catalog.json").read_text())

    def test_complete_catalog_and_role_profile_compatibility(self):
        catalog = self.catalog
        self.assertEqual(catalog["schema_version"], 1)
        self.assertEqual(catalog["source_version"], "2.2.0")
        self.assertEqual({key: len(catalog[key]) for key in ("roles", "guides", "recipes", "signals")},
                         {"roles": 27, "guides": 79, "recipes": 8, "signals": 50})
        roles = {row["id"]: row for row in catalog["roles"]}
        self.assertEqual(len(roles), 27)
        for row in roles.values():
            with self.subTest(role=row["id"]):
                self.assertIn(row["execution_role"], {"generalist", "dispatcher", "planner", "researcher", "implementer", "tester", "reviewer"})
                self.assertIn(row["default_mode"], {"work", "plan"})
                self.assertIn(row["access_ceiling"], {"read_only", "workspace_write"})
                self.assertLessEqual(len(row["instructions"]), 16000)
                self.assertEqual((PACK / row["role_path"]).read_text().strip(), row["instructions"])
                self.assertIn(row["slug"], row["aliases"])
                for heading in ("WORKING METHOD", "DELIVERABLE", "DEFINITION OF DONE", "## Guides and retrieval", "## Locus modes"):
                    self.assertIn(heading, row["instructions"])
                for foreign in ("ExitPlanMode", "Read/Grep/Glob", "WebSearch/WebFetch", "CLAUDE_CONFIG_DIR", "CODEX_HOME"):
                    self.assertNotIn(foreign, row["instructions"])
        self.assertEqual(roles["architect"]["execution_role"], "planner")
        self.assertEqual(roles["explorer"]["execution_role"], "researcher")
        self.assertEqual(roles["security-auditor"]["execution_role"], "reviewer")
        self.assertEqual(roles["ui-ux-designer"]["execution_role"], "implementer")
        self.assertEqual(roles["content-copywriter"]["execution_role"], "generalist")
        self.assertEqual({r["id"] for r in roles.values() if r["default_mode"] == "plan"},
                         {"planner", "architect", "product-manager"})

    def test_every_loadout_and_supporting_resource_resolves(self):
        catalog = self.catalog
        guides = {row["id"]: row for row in catalog["guides"]}
        external = json.loads((PACK / "catalog/external-skills.json").read_text())
        known_guides = set(guides) | {row["id"] for row in external["skills"]}
        recipe_ids = {row["id"] for row in catalog["recipes"]}
        signal_ids = {row["id"] for row in catalog["signals"]}
        mcps = json.loads((PACK / "catalog/mcp.json").read_text())
        mcp_ids = {row["id"] for row in mcps["servers"]}
        for role in catalog["roles"]:
            selected = set(role["verification"])
            for tier in ("core", "preferred", "optional"):
                selected.update(role["skills"][tier])
            for signal, ids in role["skills"]["conditional"].items():
                self.assertIn(signal, signal_ids)
                selected.update(ids)
            self.assertLessEqual(selected, known_guides)
            self.assertLessEqual(set(role["recipes"]), recipe_ids)
            self.assertLessEqual(set(role["mcps"]["recommended"] + role["mcps"]["conditional"]), mcp_ids)
        for row in [*guides.values(), *catalog["recipes"]]:
            path = PACK / row["path"]
            self.assertTrue(path.is_file(), row["path"])
            self.assertTrue(path.resolve().is_relative_to(PACK.resolve()))
            self.assertLess(path.stat().st_size, 64 * 1024)
            for rel in row.get("references", []) + row.get("scripts", []):
                self.assertTrue((path.parent / rel).is_file(), rel)
        # Only one skill is registered; guides must remain on demand.
        self.assertEqual(list(PACK.rglob("SKILL.md")), [PACK / "SKILL.md"])
        self.assertEqual(len(list((PACK / "guides").rglob("GUIDE.md"))), 79)
        for path in (PACK / "references").glob("*.md"):
            self.assertLess(path.stat().st_size, 64 * 1024)

    def test_attribution_manifest_and_host_controls(self):
        manifest = json.loads((PACK / "SOURCE.json").read_text())
        self.assertEqual(manifest["activation"], "explicit")
        self.assertEqual(manifest["license"], "MIT")
        self.assertTrue((PACK / "LICENSE").is_file())
        self.assertTrue((PACK / "NOTICE").is_file())
        files = {str(path.relative_to(PACK)) for path in PACK.rglob("*")
                 if path.is_file() and "__pycache__" not in path.parts and path.name != "SOURCE.json"}
        self.assertEqual(files, set(manifest["files_sha256"]))
        for name, digest in manifest["files_sha256"].items():
            self.assertEqual(hashlib.sha256((PACK / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual(set(p.name for p in (PACK / "decision").iterdir()), {"redact.py"})
        self.assertFalse((PACK / "hooks").exists())
        self.assertIn("disable-model-invocation: true", (PACK / "SKILL.md").read_text())
        for path in [PACK / "SKILL.md", PACK / "references/CONTROLS.md"]:
            text = path.read_text()
            self.assertNotIn("CLAUDE_CONFIG_DIR", text)
            self.assertNotIn("CODEX_HOME", text)
            self.assertNotIn("ExitPlanMode", text)
        self.assertIn("read_dispatcher_resource", (PACK / "SKILL.md").read_text())
        guidance = [PACK / "SKILL.md", *(PACK / "roles").glob("*.md"),
                    *(PACK / "references").glob("*.md")]
        for path in guidance:
            # The full UI catalog is intentionally larger than the runtime's
            # per-resource read budget. Instructions must use the small indexes.
            self.assertNotIn("`catalog.json`", path.read_text(), str(path.relative_to(PACK)))

    def test_context_and_map_helpers_are_self_contained_and_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # A relocated copy cannot accidentally resolve resources in the original checkout.
            bundle = root / "bundle"
            shutil.copytree(PACK, bundle)
            project = root / "workspace"
            project.mkdir()
            (project / "login.py").write_text("def verify_login(name):\n    return bool(name)\n")
            before = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*") if path.is_file()}
            result = subprocess.run([sys.executable, "-B", str(bundle / "scripts/context.py"),
                                     "--pack", str(bundle), "--project", str(project), "--role", "implementer",
                                     "--task-file", "-", "--json"], input="Fix verify_login in login.py", text=True,
                                    capture_output=True, check=True, cwd=project, timeout=20)
            output = json.loads(result.stdout)
            self.assertTrue(output["read_only"])
            self.assertEqual(output["role"], "implementer")
            self.assertIn("login.py", [item["path"] for item in output["excerpts"]])
            shown = subprocess.run([sys.executable, "-B", str(bundle / "scripts/project_map.py"),
                                    "--pack", str(bundle), "--project", str(project), "show", "--json"],
                                   text=True, capture_output=True, check=True, cwd=project, timeout=20)
            self.assertTrue(json.loads(shown.stdout)["read_only"])
            after = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
            self.assertFalse((project / ".agent-dispatcher").exists())

    def test_portable_enumeration_withholds_guarded_and_unsafe_files(self):
        spec = importlib.util.spec_from_file_location("dispatcher_context", PACK / "scripts/context.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        with tempfile.TemporaryDirectory() as directory, patch.object(helper.shutil, "which", return_value=None):
            root = Path(directory)
            project = root / "project"
            project.mkdir()
            (project / "billing.py").write_text("def calculate_invoice_total(items):\n    return sum(items)\n")
            outside = root / "outside.py"
            outside.write_text("calculate_invoice_total = 'outside evidence'\n")
            (project / "linked.py").symlink_to(outside)
            (project / "linked-directory").symlink_to(root, target_is_directory=True)
            (project / ".env").write_text("calculate_invoice_total=credential\n")
            for name in ("private", "node_modules", ".agent-dispatcher"):
                child = project / name
                child.mkdir()
                (child / "billing.py").write_text("calculate_invoice_total = 'withheld evidence'\n")
            # The shipped app runs on commonly case-insensitive filesystems.
            (project / "private/.GITIGNORE").write_text("billing.py\n")
            before = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*")
                      if path.is_file() and not path.is_symlink()}
            result = helper.select_context(project, "Review calculate_invoice_total in billing.py", pack=PACK)
            self.assertEqual([item["path"] for item in result["excerpts"]], ["billing.py"])
            self.assertTrue(any("ignore or version-control" in item for item in result["diagnostics"]))
            after = {str(path.relative_to(project)): path.read_bytes() for path in project.rglob("*")
                     if path.is_file() and not path.is_symlink()}
            self.assertEqual(before, after)
            # An incomplete directory cannot contribute evidence: an ignore
            # rule may occur beyond the entry, byte, or time bound.
            for limits in ({"MAX_FILES": 1}, {"MAX_LIST_BYTES": 1}):
                with self.subTest(limits=limits), patch.multiple(helper, **limits):
                    result = helper.select_context(project, "Review calculate_invoice_total", pack=PACK)
                    self.assertEqual(result["context"], [])
                    self.assertTrue(any("limit" in item for item in result["diagnostics"]))
            with patch.object(helper.time, "monotonic", side_effect=[0, 11]):
                diagnostics = []
                self.assertEqual(helper._enumerate(project, diagnostics), [])
                self.assertTrue(any("limit" in item for item in diagnostics))
            (project / ".gitignore").write_text("private/\n")
            self.assertEqual(helper._enumerate(project, []), [])

    def test_context_fallback_adaptation_is_reproducible(self):
        spec = importlib.util.spec_from_file_location("dispatcher_export", ROOT / "Tools/ExportAgentDispatcher.py")
        exporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exporter)
        exported = (PACK / "scripts/context.py").read_text()
        fallback = (ROOT / "Tools/DispatcherContextFallback.py").read_text()
        fallback = fallback[fallback.index("def _portable_enumerate("):].rstrip()
        insertion = "\n" + fallback + "\n\n"
        self.assertEqual(exported.count(insertion), 1)
        original = exported.replace(insertion, "", 1).replace(
            "    return _portable_enumerate(project, diagnostics, MAX_FILES, MAX_LIST_BYTES, _skip)",
            '    diagnostics.append("Ignore-aware file enumeration unavailable (Git or ripgrep required); no files scanned.")\n    return []', 1)
        self.assertEqual(exporter.context_helper(original), exported)
        with self.assertRaisesRegex(ValueError, "changed upstream"):
            exporter.context_helper("unexpected upstream implementation")

    def test_exporter_refuses_to_write_inside_source_or_overwrite_unowned_data(self):
        spec = importlib.util.spec_from_file_location("dispatcher_export", ROOT / "Tools/ExportAgentDispatcher.py")
        exporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exporter)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            with self.assertRaisesRegex(ValueError, "separate"):
                exporter.export(source, source / "output")
            destination = Path(directory) / "unrelated"
            destination.mkdir()
            (destination / "keep.txt").write_text("user content")
            with self.assertRaisesRegex(ValueError, "not owned"):
                exporter.export(source, destination)
            self.assertEqual((destination / "keep.txt").read_text(), "user content")

    @unittest.skipUnless(importlib.util.find_spec("requests"), "staged runtime needs agent dependencies")
    def test_both_product_stages_retain_and_use_the_complete_dispatcher(self):
        probe = """import json, sys
from pathlib import Path
stage = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(stage.parent))
from ollama_code import dispatcher_runtime as dispatcher
from ollama_code.product_build import PRODUCT_NAME
assert Path(dispatcher.__file__).resolve().is_relative_to(stage)
pack = dispatcher.pack_root().resolve()
assert pack.is_relative_to(stage)
catalog = dispatcher.catalog()
assert all(dispatcher.role_instructions(row['id']) for row in catalog['roles'])
assert all(dispatcher._read_resource(row['path']) for row in catalog['guides'])
assert all(dispatcher._read_resource(row['path']) for row in catalog['recipes'])
helper = pack / 'scripts/context.py'
namespace = {'__name__': '_packaged_dispatcher_context', '__file__': str(helper)}
exec(compile(helper.read_text(), str(helper), 'exec'), namespace)
project = Path(sys.argv[2])
result = namespace['select_context'](project=str(project), task='Fix verify_login in login.py',
                                    role='implementer', pack=str(pack))
assert result['read_only']
assert not (project / '.agent-dispatcher').exists()
print(json.dumps({'product': PRODUCT_NAME, 'roles': len(catalog['roles']),
                  'guides': len(catalog['guides']), 'recipes': len(catalog['recipes']),
                  'signals': len(catalog['signals']), 'read_only': result['read_only'],
                  'sources': [item['path'] for item in result['excerpts']]}))
"""
        expected = {str(path.relative_to(PACK)): path.read_bytes() for path in PACK.rglob("*")
                    if path.is_file() and "__pycache__" not in path.parts}
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            for edition, product in (("locus", "Locus"), ("locusx", "LocusX")):
                with self.subTest(edition=edition):
                    stage = temporary / f"{product}.app/Contents/Resources/AgentRuntime/source/ollama_code"
                    subprocess.run([sys.executable, "-B", str(ROOT / "Tools/StageBackendEdition.py"),
                                    "--source", str(ROOT / "agent/ollama_code"),
                                    "--destination", str(stage), "--edition", edition],
                                   check=True, capture_output=True, text=True, timeout=30)
                    staged_pack = stage / "builtin_skills/agent-dispatcher"
                    actual = {str(path.relative_to(staged_pack)): path.read_bytes()
                              for path in staged_pack.rglob("*") if path.is_file()}
                    self.assertEqual(actual, expected)
                    project = temporary / f"{edition}-workspace"
                    project.mkdir()
                    (project / "login.py").write_text("def verify_login(name):\n    return bool(name)\n")
                    before = {str(path.relative_to(project)): path.read_bytes()
                              for path in project.rglob("*") if path.is_file()}
                    result = subprocess.run([sys.executable, "-I", "-B", "-c", probe, str(stage), str(project)],
                                            env={**os.environ, "OLLAMA_CODE_HOME": str(temporary / f"{edition}-home")},
                                            check=True, text=True, capture_output=True, cwd=project, timeout=30)
                    report = json.loads(result.stdout)
                    self.assertEqual(report, {"product": product, "roles": 27, "guides": 79,
                                              "recipes": 8, "signals": 50, "read_only": True,
                                              "sources": ["login.py"]})
                    after = {str(path.relative_to(project)): path.read_bytes()
                             for path in project.rglob("*") if path.is_file()}
                    self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
