#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-review-tool.XXXXXX")"
trap '/usr/bin/find "${work_dir}" -depth -delete' EXIT

/usr/bin/python3 - "${repo_root}/Config/WalletReviewManifest.template.json" \
    "${work_dir}/manifest.json" <<'PY'
import datetime
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
manifest["issuedAt"] = (now - datetime.timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
manifest["expiresAt"] = (now + datetime.timedelta(hours=1)).isoformat().replace("+00:00", "Z")
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, sort_keys=True, separators=(",", ":"))
PY

/usr/bin/openssl rand -base64 32 > "${work_dir}/private-key.base64"
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    "${work_dir}/manifest.json" "${work_dir}/private-key.base64" \
    "${work_dir}/signed.json" > "${work_dir}/sign-result.txt"
public_key="$(/usr/bin/sed -n 's/^public_key_base64=//p' "${work_dir}/sign-result.txt")"
[[ -n "${public_key}" ]] || {
    echo "error: review-manifest signer did not return its public key" >&2
    exit 1
}
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    --verify "${work_dir}/signed.json" "${public_key}" >/dev/null

/usr/bin/python3 - "${work_dir}/manifest.json" "${work_dir}/phantom-evm.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
manifest["connectors"] = [{
    "connector": "phantom",
    "ownership": "connector_managed",
    "version": "2.0.2",
    "artifactSHA256": "b" * 64,
    "configurationSHA256": "c" * 64,
    "directions": ["external_account_to_locus"],
    "methods": ["list_accounts", "send_transaction", "sign_in_with_ethereum"],
}]
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(manifest, destination, sort_keys=True, separators=(",", ":"))
PY
if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    "${work_dir}/phantom-evm.json" "${work_dir}/private-key.base64" \
    "${work_dir}/phantom-evm-signed.json" >/dev/null 2>&1
then
    echo "error: review signer accepted Phantom SIWE authority" >&2
    exit 1
fi

/usr/bin/python3 - "${work_dir}/phantom-evm.json" "${work_dir}" <<'PY'
import copy
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
manifest["connectors"][0]["methods"] = ["send_transaction", "list_accounts", "sign_in_with_solana"]
root = pathlib.Path(sys.argv[2])
(root / "configured.json").write_text(json.dumps(manifest))
missing = copy.deepcopy(manifest)
del missing["connectors"][0]["configurationSHA256"]
(root / "missing-configuration.json").write_text(json.dumps(missing))
manifest["connectors"][0]["configurationSHA256"] = "C" * 64
(root / "malformed-configuration.json").write_text(json.dumps(manifest))
PY
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    "${work_dir}/configured.json" "${work_dir}/private-key.base64" \
    "${work_dir}/configured-signed.json" >/dev/null
/usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    --verify "${work_dir}/configured-signed.json" "${public_key}" >/dev/null
for invalid in missing-configuration malformed-configuration; do
    if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
        "${work_dir}/${invalid}.json" "${work_dir}/private-key.base64" \
        "${work_dir}/${invalid}-signed.json" >/dev/null 2>&1
    then
        echo "error: review signer accepted an invalid configuration identity" >&2
        exit 1
    fi
done
/usr/bin/python3 - "${work_dir}/configured-signed.json" "${work_dir}/changed-configuration.json" <<'PY'
import json
import pathlib
import sys

signed = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert signed["manifest"]["connectors"][0]["configurationSHA256"] == "c" * 64
signed["manifest"]["connectors"][0]["configurationSHA256"] = "d" * 64
pathlib.Path(sys.argv[2]).write_text(json.dumps(signed))
PY
if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    --verify "${work_dir}/changed-configuration.json" "${public_key}" >/dev/null 2>&1
then
    echo "error: review signature did not bind connector configuration" >&2
    exit 1
fi

/usr/bin/python3 - "${work_dir}/signed.json" "${work_dir}/tampered.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    signed = json.load(source)
assert signed["manifest"]["uniswapConfigurations"] == []
signed["manifest"]["uniswapConfigurations"] = [{}]
with open(sys.argv[2], "w", encoding="utf-8") as destination:
    json.dump(signed, destination, sort_keys=True, separators=(",", ":"))
PY
if /usr/bin/xcrun swift "${repo_root}/Tools/SignWalletReviewManifest.swift" \
    --verify "${work_dir}/tampered.json" "${public_key}" >/dev/null 2>&1
then
    echo "error: tampered Uniswap review authority verified" >&2
    exit 1
fi

echo "Wallet review manifest signing boundary verified."
