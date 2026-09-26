import base64
import json

import pytest

from ollama_code.extensions import ExtensionManager, parse_plugin


def plugin(root, icon="./assets/icon.svg"):
    (root / ".codex-plugin").mkdir(parents=True)
    (root / "assets").mkdir()
    (root / ".codex-plugin/plugin.json").write_text(json.dumps({
        "name": "fixture", "version": "1.0.0", "description": "Artwork fixture",
        "interface": {"iconSmall": icon},
    }))
    return root / "assets/icon.svg"


@pytest.mark.parametrize("with_panel", [False, True])
def test_plugin_svg_artwork_is_available_in_catalog_review_and_install(tmp_path, with_panel):
    path = plugin(tmp_path / "plugin")
    path.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="10" fill="#123456"/></svg>')
    if with_panel:
        root = tmp_path / "plugin"
        (root / "ui").mkdir()
        (root / "ui/index.html").write_text("<!doctype html><title>Workflows</title>")
        manifest_path = root / ".codex-plugin/plugin.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["locus"] = {"panels": [{
            "id": "workflows", "title": "Workflows", "entrypoint": "ui/index.html",
            "version": 1, "capabilities": ["chat.compose"],
        }]}
        manifest_path.write_text(json.dumps(manifest))
    (tmp_path / "marketplace.json").write_text(json.dumps({
        "plugins": [{"name": "fixture", "source": "./plugin"}],
    }))
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    market = manager.add_marketplace(str(tmp_path))
    expected = base64.b64encode(path.read_bytes()).decode()
    catalog_entry = manager.catalog()[0]
    assert catalog_entry["icon_data"] == expected
    review = manager.inspect_catalog_plugin(market["id"], "fixture")
    assert review["plugin"]["icon_data"] == expected
    installed = manager.install_plugin(market["id"], "fixture", expected_digest=review["digest"])
    assert installed["icon_data"] == expected
    snapshot_plugin = manager.snapshot()["plugins"][0]
    assert snapshot_plugin["icon_data"] == expected
    for entry in (catalog_entry["capabilities"], review["plugin"], installed, snapshot_plugin):
        assert [panel["id"] for panel in entry["panels"]] == (["workflows"] if with_panel else [])


@pytest.mark.parametrize("svg", [
    '<svg><script>alert(1)</script></svg>',
    '<svg><image href="https://example.com/track"/></svg>',
    '<svg><use href="file:///etc/passwd"/></svg>',
    '<svg xml:base="https://example.com"><use href="#logo"/></svg>',
    '<svg><path style="fill:u\\72l(https://example.com/paint)"/></svg>',
    '<svg onload="alert(1)"/>',
    '<svg><path fill="url(https://example.com/paint)"/></svg>',
    '<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>',
    '<svg><foreignObject><p>HTML</p></foreignObject></svg>',
    'broken',
])
def test_active_or_external_svg_is_ignored(tmp_path, svg):
    path = plugin(tmp_path)
    path.write_text(svg)
    assert parse_plugin(tmp_path)["icon_data"] is None


def test_oversized_or_escaping_artwork_is_ignored(tmp_path):
    root = tmp_path / "plugin"
    path = plugin(root)
    path.write_bytes(b"x" * (256 * 1024 + 1))
    assert parse_plugin(root)["icon_data"] is None
    path.unlink()
    outside = tmp_path / "outside.svg"
    outside.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
    path.symlink_to(outside)
    assert parse_plugin(root)["icon_data"] is None


def test_local_marketplace_reloads_new_plugins_outside_its_workspace(tmp_path):
    market_root = tmp_path / "market"
    market_root.mkdir()
    catalog = market_root / "marketplace.json"
    catalog.write_text('{"plugins": []}')
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    marketplace = manager.add_marketplace(str(market_root))
    assert manager.catalog() == []
    plugin(market_root / "plugin")
    catalog.write_text(json.dumps({"plugins": [{"name": "fixture", "source": "./plugin"}]}))
    entries = manager.catalog(marketplace_id=marketplace["id"])
    assert [entry["name"] for entry in entries] == ["fixture"]
    assert entries[0]["available"] is True
