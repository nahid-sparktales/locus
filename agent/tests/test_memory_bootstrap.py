"""Installed hosts select package memory automatically for a new local profile."""
from __future__ import annotations

from types import SimpleNamespace

import pytest
from locus_memory.compat.legacy_vault import LegacyMemoryVault
from locus_memory.context import CONTEXT_WRAPPER_OPEN
from locus_memory.models import Actor
from locus_memory.policies import MemoryPolicy

from ollama_code import paths
from ollama_code.memory import MemoryError, MemoryVault, _master_key
from ollama_code.memory_adapter import LegacyRecall, MemoryAdapter
from ollama_code.memory_canonical import CanonicalMemoryVault
from ollama_code.memory_ownership import ownership_state


def test_first_memory_api_call_uses_canonical_package_and_requires_approval():
    with MemoryVault(workspace="/trusted/project") as user:
        assert isinstance(user, CanonicalMemoryVault)
        with MemoryVault(workspace="/trusted/project", actor=Actor.AGENT,
                         scopes=("workspace",)) as agent:
            item = agent.save({"content": "The deployment color is violet.", "scope": "workspace",
                               "status": "candidate"})
            assert agent.search("violet") == []
            with pytest.raises(MemoryError):
                agent.approve(item["id"])
            assert user.approve(item["id"])["status"] == "approved"
            assert agent.search("violet")[0]["id"] == item["id"]
        assert user.list(scopes=[]) == []
    assert ownership_state(paths.APP_DIR, "locus") == "package_authoritative"
    assert not (paths.APP_DIR / "memory" / "memory.sqlite3").exists()


@pytest.mark.parametrize("requested", [None, "disabled", "shadow", "enabled"])
def test_first_runtime_automatically_enables_package_recall(requested):
    env = {} if requested is None else {"LOCUS_MEMORY_ENGINE_MODE": requested}
    adapter = MemoryAdapter.from_environment(app_dir=paths.APP_DIR, edition="Locus", environ=env,
                                             hold_profile_lease=True)
    try:
        assert adapter.mode == "enabled"
        assert adapter.archive is False
        with MemoryVault(workspace="/trusted/project") as user:
            user.save({"content": "Deploy using the violet command.", "scope": "workspace"})
        core = SimpleNamespace(workspace_root="/trusted/project", cwd="/trusted/project", identity_mode=False)
        text = adapter.recall(core, "violet", MemoryPolicy(), just_chat=False,
                              agent_id="primary", legacy=lambda: LegacyRecall("must not use legacy"))
        assert CONTEXT_WRAPPER_OPEN in text and "violet command" in text
        assert "must not use legacy" not in text
        assert adapter.recall(core, "violet", MemoryPolicy(recall_enabled=False), just_chat=False,
                              agent_id="primary", legacy=lambda: LegacyRecall("")) == ""
        assert adapter.recall(core, "violet", MemoryPolicy(), just_chat=True,
                              agent_id="primary", legacy=lambda: LegacyRecall("")) == ""
        second = MemoryAdapter.from_environment(app_dir=paths.APP_DIR, edition="Locus", environ={},
                                                hold_profile_lease=True)
        second.close()  # A second active service reuses the published profile.
    finally:
        adapter.close()


def test_existing_legacy_profile_keeps_its_store_and_rollout():
    database = paths.APP_DIR / "memory" / "memory.sqlite3"
    key = _master_key(vault_path=database)
    legacy = LegacyMemoryVault(database, key=key)
    item = legacy.save({"content": "Keep the existing amber record.", "scope": "personal"})
    adapter = MemoryAdapter.from_environment(app_dir=paths.APP_DIR, edition="Locus", environ={})
    try:
        assert adapter.mode == "disabled"
        assert not (paths.APP_DIR / "memory-engine").exists()
        vault = MemoryVault()
        assert isinstance(vault, LegacyMemoryVault)
        assert vault.list()[0]["id"] == item["id"]
    finally:
        adapter.close()


def test_missing_key_for_initialized_profile_is_never_replaced():
    with MemoryVault() as vault:
        vault.save({"content": "Preserve this encrypted amber value.", "scope": "personal"})
    key_path = paths.APP_DIR / "memory" / "master.key"
    key_path.unlink()
    with MemoryVault() as vault:
        with pytest.raises(MemoryError):
            vault.list()
    assert not key_path.exists()


def test_missing_master_key_with_enrolled_guard_never_creates_identity(isolated_app_dir):
    import pytest

    from ollama_code.memory import MemoryError, _master_key
    guard = isolated_app_dir / 'memory-guard'
    guard.mkdir(parents=True)
    (guard / 'enrolled.json').write_text('{}')
    key = isolated_app_dir / 'memory' / 'master.key'
    with pytest.raises(MemoryError, match='missing'):
        _master_key(fallback_path=key, vault_path=key.parent / 'memory.sqlite3')
    assert not key.exists()
