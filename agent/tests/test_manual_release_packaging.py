"""Manual public packaging keeps old installs on immutable legacy releases."""

import hashlib
import importlib.util
import plistlib
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("legacy_appcast", ROOT / "Tools/VerifyLegacyAppcast.py")
legacy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(legacy)


def info(**changes):
    return {
        "LocusEdition": "locus", "LocusUpdateMode": "manual",
        "CFBundleIdentifier": "io.sparktales.locus",
        "CFBundleShortVersionString": "2.5.0", "CFBundleVersion": "25", **changes,
    }


def feed(version="2.4.0", build="24", url=None):
    url = url or f"{legacy.RELEASE_ROOT}/v{version}/Locus-macOS.zip"
    return (
        f'<rss xmlns:sparkle="{legacy.SPARKLE}"><channel><item>'
        f'<sparkle:version>{build}</sparkle:version>'
        f'<sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
        f'<enclosure url="{url}" sparkle:edSignature="fixture"/>'
        '</item></channel></rss>'
    ).encode()


def test_legacy_feed_accepts_only_old_version_pinned_entries():
    legacy.validate(feed(), info())


@pytest.mark.parametrize("url", [
    "https://github.com/nahid-sparktales/locus/releases/latest/download/Locus-macOS.zip",
    f"{legacy.RELEASE_ROOT}/v2.5.0/Locus-macOS.zip",
    f"{legacy.RELEASE_ROOT}/v2.4.0/Locus-macOS.zip?latest=1",
    "https://example.invalid/v2.4.0/Locus-macOS.zip",
    f"{legacy.RELEASE_ROOT}/v2.4.0/delta.zip",
])
def test_legacy_feed_rejects_moving_cross_version_and_foreign_archives(url):
    with pytest.raises(ValueError, match="version-pinned"):
        legacy.validate(feed(url=url), info())


@pytest.mark.parametrize("version,build", [("2.5.0", "24"), ("2.6.0", "24"), ("2.4.0", "25")])
def test_legacy_feed_cannot_offer_the_new_manual_build(version, build):
    with pytest.raises(ValueError, match="only prior"):
        legacy.validate(feed(version, build), info())


@pytest.mark.parametrize("changes", [
    {"LocusEdition": "locusx"}, {"LocusUpdateMode": "automatic"},
    {"CFBundleIdentifier": "io.sparktales.locusx"},
])
def test_legacy_feed_preservation_cannot_publish_another_edition(changes):
    with pytest.raises(ValueError, match="wallet-free manual Locus"):
        legacy.validate(feed(), info(**changes))


def test_legacy_feed_rejects_unvalidated_enclosures_and_empty_feed():
    with pytest.raises(ValueError, match="outside"):
        legacy.validate(feed().replace(b"</rss>", b'<enclosure url="bad"/></rss>'), info())
    with pytest.raises(ValueError, match="no previous releases"):
        legacy.validate(b"<rss><channel/></rss>", info())


@pytest.fixture
def verifier(tmp_path, monkeypatch):
    tools = tmp_path / "sparkle"
    (tools / "bin").mkdir(parents=True)
    for name in ("generate_keys", "sign_update"):
        (tools / "bin" / name).touch()
    path = tmp_path / "appcast.xml"
    path.write_bytes(feed())
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(stdout=legacy.PUBLIC_KEY + "\n")

    monkeypatch.setattr(legacy.subprocess, "run", run)
    return path, tools, calls


def test_verification_checks_key_and_signed_original_without_rewriting(verifier):
    path, tools, calls = verifier
    original = path.read_bytes()
    assert legacy.verify(path, info(), tools) == hashlib.sha256(original).hexdigest()
    assert path.read_bytes() == original
    assert calls == [
        [str(tools / "bin/generate_keys"), "--account", "io.sparktales", "-p"],
        [str(tools / "bin/sign_update"), "--account", "io.sparktales", "--verify", str(path)],
    ]


def test_verification_rejects_invalid_signature(verifier, monkeypatch):
    path, tools, _ = verifier

    def run(command, **kwargs):
        if "--verify" in command:
            raise subprocess.CalledProcessError(1, command)
        return SimpleNamespace(stdout=legacy.PUBLIC_KEY)

    monkeypatch.setattr(legacy.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError):
        legacy.verify(path, info(), tools)


def test_verification_rejects_another_key(verifier, monkeypatch):
    path, tools, _ = verifier
    monkeypatch.setattr(legacy.subprocess, "run", lambda *a, **k: SimpleNamespace(stdout="wrong"))
    with pytest.raises(ValueError, match="public key"):
        legacy.verify(path, info(), tools)


def test_verification_detects_concurrent_feed_changes(verifier, monkeypatch):
    path, tools, _ = verifier

    def run(command, **kwargs):
        if "--verify" in command:
            path.write_bytes(feed(version="2.3.0", build="23"))
        return SimpleNamespace(stdout=legacy.PUBLIC_KEY)

    monkeypatch.setattr(legacy.subprocess, "run", run)
    with pytest.raises(ValueError, match="changed during"):
        legacy.verify(path, info(), tools)


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS packaging tools")
@pytest.mark.parametrize("edition,opt_in,notarize,wallet,expected", [
    ("locus", "0", "1", "disabled", "separate release/feed setup"),
    ("locusx", "1", "1", "disabled", "wallet-free manual Locus"),
    ("locus", "1", "0", "disabled", "wallet-free manual Locus"),
    ("locus", "1", "1", "canary", "wallet-free manual Locus"),
    ("locus", "1", "1", "disabled", "cannot preserve legacy appcast"),
])
def test_packaging_fails_before_mutation_without_required_public_boundary(
    tmp_path, edition, opt_in, notarize, wallet, expected,
):
    app = tmp_path / "Locus.app"
    (app / "Contents").mkdir(parents=True)
    plist = app / "Contents/Info.plist"
    original = plistlib.dumps(info(LocusEdition=edition))
    plist.write_bytes(original)
    result = subprocess.run(
        ["zsh", str(ROOT / "Tools/PackageRelease.sh"), str(app), str(tmp_path / "Locus-macOS.zip")],
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LOCUS_PUBLIC_MANUAL_RELEASE": opt_in,
            "LOCUS_NOTARIZE": notarize, "LOCUS_WALLET_RELEASE_CHANNEL": wallet,
        },
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert expected in result.stderr
    assert plist.read_bytes() == original
    assert not (tmp_path / "Locus-macOS.zip").exists()
