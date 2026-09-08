"""Release configuration, feed isolation and publication gates, all offline."""

import base64
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from artifact_fixtures import make_synthetic_app, write_info

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import AuditAppEdition as audit  # noqa: E402
import LocusUpdateFeed as feed  # noqa: E402


def release_info(**changes):
    info = plistlib.loads((ROOT / "Config/LocusRelease-Info.plist").read_bytes())
    info.update(
        CFBundleName="Locus", CFBundleExecutable="Locus", CFBundleIdentifier="io.sparktales.locus",
        CFBundleShortVersionString="2.7.0", CFBundleVersion="27",
    )
    info.update(changes)
    return info


def appcast(tmp_path, builds=(27,), **enclosure_changes):
    root = ET.Element("rss")
    channel = ET.SubElement(root, "channel")
    for build in builds:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, f"{{{feed.SPARKLE}}}version").text = str(build)
        ET.SubElement(item, f"{{{feed.SPARKLE}}}shortVersionString").text = f"2.{build - 20}.0"
        attributes = {
            "url": f"{feed.RELEASE_ROOT}/v2.{build - 20}.0/Locus-macOS.zip", "length": "123",
            f"{{{feed.SPARKLE}}}edSignature": base64.b64encode(b"x" * 64).decode(),
        }
        attributes.update(enclosure_changes)
        ET.SubElement(item, "enclosure", attributes)
    path = tmp_path / "appcast-locus.xml"
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    return path


def test_release_plist_changes_only_the_explicit_update_configuration():
    development = plistlib.loads((ROOT / "Locus/Info.plist").read_bytes())
    release = plistlib.loads((ROOT / "Config/LocusRelease-Info.plist").read_bytes())
    assert release.pop("SUFeedURL") == feed.FEED_URL
    assert release["LocusUpdateMode"] == "automatic"
    release["LocusUpdateMode"] = "manual"
    for key in ("SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks"):
        assert release[key] is True
        release[key] = False
    assert release == development
    for name in ("LocusX", "LocusExperimental"):
        info = plistlib.loads((ROOT / f"Config/{name}-Info.plist").read_bytes())
        assert info["LocusUpdateMode"] == "manual"
        assert "SUFeedURL" not in info
    mas = plistlib.loads((ROOT / "Config/LocusMAS-Info.plist").read_bytes())
    assert mas["LocusUpdateMode"] == "appStore"
    assert not any(key.startswith("SU") for key in mas)


def test_release_plan_uses_only_the_new_feed_and_pinned_zip():
    result = feed.plan(release_info())
    assert result["feedURL"] == feed.FEED_URL
    assert result["archiveURL"] == f"{feed.RELEASE_ROOT}/v2.7.0/Locus-macOS.zip"
    assert result["candidate"] is False


@pytest.mark.parametrize("field,value", [
    ("LocusEdition", "locusx"), ("CFBundleIdentifier", "io.sparktales.locusx"),
    ("CFBundleName", "LocusX"), ("CFBundleExecutable", "LocusX"),
    ("LocusUpdateMode", "manual"), ("LocusUpdateMode", "appStore"),
    ("SUFeedURL", feed.FEED_URL.replace("appcast-locus.xml", "appcast.xml")),
    ("SUFeedURL", "https://example.invalid/appcast-locus.xml"),
    ("SUFeedURL", ""), ("SUPublicEDKey", "unknown"),
    ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
    ("SUAutomaticallyUpdate", "true"), ("SUEnableSystemProfiling", True),
    ("SUScheduledCheckInterval", 60), ("LocusWalletCandidateArchiveURL", "https://example.invalid/candidate.zip"),
])
def test_automatic_artifact_rejects_wrong_identity_routing_and_security(tmp_path, monkeypatch, field, value):
    app, _ = make_synthetic_app(tmp_path)
    write_info(app, release_info(**{field: value}))
    monkeypatch.setattr(audit, "inspect_output", lambda _: "_main\n")
    with pytest.raises((audit.AuditError, ValueError)):
        audit.audit(app, "locus")


def test_audit_accepts_automatic_locus_before_a_release_version_bump(tmp_path, monkeypatch):
    app, _ = make_synthetic_app(tmp_path)
    info = release_info(CFBundleVersion="26", CFBundleShortVersionString="2.6.0")
    write_info(app, info)
    monkeypatch.setattr(audit, "inspect_output", lambda _: "_main\n")
    assert audit.audit(app, "locus")["passed"]
    with pytest.raises(ValueError, match="exceed build 26"):
        feed.plan(info)


@pytest.mark.parametrize("build", ["", "26", "24", "-1", "27.1", "not-a-build"])
def test_only_new_numeric_builds_are_publishable(build):
    with pytest.raises(ValueError):
        feed.plan(release_info(CFBundleVersion=build))


def test_feed_preserves_separate_history_and_matches_the_packaged_app(tmp_path):
    path = appcast(tmp_path, (29, 28, 27))
    expected = feed.plan(release_info(CFBundleVersion="29", CFBundleShortVersionString="2.9.0"))
    feed.verify_feed(path, expected=expected)
    feed.verify_feed(path, newer_build=30)
    with pytest.raises(ValueError, match="packaged release"):
        feed.verify_feed(path, expected=feed.plan(release_info()))


def test_build_must_exceed_every_entry_even_when_history_is_unordered(tmp_path):
    path = appcast(tmp_path, (27, 30, 28))
    with pytest.raises(ValueError, match="every published build"):
        feed.verify_feed(path, newer_build=29)


@pytest.mark.parametrize("builds", [(27, 27), (26,), ()])
def test_feed_rejects_duplicates_manual_history_and_empty_history(tmp_path, builds):
    with pytest.raises(ValueError):
        feed.verify_feed(appcast(tmp_path, builds))


@pytest.mark.parametrize("changes", [
    {"url": feed.FEED_URL},
    {"url": f"{feed.RELEASE_ROOT}/v2.8.0/Locus-macOS.zip"},
    {"url": f"{feed.RELEASE_ROOT}/v2.7.0/LocusX-macOS.zip"},
    {"url": f"{feed.RELEASE_ROOT}/v2.7.0/Locus-macOS.zip?latest=1"},
    {"url": "https://github.com/nahid-sparktales/locus/releases/latest/download/Locus-macOS.zip"},
    {"length": "0"}, {f"{{{feed.SPARKLE}}}edSignature": ""},
    {f"{{{feed.SPARKLE}}}edSignature": "garbage"},
])
def test_feed_rejects_unpinned_archives_and_missing_signatures(tmp_path, changes):
    with pytest.raises(ValueError):
        feed.verify_feed(appcast(tmp_path, **changes))


@pytest.mark.parametrize("mutation", ["channel", "extra_archive", "extra_item", "dtd", "invalid_xml"])
def test_feed_rejects_wallet_channels_and_ambiguous_xml(tmp_path, mutation):
    path = appcast(tmp_path)
    root = ET.parse(path).getroot()
    if mutation == "channel":
        ET.SubElement(root.find("channel/item"), f"{{{feed.SPARKLE}}}channel").text = "canary"
    elif mutation == "extra_archive":
        ET.SubElement(root, "enclosure", {"url": "https://example.invalid/unverified.zip"})
    elif mutation == "extra_item":
        ET.SubElement(root, "item")
    ET.ElementTree(root).write(path)
    if mutation == "dtd":
        path.write_bytes(b'<!DOCTYPE rss [<!ENTITY injected "update">]>' + path.read_bytes())
    elif mutation == "invalid_xml":
        path.write_bytes(b"<rss>")
    with pytest.raises((ValueError, ET.ParseError)):
        feed.verify_feed(path)


@pytest.mark.parametrize("status,initial", [("404", ""), ("404", "canary"), ("500", "locus"), ("000", "locus"), ("403", "locus")])
def test_first_feed_requires_explicit_initialization_and_a_real_404(status, initial):
    with pytest.raises(ValueError, match="initialization requires"):
        feed.history_action(status, initial)


def test_existing_feed_must_be_verified_even_during_initialization():
    assert feed.history_action("404", "locus") == "initialize"
    assert feed.history_action("200", "locus") == "verify"
    assert feed.history_action("200", "") == "verify"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS release scripts")
@pytest.mark.parametrize("channel,filename", [("locus", "appcast.xml"), ("stable", "appcast-locus.xml"), ("canary", "appcast-locus.xml")])
def test_generator_rejects_cross_feed_outputs_before_using_signing_keys(tmp_path, channel, filename):
    result = subprocess.run(
        ["zsh", str(ROOT / "Tools/GenerateAppcast.sh"), str(tmp_path / "Locus-macOS.zip"), str(tmp_path / filename), channel],
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "feed output must be named" in result.stderr
    assert not (tmp_path / filename).exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS release scripts")
def test_generator_requires_component_assets_before_using_signing_keys(tmp_path):
    (tmp_path / "Locus-macOS.zip").touch()
    result = subprocess.run(
        ["zsh", str(ROOT / "Tools/GenerateAppcast.sh"), str(tmp_path / "Locus-macOS.zip"), str(tmp_path / "appcast-locus.xml"), "locus"],
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "without the component assets" in result.stderr


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS release scripts")
@pytest.mark.parametrize("changes,expected", [
    ({"CFBundleVersion": "26"}, "exceed build 26"),
    ({"SUFeedURL": feed.FEED_URL.replace("appcast-locus", "appcast")}, "separate appcast-locus.xml"),
    ({"SUPublicEDKey": "wrong"}, "public key"),
    ({}, "cannot preserve legacy appcast"),
])
def test_automatic_public_packaging_rejects_invalid_staging_before_mutating_app(tmp_path, changes, expected):
    app, _ = make_synthetic_app(tmp_path)
    write_info(app, release_info(**changes))
    plist = app / "Contents/Info.plist"
    original = plist.read_bytes()
    result = subprocess.run(
        ["zsh", str(ROOT / "Tools/PackageRelease.sh"), str(app), str(tmp_path / "Locus-macOS.zip")],
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LOCUS_NOTARIZE": "1"},
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert expected in result.stderr
    assert plist.read_bytes() == original
    assert not (tmp_path / "Locus-macOS.zip").exists()
