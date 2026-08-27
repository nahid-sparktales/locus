#!/usr/bin/env python3
"""Generate and validate the locked WalletSigner CycloneDX inventory."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import urllib.parse
import uuid
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError as error:  # pragma: no cover - CI and release Macs use Python 3.11+
    raise SystemExit("WalletSignerSBOM.py requires Python 3.11 or newer") from error


EXPECTED_DIRECT = {
    "alloy": "2.4.1",
    "bip39": "2.2.2",
    "ed25519-dalek": "3.0.0",
    "hex": "0.4.3",
    "serde": "1.0.228",
    "serde_json": "1.0.145",
    "slip10_ed25519": "0.1.3",
    "solana-pubkey": "4.3.0",
    "sui-crypto": "0.3.1",
    "sui-sdk-types": "0.3.2",
    "zeroize": "1.9.0",
}

# Every expression is reviewed as a complete SPDX choice. A newly introduced
# expression stops CI/release packaging until it is explicitly accepted.
ALLOWED_LICENSE_EXPRESSIONS = {
    "(MIT OR Apache-2.0) AND Unicode-3.0",
    "Apache-2.0",
    "Apache-2.0 OR BSL-1.0",
    "Apache-2.0 OR MIT",
    "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT",
    "Apache-2.0/MIT",
    "BSD-2-Clause OR Apache-2.0 OR MIT",
    "BSD-3-Clause",
    "CC0-1.0",
    "CC0-1.0 OR MIT-0 OR Apache-2.0",
    "ISC",
    "MIT",
    "MIT OR Apache-2.0",
    "MIT OR Apache-2.0 OR BSD-1-Clause",
    "MIT OR Apache-2.0 OR LGPL-2.1-or-later",
    "MIT OR Apache-2.0 OR Zlib",
    "MIT/Apache-2.0",
    "MPL-2.0",
    "Unlicense OR MIT",
    "Zlib",
    "Zlib OR Apache-2.0 OR MIT",
}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def exact_version(spec: object) -> str | None:
    if isinstance(spec, str):
        return spec.removeprefix("=") if spec.startswith("=") else None
    if isinstance(spec, dict):
        version = spec.get("version")
        if isinstance(version, str) and version.startswith("="):
            return version[1:]
    return None


def cyclonedx_license(expression: str) -> str:
    # A few older crates publish slash-separated dual-license metadata. The
    # policy reviews the original string; the SBOM emits the equivalent SPDX.
    return {
        "Apache-2.0/MIT": "Apache-2.0 OR MIT",
        "MIT/Apache-2.0": "MIT OR Apache-2.0",
    }.get(expression, expression)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: WalletSignerSBOM.py <WalletSignerCore> <output.cdx.json>")
    core = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    manifest_path = core / "Cargo.toml"
    lock_path = core / "Cargo.lock"
    if not manifest_path.is_file() or not lock_path.is_file():
        fail("Cargo.toml and Cargo.lock are both required")

    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", {})
    if set(dependencies) != set(EXPECTED_DIRECT):
        missing = sorted(set(EXPECTED_DIRECT) - set(dependencies))
        added = sorted(set(dependencies) - set(EXPECTED_DIRECT))
        fail(f"direct dependency review required (missing={missing}, added={added})")
    for name, wanted in EXPECTED_DIRECT.items():
        if exact_version(dependencies[name]) != wanted:
            fail(f"{name} must remain exactly pinned to {wanted}")

    process = subprocess.run(
        [
            "cargo", "metadata", "--locked", "--format-version", "1",
            "--manifest-path", str(manifest_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    metadata = json.loads(process.stdout)
    packages = metadata["packages"]
    root_id = metadata["resolve"]["root"]
    by_id = {package["id"]: package for package in packages}

    for package in packages:
        source = package.get("source")
        if package["id"] != root_id and not str(source).startswith("registry+"):
            fail(f"unreviewed non-registry source for {package['name']} {package['version']}")
        license_expression = package.get("license")
        if not license_expression:
            fail(f"missing license expression for {package['name']} {package['version']}")
        if license_expression not in ALLOWED_LICENSE_EXPRESSIONS:
            fail(
                "license review required for "
                f"{package['name']} {package['version']}: {license_expression}"
            )

    def purl(package: dict[str, object]) -> str:
        name = urllib.parse.quote(str(package["name"]), safe="-._~")
        version = urllib.parse.quote(str(package["version"]), safe="-._~+")
        return f"pkg:cargo/{name}@{version}"

    references = {package_id: purl(package) for package_id, package in by_id.items()}
    components = []
    for package in sorted(packages, key=lambda value: (value["name"], value["version"])):
        component = {
            "type": "library" if package["id"] != root_id else "application",
            "bom-ref": references[package["id"]],
            "name": package["name"],
            "version": package["version"],
            "purl": references[package["id"]],
            "licenses": [{"expression": cyclonedx_license(package["license"])}],
        }
        if package.get("repository"):
            component["externalReferences"] = [
                {"type": "vcs", "url": package["repository"]}
            ]
        components.append(component)

    dependency_nodes = []
    for node in sorted(metadata["resolve"]["nodes"], key=lambda value: value["id"]):
        dependency_nodes.append(
            {
                "ref": references[node["id"]],
                "dependsOn": sorted(references[item] for item in node["dependencies"]),
            }
        )

    lock_digest = hashlib.sha256(lock_path.read_bytes()).hexdigest()
    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"locus-wallet:{lock_digest}")
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "component": next(item for item in components if item["bom-ref"] == references[root_id]),
            "properties": [
                {"name": "locus:cargo-lock:sha256", "value": lock_digest},
                {"name": "locus:dependency-policy", "value": "exact-direct-and-locked-transitive"},
            ],
        },
        "components": components,
        "dependencies": dependency_nodes,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wallet signer SBOM: {len(components)} locked components -> {output}")


if __name__ == "__main__":
    main()
