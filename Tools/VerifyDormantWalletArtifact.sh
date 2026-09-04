#!/bin/zsh
set -euo pipefail
app="${1:?usage: VerifyDormantWalletArtifact.sh <exported Locus.app>}"
repo_root="${0:A:h:h}"
info="${app}/Contents/Info.plist"
signer_info="${app}/Contents/XPCServices/WalletSigner.xpc/Contents/Info.plist"
key="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletCapabilityPublicKey' "${signer_info}")"
capability="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletCapabilityManifestBase64' "${signer_info}")"
review="$(/usr/libexec/PlistBuddy -c 'Print :LocusWalletReviewManifestBase64' "${signer_info}")"
[[ -n "${key}" && -n "${review}" && -z "${capability}" ]] || {
    echo "error: the artifact is not dormant" >&2; exit 1
}
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-dormant-audit.XXXXXX")"
trap '/bin/rm -rf "${temporary}"' EXIT
/bin/echo -n "${review}" | /usr/bin/base64 -D > "${temporary}/review.json"
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    --verify "${temporary}/review.json" "${key}" >/dev/null
# This check independently reproduces connector configuration digests as well
# as the exact reviewed provider identities. It never prints the source values.
python3 "${repo_root}/Tools/VerifyWalletProviderBindings.py" "${temporary}/review.json" "${info}"
python3 - "${app}" <<'PY'
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

app = Path(sys.argv[1])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
outer = plistlib.loads((app / "Contents/XPCServices/WalletSigner.xpc/Contents/Info.plist").read_bytes())
inner = plistlib.loads((app / "Contents/Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/Info.plist").read_bytes())
for key in ("LocusWalletCapabilityPublicKey", "LocusWalletCapabilityManifestBase64", "LocusWalletReviewManifestBase64", "LocusSourceRevision"):
    if outer.get(key) != inner.get(key):
        raise SystemExit("error: signer copies have different release configuration")
if not re.fullmatch(r"[0-9a-f]{40}", str(info.get("LocusSourceRevision", ""))) or info.get("LocusSourceRevision") != outer.get("LocusSourceRevision"):
    raise SystemExit("error: clean app/signer source identities are required")
for key in ("LocusWalletReleaseActivationURL", "LocusPhantomRedirectURL"):
    value = urlsplit(str(info.get(key, "")))
    if value.scheme != "https" or not value.hostname or value.username or value.password or value.fragment:
        raise SystemExit("error: invalid release endpoint configuration")
if info.get("LocusWalletConnectRedirectURL") != "locus-wallet://walletconnect":
    raise SystemExit("error: WalletConnect redirect must match the registered release URL")
for key, pattern in (("LocusReownProjectID", r"[A-Za-z0-9_-]{16,128}"), ("LocusPhantomAppID", r"[A-Za-z0-9._-]{1,128}")):
    if not re.fullmatch(pattern, str(info.get(key, ""))):
        raise SystemExit("error: connector release configuration is missing or invalid")
for chain in ("Ethereum", "Solana", "Sui"):
    for provider in ("Alchemy", "QuickNode"):
        suffix = "GraphQLURL" if chain == "Sui" else "RPCURL"
        if not info.get(f"LocusWallet{provider}{chain}Mainnet{suffix}"):
            raise SystemExit("error: all-chain canary requires both mainnet providers for every chain")
for path in app.rglob("*"):
    if path.name.lower() in {"wallet-activation.json", "walletreleaseactivation.json"}:
        raise SystemExit("error: dormant artifact contains an activating envelope")
print("Dormant wallet configuration and all-chain provider ceiling verified.")
PY
