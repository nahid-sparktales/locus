#!/usr/bin/env python3
"""Bind every configured wallet provider URL to the signed review ceiling."""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

BINDINGS = {
    "LocusWalletAlchemyEthereumMainnetRPCURL": ("alchemy", "eip155:1"),
    "LocusWalletQuickNodeEthereumMainnetRPCURL": ("quicknode", "eip155:1"),
    "LocusWalletAlchemyEthereumSepoliaRPCURL": ("alchemy", "eip155:11155111"),
    "LocusWalletQuickNodeEthereumSepoliaRPCURL": ("quicknode", "eip155:11155111"),
    "LocusWalletAlchemySolanaMainnetRPCURL": ("alchemy", "solana:mainnet-beta"),
    "LocusWalletQuickNodeSolanaMainnetRPCURL": ("quicknode", "solana:mainnet-beta"),
    "LocusWalletAlchemySolanaDevnetRPCURL": ("alchemy", "solana:devnet"),
    "LocusWalletQuickNodeSolanaDevnetRPCURL": ("quicknode", "solana:devnet"),
    "LocusWalletAlchemySuiMainnetGraphQLURL": ("alchemy", "sui:mainnet"),
    "LocusWalletQuickNodeSuiMainnetGraphQLURL": ("quicknode", "sui:mainnet"),
    "LocusWalletAlchemySuiTestnetGraphQLURL": ("alchemy", "sui:testnet"),
    "LocusWalletQuickNodeSuiTestnetGraphQLURL": ("quicknode", "sui:testnet"),
}


def fail(message: str) -> None:
    raise SystemExit(f"wallet provider binding audit failed: {message}")


def configuration_value(info: dict, key: str) -> str:
    value = info.get(key, "")
    return value.strip(" \t\r\n") if isinstance(value, str) else ""


def canonical_https_url(value: str) -> bool:
    if not 1 <= len(value) <= 2048 or any(not 33 <= ord(char) <= 126 for char in value):
        return False
    try:
        parsed = urlsplit(value)
        # Foundation percent-encodes these characters; reject values that would
        # not survive URL.absoluteString unchanged in the Swift runtime.
        return value.startswith("https://") and bool(parsed.hostname) \
            and (parsed.port is None or 1 <= parsed.port <= 65535) \
            and parsed.username is None and parsed.password is None and parsed.fragment == "" \
            and "#" not in value and not any(char in value for char in '\\<>"{}|^`[]') \
            and re.search(r"%(?![0-9A-Fa-f]{2})", value) is None
    except ValueError:
        return False


def metamask_rpc_urls(info: dict, providers: list[dict]) -> dict[str, str]:
    result = {}
    for network, label in (("eip155:1", "EthereumMainnet"), ("eip155:11155111", "EthereumSepolia")):
        for provider, title in (("alchemy", "Alchemy"), ("quicknode", "QuickNode")):
            value = configuration_value(info, f"LocusWallet{title}{label}RPCURL")
            if not canonical_https_url(value):
                continue
            identity = {
                "networkID": network, "provider": provider,
                "configurationID": f"{provider}:{network}",
                "endpointSHA256": hashlib.sha256(value.encode()).hexdigest(),
                "expectedIdentity": {"kind": "eip155_chain_id", "value": network.split(":")[1]},
            }
            if identity not in providers:
                continue
            result[network] = value
            break
    return result


def connector_canonical_bytes(connector: str, info: dict, providers: list[dict]) -> bytes | None:
    payload = {"format": "locus-wallet-connector-config-v1", "connector": connector}
    if connector == "phantom":
        app_id = configuration_value(info, "LocusPhantomAppID")
        redirect = configuration_value(info, "LocusPhantomRedirectURL")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", app_id) or not canonical_https_url(redirect):
            return None
        payload.update({
            "appID": app_id, "redirectURL": redirect, "providers": ["phantom"],
            "addressTypes": ["solana"], "embeddedWalletType": "user-wallet", "autoConnect": True,
        })
    elif connector == "wallet_connect":
        project_id = configuration_value(info, "LocusReownProjectID")
        redirect = configuration_value(info, "LocusWalletConnectRedirectURL")
        if not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", project_id) or redirect != "locus-wallet://walletconnect":
            return None
        payload.update({
            "projectID": project_id, "redirectURL": redirect,
            "mode": "walletconnect-sign", "dappURL": "https://locus.app",
        })
    elif connector == "metamask":
        urls = metamask_rpc_urls(info, providers)
        if not urls:
            return None
        payload.update({
            "rpcURLs": urls, "dappName": "Locus", "dappURL": "https://locus.app",
            "analyticsEnabled": False, "skipAutoAnnounce": True,
        })
    elif connector == "slush":
        payload.update({
            "mode": "wallet-standard", "walletName": "Slush", "dappName": "Locus",
            "origin": "https://my.slush.app",
        })
    elif connector == "embedded_browser":
        payload.update({"mode": "embedded-browser", "signerProtocolVersion": 3})
    else:
        return None
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def verify_connector_bindings(review: dict, info: dict) -> int:
    count = 0
    for entry in review.get("connectors", []):
        canonical = connector_canonical_bytes(entry["connector"], info, review.get("providerIdentities", []))
        if canonical is None or entry.get("configurationSHA256") != hashlib.sha256(canonical).hexdigest():
            fail("a connector has missing, invalid, or unreviewed release configuration")
        count += 1
    return count


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: VerifyWalletProviderBindings.py signed-review.json app-Info.plist")
    document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    review = document["ceiling"]["scope"] if "ceiling" in document else document["manifest"]
    with Path(sys.argv[2]).open("rb") as stream:
        info = plistlib.load(stream)
    reviewed = {
        (item["provider"], item["networkID"], item["configurationID"], item["endpointSHA256"])
        for item in review.get("providerIdentities", [])
    }
    configured = 0
    for plist_key, (provider, network_id) in BINDINGS.items():
        value = configuration_value(info, plist_key)
        if not value:
            continue
        if not canonical_https_url(value):
            fail(f"{plist_key} is not a credential-free HTTPS URL")
        digest = hashlib.sha256(value.encode()).hexdigest()
        configuration_id = f"{provider}:{network_id}"
        if (provider, network_id, configuration_id, digest) not in reviewed:
            fail(f"{plist_key} is absent from the signed review ceiling")
        configured += 1
    if configured == 0:
        fail("no reviewed provider endpoints are configured")
    connector_count = verify_connector_bindings(review, info)
    print(f"Wallet bindings verified: {configured} providers, {connector_count} connectors")


if __name__ == "__main__":
    main()
