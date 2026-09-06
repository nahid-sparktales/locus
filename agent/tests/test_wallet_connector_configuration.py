"""Public synthetic vectors; never read a user's connector configuration."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("wallet_bindings", ROOT / "Tools/VerifyWalletProviderBindings.py")
bindings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bindings)


@pytest.fixture
def fixture():
    return json.loads((ROOT / "ProtocolFixtures/wallet-connector-configuration-v1.json").read_text())


def test_all_connector_bytes_and_digests_match_shared_swift_vectors(fixture):
    for vector in fixture["vectors"]:
        data = bindings.connector_canonical_bytes(vector["connector"], fixture["info"], fixture["providerIdentities"])
        assert data == vector["canonicalJSON"].encode("ascii")
        assert hashlib.sha256(data).hexdigest() == vector["configurationSHA256"]
    review = {"connectors": fixture["vectors"], "providerIdentities": fixture["providerIdentities"]}
    assert bindings.verify_connector_bindings(review, fixture["info"]) == 5


@pytest.mark.parametrize("connector,key", [
    ("phantom", "LocusPhantomAppID"), ("phantom", "LocusPhantomRedirectURL"),
    ("wallet_connect", "LocusReownProjectID"), ("wallet_connect", "LocusWalletConnectRedirectURL"),
    ("metamask", "LocusWalletAlchemyEthereumMainnetRPCURL"),
])
def test_changed_configuration_is_not_covered_by_a_reviewed_digest(fixture, connector, key):
    info = copy.deepcopy(fixture["info"])
    info[key] += "changed"
    review = {"connectors": [next(row for row in fixture["vectors"] if row["connector"] == connector)],
              "providerIdentities": fixture["providerIdentities"]}
    with pytest.raises(SystemExit, match="unreviewed release configuration"):
        bindings.verify_connector_bindings(review, info)


@pytest.mark.parametrize("digest", [None, "", "A" * 64, "0" * 64])
def test_missing_or_incorrect_configuration_digest_fails_closed(fixture, digest):
    row = copy.deepcopy(fixture["vectors"][2])
    row["configurationSHA256"] = digest
    with pytest.raises(SystemExit, match="release configuration"):
        bindings.verify_connector_bindings({"connectors": [row]}, fixture["info"])


@pytest.mark.parametrize("url", [
    "http://wallet.example/callback", "https://user:pass@wallet.example/", "https://wallet.example/#",
    "https://wallet.example/#fragment", "https://wallet.example/has space", "https://wallet.example/%GG",
    "https://wallet.example/é", "https://wallet.example/[raw]", "https://wallet.example/" + "x" * 2048,
    "https://wallet.example:abc/", "https://wallet.example:65536/", "https://wallet.example:0/",
    "\x1chttps://wallet.example/", "\u00a0https://wallet.example/",
])
def test_noncanonical_or_unsafe_redirect_is_rejected(fixture, url):
    fixture["info"]["LocusPhantomRedirectURL"] = url
    assert bindings.connector_canonical_bytes("phantom", fixture["info"], []) is None


def test_metamask_prefers_reviewed_primary_and_does_not_include_unreviewed_networks(fixture):
    assert bindings.metamask_rpc_urls(fixture["info"], fixture["providerIdentities"]) == {
        "eip155:1": fixture["info"]["LocusWalletAlchemyEthereumMainnetRPCURL"],
        "eip155:11155111": fixture["info"]["LocusWalletQuickNodeEthereumSepoliaRPCURL"],
    }
    fallback_only = [row for row in fixture["providerIdentities"] if row["provider"] == "quicknode"]
    assert bindings.metamask_rpc_urls(fixture["info"], fallback_only)["eip155:1"] \
        == fixture["info"]["LocusWalletQuickNodeEthereumMainnetRPCURL"]
    assert bindings.connector_canonical_bytes("metamask", fixture["info"], []) is None
    mismatched = copy.deepcopy(fixture["providerIdentities"])
    for row in mismatched:
        row["expectedIdentity"]["value"] = "0"
    assert bindings.metamask_rpc_urls(fixture["info"], mismatched) == {}


def test_mapping_order_and_unused_fields_do_not_change_configuration(fixture):
    info = dict(reversed(list(fixture["info"].items())))
    info["UnrelatedAppSetting"] = "not part of connector authority"
    for vector in fixture["vectors"]:
        assert bindings.connector_canonical_bytes(vector["connector"], info, list(reversed(fixture["providerIdentities"]))) \
            == vector["canonicalJSON"].encode()


def test_ascii_padding_is_identical_to_runtime_input_normalization(fixture):
    padded = {key: " \t\r\n" + value + " \t\r\n" for key, value in fixture["info"].items()}
    for vector in fixture["vectors"]:
        assert bindings.connector_canonical_bytes(vector["connector"], padded, fixture["providerIdentities"]) \
            == vector["canonicalJSON"].encode()
