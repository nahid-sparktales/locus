#!/usr/bin/env python3
"""Verify Direct-only wallet dependencies and emit a CycloneDX 1.5 SBOM."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys


REOWN = {
    "name": "reown-swift",
    "version": "2.3.2",
    "revision": "0b1337bdff0d6925eaa0467b83e2cc664275a8ee",
    "archiveURL": "https://github.com/reown-com/reown-swift/archive/refs/tags/2.3.2.tar.gz",
    "archiveSHA256": "c5de42f4a78a3b33aa58a593d81d9ba7295e69bdc00d25ffce20afb6932ee3a8",
    "patchedTreeSHA256": "2eac4caec48ca638bab63d61cadc22c8b8cb86df454040560cf28e1d7cbfb838",
    "licenseSHA256": "e30bbba6782f025ba0b6ced7d36840ac8587073d8df06a21be369a5cfcfc5830",
}
EXPECTED_DIRECT = {
    "@metamask/connect-evm": "2.1.1",
    "@phantom/browser-sdk": "2.0.2",
    "@mysten/slush-wallet": "1.1.23",
    "@solana/wallet-standard": "1.1.6",
    "@wallet-standard/core": "1.1.2",
    "esbuild": "0.28.2",
    # Direct because the audited bridge imports these public types.
    "@mysten/sui": "2.29.0",
    "@mysten/wallet-standard": "0.21.22",
    "@solana/web3.js": "1.98.4",
}
EXPECTED_BUNDLE_SHA256 = (
    "09aa8643956ae5e17ab004ccd85b62811a36f7f4e44535d2659ef43e512323bf"
)
EXPECTED_REOWN_TARGETS = {
    "Commons", "Events", "HTTPClient", "JSONRPC", "WalletConnectJWT",
    "WalletConnectKMS", "WalletConnectNetworking", "WalletConnectPairing",
    "WalletConnectRelay", "WalletConnectSign", "WalletConnectSigner",
    "WalletConnectUtils", "WalletConnectVerify",
}
PHANTOM_LICENSE = {
    "license": "MIT",
    "path": "WalletConnectionsWeb/licenses/phantom-wallet-sdk-87ad8fac.LICENSE",
    "sha256": "2f6200a1de42d6684738dce0b2d7b88f0728f948e39dc1a6861c79e8221adb6d",
    "source": "https://github.com/phantom/wallet-sdk/blob/87ad8fac24721cbe00377e92f429a500b0da4139/LICENSE",
}
LICENSE_EVIDENCE = {
    ("@phantom/api-key-stamper", "2.0.2", "sha512-TCjfFN7FrNuIQzHqgQOcBR/Vu32Jfr+y2/9VVwRDdPgRwrm0oNDQPIuCUhd7QAWmlotBtNnrZh9fDxc5DeCo7g=="): PHANTOM_LICENSE,
    ("@phantom/browser-sdk", "2.0.2", "sha512-fGcSR5o355Sl8NHMni8+TAsBJ/nVcVxOtOFiEjjzZHtbriMAC925lLhVprgpg9oRj5qze3lj2jOnpl5plmhEug=="): PHANTOM_LICENSE,
    ("@phantom/chain-interfaces", "2.0.2", "sha512-HgWDvODDulbLZZJYBtapUhUwE3CIqLuU6mwlLgu7E/w5dcGzQ+VZCN34bgtJTXc7ggl3f1HkC8JKRjPfPyOdSw=="): PHANTOM_LICENSE,
    ("@phantom/client", "2.0.2", "sha512-jMdkxBEfPpja+6QaTwusqhlHg9/a7achn2mh/WptMe5rX1v3TCwPmPy9vfWIj5U9QygyKe75U/exPB8jggz0gQ=="): PHANTOM_LICENSE,
    ("@phantom/indexed-db-stamper", "2.0.2", "sha512-5onsgIr9ylBLz3d2fTOFH0gYt4IG+ZcyebP4PamNqseLZjHp8ttpR7UVa1lxdA9T5plJB0BpWZQfV8kBkcOyEA=="): PHANTOM_LICENSE,
    ("@phantom/sdk-types", "2.0.2", "sha512-2xvIZZrCDbj4lDcSh4YWf3ODISubym9lha/FiVyrKoyz7aEhvT4YF2qm4Z/K42uBvKyC0FcdBtjAMiQiylyuBQ=="): PHANTOM_LICENSE,
    ("@phantom/utils", "2.0.2", "sha512-d0/cezg2Dd95lQe0RlZrAWK+jQ3t1KnE30oVmFkJZF3K/X05XIX9MO02wfVnXsPESX+bENuJIr12kRIQbSBA7g=="): PHANTOM_LICENSE,
    ("eyes", "0.1.8", "sha512-GipyPsXO1anza0AOZdy69Im7hGFCNB7Y/NGjDlZGJ3GJJLtwNSb2vrzYrTYJRrRloVx7pl+bhUaTB8yiccPvFQ=="): {
        "license": "MIT",
        "path": "WalletConnectionsWeb/licenses/eyes-0.1.8.LICENSE",
        "sha256": "e424cbb68485fe465f6e58959da4bf157e5a0e716c02cd8d9a2041a12520fb93",
        "source": "npm-package:eyes@0.1.8/LICENSE",
    },
    ("text-encoding-utf-8", "1.0.2", "sha512-8bw4MY9WjdsD2aMtO0OzOCY3pXGYNx2d2FfHRVUKkiCPDWjKuOlhLVASS+pD7VkLTVjW268LYJHwsnPFlBpbAg=="): {
        "license": "Unlicense",
        "path": "WalletConnectionsWeb/licenses/text-encoding-utf-8-1.0.2.LICENSE",
        "sha256": "caecf721eb8d6c1d74e57a798ef53d9cbeb58fc637af1877741a5572455206ec",
        "source": "npm-package:text-encoding-utf-8@1.0.2/LICENSE.md",
    },
}
EXCLUDED_REOWN_PRODUCTS = {
    "ReownWalletKit", "WalletConnectPay", "YttriumWrapper", "YttriumUtilsWrapper",
}


def fail(message: str) -> None:
    raise SystemExit(f"wallet connections dependency audit failed: {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")


def verify_reown(root: Path, project: str) -> dict:
    vendor = root / "Vendor/ReownSwift"
    evidence = load_json(vendor / "VENDORING.json")
    for key in (
        "name", "version", "revision", "archiveURL", "archiveSHA256",
        "patchedTreeSHA256",
    ):
        if evidence.get(key) != REOWN[key]:
            fail(f"Reown {key} changed")
    if evidence.get("enabledProduct") != "WalletConnect":
        fail("Reown enabled product is not WalletConnect Sign")
    if set(evidence.get("excludedProducts", [])) != EXCLUDED_REOWN_PRODUCTS:
        fail("Reown excluded product set changed")
    if sha256(vendor / "LICENSE") != REOWN["licenseSHA256"]:
        fail("Reown license changed")
    if sha256(vendor / "Files.sha256") != REOWN["patchedTreeSHA256"]:
        fail("Reown patched-tree digest changed")

    listed: set[str] = set()
    line_pattern = re.compile(r"^([0-9a-f]{64})  ([^/].*)$")
    for line in (vendor / "Files.sha256").read_text().splitlines():
        match = line_pattern.fullmatch(line)
        if not match:
            fail("Reown Files.sha256 contains a malformed entry")
        digest, relative = match.groups()
        if relative in listed or ".." in Path(relative).parts:
            fail("Reown Files.sha256 contains a duplicate or unsafe path")
        listed.add(relative)
        path = vendor / relative
        if not path.is_file() or sha256(path) != digest:
            fail(f"Reown patched file changed: {relative}")
    actual = {
        str(path.relative_to(vendor))
        for path in (vendor / "Sources").rglob("*") if path.is_file()
    } | {"LICENSE", "Package.swift"}
    if listed != actual:
        fail("Reown file inventory is incomplete or contains unexpected files")
    source_targets = {
        path.name for path in (vendor / "Sources").iterdir() if path.is_dir()
    }
    if source_targets != EXPECTED_REOWN_TARGETS:
        fail("Reown in-tree target graph changed")
    package = (vendor / "Package.swift").read_text()
    if '.library(name: "WalletConnect", targets: ["WalletConnectSign"])' not in package:
        fail("Reown package no longer exposes the reviewed Sign-only product")
    if any(name in package for name in EXCLUDED_REOWN_PRODUCTS):
        fail("an excluded Reown product entered the package graph")
    if not re.search(r"ReownSwift:\s*\n\s*path: Vendor/ReownSwift\b", project):
        fail("project.yml no longer uses the vendored Reown tree")
    if not re.search(
        r"- package: ReownSwift\s*\n\s*product: WalletConnect\b", project
    ):
        fail("the Direct target no longer links the reviewed WalletConnect product")
    mas_block = project.split("  LocusMAS:", 1)[1].split("  LocusTests:", 1)[0]
    if "ReownSwift" in mas_block or "WalletConnectionsRuntime" in mas_block:
        fail("the Mac App Store target references the connector runtime")
    return evidence


def npm_name(path: str) -> str:
    return path.rsplit("node_modules/", 1)[-1]


def verify_npm(root: Path) -> tuple[list[dict], dict]:
    web = root / "WalletConnectionsWeb"
    package = load_json(web / "package.json")
    lock = load_json(web / "package-lock.json")
    if lock.get("lockfileVersion") != 3:
        fail("npm lockfile must remain format v3")
    declared = dict(package.get("dependencies", {}))
    declared.update(package.get("devDependencies", {}))
    if declared != EXPECTED_DIRECT:
        fail("the direct npm dependency set or exact versions changed")
    packages = lock.get("packages")
    if not isinstance(packages, dict) or not packages:
        fail("npm lockfile has no package inventory")
    root_lock = packages.get("")
    if not isinstance(root_lock, dict):
        fail("npm lockfile has no root package")
    locked_direct = dict(root_lock.get("dependencies", {}))
    locked_direct.update(root_lock.get("devDependencies", {}))
    if locked_direct != EXPECTED_DIRECT:
        fail("npm lockfile root does not match package.json")

    components: list[dict] = []
    unresolved_licenses = 0
    for path, record in sorted(packages.items()):
        if not path:
            continue
        name = npm_name(path)
        version = record.get("version")
        integrity = record.get("integrity")
        resolved = record.get("resolved")
        if not isinstance(version, str) or not version:
            fail(f"npm component has no version: {path}")
        if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
            fail(f"npm component has no SHA-512 integrity: {name}@{version}")
        if not isinstance(resolved, str) or not resolved.startswith("https://registry.npmjs.org/"):
            fail(f"npm component has an unreviewed source: {name}@{version}")
        license_value = record.get("license")
        license_evidence = None
        if not isinstance(license_value, str) or not license_value.strip():
            license_evidence = LICENSE_EVIDENCE.get((name, version, integrity))
            if license_evidence:
                evidence_path = root / license_evidence["path"]
                if not evidence_path.is_file() or sha256(evidence_path) != license_evidence["sha256"]:
                    fail(f"license evidence changed: {name}@{version}")
                license_value = license_evidence["license"]
            else:
                license_value = "NOASSERTION"
                unresolved_licenses += 1
        purl = f"pkg:npm/{name.replace('@', '%40')}@{version}"
        ref = "urn:locus:npm:" + hashlib.sha256(path.encode()).hexdigest()
        license_record = (
            {"id": license_value}
            if re.fullmatch(r"[A-Za-z0-9.+-]+", license_value)
            and license_value != "NOASSERTION"
            else {"name": license_value}
        )
        components.append({
            "type": "library",
            "bom-ref": ref,
            "name": name,
            "version": version,
            "purl": purl,
            "scope": "optional" if record.get("dev") else "required",
            "hashes": [{
                "alg": "SHA-512", "content": integrity.removeprefix("sha512-")
            }],
            "licenses": [{"license": license_record}],
            "externalReferences": [{"type": "distribution", "url": resolved}],
            "properties": [
                {"name": "locus:npm-lock-path", "value": path},
                {"name": "locus:bundling", "value": "esbuild-static-bundle"},
                *([{
                    "name": "locus:license-evidence",
                    "value": f"{license_evidence['source']}#sha256:{license_evidence['sha256']}",
                }] if license_evidence else []),
            ],
        })
    if unresolved_licenses:
        fail(f"{unresolved_licenses} npm license declarations remain unresolved")
    bundle = root / "WalletConnectionsRuntime/Resources/WalletConnections.bundle.js"
    if not bundle.is_file() or sha256(bundle) != EXPECTED_BUNDLE_SHA256:
        fail("the deterministic wallet connector bundle digest changed")
    return components, {
        "componentCount": len(components),
        "unresolvedLicenseCount": unresolved_licenses,
        "bundleSHA256": EXPECTED_BUNDLE_SHA256,
        "packageLockSHA256": sha256(web / "package-lock.json"),
    }


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: WalletConnectionsSBOM.py <Package.resolved> <project.yml> <output>")
    _, project_arg, output_arg = sys.argv[1:]
    project_path = Path(project_arg).resolve()
    root = project_path.parent
    try:
        project = project_path.read_text()
    except OSError as error:
        fail(str(error))
    evidence = verify_reown(root, project)
    npm_components, npm_evidence = verify_npm(root)

    reown_ref = "pkg:github/reown-com/reown-swift@2.3.2"
    reown_component = {
        "type": "library",
        "bom-ref": reown_ref,
        "name": "reown-swift",
        "version": "2.3.2+locus.1",
        "scope": "required",
        "hashes": [
            {"alg": "SHA-1", "content": REOWN["revision"]},
            {"alg": "SHA-256", "content": REOWN["patchedTreeSHA256"]},
        ],
        "licenses": [{"license": {
            "name": "WalletConnect Community License Agreement (2025-08-20)",
            "url": "https://github.com/reown-com/reown-swift/blob/2.3.2/LICENSE",
        }}],
        "externalReferences": [
            {"type": "distribution", "url": REOWN["archiveURL"]},
            {"type": "vcs", "url": "https://github.com/reown-com/reown-swift"},
        ],
        "properties": [
            {"name": "locus:enabled-product", "value": evidence["enabledProduct"]},
            {"name": "locus:patches", "value": ",".join(evidence["patches"])},
            {"name": "locus:runtime-target", "value": "Direct-only"},
        ],
    }
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {"type": "application", "name": "Locus Wallet Connections"},
            "properties": [
                {"name": "locus:dependency-policy", "value": "exact-lock-and-artifact-digest"},
                {"name": "locus:runtime-enabled", "value": "true-direct-only"},
                {"name": "locus:app-store-runtime-enabled", "value": "false"},
                {"name": "locus:bundle-sha256", "value": npm_evidence["bundleSHA256"]},
                {"name": "locus:package-lock-sha256", "value": npm_evidence["packageLockSHA256"]},
                {"name": "locus:unresolved-license-count", "value": str(npm_evidence["unresolvedLicenseCount"])},
            ],
        },
        "components": [reown_component, *npm_components],
        "dependencies": [
            {"ref": reown_ref, "dependsOn": []},
            *[{"ref": item["bom-ref"], "dependsOn": []} for item in npm_components],
        ],
    }
    output = Path(output_arg)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(sbom, indent=2, sort_keys=True) + "\n")
    print(
        "Wallet connections SBOM: "
        f"Reown + {npm_evidence['componentCount']} locked npm entries, "
        f"{npm_evidence['unresolvedLicenseCount']} license declarations unresolved -> {output}"
    )


if __name__ == "__main__":
    main()
