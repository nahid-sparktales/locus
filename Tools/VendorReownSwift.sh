#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$root/Vendor/ReownSwift"
archive_url="https://github.com/reown-com/reown-swift/archive/refs/tags/2.3.2.tar.gz"
archive_sha256="c5de42f4a78a3b33aa58a593d81d9ba7295e69bdc00d25ffce20afb6932ee3a8"
revision="0b1337bdff0d6925eaa0467b83e2cc664275a8ee"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --fail --location --silent --show-error "$archive_url" -o "$work/reown-swift-2.3.2.tar.gz"
actual_archive_sha="$(shasum -a 256 "$work/reown-swift-2.3.2.tar.gz" | awk '{print $1}')"
test "$actual_archive_sha" = "$archive_sha256" || {
  echo "Reown archive digest mismatch" >&2
  exit 1
}
tar -xzf "$work/reown-swift-2.3.2.tar.gz" -C "$work"
source_root="$work/reown-swift-2.3.2"

mkdir -p "$work/vendor/Sources"
for target in \
  Commons Events HTTPClient JSONRPC WalletConnectJWT WalletConnectKMS \
  WalletConnectNetworking WalletConnectPairing WalletConnectRelay \
  WalletConnectSign WalletConnectSigner WalletConnectUtils WalletConnectVerify
do
  cp -R "$source_root/Sources/$target" "$work/vendor/Sources/$target"
done
cp "$source_root/LICENSE" "$work/vendor/LICENSE"
cp "$root/Tools/ReownSwift.Package.swift" "$work/vendor/Package.swift"
patch -d "$work/vendor" -p1 < "$root/Tools/Patches/reown-swift-2.3.2-foundation.patch"

(
  cd "$work/vendor"
  find LICENSE Package.swift Sources -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 > Files.sha256
)
tree_sha256="$(shasum -a 256 "$work/vendor/Files.sha256" | awk '{print $1}')"

mkdir -p "$root/Vendor"
rm -rf "$destination"
mv "$work/vendor" "$destination"
printf '%s\n' \
  '{' \
  '  "name": "reown-swift",' \
  '  "version": "2.3.2",' \
  "  \"revision\": \"$revision\"," \
  "  \"archiveURL\": \"$archive_url\"," \
  "  \"archiveSHA256\": \"$archive_sha256\"," \
  '  "patches": ["Tools/Patches/reown-swift-2.3.2-foundation.patch", "Tools/ReownSwift.Package.swift"],' \
  "  \"patchedTreeSHA256\": \"$tree_sha256\"," \
  '  "enabledProduct": "WalletConnect",' \
  '  "excludedProducts": ["ReownWalletKit", "WalletConnectPay", "YttriumWrapper", "YttriumUtilsWrapper"]' \
  '}' > "$destination/VENDORING.json"

echo "Vendored Reown Swift 2.3.2 ($tree_sha256)"
