"""Architecture guard: installing an external world must not re-bundle its source."""
import importlib.util
import json
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parents[2] / "Tools/VerifyAgentWorldsHostBoundary.py"
spec = importlib.util.spec_from_file_location("world_host_boundary", SOURCE)
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)


def test_locus_has_no_embedded_world_implementation():
    assert boundary.verify(SOURCE.parents[1])["source_boundary"] == "passed"


def test_resource_scan_rejects_embedded_world_but_allows_unrelated_plugins(tmp_path):
    (tmp_path / "social-studio").mkdir()
    (tmp_path / "social-studio/workspace.js").write_text("fixture")
    assert boundary.verify_resources(tmp_path) == 1
    (tmp_path / "agent-world").mkdir()
    with pytest.raises(ValueError, match="Embedded world resource"):
        boundary.verify_resources(tmp_path)


def test_removed_source_cannot_return_through_the_local_catalog(tmp_path):
    (tmp_path / ".agents/plugins").mkdir(parents=True)
    (tmp_path / ".agents/plugins/marketplace.json").write_text(json.dumps({"plugins": [{"name": "agent-world"}]}))
    with pytest.raises(ValueError, match="Bundled marketplace"):
        boundary.verify(tmp_path)
