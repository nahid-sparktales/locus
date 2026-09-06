#!/usr/bin/env python3
"""Verify the edition of a built app, independently of signing/distribution."""
from __future__ import annotations

import argparse
import ast
import json
import plistlib
import re
import subprocess
from pathlib import Path


class AuditError(RuntimeError):
    pass


WALLET_CODE = re.compile(
    r"WalletGateway|WalletSigner|WalletConnect|DirectWallet|WalletRecovery|"
    r"WalletPublicStore|WalletProviderCoordinator|WalletDapp|WalletCandidateUpdate|"
    r"walletProviderScript|locus_wallet_|locus-wallet|locusWallet|LocusWallet|LOCUS_WALLET|"
    r"LOCUS_ENABLE_EXPERIMENTAL_WALLET|WALLET_TOOL_SCHEMAS|"
    r"set_wallet_control|wallet_action_(?:request|result)|"
    r"wallet_(?:list_accounts|get_balance|get_activity|prepare_transaction|"
    r"simulate_transaction|execute_transaction|lock)"
)
WALLET_FILES = re.compile(
    r"Wallet(?:Signer|Recovery|Connections|FuzzHost)|LocusReownSwift|ReownSwift|"
    r"phantom-wallet-sdk|^_locusx$|wallet.*(?:activation|authority|admission|ceiling)",
    re.IGNORECASE,
)
MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def read_plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise AuditError(f"Cannot inspect {path}: {exc}") from exc


def inspect_output(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, errors="replace", check=False)
    require(result.returncode == 0, f"Inspection failed: {command[0]} {command[-1]}")
    return result.stdout


def audit_backend_factory(path: Path, edition: str) -> None:
    """Validate the staged factory as data; never import app-owned Python."""
    name = "Locus" if edition == "locus" else "LocusX"
    factory = "    return ProductFeatures(registry)\n"
    if edition == "locusx":
        factory = (
            "    from ._locusx.wallet import WalletFeature\n"
            "    return WalletFeature(registry)\n"
        )
    # StageBackendEdition.py emits this fixed module. Comparing its AST permits
    # comments/docstring/formatting changes, but no alternate imports, rebinding,
    # environment-based selection, or extra executable statements.
    expected = ast.parse(
        "from __future__ import annotations\n"
        "from typing import Any\n"
        "from .product_features import ProductFeatures\n"
        f"PRODUCT_NAME = {name!r}\n"
        f"PRODUCT_BUNDLE_ID = {'io.sparktales.' + edition!r}\n"
        f"PRODUCT_URL_SCHEME = {edition!r}\n"
        "def create_features(registry: Any) -> ProductFeatures:\n" + factory
    )
    try:
        actual = ast.parse(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise AuditError(f"Cannot parse sealed backend factory: {path}") from exc
    if (actual.body and isinstance(actual.body[0], ast.Expr)
            and isinstance(actual.body[0].value, ast.Constant)
            and isinstance(actual.body[0].value.value, str)):
        actual.body.pop(0)
    require(ast.dump(actual) == ast.dump(expected),
            "Sealed backend identity or feature factory does not match app edition")


def audit(app: Path, edition: str, allow_missing_runtime: bool = False) -> dict:
    require(app.is_dir(), "App bundle is missing")
    contents = app / "Contents"
    info = read_plist(contents / "Info.plist")
    require(info.get("LocusEdition") == edition, "App edition metadata does not match requested edition")
    require(info.get("CFBundleIdentifier") == f"io.sparktales.{edition}", "Unexpected app bundle identity")
    expected_name = "Locus" if edition == "locus" else "LocusX"
    allowed_names = {expected_name} if edition == "locus" else {expected_name, "LocusX Experimental"}
    require(info.get("CFBundleName") in allowed_names, "Unexpected product name")
    executable = contents / "MacOS" / info.get("CFBundleExecutable", "")
    require(executable.is_file(), "Main executable is missing")
    schemes = {
        scheme for item in info.get("CFBundleURLTypes", [])
        for scheme in item.get("CFBundleURLSchemes", [])
    }
    require(edition in schemes, "MCP callback scheme is missing")
    require(({"locus", "locusx"} - {edition}).isdisjoint(schemes), "Other edition's callback is registered")
    mode = info.get("LocusUpdateMode")
    require(mode in {"manual", "appStore"}, "Local artifact must use manual or App Store updates")
    require("SUFeedURL" not in info, "Local artifact still registers an app update feed")
    sparkle = contents / "Frameworks/Sparkle.framework"
    require(sparkle.is_dir() == (mode == "manual"), "Sparkle does not match distribution")
    runtime = contents / "Resources/AgentRuntime/source/ollama_code"
    require(allow_missing_runtime or runtime.is_dir(), "Bundled backend source is missing")
    if runtime.is_dir():
        factory = runtime / "product_build.py"
        require(factory.is_file(), "Sealed backend edition factory is missing")
        require(factory.resolve().is_relative_to(contents.resolve()),
                "Backend factory symlink escapes Contents")
        audit_backend_factory(factory, edition)

    macho_count = 0
    source_count = 0
    for path in contents.rglob("*"):
        relative = path.relative_to(contents)
        if path.is_symlink():
            require(path.resolve().is_relative_to(contents.resolve()),
                    f"Bundle symlink escapes Contents: {relative}")
            require(path.exists(), f"Broken bundle symlink: {relative}")
        if edition == "locus":
            require(not WALLET_FILES.search(path.name), f"Wallet payload in standard app: {relative}")
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic in MACHO_MAGIC:
            macho_count += 1
            if edition == "locus":
                for tool in ("/usr/bin/nm", "/usr/bin/strings"):
                    match = WALLET_CODE.search(inspect_output([tool, str(path)]))
                    require(match is None, f"Wallet code in {relative}: {match.group() if match else ''}")
        elif edition == "locus" and path.suffix in {".py", ".pyc", ".js", ".html", ".plist", ".md", ".json"}:
            source_count += 1
            match = WALLET_CODE.search(path.read_bytes().decode("utf-8", errors="replace"))
            require(match is None, f"Wallet content in {relative}: {match.group() if match else ''}")

    require(macho_count > 0, "App contains no Mach-O executables")
    if edition == "locus":
        require(not any(key.startswith(("LocusWallet", "LocusReown", "LocusPhantom", "LocusCanary")) for key in info),
                "Wallet configuration remains in standard app")
    else:
        require("locus-wallet" in schemes, "LocusX wallet callback is missing")
        for component in (
            "XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
            "Helpers/WalletRecovery.app/Contents/MacOS/WalletRecovery",
            "Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
            "Resources/WalletConnections.bundle.js",
        ):
            require((contents / component).is_file(), f"LocusX component is missing: {component}")
        if runtime.is_dir():
            require((runtime / "_locusx/wallet.py").is_file(), "LocusX backend feature is missing")
    return {"edition": edition, "app": str(app.resolve()), "mach_o_files": macho_count,
            "source_resources_checked": source_count, "bundled_backend": runtime.is_dir(), "passed": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--edition", choices=("locus", "locusx"), required=True)
    parser.add_argument("--allow-missing-runtime", action="store_true", help="Only for compile-only CI builds")
    args = parser.parse_args()
    try:
        print(json.dumps(audit(args.app, args.edition, args.allow_missing_runtime), indent=2))
    except AuditError as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    main()
