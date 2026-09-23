"""The native Social Studio is installed and trusted through the plugin catalog."""
import json
from pathlib import Path

import pytest

from ollama_code.extensions import ExtensionError, ExtensionManager, parse_plugin

REPO = Path(__file__).resolve().parents[2]


def test_social_studio_marketplace_install(tmp_path):
    manager = ExtensionManager(str(REPO), root=tmp_path / "state")
    marketplace = manager.add_marketplace(str(REPO))
    inspection = manager.inspect_catalog_plugin(marketplace["id"], "social-studio")
    screens = inspection["plugin"]["screens"]
    assert screens == [{
        "id": "social-studio", "title": "Social Studio", "entrypoint": "ui/index.html",
        "version": 1, "capabilities": ["social.workspace"],
    }]
    assert inspection["trust"]["screens"] == screens
    installed = manager.install_plugin(marketplace["id"], "social-studio", expected_digest=inspection["digest"])
    assert installed["screens"] == screens
    assert (Path(installed["root"]) / "ui/index.html").is_file()
    assert installed["mcp_servers"] == []


@pytest.mark.parametrize("identifier,capabilities", [
    ("agent-world", ["social.workspace"]),
    ("social-studio", ["social.workspace", "agents.read"]),
    ("social-studio", ["social.workspace", "agents.interact"]),
])
def test_native_capability_cannot_be_mixed_with_web_bridge(tmp_path, identifier, capabilities):
    (tmp_path / ".codex-plugin").mkdir()
    (tmp_path / "ui").mkdir()
    (tmp_path / "ui/index.html").write_text("<!doctype html><title>Fixture</title>")
    manifest = json.loads((REPO / "plugins/social-studio/.codex-plugin/plugin.json").read_text())
    screen = manifest["locus"]["screens"][0]
    screen["id"] = identifier
    screen["capabilities"] = capabilities
    (tmp_path / ".codex-plugin/plugin.json").write_text(json.dumps(manifest))
    with pytest.raises(ExtensionError, match="native social-studio"):
        parse_plugin(tmp_path)
