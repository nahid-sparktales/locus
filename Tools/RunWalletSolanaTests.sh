#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
if [[ -z "${LOCUS_TEST_EXECUTION_LOCK_FD:-}" ]]; then
  exec python3 "$repo_root/Tools/WalletTestExecution.py" --lock-timeout 600 -- "$0" "$@"
fi
python3 "$repo_root/Tools/WalletTestExecution.py" --assert-held
pinned_version="4.1.2"
validator_bin="${LOCUS_SOLANA_TEST_VALIDATOR_BIN:-$(command -v solana-test-validator 2>/dev/null || true)}"

if [[ -z "$validator_bin" || ! -x "$validator_bin" ]]; then
  print -u2 "error: solana-test-validator v${pinned_version} is required. Set LOCUS_SOLANA_TEST_VALIDATOR_BIN to the pinned executable."
  exit 1
fi
version_output="$($validator_bin --version)"
if [[ "$version_output" != *"$pinned_version"* ]]; then
  print -u2 "error: expected solana-test-validator v${pinned_version}, got: ${version_output}"
  exit 1
fi

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/locus-wallet-solana.XXXXXX")"
validator_pid=""

cleanup() {
  if [[ -n "$validator_pid" ]]; then
    kill "$validator_pid" 2>/dev/null || true
    wait "$validator_pid" 2>/dev/null || true
  fi
  find "$temp_dir" -depth -delete
}
trap cleanup EXIT INT TERM

"$validator_bin" \
  --bind-address 127.0.0.1 \
  --rpc-port "$port" \
  --ledger "$temp_dir/ledger" \
  --reset \
  --quiet \
  >"$temp_dir/validator.log" 2>&1 &
validator_pid="$!"

rpc_url="http://127.0.0.1:${port}"
for _ in {1..300}; do
  if genesis_hash="$(curl -fsS --connect-timeout 2 --max-time 3 \
      -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash","params":[]}' \
      "$rpc_url" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result", ""))' 2>/dev/null)" \
      && [[ -n "$genesis_hash" ]]; then
    break
  fi
  if ! kill -0 "$validator_pid" 2>/dev/null; then
    print -u2 "error: solana-test-validator exited before becoming ready"
    tail -80 "$temp_dir/validator.log" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ -z "${genesis_hash:-}" ]]; then
  print -u2 "error: solana-test-validator did not return a genesis hash"
  tail -80 "$temp_dir/validator.log" >&2
  exit 1
fi

cd "$repo_root"
LOCUS_BUNDLE_MODE=skip \
xcodebuild test \
  -project Locus.xcodeproj \
  -scheme WalletChainIntegration \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:LocusWalletChainTests/WalletSolanaIntegrationTests \
  LOCUS_SOLANA_VALIDATOR_RPC_URL="$rpc_url" \
  LOCUS_SOLANA_VALIDATOR_GENESIS_HASH="$genesis_hash" \
  LOCUS_SOLANA_VALIDATOR_VERSION="$pinned_version" \
  "$@"
