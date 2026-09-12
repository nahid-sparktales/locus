#!/usr/bin/env python3
"""Transport-security audit.

Locus ships ``NSAllowsArbitraryLoads`` because the model servers it exists to
talk to — Ollama, llama.cpp, LM Studio — serve plain HTTP on LAN addresses that
no certificate authority will vouch for, and Apple offers no narrower key that
reaches them: ``NSAllowsLocalNetworking`` does not cover RFC1918 literals, and
``NSExceptionDomains`` does not accept IP addresses at all.

The cost of the blanket key is that the OS stops enforcing HTTPS for *every*
connection the process makes, including ones no user configured. Nothing fails
when that enforcement disappears; a cleartext endpoint simply starts working,
silently, which is why it needs a check that is not the operating system.

This audit is that check. It enforces three things:

1. every shipping app bundle declares the opt-out, and declares it ALONE —
   pairing it with ``NSAllowsLocalNetworking`` or
   ``NSAllowsArbitraryLoadsInWebContent`` makes current macOS ignore it, so the
   app would lose LAN model servers again with nothing to show why;
2. every shipping app bundle still explains its private-network use, because a
   missing ``NSLocalNetworkUsageDescription`` fails identically to an ATS block
   and costs an afternoon to tell apart;
3. no Swift source gains a cleartext URL literal pointing anywhere but this
   machine or this network — the rule ATS used to enforce for free.
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Every bundle that ships as a running app. Helper executables keep full ATS
# enforcement and are deliberately absent: only the process that talks to a
# user's model server needs the opt-out.
APP_PLISTS = [
    Path("Locus/Info.plist"),
    Path("Config/LocusRelease-Info.plist"),
    Path("Config/LocusX-Info.plist"),
    Path("Config/LocusExperimental-Info.plist"),
    Path("Config/LocusMAS-Info.plist"),
]

# Keys whose mere presence makes macOS 10.15+/iOS 13+ disregard
# NSAllowsArbitraryLoads. They are not additive with it; they replace it.
CONFLICTING_ATS_KEYS = [
    "NSAllowsArbitraryLoadsInWebContent",
    "NSAllowsArbitraryLoadsForMedia",
    "NSAllowsLocalNetworking",
]

SWIFT_ROOTS = [
    "Locus",
    "WalletConnectionsRuntime",
    "RuntimeHelper",
    "DocumentExtractor",
    "SimulatorBridge",
    "WalletSignerService",
    "WalletRecoveryService",
]

# Cleartext literals that are reviewed and not network destinations. Keyed by
# host so a new file reusing a known-inert host does not need a new entry, but
# a genuinely new host still has to be argued for here.
ALLOWED_CLEARTEXT_HOSTS = {
    # An XML namespace identifier. Never dereferenced; changing it would break
    # SVG parsing rather than secure anything.
    "www.w3.org": "SVG namespace identifier, not a request target",
    # A prefix-stripping table for model references the user pastes, not a URL
    # the app builds a request from.
    "huggingface.co": "prefix match when normalising pasted model references",
    # Placeholder and documentation strings shown in proxy settings.
    "proxy.corp": "example proxy shown in help text",
    "proxy.example": "example proxy shown in help text",
}

# Stops at the first character that cannot appear in an authority, so an
# interpolation, a path, or prose after the URL never lands in the host.
CLEARTEXT_PATTERN = re.compile(r"http://([A-Za-z0-9._:%@\[\]-]*)")


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def is_private_host(raw_host: str) -> bool:
    """Mirror of ``TransportSecurity.isPrivate(host:)`` in the app.

    Kept in step with it by ``TransportSecurityTests``, which asserts the same
    table of hosts the cases below encode.
    """
    host = raw_host.lower()
    host = host.split("@")[-1]  # drop any user:password prefix
    # A port may be absent, literal, or an interpolation the regex already cut
    # away — leaving a bare trailing colon behind either way.
    host = host.rstrip(":")
    if re.match(r"^[^:]+:\d+$", host):
        host = host.rsplit(":", 1)[0]
    if host.startswith("[") and "]" in host:  # bracketed IPv6, with or without a port
        host = host[1 : host.index("]")]
    host = host.split("%", 1)[0]
    if not host:
        return False
    if host == "localhost" or host.endswith(".localhost") or host.endswith(".local"):
        return True

    octets = host.split(".")
    if len(octets) == 4 and all(o.isdigit() and str(int(o)) == o and int(o) < 256 for o in octets):
        first, second = int(octets[0]), int(octets[1])
        return (
            first in (0, 10, 127)
            or (first, second) == (192, 168)
            or (first == 172 and 16 <= second <= 31)
            or (first, second) == (169, 254)
            or (first == 100 and 64 <= second <= 127)
        )

    if ":" in host:
        return host in ("::1", "::") or host[:4].startswith(("fc", "fd", "fe8", "fe9", "fea", "feb"))

    # An unqualified name cannot resolve outside the local resolver.
    return "." not in host


def audit_plists() -> int:
    failures = 0
    for relative in APP_PLISTS:
        path = REPO / relative
        if not path.exists():
            fail(f"{relative}: expected app Info.plist is missing")
            failures += 1
            continue
        with path.open("rb") as handle:
            plist = plistlib.load(handle)

        ats = plist.get("NSAppTransportSecurity")
        if not isinstance(ats, dict):
            fail(
                f"{relative}: no NSAppTransportSecurity dictionary. Without it the app "
                "cannot reach a self-hosted model server on a LAN address."
            )
            failures += 1
            continue

        if ats.get("NSAllowsArbitraryLoads") is not True:
            fail(f"{relative}: NSAllowsArbitraryLoads must be present and true")
            failures += 1

        for key in CONFLICTING_ATS_KEYS:
            if key in ats:
                fail(
                    f"{relative}: {key} is set alongside NSAllowsArbitraryLoads. Current "
                    "macOS honours the narrower key and ignores the blanket one, so LAN "
                    "model servers stop resolving. Remove it."
                )
                failures += 1

        # Endpoints the app ships rather than the user typing them. Sparkle
        # reads SUFeedURL itself, so no Swift gate can cover it; this is the
        # only place that says it has to be encrypted.
        for key, value in plist.items():
            if not isinstance(value, str) or not value.lower().startswith("http://"):
                continue
            fail(
                f"{relative}: {key} is a cleartext URL ({value}). Endpoints the app "
                "declares for itself must be https — ATS no longer requires it."
            )
            failures += 1

        if not plist.get("NSLocalNetworkUsageDescription"):
            fail(
                f"{relative}: NSLocalNetworkUsageDescription is missing. The private-network "
                "prompt never appears and the failure is indistinguishable from an ATS block."
            )
            failures += 1
    return failures


def audit_sources() -> int:
    failures = 0
    for root in SWIFT_ROOTS:
        base = REPO / root
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            relative = path.relative_to(REPO)
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for match in CLEARTEXT_PATTERN.finditer(line):
                    host = match.group(1)
                    # "http://" followed straight by an interpolation or the end
                    # of the literal builds its host at runtime; TransportSecurity
                    # classifies those, a grep cannot.
                    if not host or host.startswith("\\("):
                        continue
                    if is_private_host(host):
                        continue
                    bare = host.split("@")[-1].split(":")[0]
                    if bare in ALLOWED_CLEARTEXT_HOSTS:
                        continue
                    fail(
                        f"{relative}:{number}: cleartext URL to '{host}'. App Transport "
                        "Security no longer blocks this — use https, or add the host to "
                        "ALLOWED_CLEARTEXT_HOSTS in Tools/AuditTransportSecurity.py with "
                        "the reason it is not a request target."
                    )
                    failures += 1
    return failures


def main() -> int:
    failures = audit_plists() + audit_sources()
    if failures:
        print(
            f"Transport-security audit failed with {failures} problem(s).",
            file=sys.stderr,
        )
        return 1
    print(f"Transport-security audit passed ({len(APP_PLISTS)} app bundles checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
