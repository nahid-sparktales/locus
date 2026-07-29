"""Shared filesystem locations for the CLI and bundled macOS app."""
from __future__ import annotations

import os
from pathlib import Path


def app_dir() -> Path:
    """Agent data root, relocated into the app container when requested."""
    override = os.environ.get("OLLAMA_CODE_HOME", "").strip()
    return Path(override).expanduser() if override else Path.home() / ".ollama-code"


APP_DIR = app_dir()
