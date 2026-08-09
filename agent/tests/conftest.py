"""Test-suite isolation for the bundled agent.

Everything the agent persists hangs off one root (``paths.APP_DIR``, paths.py:14)
and every module binds its own constant off it *at import time*:
``config.CONFIG_PATH``, ``sessions.SESSIONS_DIR``, the ``ExtensionManager``
default root, ``app.HISTORY_FILE``. Isolation therefore needs two layers, and
this file is the only place either of them happens.

Layer 1 sets ``OLLAMA_CODE_HOME`` before ``ollama_code`` is imported, so every
derived constant relocates itself. That is what makes a constant nobody
remembered — the previous per-module fixture missed two — safe by construction
rather than by vigilance. Layer 2 gives each test its own directory by patching
those already-bound constants.

This file lives beside the test modules on purpose: ``agent/pyproject.toml`` used
to declare a second pytest config, which made ``cd agent && pytest`` treat
``agent`` as the rootdir. pytest's ``confcutdir`` defaults to the rootdir, so a
repo-root conftest would have been skipped by exactly the command the docs tell
developers to run. A conftest in the tests directory is picked up either way.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

#: The directory the suite must never read from or write to.
REAL_APP_DIR = Path.home() / ".ollama-code"

# `python -m pytest` from `agent/` puts the agent directory on the path, and
# pytest.ini sets `pythonpath = agent` for a repo-root run. Neither is
# guaranteed for a bare `pytest` invocation, and this file imports the package
# before any test module does, so make the import work regardless.
_AGENT_DIR = Path(__file__).resolve().parent.parent
if str(_AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(_AGENT_DIR))

# --- Layer 1: before the first `import ollama_code` in this process ----------
_SESSION_HOME = Path(tempfile.mkdtemp(prefix="ollama-code-test-home-"))
os.environ["OLLAMA_CODE_HOME"] = str(_SESSION_HOME)

import pytest  # noqa: E402

from ollama_code import app as app_mod  # noqa: E402
from ollama_code import config as config_mod  # noqa: E402
from ollama_code import extensions as extensions_mod  # noqa: E402
from ollama_code import paths as paths_mod  # noqa: E402
from ollama_code import sessions as sessions_mod  # noqa: E402
from ollama_code import transcript_search as transcript_search_mod  # noqa: E402

# Fails now, loudly, rather than at some later write: if anything imported
# ollama_code above the assignment, every constant below is already pointing at
# the developer's real home and no amount of patching here would catch all of
# them.
assert paths_mod.APP_DIR == _SESSION_HOME, (
    "ollama_code was imported before OLLAMA_CODE_HOME was set; "
    f"APP_DIR is {paths_mod.APP_DIR}"
)


# --- Layer 2: one directory per test ----------------------------------------
#: Every module-level constant derived from APP_DIR, as (module, attribute,
#: leaf-under-the-home). Kept honest by test_isolation.py, which rediscovers
#: them by reflection instead of trusting this list.
_APP_DIR_CONSTANTS: tuple[tuple[Any, str, str | None], ...] = (
    (paths_mod, "APP_DIR", None),
    (config_mod, "APP_DIR", None),
    (config_mod, "CONFIG_PATH", "config.json"),
    (sessions_mod, "APP_DIR", None),
    (sessions_mod, "SESSIONS_DIR", "sessions"),
    (extensions_mod, "APP_DIR", None),
    (app_mod, "APP_DIR", None),
    (app_mod, "HISTORY_FILE", "history"),
    (transcript_search_mod, "APP_DIR", None),
    (transcript_search_mod, "DEFAULT_PATH", "transcript-index.sqlite3"),
)


@pytest.fixture(autouse=True)
def isolated_app_dir(tmp_path, monkeypatch):
    """Every agent data path for this test, under this test's own tmp_path."""
    # Deliberately not created: the agent's own code makes what it needs, and
    # pre-creating `sessions` would hide a missing mkdir in that code.
    home = tmp_path / "dot-ollama-code"
    # Child processes matter too: the stdio MCP servers the extension tests
    # spawn re-run paths.app_dir() in a fresh interpreter.
    monkeypatch.setenv("OLLAMA_CODE_HOME", str(home))
    for module, attribute, leaf in _APP_DIR_CONSTANTS:
        monkeypatch.setattr(module, attribute, home / leaf if leaf else home)
    return home


@pytest.fixture(autouse=True)
def no_background_probes(monkeypatch):
    """No test reaches out to discover a context window unless it says so.

    Switching provider spawns a background thread that asks the endpoint what
    window it serves. Left on, a test that points the agent at an example URL
    would make a real request to a real host — slowly, flakily, and only on
    machines with a network.
    """
    from ollama_code import server as server_mod

    monkeypatch.setattr(server_mod.ChatService, "background_probes", False)


@pytest.fixture(scope="session")
def real_app_dir() -> Path:
    """The directory the suite must never touch. For the containment tests."""
    return REAL_APP_DIR


@pytest.fixture
def clearable_sessions(isolated_app_dir) -> Path:
    """For the tests that mass-move every transcript in SESSIONS_DIR.

    ``clear_saved_sessions`` and ``server.sessions_clear()`` are indiscriminate
    by design, so the blast radius is asserted before they are armed.
    """
    assert isolated_app_dir in sessions_mod.SESSIONS_DIR.parents
    return sessions_mod.SESSIONS_DIR


@pytest.fixture(scope="session", autouse=True)
def _session_home_cleanup():
    yield
    shutil.rmtree(_SESSION_HOME, ignore_errors=True)


# --- The tripwire -----------------------------------------------------------
#: Audited events that mutate the filesystem, mapped to the argument indexes
#: that carry a path. "open" is handled separately: only a write-open matters.
_MUTATING_EVENTS: dict[str, tuple[int, ...]] = {
    "os.mkdir": (0,),
    "os.rmdir": (0,),
    "os.remove": (0,),
    "os.truncate": (0,),
    "os.chmod": (0,),
    "os.rename": (0, 1),
    "os.link": (0, 1),
    "os.symlink": (0, 1),
    "shutil.move": (0, 1),
    "shutil.copyfile": (0, 1),
    "shutil.copytree": (0, 1),
    "shutil.rmtree": (0,),
}

_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC


def _install_real_app_dir_tripwire() -> None:
    """Raise at the call site if this process writes into the real agent home.

    ``config.save_config`` catches and drops every ``OSError`` and the session
    writes are fire-and-forget, so a misdirected write is otherwise completely
    invisible — which is how test transcripts accumulated in a real
    ``~/.ollama-code/sessions`` without anyone noticing.

    An mtime snapshot of that directory is the obvious alternative and it is the
    wrong tool: the developer's own Locus is usually running while the suite
    runs, writing its own sessions and config there, so a snapshot fails on
    someone else's work and gets switched off within a week. Every event that is
    not one of the dozen above returns on a single dict lookup.
    """
    exact = str(REAL_APP_DIR)
    # Not a bare prefix: a sibling ~/.ollama-code.backup-* is not the real home.
    inside = exact + os.sep

    def guarded(value: object) -> bool:
        text = str(value or "")
        return text == exact or text.startswith(inside)

    def audit(event: str, args: tuple) -> None:
        if event == "open":
            path, mode, flags = args
            if not guarded(path):
                return
            writing = any(flag in (mode or "") for flag in ("w", "a", "+", "x"))
            if writing or (isinstance(flags, int) and flags & _WRITE_FLAGS):
                raise AssertionError(
                    f"a test opened the real agent home for writing: {path}\n"
                    "Something bypassed the isolated_app_dir fixture."
                )
            return
        indexes = _MUTATING_EVENTS.get(event)
        if indexes is None:
            return
        for index in indexes:
            if index < len(args) and guarded(args[index]):
                raise AssertionError(
                    f"a test mutated the real agent home: {event} {args[index]}"
                )

    sys.addaudithook(audit)


_install_real_app_dir_tripwire()
