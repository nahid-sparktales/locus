"""Count context categories from the runtime's prompt; never export its content."""
from __future__ import annotations

from typing import Any


def context_breakdown(core: Any) -> dict[str, Any]:
    conversation = core.context_tokens()
    schemas = core._tool_schema_tokens()
    extensions = core._extension_prompt_tokens()
    reserved = max(core.context_limit - core.budget_tokens() - schemas - extensions, 0) \
        if core.context_limit > 0 else None
    if core.identity_mode or core.chatgpt_parity_active(core._turn_allows_tools):
        # These requests include provider-owned or per-request private context
        # that the persisted transcript cannot accurately classify. In
        # particular, reading this meter must never invoke the Vault broker.
        return {
            "categories": [{"id": "provider_context", "label": "Provider-managed context",
                            "tokens": conversation + schemas + extensions, "children": []}],
            "deferred": [], "reserved_tokens": reserved,
            "note": "This provider reports combined usage. Individual prompt and tool categories are unavailable.",
        }

    categories = {key: {"id": key, "label": label, "tokens": 0, "children": []} for key, label in [
        ("messages", "Messages"), ("system_tools", "System tools"),
        ("mcp_tools", "MCP tools"), ("skills", "Skills"),
        ("system_prompt", "System prompt"), ("agent_instructions", "Agent instructions"),
        ("workspace_instructions", "Workspace instructions"), ("memory", "Memory"),
    ]}

    def add(key: str, label: str, tokens: int) -> None:
        tokens = max(tokens, 0)
        categories[key]["tokens"] += tokens
        if tokens:
            categories[key]["children"].append({
                "id": f"{key}-{len(categories[key]['children'])}", "label": label, "tokens": tokens,
            })

    system_text = "\n".join(str(m.get("content") or "") for m in core.messages if m.get("role") == "system")
    system_tokens = min(len(system_text) // 4, conversation)
    remaining = system_tokens
    for layer in getattr(core, "prompt_layers", []):
        name = str(layer.get("name") or "")
        rendered = f"## {name}\n{layer.get('content') or ''}"
        if rendered not in system_text:
            continue
        if name.startswith("Workspace instructions"):
            key = "workspace_instructions"
        elif name in {"Approved memory", "Cross-chat workspace context"}:
            key = "memory"
        elif name in {"Editable agent behavior", "Locked role and access contract"}:
            key = "agent_instructions"
        else:
            key = "system_prompt"
        tokens = min(len(rendered) // 4, remaining)
        add(key, name, tokens)
        remaining -= tokens
        system_text = system_text.replace(rendered, "", 1)
    add("system_prompt", "Additional runtime instructions", remaining)
    # Provider measurements can include working history held outside Locus.
    # Keep that difference explicit instead of attributing it to local files.
    provider_extra = max(conversation - core.approx_tokens(), 0)
    add("messages", "Conversation, reasoning, attachments and tool results",
        conversation - system_tokens - provider_extra)
    if provider_extra:
        categories["provider_context"] = {
            "id": "provider_context", "label": "Additional provider context",
            "tokens": provider_extra, "children": [],
        }

    extension_remaining = extensions
    for label, content in core._extension_prompt_sections():
        tokens = min(len(content) // 4, extension_remaining)
        add("system_prompt" if label == "Extension instructions" else "skills", label, tokens)
        extension_remaining -= tokens
    add("system_prompt", "Prompt separators", extension_remaining)

    deferred = []
    if core._turn_allows_tools:
        groups = core.tool_registry.context_schema_usage()
        for key in ("system_tools", "mcp_tools"):
            categories[key]["children"] = groups[key]
            categories[key]["tokens"] = sum(item["tokens"] for item in groups[key])
        if groups["deferred_mcp"]:
            deferred.append({
                "id": "deferred_mcp", "label": "MCP tools (deferred)",
                "tokens": sum(item["tokens"] for item in groups["deferred_mcp"]),
                "children": groups["deferred_mcp"],
            })
    return {
        "categories": list(categories.values()), "deferred": deferred,
        "reserved_tokens": reserved,
        "note": "Category counts are estimates. Messages include reasoning, attachments and tool results. "
                "The compaction buffer reserves room for replies and estimation headroom.",
    }
