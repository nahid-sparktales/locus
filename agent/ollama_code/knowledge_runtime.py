"""Request-neutral workspace knowledge construction."""

from .chat_service import ChatService
from .knowledge import KnowledgeStore


def knowledge_store(
    service: ChatService | None,
    workspace: str = "",
) -> KnowledgeStore:
    target = workspace.strip()
    if not target:
        if service is None:
            raise ValueError("a service is required when workspace is empty")
        target = service.core.workspace_root or service.core.cwd
    return KnowledgeStore(target)


__all__ = ["knowledge_store"]
