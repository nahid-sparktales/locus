"""Config file handling: ~/.ollama-code/config.json"""
from __future__ import annotations

import json
import logging
from typing import Any

from .paths import APP_DIR

CONFIG_PATH = APP_DIR / "config.json"
MAX_CONFIG_BYTES = 1024 * 1024

DEFAULTS: dict[str, Any] = {
    "model": "",
    "host": "http://localhost:11434",
    "max_iterations": 40,
    # "ollama" talks to a local Ollama; "remote" talks to any
    # OpenAI-compatible endpoint (a Hugging Face Inference Endpoint, vLLM or
    # TGI on a rented GPU, …).
    "provider": "ollama",
    "remote_base_url": "",
    "remote_model": "",
    # How the key is presented to the endpoint: "bearer", or "anthropic" for
    # the extra x-api-key/anthropic-version pair. "" infers it from the host.
    "remote_auth_style": "",
    # Which of the app's provider accounts is in use ("Claude — Work"). A
    # display label only: two accounts can share a host, and without it the
    # app cannot tell which one this process is actually holding a key for.
    "remote_account_label": "",
    # "" means send no effort at all, which is what a model without an effort
    # control requires — the endpoint rejects the turn rather than ignoring an
    # unknown field. The app only sends a value for models it knows accept one.
    # Applied per request, so changing it never restarts anything.
    "remote_reasoning_effort": "",
    # False for a provider that serves chat completions and no model
    # listing (Kimi Code), so the health probe does not read its auth
    # error on /models as a rejected key.
    "remote_lists_models": True,
    # The vendor's documented window for the remote model in use, pushed by the
    # app from its own table. Kept apart from context_window because it is an
    # assumption, not an instruction: it is used only when the endpoint reports
    # nothing, it is reported to clients as "published", and it is never written
    # to model_windows.
    "published_context_window": 0,
    # The API key is NEVER written here. It comes from the app's credential
    # file via /api/provider, or from one of REMOTE_API_KEY_ENV at the command
    # line.
    "remote_api_key": "",
    # Managed ChatGPT-plan routing. Only identifiers and display metadata are
    # persisted; OAuth credentials remain in the isolated App Server home.
    "chatgpt_account_id": "",
    "chatgpt_account_label": "",
    "chatgpt_model": "",
    # Codex-native parity: the model runs under its own Codex prompt and
    # Codex-shaped tools instead of the Locus contract. Web search is separate
    # because it changes where queries go, not just how the model behaves.
    "chatgpt_native_mode": True,
    "chatgpt_web_search": False,
    # "" means the model's default effort; otherwise a value the account's
    # model list advertised. Applied per turn, so changing it never restarts
    # the helper thread.
    "chatgpt_reasoning_effort": "",
    # "ask" prompts for every non-safe tool, "accept_edits" also auto-allows
    # file writes/edits, "bypass" auto-allows everything (equivalent to
    # --dangerously-skip-permissions).
    "permission_mode": "ask",
    # Tools the user has permanently allowed, across sessions.
    "always_allow": [],
    # Shell commands that may never run, matched as a prefix.
    "deny_commands": ["rm -rf /", "mkfs", "dd if=", ":(){"],
    # Context windows Ollama was actually seen running a model in, keyed by
    # model name. Measured from /api/ps, never guessed — see
    # AgentCore.refresh_context_limit.
    "model_windows": {},
    # Largest window each model was seen to fit in without spilling to CPU,
    # keyed the same way. Written only after a measured spill, and kept apart
    # from model_windows because these are ceilings this machine imposed, not
    # windows anything was observed serving.
    "model_window_caps": {},
    # Ceiling for the window the agent asks Ollama for when the user has not
    # pinned one. Bigger windows cost KV-cache memory: a 27B model at 32768
    # needs several GB of it on top of the weights, so this is deliberately
    # short of what most models were trained for. A model that spills to CPU at
    # this size gets its own lower ceiling recorded in model_window_caps.
    "context_window_cap": 32_768,
    "auto_compact": True,
    # Context window in tokens, and the single source of truth for both what
    # the agent asks Ollama for (`num_ctx`) and what it budgets against. 0 means
    # follow OLLAMA_CONTEXT_LENGTH when the server was given one, else Ollama's
    # own default. Raising it costs memory for the KV cache; it is clamped to
    # what the model was trained for.
    "context_window": 0,
    # Retained as migration/configuration inputs for the app-owned Terminal.
    # The backend never starts that shell itself.
    "terminal_shell": "",
    "terminal_login_shell": True,
}

PERMISSION_MODES = ("ask", "accept_edits", "bypass")

PROVIDERS = ("ollama", "remote", "chatgpt")

#: Environment variables searched for the remote API key, in order.
REMOTE_API_KEY_ENV = (
    "LOCUS_REMOTE_API_KEY",
    "OLLAMA_CODE_API_KEY",
    "HF_TOKEN",
    "HUGGING_FACE_HUB_TOKEN",
    "OPENAI_API_KEY",
)


#: Below this a window cannot hold the system prompt and the tool schemas, let
#: alone a conversation. A positive value this small is a mistake — most often a
#: window written in thousands, or a JSON `true` coerced to 1 — and honouring it
#: would truncate every single request with nothing to point at the cause.
MINIMUM_CONTEXT_WINDOW = 1_024


def context_window(value: Any) -> int:
    """The configured window in tokens, or 0 when there is no usable one."""
    number = non_negative_int(value)
    return number if number >= MINIMUM_CONTEXT_WINDOW else 0


#: A turn that is allowed thousands of tool calls is a hang, not a feature: the
#: limit exists so a model looping on a failing edit stops and says so.
MAX_ITERATIONS_CEILING = 1_000


def iteration_limit(value: Any) -> int:
    """Tool iterations allowed in one turn, falling back to the default.

    `non_negative_int` already survives a hand-edited file. What matters here is
    that "no usable value" must land on the default rather than on `range(0)`:
    a bare `int()` gave two silent failures instead. A negative value yielded
    `range(-1)`, so every turn ended immediately with reason "max_iterations"
    and no tool calls — indistinguishable, from the app, from a model that
    refused to work. A non-numeric string raised ValueError inside AgentCore's
    constructor, so the agent never started at all.
    """
    number = non_negative_int(value)
    if number <= 0:
        return int(DEFAULTS["max_iterations"])
    return min(number, MAX_ITERATIONS_CEILING)


def non_negative_int(value: Any) -> int:
    """Tolerant coercion: a hand-edited config must not break the agent.

    `OverflowError` is in the list because JSON parses `1e999` into
    `float('inf')` quite happily, and `int(inf)` raises — which would take the
    service down at startup, before the user could reach the setting to fix it.
    """
    try:
        number = int(value)
    except (TypeError, ValueError, OverflowError):
        return 0
    return number if number > 0 else 0


def remote_api_key_from_env(consume: bool = False) -> str:
    """First API key found in the environment, optionally removing all copies."""
    import os

    resolved = ""
    for name in REMOTE_API_KEY_ENV:
        value = os.environ.get(name, "").strip()
        if value and not resolved:
            resolved = value
    if consume:
        for name in REMOTE_API_KEY_ENV:
            os.environ.pop(name, None)
    return resolved


def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULTS)
    try:
        if CONFIG_PATH.exists() and CONFIG_PATH.stat().st_size <= MAX_CONFIG_BYTES:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                cfg.update(data)
    except (json.JSONDecodeError, OSError):
        pass
    if cfg.get("permission_mode") not in PERMISSION_MODES:
        cfg["permission_mode"] = "ask"
    # Tolerate a hand-edited or older file: anything that is not a
    # name -> positive int mapping is dropped rather than trusted.
    windows = cfg.get("model_windows")
    clean = (
        {
            str(name): int(value)
            for name, value in windows.items()
            if isinstance(value, int) and value > 0
        }
        if isinstance(windows, dict)
        else {}
    )
    caps = cfg.get("model_window_caps")
    cfg["model_window_caps"] = (
        {
            str(name): int(value)
            for name, value in caps.items()
            if isinstance(value, int) and value > 0
        }
        if isinstance(caps, dict)
        else {}
    )
    # Entries written before windows were scoped by host carry a bare model
    # name. They were measured against the host in this same config, so re-key
    # them to it rather than discarding a real measurement and leaving the
    # meter blank until the model is next resident.
    host = str(cfg.get("host") or "").rstrip("/")
    if host:
        cfg["model_windows"] = {
            (name if "|" in name else f"{host}|{name}"): value
            for name, value in clean.items()
        }
    else:
        cfg["model_windows"] = clean
    cfg["remote_lists_models"] = bool(cfg.get("remote_lists_models", True))
    if not isinstance(cfg.get("always_allow"), list):
        cfg["always_allow"] = []
    if not isinstance(cfg.get("deny_commands"), list):
        cfg["deny_commands"] = list(DEFAULTS["deny_commands"])
    if cfg.get("provider") not in PROVIDERS:
        cfg["provider"] = "ollama"
    for key in (
        "remote_auth_style", "remote_account_label", "remote_reasoning_effort",
        "chatgpt_account_id", "chatgpt_account_label", "chatgpt_model",
        "chatgpt_reasoning_effort",
    ):
        if not isinstance(cfg.get(key), str):
            cfg[key] = ""
    cfg["chatgpt_native_mode"] = bool(cfg.get("chatgpt_native_mode", True))
    cfg["chatgpt_web_search"] = bool(cfg.get("chatgpt_web_search", False))
    # Silently, rather than raising: a hand-edited config reaches here at
    # startup, and refusing to start is how a user loses the ability to fix it.
    cfg["context_window"] = context_window(cfg.get("context_window"))
    cfg["max_iterations"] = iteration_limit(cfg.get("max_iterations"))
    cfg["context_window_cap"] = context_window(cfg.get("context_window_cap")) or int(
        DEFAULTS["context_window_cap"]
    )
    if not cfg.get("remote_api_key"):
        # Keep provider credentials in process memory, but do not let shell
        # tools or other agent-owned children inherit them through os.environ.
        cfg["remote_api_key"] = remote_api_key_from_env(consume=True)
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    """Persist settings. The API key is deliberately never written to disk."""
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        safe = {k: v for k, v in cfg.items() if k != "remote_api_key"}
        tmp = CONFIG_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(safe, indent=2) + "\n", encoding="utf-8")
        tmp.replace(CONFIG_PATH)
    except OSError as error:
        # Still swallowed: refusing to start is how a user loses the ability to
        # fix a bad config. But a silent failure here is how a misdirected write
        # went unnoticed for a week, so say so once.
        logging.getLogger(__name__).warning(
            "could not save config to %s: %s", CONFIG_PATH, error
        )
