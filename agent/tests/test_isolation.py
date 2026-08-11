"""The suite's own containment, asserted rather than assumed.

``save_config`` drops its errors and the session writes are fire-and-forget, so
"the tests passed" has never been evidence that they wrote where they meant to.
These four tests are that evidence.
"""
from __future__ import annotations

from pathlib import Path

from ollama_code import app as app_mod
from ollama_code import config as config_mod
from ollama_code import extensions as extensions_mod
from ollama_code import paths as paths_mod
from ollama_code import sessions as sessions_mod
from ollama_code import transcript_search as transcript_search_mod
from ollama_code.extensions import ExtensionManager
from ollama_code.sessions import SessionStore

_MODULES = (
    paths_mod, config_mod, sessions_mod, extensions_mod, app_mod,
    transcript_search_mod,
)
_IMMUTABLE_BUNDLE_PATHS = {
    (extensions_mod.__name__, "BUILTIN_SKILLS_ROOT"),
}


def test_every_app_dir_constant_points_inside_this_tests_home(
    isolated_app_dir, real_app_dir
):
    """Catches an import-time constant nobody added to the fixture's list.

    Every writable ``Path`` constant in these modules is derived from ``APP_DIR``,
    so all of them must sit under *this test's* directory. Immutable paths into
    bundled application resources are explicitly exempt. Asserting only "not the
    real home" would not be enough: layer 1 already relocates a forgotten
    constant to the session-wide temp home, so a missing entry in the fixture's
    list leaks state between tests while still passing that weaker check.
    """
    stale, escaped = [], []
    for module in _MODULES:
        for name, value in vars(module).items():
            if not isinstance(value, Path):
                continue
            if (module.__name__, name) in _IMMUTABLE_BUNDLE_PATHS:
                continue
            where = f"{module.__name__}.{name} = {value}"
            if value == real_app_dir or real_app_dir in value.parents:
                escaped.append(where)
            elif isolated_app_dir not in (value, *value.parents):
                stale.append(where)
    assert not escaped, (
        "pointing at the developer's real agent home — ollama_code was imported "
        "before conftest set OLLAMA_CODE_HOME: " + ", ".join(escaped)
    )
    assert not stale, (
        "outside this test's home, so it is shared with every other test — add "
        "it to _APP_DIR_CONSTANTS in conftest.py: " + ", ".join(stale)
    )


def test_config_writes_land_inside_the_isolated_home(isolated_app_dir):
    """save_config swallows OSError, so prove the write rather than the call."""
    config_mod.save_config({"model": "sentinel"})
    assert (isolated_app_dir / "config.json").exists()
    assert config_mod.load_config()["model"] == "sentinel"


def test_a_new_transcript_lands_inside_the_isolated_home(isolated_app_dir, tmp_path):
    store = SessionStore(str(tmp_path))
    store.append({"type": "message", "message": {"role": "user", "content": "hi"}})
    assert isolated_app_dir in store.path.parents


def test_an_extension_manager_defaults_inside_the_isolated_home(isolated_app_dir, tmp_path):
    assert ExtensionManager(str(tmp_path)).root == isolated_app_dir / "extensions"
