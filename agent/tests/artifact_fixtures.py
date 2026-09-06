"""Synthetic edition bundles for filesystem audits; no usable native code."""

import plistlib


def write_info(app, info):
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))


def make_synthetic_app(tmp_path, edition="locus", *, mode="manual", runtime=True):
    name = "Locus" if edition == "locus" else "LocusX"
    app = tmp_path / f"{name}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "MacOS" / name).write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic binary")
    info = {
        "CFBundleName": name,
        "CFBundleExecutable": name,
        "CFBundleIdentifier": f"io.sparktales.{edition}",
        "LocusEdition": edition,
        "LocusUpdateMode": mode,
        "CFBundleURLTypes": [{"CFBundleURLSchemes": [edition]}],
    }
    if mode == "manual":
        (contents / "Frameworks/Sparkle.framework").mkdir(parents=True)
    backend = contents / "Resources/AgentRuntime/source/ollama_code"
    if runtime:
        backend.mkdir(parents=True)
        factory = "    return ProductFeatures(registry)\n"
        if edition == "locusx":
            factory = "    from ._locusx.wallet import WalletFeature\n    return WalletFeature(registry)\n"
        (backend / "product_build.py").write_text(
            "from __future__ import annotations\n"
            "from typing import Any\n"
            "from .product_features import ProductFeatures\n"
            f"PRODUCT_NAME = {name!r}\n"
            f"PRODUCT_BUNDLE_ID = {'io.sparktales.' + edition!r}\n"
            f"PRODUCT_URL_SCHEME = {edition!r}\n"
            "def create_features(registry: Any) -> ProductFeatures:\n" + factory
        )
    if edition == "locusx":
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append("locus-wallet")
        for relative in (
            "XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
            "Helpers/WalletRecovery.app/Contents/MacOS/WalletRecovery",
            "Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
            "Resources/WalletConnections.bundle.js",
        ):
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic wallet component")
        if runtime:
            (backend / "_locusx").mkdir()
            (backend / "_locusx/wallet.py").write_text("class Wallet: pass\n")
    write_info(app, info)
    return app, info
