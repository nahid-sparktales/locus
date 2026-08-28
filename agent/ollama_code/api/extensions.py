"""Extension marketplace, plugin, skill, and MCP routes."""

from types import ModuleType

from fastapi import APIRouter


def register_routes(router: APIRouter, handlers: ModuleType) -> None:
    router.add_api_route("/api/extensions", handlers.get_extensions, methods=["GET"])
    router.add_api_route("/api/extensions/catalog", handlers.get_extension_catalog, methods=["GET"])
    router.add_api_route(
        "/api/extensions/catalog/trust", handlers.inspect_extension_plugin, methods=["GET"]
    )
    router.add_api_route(
        "/api/extensions/marketplaces", handlers.add_extension_marketplace, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/marketplaces/{marketplace_id}/refresh",
        handlers.refresh_extension_marketplace,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/extensions/marketplaces/{marketplace_id}",
        handlers.delete_extension_marketplace,
        methods=["DELETE"],
    )
    router.add_api_route(
        "/api/extensions/plugins/install", handlers.install_extension_plugin, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/plugins/enable", handlers.enable_extension_plugin, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/plugins/update", handlers.update_extension_plugin, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/plugins/rollback", handlers.rollback_extension_plugin, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/plugins/{plugin_id:path}",
        handlers.uninstall_extension_plugin,
        methods=["DELETE"],
    )
    router.add_api_route(
        "/api/extensions/skills/import", handlers.import_extension_skill, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/skills/enable", handlers.enable_extension_skill, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/skills/{skill_id:path}",
        handlers.remove_extension_skill,
        methods=["DELETE"],
    )
    router.add_api_route("/api/extensions/mcp", handlers.upsert_extension_mcp, methods=["POST"])
    router.add_api_route(
        "/api/extensions/mcp/presets/materialize",
        handlers.materialize_extension_mcp_preset,
        methods=["POST"],
    )
    router.add_api_route(
        "/api/extensions/mcp/enable", handlers.enable_extension_mcp, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/mcp/credentials", handlers.set_extension_mcp_credentials, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/mcp/policy", handlers.set_extension_mcp_policy, methods=["POST"]
    )
    router.add_api_route("/api/extensions/mcp/test", handlers.test_extension_mcp, methods=["POST"])
    router.add_api_route(
        "/api/extensions/mcp/reconnect", handlers.reconnect_extension_mcp, methods=["POST"]
    )
    router.add_api_route(
        "/api/extensions/mcp/{server_id:path}", handlers.delete_extension_mcp, methods=["DELETE"]
    )
