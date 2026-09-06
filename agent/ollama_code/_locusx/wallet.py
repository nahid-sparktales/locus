"""LocusX-only native wallet tools and their capability-gated bridge."""
from __future__ import annotations

from collections.abc import Callable
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeout
from typing import Any

from ..product_features import ProductFeatures
from ..tools import truncate_output

WALLET_BUDGET_MS = 60_000


def _schema(
    name: str,
    description: str,
    properties: dict[str, Any],
    required: list[str],
) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
            },
        },
    }


WALLET_TOOL_SCHEMAS = [
    _schema(
        "wallet_list_accounts",
        "List public Locus Vault accounts and chains. Never returns keys or recovery material.",
        {},
        [],
    ),
    _schema(
        "wallet_get_balance",
        "Read balances for one public Locus Vault account.",
        {"account_id": {"type": "string"}, "network_id": {"type": "string"}},
        ["account_id", "network_id"],
    ),
    _schema(
        "wallet_get_activity",
        "Read recent on-chain activity for one public Locus Vault account.",
        {"account_id": {"type": "string"}, "network_id": {"type": "string"}, "limit": {"type": "integer"}},
        ["account_id", "network_id"],
    ),
    _schema(
        "wallet_prepare_transaction",
        "Prepare one semantic transaction without exposing key material. Locus, not the caller, encodes and classifies the transaction.",
        {
            "network_id": {
                "type": "string",
                "enum": ["eip155:11155111"],
                "description": "CAIP-2 network identifier. The experimental signer supports Sepolia only.",
            },
            "account_id": {"type": "string"},
            "action": {
                "type": "object",
                "description": "A semantic action. Raw calldata and caller-supplied safety labels are not accepted.",
                "properties": {
                    "type": {"type": "string", "enum": ["native_transfer", "contract_call"]},
                    "recipient": {"type": "string"},
                    "amount_base_units": {"type": "string", "pattern": "^[0-9]+$"},
                    "contract_id": {"type": "string"},
                    "function": {"type": "string"},
                    "arguments": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "type": {"type": "string"},
                                "value": {},
                            },
                            "required": ["type", "value"],
                            "additionalProperties": False,
                        },
                    },
                    "value_base_units": {"type": "string", "pattern": "^[0-9]+$"},
                },
                "required": ["type"],
                "additionalProperties": False,
            },
            "maximum_fee_base_units": {
                "type": "string",
                "pattern": "^[0-9]+$",
                "description": "Unsigned fee ceiling in the network's smallest unit.",
            },
        },
        ["network_id", "account_id", "action", "maximum_fee_base_units"],
    ),
    _schema(
        "wallet_simulate_transaction",
        "Re-simulate one prepared transaction and report decoded asset and fee changes.",
        {"intent_id": {"type": "string"}},
        ["intent_id"],
    ),
    _schema(
        "wallet_execute_transaction",
        "Execute exactly one prepared digest after native policy, expiry, nonce, and simulation checks. No permission mode can bypass the wallet policy.",
        {"intent_id": {"type": "string"}},
        ["intent_id"],
    ),
    _schema(
        "wallet_lock",
        "Lock the Locus Vault immediately and clear all session transaction policies.",
        {},
        [],
    ),
]

_READ_ONLY_WALLET_TOOLS = {
    "wallet_list_accounts", "wallet_get_balance", "wallet_get_activity",
}
_WALLET_TOOL_NAMES = {
    schema["function"]["name"] for schema in WALLET_TOOL_SCHEMAS
}


class WalletFeature(ProductFeatures):
    persisted_event_types = frozenset({"wallet_action_request"})

    def __init__(self, registry: Any) -> None:
        super().__init__(registry)
        self.capability: dict[str, Any] | None = None
        self.pending_actions: dict[str, Future[dict[str, Any]]] = {}
        self.executor: Callable[[str, dict[str, Any], str], str] | None = None

    def bind(self, service: Any) -> None:
        super().bind(service)
        self.executor = self._execute_bridge

    def schemas(self) -> list[dict[str, Any]]:
        if not self.enabled:
            return []
        return [
            schema for schema in WALLET_TOOL_SCHEMAS
            if self.tool_allowed(schema["function"]["name"])
        ]

    def tool_allowed(self, name: str) -> bool:
        if not self.enabled or name not in _WALLET_TOOL_NAMES:
            return False
        allowed = set(self.capability.get("allowed_operations") or [])
        if name not in allowed:
            return False
        if self.registry._agent_access_ceiling == "read_only":
            return name in _READ_ONLY_WALLET_TOOLS
        return True

    @property
    def enabled(self) -> bool:
        capability = self.capability
        return bool(
            capability
            and capability.get("protocol_version") == 1
            and capability.get("signer_state") == "unlocked"
            and str(capability.get("session_id") or "").strip()
        )

    def configure_capability(self, value: Any) -> bool:
        """Validate and install the native signer's least-authority surface."""
        if not isinstance(value, dict):
            self.capability = None
            return False
        operations = value.get("allowed_operations")
        chains = value.get("supported_chains")
        valid = (
            value.get("protocol_version") == 1
            and value.get("signer_state") == "unlocked"
            and bool(str(value.get("session_id") or "").strip())
            and isinstance(operations, list)
            and bool(operations)
            and set(operations) <= _WALLET_TOOL_NAMES
            and isinstance(chains, list)
            and bool(chains)
            and all(isinstance(chain, str) and ":" in chain for chain in chains)
        )
        if not valid:
            self.capability = None
            return False
        self.capability = {
            "protocol_version": 1,
            "signer_state": "unlocked",
            "session_id": str(value["session_id"]),
            "supported_chains": list(dict.fromkeys(chains)),
            "allowed_operations": list(dict.fromkeys(operations)),
        }
        return True

    def owns(self, name: str) -> bool:
        return name in _WALLET_TOOL_NAMES

    def is_safe(self, name: str) -> bool:
        return self.tool_allowed(name) and name in _READ_ONLY_WALLET_TOOLS

    def tool_info(self, name: str) -> dict[str, Any] | None:
        if not self.enabled or not self.owns(name):
            return None
        return {
            "origin": "wallet",
            "annotations": {
                "readOnlyHint": name in _READ_ONLY_WALLET_TOOLS,
                "destructiveHint": name == "wallet_execute_transaction",
            },
        }

    def execute(self, name: str, arguments: dict[str, Any], request_id: str) -> str:
        # A guessed name and a route that changed its access ceiling must pass
        # the same authority checks as an advertised call.
        if not self.tool_allowed(name):
            return "Error: this agent cannot use that wallet tool."
        if self.executor is None:
            return "Error: the Locus Vault is unavailable."
        return self.executor(name, arguments, request_id)

    def handle_message(self, message: dict[str, Any]) -> bool:
        if self.service is None:
            return False
        kind = message.get("type")
        if kind == "set_wallet_control":
            if self.service.busy:
                from ..chat_transport_runtime import command_error

                command_error(self.service, kind, "Wait for the active turn to finish.")
                return True
            enabled = self.configure_capability(message.get("capability"))
            self.service.queue_event({
                "type": "wallet_control_status",
                "enabled": enabled,
                "protocol_version": 1,
                "session_id": self.capability.get("session_id") if self.capability else None,
            })
            return True
        if kind == "wallet_action_result":
            request_id = str(message.get("request_id") or "")
            raw = message.get("result")
            result = raw if isinstance(raw, dict) else {"error": "invalid wallet result"}
            self.answer(request_id, result)
            return True
        return False

    def _execute_bridge(
        self,
        tool: str,
        arguments: dict[str, Any],
        request_id: str,
    ) -> str:
        """Bridge a capability-gated wallet call to the native policy gateway."""
        if not self.enabled:
            return "Error: the Locus Vault is unavailable."
        if not self.tool_allowed(tool):
            return "Error: this wallet operation is not present in the active signer capability."
        future: Future[dict[str, Any]] = Future()
        self.pending_actions[request_id] = future
        self.service.emit({
            "type": "wallet_action_request",
            "request_id": request_id,
            "tool": tool,
            "arguments": arguments,
            "timeout_ms": WALLET_BUDGET_MS,
            "session_id": self.service.core.session.session_id,
        })
        try:
            result = future.result(timeout=WALLET_BUDGET_MS / 1000 + 2)
        except FutureTimeout:
            return "Error: the Locus Vault did not answer within 60 seconds."
        finally:
            self.pending_actions.pop(request_id, None)
        error = str(result.get("error") or "").strip()
        if error:
            return f"Error: {error}"
        text = str(result.get("text") or "")
        return truncate_output(text) if text else "Wallet action completed."

    def answer(self, request_id: str, result: dict[str, Any]) -> bool:
        future = self.pending_actions.get(request_id)
        if future is None or future.done():
            return False
        future.set_result(result)
        return True

    def cancel_pending(self) -> None:
        for future in list(self.pending_actions.values()):
            if not future.done():
                future.set_result({"error": "cancelled by the user"})
