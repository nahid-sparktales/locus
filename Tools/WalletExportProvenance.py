#!/usr/bin/env python3
"""Record and verify the exact Xcode Developer ID export, without modifying it."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

SIGNERS = (
    "Contents/XPCServices/WalletSigner.xpc",
    "Contents/Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc",
)
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def run(*command: str) -> bytes:
    result = subprocess.run(command, capture_output=True, check=False)
    require(result.returncode == 0, f"{Path(command[0]).name} verification failed")
    return result.stdout


def plist(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())


def signature(path: Path) -> dict:
    run("/usr/bin/codesign", "--verify", "--strict", str(path))
    result = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(path)], capture_output=True, check=False
    )
    require(result.returncode == 0, "code signature cannot be inspected")
    fields = {}
    for line in result.stderr.decode().splitlines():
        name, _, value = line.partition("=")
        if name in {"CDHash", "TeamIdentifier", "Identifier"}:
            fields[name] = value
    require(bool(re.fullmatch(r"[0-9a-f]{40,64}", fields.get("CDHash", ""))), "missing CodeDirectory identity")
    require(bool(re.fullmatch(r"[A-Z0-9]{10}", fields.get("TeamIdentifier", ""))), "export has no signing team")
    return fields


def unsigned_digest(path: Path) -> str:
    # Signature removal applies exclusively to this disposable copy. It gives
    # stable code provenance when Xcode replaces a timestamp or certificate.
    with tempfile.TemporaryDirectory(prefix="locus-unsigned-code-") as temporary:
        copy = Path(temporary) / "executable"
        shutil.copy2(path, copy)
        run("/usr/bin/codesign", "--remove-signature", str(copy))
        return digest(copy)


def source_identity(app: Path) -> tuple[str, str]:
    info = plist(app / "Contents/Info.plist")
    source = info.get("LocusSourceRevision", "")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", source)), "app has no clean source revision")
    provenance = dict(
        line.split("=", 1) for line in (app / "Contents/Resources/BuildProvenance.txt").read_text().splitlines()
        if "=" in line
    )
    require(provenance.get("source_revision") == source, "build and app source identities differ")
    for relative in SIGNERS:
        signer_info = plist(app / relative / "Contents/Info.plist")
        require(signer_info.get("LocusSourceRevision") == source, "signer source identity differs")
    return source, str(info["CFBundleVersion"])


def validate_profile(signer: Path, team: str) -> str:
    profile_path = signer / "Contents/embedded.provisionprofile"
    require(profile_path.is_file(), "nested signer lacks its exported provisioning profile")
    profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(profile_path)))
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), "provisioning profile lacks expiry")
    require(expiry.replace(tzinfo=dt.timezone.utc) > dt.datetime.now(dt.timezone.utc), "provisioning profile expired")
    require(team in profile.get("TeamIdentifier", []), "profile team differs from the app")
    require(profile.get("ProvisionsAllDevices") is True, "signer requires a Developer ID distribution profile")
    entitlements = profile.get("Entitlements", {})
    require(entitlements.get("get-task-allow", False) is False
            and entitlements.get("com.apple.security.get-task-allow", False) is False,
            "development profile cannot authorize a release")
    expected = f"{team}.io.sparktales.locus.WalletSigner"
    groups = entitlements.get("keychain-access-groups", [])
    require(expected in groups or f"{team}.*" in groups, "profile does not authorize signer Keychain access")
    identifier = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    require(identifier in {expected, f"{team}.*"}, "profile does not authorize the signer application")
    return digest(profile_path)


def snapshot(app: Path) -> dict:
    source, version = source_identity(app)
    outer = signature(app)
    require(outer["Identifier"] == "io.sparktales.locus", "unexpected outer application identifier")
    # Require Apple's Developer ID certificate class, not just a same-team
    # development certificate. Xcode's profile is validated independently.
    requirement = (
        'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
        'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
        f'and certificate leaf[subject.OU] = "{outer["TeamIdentifier"]}"'
    )
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, str(app))
    signers = {}
    for relative in SIGNERS:
        identity = signature(app / relative)
        require(identity["TeamIdentifier"] == outer["TeamIdentifier"], "signer team differs")
        identity["profileSHA256"] = validate_profile(app / relative, outer["TeamIdentifier"])
        signers[relative] = identity
    require(len({item["CDHash"] for item in signers.values()}) == 1, "signer copies have different code identities")
    files = {}
    for path in sorted(app.rglob("*")):
        if path.is_file() and not path.is_symlink():
            files[path.relative_to(app).as_posix()] = digest(path)
    return {"sourceRevision": source, "bundleVersion": version, "outerApp": outer, "signers": signers, "files": files}


def verify(receipt: dict, app: Path) -> dict:
    require(receipt.get("schemaVersion") == 1 and receipt.get("exportMethod") == "developer-id", "not a Developer ID export receipt")
    current = snapshot(app)
    for name in ("sourceRevision", "bundleVersion", "outerApp", "signers"):
        require(current[name] == receipt.get(name), f"exported {name} changed")
    for relative, expected in receipt.get("files", {}).items():
        require(current["files"].get(relative) == expected, "exported bundle content changed")
    require(bool(receipt.get("files")), "export receipt has an empty bundle inventory")
    return current


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    record = sub.add_parser("record")
    record.add_argument("archive", type=Path)
    record.add_argument("app", type=Path)
    record.add_argument("options", type=Path)
    record.add_argument("receipt", type=Path)
    record.add_argument("--channel", choices=("canary", "ga"), required=True)
    check = sub.add_parser("verify")
    check.add_argument("app", type=Path)
    check.add_argument("receipt", type=Path)
    code = sub.add_parser("unsigned-digest")
    code.add_argument("executable", type=Path)
    args = parser.parse_args()
    if args.operation == "unsigned-digest":
        print(unsigned_digest(args.executable))
        return
    if args.operation == "verify":
        verify(json.loads(args.receipt.read_text()), args.app)
        print("Developer ID export identity and sealed content verified.")
        return
    require(not args.receipt.exists(), "export receipt already exists")
    options = plist(args.options)
    require(options.get("method") == "developer-id" and options.get("signingStyle") == "automatic", "unexpected export options")
    archived = args.archive / "Products/Applications/Locus.app"
    require(source_identity(archived) == source_identity(args.app), "archive/export source or version differs")
    receipt = snapshot(args.app)
    archived_files = {
        path.relative_to(archived).as_posix() for path in archived.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    def signing_metadata(relative: str) -> bool:
        return "/_CodeSignature/" in relative or relative.endswith("embedded.provisionprofile")

    require(
        {path for path in archived_files if not signing_metadata(path)}
        == {path for path in receipt["files"] if not signing_metadata(path)},
        "export added or removed archived content",
    )
    for relative, expected in receipt["files"].items():
        exported_file = args.app / relative
        with exported_file.open("rb") as stream:
            macho = stream.read(4) in MACHO_MAGICS
        if macho:
            archived_file = archived / relative
            require(archived_file.is_file(), "export added an executable absent from the archive")
            require(unsigned_digest(archived_file) == unsigned_digest(exported_file), "export changed executable content")
        elif relative.endswith("Info.plist"):
            before, after = plist(archived / relative), plist(exported_file)
            # Xcode may stamp its export-tool version, but release configuration
            # (providers, manifests, callbacks, entitlements input) must not drift.
            before.pop("DTAppStoreToolsBuild", None)
            after.pop("DTAppStoreToolsBuild", None)
            require(before == after, "export changed application configuration")
        elif signing_metadata(relative):
            continue
        else:
            require((archived / relative).is_file() and digest(archived / relative) == expected, "export changed an archived resource")
    receipt.update({
        "schemaVersion": 1, "exportMethod": "developer-id", "releaseChannel": args.channel,
        "exportOptionsSHA256": digest(args.options), "archiveInfoSHA256": digest(args.archive / "Info.plist"),
    })
    args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print("Developer ID export provenance recorded; this is not release activation.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"wallet export provenance failed: {error}") from None
