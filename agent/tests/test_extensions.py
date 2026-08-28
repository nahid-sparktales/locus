"""Extension manifests, deferred tools, and the real MCP transports."""
from __future__ import annotations

import json
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from ollama_code.extensions import (
    ExtensionError,
    ExtensionManager,
    discover_oauth_metadata,
    parse_plugin,
    parse_skill,
)
from ollama_code.mcp_runtime import (
    MCPManager,
    _sensitive_elicitation_schema,
    _validated_form_content,
    _verified_elicitation_url,
)
from ollama_code.tool_registry import ToolRegistry
from ollama_code.tools import ToolContext


def _skill(root: Path, name: str = "review", description: str = "Review a change") -> Path:
    folder = root / name
    folder.mkdir(parents=True)
    (folder / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n---\n\nFollow this workflow.\n"
    )
    return folder


def _plugin(root: Path, *, version: str = "1.0.0", endpoint: str = "https://example.com/mcp") -> Path:
    (root / ".codex-plugin").mkdir(parents=True)
    (root / ".codex-plugin/plugin.json").write_text(json.dumps({
        "name": "fixture",
        "version": version,
        "description": "Fixture plugin",
        "skills": "./skills/",
        "mcpServers": "./.mcp.json",
    }))
    _skill(root / "skills")
    (root / ".mcp.json").write_text(json.dumps({
        "mcp_servers": {"fixture": {"url": endpoint}}
    }))
    return root


def _marketplace(root: Path, plugin: Path) -> Path:
    (root / ".agents/plugins").mkdir(parents=True)
    (root / ".agents/plugins/marketplace.json").write_text(json.dumps({
        "name": "Fixture marketplace",
        "plugins": [{
            "name": "fixture",
            "source": {"source": "local", "path": f"./{plugin.relative_to(root)}"},
        }],
    }))
    return root


def test_skill_metadata_and_supporting_file_confinement(tmp_path):
    root = _skill(tmp_path)
    (root / "reference.md").write_text("safe reference")
    (root / "agents").mkdir()
    (root / "agents/openai.yaml").write_text(
        "interface:\n  display_name: Change Reviewer\n"
        "policy:\n  allow_implicit_invocation: false\n"
    )
    parsed = parse_skill(root / "SKILL.md", source="workspace")
    assert parsed["name"] == "review"
    assert parsed["display_name"] == "Change Reviewer"
    assert parsed["allow_implicit_invocation"] is False

    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    manager.import_skill(str(root))
    assert "Follow this workflow" in manager.load_skill("review")
    assert manager.read_skill_file("review", "reference.md") == "safe reference"
    with pytest.raises(ExtensionError, match="stay inside"):
        manager.read_skill_file("review", "../outside.txt")

    registry = ToolRegistry(manager)
    registry.begin_turn("Review this", str(tmp_path))
    context = ToolContext(cwd=str(tmp_path))
    assert registry.execute(
        "read_skill_file", {"skill": "review", "path": "reference.md"}, context
    ).startswith("Error: load skill")
    assert "requires an explicit" in registry.execute(
        "load_skill", {"skill": "review"}, context
    )
    registry.end_turn()
    registry.begin_turn("Use $review", str(tmp_path))
    assert registry.execute(
        "read_skill_file", {"skill": "review", "path": "reference.md"}, context
    ) == "safe reference"


def test_manifest_rejects_escaping_components_and_symlinks(tmp_path):
    root = tmp_path / "bad"
    (root / ".codex-plugin").mkdir(parents=True)
    (root / ".codex-plugin/plugin.json").write_text(json.dumps({
        "name": "bad",
        "description": "unsafe",
        "skills": "./../outside",
    }))
    with pytest.raises(ExtensionError, match="escapes"):
        parse_plugin(root)

    market = tmp_path / "market"
    plugin = _plugin(market / "plugins/linked")
    (plugin / "escape").symlink_to(tmp_path)
    _marketplace(market, plugin)
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    manager.add_marketplace(str(market))
    with pytest.raises(ExtensionError, match="symlink escapes"):
        manager.inspect_catalog_plugin("market", "fixture")


def test_marketplace_install_scope_update_and_rollback(tmp_path):
    market = tmp_path / "market"
    plugin = _plugin(market / "plugins/fixture", version="1.0.0")
    _marketplace(market, plugin)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    manager = ExtensionManager(str(workspace), root=tmp_path / "state")

    source = manager.add_marketplace(str(market), name="Fixture")
    trust = manager.inspect_catalog_plugin(source["id"], "fixture")
    installed = manager.install_plugin(
        source["id"], "fixture", scope="workspace", workspace=str(workspace),
        expected_digest=trust["digest"],
    )
    assert installed["enabled_global"] is False
    assert str(workspace.resolve()) in installed["enabled_workspaces"]
    assert any(item["id"] == "fixture:review" for item in manager.skills())

    manager.set_plugin_enabled(installed["id"], True, scope="global")
    manager.set_plugin_enabled(
        installed["id"], False, scope="workspace", workspace=str(workspace)
    )
    workspace_skill = next(item for item in manager.skills(str(workspace)) if item["id"] == "fixture:review")
    assert workspace_skill["enabled"] is False, "workspace disable must override global enable"
    other = tmp_path / "other"
    other.mkdir()
    other_skill = next(item for item in manager.skills(str(other)) if item["id"] == "fixture:review")
    assert other_skill["enabled"] is True

    (plugin / ".codex-plugin/plugin.json").write_text(json.dumps({
        "name": "fixture", "version": "2.0.0", "description": "Fixture plugin",
        "skills": "./skills/", "mcpServers": "./.mcp.json",
    }))
    manager.refresh_marketplace(source["id"])
    next_trust = manager.inspect_catalog_plugin(source["id"], "fixture")
    updated = manager.update_plugin(
        installed["id"], expected_digest=next_trust["digest"]
    )
    assert updated["version"] == "2.0.0"
    assert updated["previous_versions"] == ["1.0.0"]
    assert manager.rollback_plugin(installed["id"])["version"] == "1.0.0"


def test_credentials_are_memory_only(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    server = manager.upsert_mcp_server({
        "name": "remote",
        "url": "https://example.com/mcp",
        "auth": "headers",
        "http_headers": {"X-Secret": "do-not-persist"},
        "env": {"TOKEN": "also-secret"},
    })
    manager.set_credentials(server["id"], {
        "access_token": "bearer-secret",
        "refresh_token": "must-stay-native",
        "client_secret": "must-also-stay-native",
    })
    persisted = (tmp_path / "state/state.json").read_text()
    assert "do-not-persist" not in persisted
    assert "also-secret" not in persisted
    assert "bearer-secret" not in persisted
    assert manager.credentials(server["id"])["access_token"] == "bearer-secret"
    assert "refresh_token" not in manager.credentials(server["id"])
    assert "client_secret" not in manager.credentials(server["id"])


def test_version_one_state_migrates_with_builtins_and_preserves_user_entries(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    imported = _skill(tmp_path / "user-skills", name="frontend-design")
    (state / "state.json").write_text(json.dumps({
        "version": 1,
        "marketplaces": [],
        "plugins": [],
        "standalone_skills": [{
            "id": "frontend-design",
            "name": "frontend-design",
            "root": str(imported),
            "enabled_global": True,
            "enabled_workspaces": [],
            "disabled_workspaces": [],
        }],
        "mcp_servers": [{
            "id": "user:existing:1",
            "name": "existing",
            "url": "https://example.com/mcp",
            "command": "",
            "transport": "streamable_http",
            "enabled": True,
            "enabled_global": True,
        }],
        "mcp_policies": {"user:existing:1": {"default": "ask", "tools": {}}},
    }))

    manager = ExtensionManager(str(tmp_path), root=state)
    skills = manager.skills()
    builtin = next(item for item in skills if item["id"] == "builtin:frontend-design")
    assert builtin["shadowed"] is True
    assert builtin["enabled"] is False
    assert next(item for item in skills if item["id"] == "frontend-design")["enabled"] is True
    bundled = [item for item in skills if item.get("builtin")]
    assert len(bundled) == 26
    assert {
        "builtin:using-superpowers",
        "builtin:task-observer",
        "builtin:grill-me",
        "builtin:grilling",
        "builtin:gsd-workflow",
        "builtin:gsd-project",
        "builtin:gsd-quality",
        "builtin:gsd-context",
        "builtin:gsd-manage",
        "builtin:gsd-ideate",
        "builtin:context-handoff",
    } <= {item["id"] for item in bundled}
    assert manager.mcp_servers()[0]["id"] == "user:existing:1"
    assert manager.mcp_servers()[0]["approval_mode"] == "ask"

    manager.set_skill_enabled(
        "builtin:systematic-debugging", False, scope="workspace", workspace=str(tmp_path)
    )
    current = next(
        item for item in manager.skills() if item["id"] == "builtin:systematic-debugging"
    )
    assert current["enabled"] is False
    with pytest.raises(ExtensionError, match="only imported"):
        manager.remove_skill("builtin:systematic-debugging")
    persisted = json.loads((state / "state.json").read_text())
    assert persisted["version"] == 3
    assert persisted["builtin_skill_overrides"]


def test_startup_skills_are_trusted_ordered_and_shadow_safe(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    assert [item["id"] for item in manager.startup_skills(str(tmp_path))] == [
        "builtin:using-superpowers",
        "builtin:task-observer",
    ]

    registry = ToolRegistry(manager)
    registry.begin_turn("Use $grill-me to clarify this feature", str(tmp_path))
    context = registry.explicit_skill_context
    assert context.index("Startup skill $using-superpowers") < context.index(
        "Startup skill $task-observer"
    )
    assert context.index("Startup skill $task-observer") < context.index(
        "Explicitly activated skill $builtin:grill-me"
    )

    shadow = _skill(tmp_path / "user-skills", name="using-superpowers")
    manager.import_skill(str(shadow))
    startup = manager.startup_skills(str(tmp_path))
    assert all(item["name"] != "using-superpowers" for item in startup)
    replacement = next(
        item for item in manager.skills(str(tmp_path))
        if item["name"] == "using-superpowers" and not item.get("builtin")
    )
    assert replacement["activation"] == "automatic"


def test_bundled_skill_source_pins_and_activation_metadata(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    skills = {item["id"]: item for item in manager.skills(str(tmp_path))}

    assert skills["builtin:task-observer"]["provenance"]["commit"] == (
        "281f13466cd3a73e9ebc9d210907748e1941a3dd"
    )
    assert skills["builtin:task-observer"]["activation"] == "startup"
    assert skills["builtin:using-superpowers"]["provenance"]["commit"] == (
        "b36e0829c6d0140e93cfef2ca599b1b07d4a7797"
    )
    assert skills["builtin:using-superpowers"]["activation"] == "startup"
    assert skills["builtin:grill-me"]["provenance"]["commit"] == (
        "068b6e0c62393147daf03530149cdce209c93da8"
    )
    assert skills["builtin:grill-me"]["activation"] == "explicit"
    assert skills["builtin:grilling"]["activation"] == "automatic"
    for router in ("workflow", "project", "quality", "context", "manage", "ideate"):
        skill = skills[f"builtin:gsd-{router}"]
        assert skill["provenance"]["commit"] == (
            "bdcaab2c752d9a33a1a1ca9acf3a3c81fb991815"
        )
        assert skill["activation"] == "automatic"


def test_recommended_mcp_presets_are_inert_scoped_and_idempotent(tmp_path, monkeypatch):
    def network_forbidden(*_args, **_kwargs):
        raise AssertionError("listing and materializing presets must not use the network")

    monkeypatch.setattr("ollama_code.extensions.requests.get", network_forbidden)
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    presets = manager.snapshot()["mcp_presets"]
    assert [item["id"] for item in presets] == [
        "context7", "github", "sentry", "supabase", "openai-docs"
    ]
    assert all(item["installed"] is False for item in presets)
    github = next(item for item in presets if item["id"] == "github")
    assert github["catalog_version"] == 2
    assert github["oauth_strategy"] == "github_device"

    with pytest.raises(ExtensionError, match="project reference"):
        manager.materialize_mcp_preset("supabase")
    server = manager.materialize_mcp_preset("supabase", project_ref="abcd1234")
    assert server["enabled_global"] is False
    assert "project_ref=abcd1234" in server["url"]
    assert "read_only=true" in server["url"]
    assert manager.materialize_mcp_preset(
        "supabase", project_ref="different"
    )["id"] == server["id"]
    assert manager.mcp_presets()[3]["installed"] is True


def test_github_preset_state_migration_preserves_user_scope(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    (state / "state.json").write_text(json.dumps({
        "version": 2,
        "mcp_servers": [{
            "id": "user:custom-github",
            "name": "GitHub",
            "url": "https://api.githubcopilot.com/mcp/",
            "enabled": False,
            "enabled_global": False,
            "enabled_workspaces": [str(tmp_path)],
            "disabled_workspaces": [],
            "custom_marker": "keep-me",
        }],
    }))

    manager = ExtensionManager(str(tmp_path), root=state)
    server = manager.mcp_servers(str(tmp_path))[0]
    assert server["id"] == "user:custom-github"
    assert server["enabled"] is False
    assert server["enabled_global"] is False
    assert server["enabled_workspaces"] == [str(tmp_path)]
    assert server["custom_marker"] == "keep-me"
    assert server["preset_id"] == "github"
    assert server["oauth_strategy"] == "github_device"
    assert server["preset_provenance"]["catalog_version"] == 2


def test_oauth_metadata_discovery_validates_issuer_and_does_not_follow_redirects(monkeypatch):
    seen = {}

    class Response:
        status_code = 200
        content = b"{}"

        @staticmethod
        def json():
            return {
                "issuer": "https://auth.example",
                "authorization_endpoint": "https://auth.example/authorize",
                "token_endpoint": "https://auth.example/token",
            }

    def get(url, **kwargs):
        seen.update(url=url, **kwargs)
        return Response()

    monkeypatch.setattr("ollama_code.extensions.requests.get", get)
    value = discover_oauth_metadata({
        "auth": "oauth",
        "oauth": {"issuer": "https://auth.example", "client_id": "locus"},
    })
    assert value["oauth"]["token_endpoint"] == "https://auth.example/token"
    assert seen["allow_redirects"] is False

    Response.json = staticmethod(lambda: {"issuer": "https://attacker.example"})
    with pytest.raises(ExtensionError, match="issuer"):
        discover_oauth_metadata({
            "auth": "oauth",
            "oauth": {"issuer": "https://auth.example", "client_id": "locus"},
        })


class _FakeMCP:
    def available_tools(self):
        return [{
            "server_id": "remote-1",
            "server_name": "Linear",
            "name": "list_issues",
            "description": "List Linear issues",
            "input_schema": {"type": "object", "properties": {}},
            "annotations": {"readOnlyHint": True, "openWorldHint": False},
            "schema_digest": "abc",
            "server_fingerprint": "server",
            "approval_mode": "annotations",
        }]

    def call_tool(self, server_id, tool_name, arguments, should_stop=None):
        return f"{server_id}:{tool_name}"

    def available_resources(self):
        return [{
            "server_id": "remote-1", "server_name": "Linear",
            "uri": "linear://issues", "name": "Issues", "title": "Team issues",
            "description": "Current issue evidence",
        }]

    def read_resource(self, server_id, uri):
        return f"Untrusted MCP resource content\n{server_id}:{uri}"

    def available_prompts(self):
        return [{
            "server_id": "remote-1", "server_name": "Linear",
            "name": "triage", "title": "Triage", "description": "Triage instructions",
            "arguments": [{"name": "project"}],
        }]

    def load_prompt(self, server_id, prompt_name, arguments):
        return f"Untrusted MCP prompt content\n{server_id}:{prompt_name}:{arguments}"

    def refresh(self, wait=True):
        return None

    def statuses(self):
        return []

    def status(self, server_id):
        return None

    def close(self):
        return None


def test_deferred_tool_discovery_and_annotation_policy(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    registry = ToolRegistry(manager, _FakeMCP())
    registry.begin_turn("Find issues", str(tmp_path))
    names = [item["function"]["name"] for item in registry.schemas()]
    assert not any(name.startswith("mcp__") for name in names)

    result = registry.execute(
        "search_extension_tools", {"query": "Linear issues"}, ToolContext(cwd=str(tmp_path))
    )
    assert "mcp__Linear__list_issues" in result
    names = [item["function"]["name"] for item in registry.schemas()]
    qualified = next(name for name in names if name.startswith("mcp__"))
    assert registry.is_safe(qualified) is True
    assert registry.execute(qualified, {}, ToolContext(cwd=str(tmp_path))) == "remote-1:list_issues"


def test_read_only_agent_cannot_use_mutating_mcp_even_when_server_says_allow(tmp_path):
    class MutatingMCP(_FakeMCP):
        def available_tools(self):
            value = super().available_tools()[0]
            return [{
                **value,
                "name": "delete_issue",
                "approval_mode": "allow",
                "annotations": {"readOnlyHint": False, "destructiveHint": True},
            }]

    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    registry = ToolRegistry(manager, MutatingMCP())
    registry.set_mcp_agent_policy({
        "server_ids": ["remote-1"], "tools": ["delete_issue"],
        "resources": [], "prompts": [],
    }, access_ceiling="read_only", role="reviewer")
    registry.begin_turn("review", str(tmp_path))
    registry.execute(
        "search_extension_tools", {"query": "delete"}, ToolContext(cwd=str(tmp_path))
    )
    name = "mcp__Linear__delete_issue"

    assert registry.is_safe(name) is False
    assert name not in {item["function"]["name"] for item in registry.schemas()}
    assert "read-only MCP tools" in registry.execute(
        name, {}, ToolContext(cwd=str(tmp_path))
    )


def test_resources_are_untrusted_and_prompts_require_agent_allowlisting(tmp_path):
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    registry = ToolRegistry(manager, _FakeMCP())
    context = ToolContext(cwd=str(tmp_path))
    registry.set_mcp_agent_policy({
        "server_ids": ["remote-1"],
        "resources": ["linear://issues"],
        "prompts": [],
        "tools": [],
    }, access_ceiling="read_only", role="reviewer")

    found = registry.execute("search_extension_resources", {"query": "issues"}, context)
    assert "untrusted external data" in found
    assert "Untrusted MCP resource" in registry.execute(
        "read_extension_resource",
        {"server_id": "remote-1", "uri": "linear://issues"},
        context,
    )
    assert "No allowed MCP prompts" in registry.execute(
        "search_extension_prompts", {"query": "triage"}, context,
    )

    registry.set_mcp_agent_policy({
        "server_ids": ["remote-1"], "resources": [],
        "prompts": ["triage"], "tools": [],
    }, access_ceiling="read_only", role="reviewer")
    assert "Untrusted MCP prompt" in registry.execute(
        "load_extension_prompt",
        {"server_id": "remote-1", "prompt": "triage", "arguments": {"project": "app"}},
        context,
    )


def test_mcp_elicitation_rejects_sensitive_forms_and_validates_bounded_values():
    assert _sensitive_elicitation_schema({
        "type": "object", "properties": {"api_key": {"type": "string"}},
    })
    assert _sensitive_elicitation_schema({
        "type": "object", "properties": {
            "account": {"type": "object", "properties": {
                "password": {"type": "string"},
            }},
        },
    })
    schema = {
        "type": "object",
        "properties": {"project": {"type": "string"}, "count": {"type": "integer"}},
        "required": ["project"],
    }
    assert _validated_form_content(schema, {"project": "Locus", "count": 2}) == {
        "project": "Locus", "count": 2,
    }
    assert _validated_form_content(schema, {"project": "Locus", "extra": True}) is None
    assert _validated_form_content(schema, {"count": 2}) is None
    server = {
        "url": "https://mcp.example/rpc",
        "oauth": {"issuer": "https://login.example"},
    }
    assert _verified_elicitation_url("https://mcp.example/verify?id=1", server)
    assert _verified_elicitation_url("https://login.example/approve?id=1", server)
    assert not _verified_elicitation_url("https://attacker.example/approve", server)


def test_mcp_namespace_collisions_are_stable(tmp_path):
    class CollisionMCP(_FakeMCP):
        def available_tools(self):
            tool = super().available_tools()[0]
            return [tool, {**tool, "server_id": "remote-2"}]

    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    registry = ToolRegistry(manager, CollisionMCP())
    names = sorted(
        item["name"] for item in registry.metadata() if item["origin"] == "mcp"
    )
    assert len(names) == 2
    assert all(name.startswith("mcp__Linear__list_issues_") for name in names)
    assert len(set(names)) == 2


def test_loaded_skill_instructions_are_ephemeral(tmp_path):
    source = _skill(tmp_path / "source")
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    manager.import_skill(str(source))
    registry = ToolRegistry(manager)
    registry.begin_turn("Please review this", str(tmp_path))
    result = registry.execute("load_skill", {"skill": "review"}, ToolContext(cwd=str(tmp_path)))
    assert "Loaded skill $review for this turn" in result
    assert "Follow this workflow" not in result
    assert "Follow this workflow" in registry.explicit_skill_context
    registry.end_turn()
    assert registry.explicit_skill_context == ""


def test_extension_rest_contract_and_busy_conflict(tmp_path):
    from concurrent.futures import Future

    from ollama_code import server as server_mod
    from ollama_code.core import AgentCore

    market = tmp_path / "market"
    _marketplace(market, _plugin(market / "plugins/fixture"))
    core = AgentCore(cwd=str(tmp_path), config={"model": "fixture", "max_iterations": 2})
    core.mcp.close()
    core.extensions = ExtensionManager(str(tmp_path), root=tmp_path / "state")
    core.mcp = _FakeMCP()
    core.tool_registry = ToolRegistry(core.extensions, core.mcp)
    service = server_mod.ChatService(core)
    test_app = server_mod.create_app(chat_service=service)

    with TestClient(test_app) as client:
        added = client.post(
            "/api/extensions/marketplaces", json={"source": str(market), "name": "Fixture"}
        )
        assert added.status_code == 200
        marketplace_id = added.json()["id"]
        catalog = client.get("/api/extensions/catalog").json()["entries"]
        assert [item["name"] for item in catalog] == ["fixture"]
        trust = client.get(
            "/api/extensions/catalog/trust",
            params={"marketplace_id": marketplace_id, "plugin": "fixture"},
        ).json()
        installed = client.post("/api/extensions/plugins/install", json={
            "marketplace_id": marketplace_id,
            "plugin": "fixture",
            "expected_digest": trust["digest"],
        })
        assert installed.status_code == 200
        snapshot = client.get("/api/extensions").json()
        assert len(snapshot["plugins"]) == 1
        assert any(skill["id"] == "fixture:review" for skill in snapshot["skills"])

        manifest = market / "plugins/fixture/.codex-plugin/plugin.json"
        updated_manifest = json.loads(manifest.read_text())
        updated_manifest["version"] = "2.0.0"
        manifest.write_text(json.dumps(updated_manifest))
        client.post(f"/api/extensions/marketplaces/{marketplace_id}/refresh")
        update_trust = client.get(
            "/api/extensions/catalog/trust",
            params={"marketplace_id": marketplace_id, "plugin": "fixture"},
        ).json()
        updated = client.post("/api/extensions/plugins/update", json={
            "id": installed.json()["id"], "expected_digest": update_trust["digest"],
        })
        assert updated.status_code == 200
        assert updated.json()["version"] == "2.0.0"

        service.turn_future = Future()
        conflict = client.post("/api/extensions/plugins/enable", json={
            "id": installed.json()["id"], "enabled": False,
        })
        assert conflict.status_code == 409
        assert client.get("/api/extensions/catalog").status_code == 200
        service.turn_future.set_result(None)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@pytest.mark.parametrize("transport", ["stdio", "http"])
def test_official_mcp_runtime_discovers_and_calls_tools(tmp_path, transport):
    script = tmp_path / "fixture_mcp.py"
    script.write_text(
        "from mcp.server import MCPServer\n"
        "from mcp.types import ToolAnnotations\n"
        "server=MCPServer('fixture')\n"
        "@server.tool(annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False))\n"
        "def greet(name: str) -> str:\n    return f'hello {name}'\n"
        + (
            "server.run('stdio')\n" if transport == "stdio" else
            "import sys\nserver.run('streamable-http', host='127.0.0.1', port=int(sys.argv[1]), stateless_http=True, json_response=True)\n"
        )
    )
    manager = ExtensionManager(str(tmp_path), root=tmp_path / "state", sandboxed=False)
    process = None
    if transport == "stdio":
        config = {"name": "fixture", "command": sys.executable, "args": [str(script)]}
    else:
        port = _free_port()
        process = subprocess.Popen(
            [sys.executable, str(script), str(port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        config = {"name": "fixture", "url": f"http://127.0.0.1:{port}/mcp"}
    server = manager.upsert_mcp_server(config)
    runtime = MCPManager(manager)
    try:
        runtime.refresh(wait=True)
        tools = runtime.available_tools()
        assert [item["name"] for item in tools] == ["greet"]
        result = runtime.call_tool(server["id"], "greet", {"name": "Locus"})
        assert result.startswith("hello Locus")
        assert '"result": "hello Locus"' in result
        runtime.reconnect(server["id"])
        assert runtime.status(server["id"])["state"] == "connected"
        assert [item["name"] for item in runtime.available_tools()] == ["greet"]
    finally:
        runtime.close()
        if process is not None:
            process.terminate()
            process.wait(timeout=5)


def test_marketplace_plugin_skill_mcp_and_restart_end_to_end(tmp_path):
    market = tmp_path / "market"
    plugin = _plugin(market / "plugins/fixture")
    (plugin / "fixture_mcp.py").write_text(
        "from mcp.server import MCPServer\n"
        "from mcp.types import ToolAnnotations\n"
        "server=MCPServer('fixture')\n"
        "@server.tool(annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False))\n"
        "def greet(name: str) -> str:\n    return f'hello {name}'\n"
        "server.run('stdio')\n"
    )
    (plugin / ".mcp.json").write_text(json.dumps({
        "mcpServers": {
            "fixture": {
                "command": sys.executable,
                "args": ["${PLUGIN_ROOT}/fixture_mcp.py"],
            }
        }
    }))
    _marketplace(market, plugin)
    state = tmp_path / "state"
    manager = ExtensionManager(str(tmp_path), root=state, sandboxed=False)
    source = manager.add_marketplace(str(market))
    trust = manager.inspect_catalog_plugin(source["id"], "fixture")
    installed = manager.install_plugin(
        source["id"], "fixture", expected_digest=trust["digest"]
    )

    runtime = MCPManager(manager)
    try:
        runtime.refresh(wait=True)
        registry = ToolRegistry(manager, runtime)
        registry.begin_turn("Use $fixture:review", str(tmp_path))
        assert "Follow this workflow" in registry.explicit_skill_context
        registry.end_turn()

        registry.begin_turn("Review these changes", str(tmp_path))
        loaded = registry.execute(
            "load_skill", {"skill": "fixture:review"}, ToolContext(cwd=str(tmp_path))
        )
        assert "Loaded skill $fixture:review" in loaded
        registry.execute(
            "search_extension_tools", {"query": "greet"}, ToolContext(cwd=str(tmp_path))
        )
        tool_name = next(
            item["function"]["name"] for item in registry.schemas()
            if item["function"]["name"].startswith("mcp__")
        )
        assert registry.execute(
            tool_name, {"name": "Locus"}, ToolContext(cwd=str(tmp_path))
        ).startswith("hello Locus")
    finally:
        runtime.close()

    restarted = ExtensionManager(str(tmp_path), root=state, sandboxed=False)
    assert any(item["id"] == installed["id"] for item in restarted.snapshot()["plugins"])
    assert any(item["id"] == "fixture:review" for item in restarted.skills())
    assert any(item["id"] == "plugin:fixture:fixture" for item in restarted.mcp_servers())


def test_degraded_state_read_is_reported_in_snapshot_errors(tmp_path):
    # The app reclaims orphaned MCP credential entries against snapshot()["errors"]:
    # an empty list means "this server list is complete, anything missing from it
    # is an orphan". A silently degraded read would therefore delete live OAuth
    # refresh tokens, so a read that loses servers has to say so.
    state = tmp_path / "state"
    manager = ExtensionManager(str(tmp_path), root=state, sandboxed=False)
    manager.upsert_mcp_server({"name": "remote", "transport": "streamable_http",
                               "url": "https://example.com/mcp"})
    assert manager.snapshot()["errors"] == []
    assert manager.snapshot()["mcp_servers"]

    # Corrupt the state file the way a truncated write or a reset container would.
    (state / "state.json").write_text("{ not json")
    degraded = ExtensionManager(str(tmp_path), root=state, sandboxed=False)
    assert degraded.snapshot()["mcp_servers"] == []
    assert degraded.snapshot()["errors"], "a lost server list must be reported"


def test_missing_state_file_is_not_an_error(tmp_path):
    # A first run genuinely has no servers; reporting that as degraded would
    # permanently disable orphan reclamation.
    fresh = ExtensionManager(str(tmp_path), root=tmp_path / "nothing-here", sandboxed=False)
    assert fresh.snapshot()["errors"] == []
