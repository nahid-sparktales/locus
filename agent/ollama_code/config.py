"""Config file handling: ~/.ollama-code/config.json"""
from __future__ import annotations

import json
from typing import Any

from .paths import APP_DIR

CONFIG_PATH = APP_DIR / "config.json"

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
    # False for a provider that serves chat completions and no model
    # listing (Kimi Code), so the health probe does not read its auth
    # error on /models as a rejected key.
    "remote_lists_models": True,
    # The API key is NEVER written here. It comes from the keychain via the
    # app, or from one of REMOTE_API_KEY_ENV at the command line.
    "remote_api_key": "",
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
    "auto_compact": True,
    # Context window in tokens, and the single source of truth for both what
    # the agent asks Ollama for (`num_ctx`) and what it budgets against. 0 means
    # follow OLLAMA_CONTEXT_LENGTH when the server was given one, else Ollama's
    # own default. Raising it costs memory for the KV cache; it is clamped to
    # what the model was trained for.
    "context_window": 0,
    # Console settings. terminal_shell "" means $SHELL, then /bin/sh.
    "terminal_shell": "",
    "terminal_login_shell": True,
    "terminal_timeout": 600,
    "terminal_record_output": True,
}

PERMISSION_MODES = ("ask", "accept_edits", "bypass")

PROVIDERS = ("ollama", "remote")

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


def remote_api_key_from_env() -> str:
    """First API key found in the environment, or an empty string."""
    import os

    for name in REMOTE_API_KEY_ENV:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULTS)
    try:
        if CONFIG_PATH.exists():
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
    for key in ("remote_auth_style", "remote_account_label"):
        if not isinstance(cfg.get(key), str):
            cfg[key] = ""
    # Silently, rather than raising: a hand-edited config reaches here at
    # startup, and refusing to start is how a user loses the ability to fix it.
    cfg["context_window"] = context_window(cfg.get("context_window"))
    if not cfg.get("remote_api_key"):
        cfg["remote_api_key"] = remote_api_key_from_env()
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    """Persist settings. The API key is deliberately never written to disk."""
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        safe = {k: v for k, v in cfg.items() if k != "remote_api_key"}
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = CONFIG_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(safe, indent=2) + "\n", encoding="utf-8")
        tmp.replace(CONFIG_PATH)
    except OSError:
        pass
