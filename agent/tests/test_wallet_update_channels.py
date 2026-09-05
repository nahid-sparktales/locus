"""Offline update-channel contracts; no Keychain, network, or publication."""

import copy
import importlib.util
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "wallet_update_channel", ROOT / "Tools/WalletUpdateChannel.py"
)
channel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(channel)


@pytest.fixture
def sealed_info():
    return {
        "CFBundleVersion": "24",
        "CFBundleShortVersionString": "2.4.0",
        "SUFeedURL": channel.STABLE_FEED,
        "LocusCanaryUpdateFeedURL": "https://updates.example.invalid/canary/appcast.xml",
        "LocusWalletCandidateArchiveURL": "https://updates.example.invalid/candidate-24/Locus-macOS.zip",
    }


def test_same_sealed_archive_can_be_promoted_without_changing_its_feed_configuration(sealed_info):
    original = copy.deepcopy(sealed_info)
    canary, stable = [
        channel.plan(sealed_info, value, require_candidate=True) for value in ["canary", "stable"]
    ]
    assert canary["feedURL"] != stable["feedURL"]
    assert canary["archiveURL"] == stable["archiveURL"]
    assert sealed_info == original


@pytest.mark.parametrize(
    "field,value",
    [
        ("LocusCanaryUpdateFeedURL", channel.STABLE_FEED),
        (
            "LocusCanaryUpdateFeedURL",
            "https://example.invalid/releases/latest/download/appcast.xml",
        ),
        ("LocusCanaryUpdateFeedURL", ""),
        ("LocusWalletCandidateArchiveURL", ""),
        ("LocusWalletCandidateArchiveURL", "http://example.invalid/Locus-macOS.zip"),
        ("LocusWalletCandidateArchiveURL", "https://user:secret@example.invalid/Locus-macOS.zip"),
        ("LocusWalletCandidateArchiveURL", "https://example.invalid/Locus-macOS.zip?token=private"),
        ("LocusWalletCandidateArchiveURL", "https://example.invalid/latest/Locus-macOS.zip"),
        ("SUFeedURL", "https://example.invalid/unreviewed/appcast.xml"),
    ],
)
def test_invalid_sealed_channel_configuration_is_fail_closed(sealed_info, field, value):
    sealed_info[field] = value
    with pytest.raises(ValueError):
        channel.plan(sealed_info, "canary", require_candidate=True)


def test_legacy_builds_have_only_explicit_stable_updates(sealed_info):
    del sealed_info["LocusCanaryUpdateFeedURL"], sealed_info["LocusWalletCandidateArchiveURL"]
    assert (
        channel.plan(sealed_info, "stable")["archiveURL"]
        == f"{channel.RELEASE_ROOT}/v2.4.0/Locus-macOS.zip"
    )
    with pytest.raises(ValueError):
        channel.plan(sealed_info, "canary")
    with pytest.raises(ValueError):
        channel.plan(sealed_info, "stable", require_candidate=True)


def _feed(path, info, labels):
    label_xml = "".join(f"<sparkle:channel>{label}</sparkle:channel>" for label in labels)
    path.write_text(f'''<rss xmlns:sparkle="{channel.SPARKLE}"><channel><item>
        <sparkle:version>24</sparkle:version><sparkle:shortVersionString>2.4.0</sparkle:shortVersionString>
        {label_xml}<enclosure url="{info["LocusWalletCandidateArchiveURL"]}"/>
        </item></channel></rss>''')
    return path


@pytest.mark.parametrize(
    "target,labels",
    [
        ("canary", []),
        ("stable", ["canary"]),
        ("canary", ["beta"]),
        ("canary", ["canary", "canary"]),
    ],
)
def test_feed_rejects_other_or_ambiguous_channels(tmp_path, sealed_info, target, labels):
    with pytest.raises(ValueError, match="another update channel"):
        channel.verify_feed(_feed(tmp_path / "appcast.xml", sealed_info, labels), target)


@pytest.mark.parametrize("target", ["canary", "stable"])
def test_channel_feed_references_same_exact_archive(tmp_path, sealed_info, target):
    path = _feed(tmp_path / "appcast.xml", sealed_info, ["canary"] if target == "canary" else [])
    channel.verify_feed(path, target, expected=channel.plan(sealed_info, target))
    changed = copy.deepcopy(sealed_info)
    changed["LocusWalletCandidateArchiveURL"] = "https://example.invalid/repacked/Locus-macOS.zip"
    with pytest.raises(ValueError, match="exact sealed candidate"):
        channel.verify_feed(path, target, expected=channel.plan(changed, target))


def test_feed_rejects_xml_entity_expansion(tmp_path):
    path = tmp_path / "bad.xml"
    path.write_text('<!DOCTYPE rss [<!ENTITY x "bad">]><rss/>')
    with pytest.raises(ValueError, match="declarations"):
        channel.verify_feed(path, "canary")


@pytest.mark.parametrize("argument", [None, "ga", "", "beta"])
def test_generator_requires_channel_before_accessing_any_release_key(tmp_path, argument):
    archive = tmp_path / "Locus-macOS.zip"
    output = tmp_path / "appcast.xml"
    archive.write_bytes(b"not-an-app")
    arguments = ["zsh", str(ROOT / "Tools/GenerateAppcast.sh"), str(archive), str(output)]
    if argument is not None:
        arguments.append(argument)
    result = subprocess.run(
        arguments, capture_output=True, timeout=5, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    )
    assert result.returncode != 0
    assert b"channel" in result.stderr
    assert not output.exists()
