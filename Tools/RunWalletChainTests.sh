#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
pinned_version="1.7.1"
anvil_bin="${LOCUS_ANVIL_BIN:-$(command -v anvil 2>/dev/null || true)}"

if [[ -z "$anvil_bin" || ! -x "$anvil_bin" ]]; then
  print -u2 "error: Anvil v${pinned_version} is required. Set LOCUS_ANVIL_BIN to the pinned executable."
  exit 1
fi

version_output="$($anvil_bin --version)"
if [[ "$version_output" != *"$pinned_version"* ]]; then
  print -u2 "error: expected Anvil v${pinned_version}, got: ${version_output}"
  exit 1
fi

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/locus-wallet-anvil.XXXXXX")"
anvil_pid=""

cleanup() {
  if [[ -n "$anvil_pid" ]]; then
    kill "$anvil_pid" 2>/dev/null || true
    wait "$anvil_pid" 2>/dev/null || true
  fi
  find "$temp_dir" -depth -delete
}
trap cleanup EXIT INT TERM

"$anvil_bin" \
  --host 127.0.0.1 \
  --port "$port" \
  --chain-id 11155111 \
  --accounts 2 \
  >"$temp_dir/anvil.log" 2>&1 &
anvil_pid="$!"

rpc_url="http://127.0.0.1:${port}"
for _ in {1..100}; do
  if curl -fsS \
    -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    "$rpc_url" | grep -q '0xaa36a7'; then
    break
  fi
  if ! kill -0 "$anvil_pid" 2>/dev/null; then
    print -u2 "error: Anvil exited before becoming ready"
    tail -80 "$temp_dir/anvil.log" >&2
    exit 1
  fi
  sleep 0.1
done

if ! curl -fsS \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  "$rpc_url" | grep -q '0xaa36a7'; then
  print -u2 "error: Anvil did not start with Sepolia chain ID 11155111"
  tail -80 "$temp_dir/anvil.log" >&2
  exit 1
fi

cd "$repo_root"
# Extra arguments pass through to xcodebuild. CI and contributors outside
# the team append `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` (CONTRIBUTING.md).
LOCUS_BUNDLE_MODE=skip \
xcodebuild test \
  -project Locus.xcodeproj \
  -scheme WalletChainIntegration \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:LocusWalletChainTests \
  LOCUS_ANVIL_RPC_URL="$rpc_url" \
  LOCUS_ANVIL_VERSION="$pinned_version" \
  "$@"
