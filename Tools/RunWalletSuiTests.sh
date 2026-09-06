#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
if [[ -z "${LOCUS_TEST_EXECUTION_LOCK_FD:-}" ]]; then
  exec python3 "$repo_root/Tools/WalletTestExecution.py" --lock-timeout 600 -- "$0" "$@"
fi
python3 "$repo_root/Tools/WalletTestExecution.py" --assert-held
pinned_version="1.79.0"
pinned_commit="46f18562f1f5af2438d35828e8b62d5e0b972db7"
case "$(uname -m)" in
  arm64)
    asset="sui-testnet-v1.79.0-macos-arm64.tgz"
    expected="79900034cb533832a3bf9f10d783c309bfa8259697d6417e6dccdb0758f0f613" ;;
  x86_64)
    asset="sui-testnet-v1.79.0-macos-x86_64.tgz"
    expected="de1cef624dd7344102094a46d68008de4f5256fc6aeb5c25f3a87dc21df333e1" ;;
  *) print -u2 'error: Sui localnet runner requires a reviewed macOS architecture'; exit 1 ;;
esac
# Source: https://api.github.com/repos/MystenLabs/sui/releases/tags/testnet-v1.79.0
# --with-graphql starts its indexer/consistent store and requires PostgreSQL tools.
for executable in initdb pg_ctl; do
  command -v "$executable" >/dev/null || {
    print -u2 "error: PostgreSQL 17 tools must be on PATH ($executable missing)"; exit 1
  }
done
[[ "$(initdb --version)" == *' 17.'* ]] || {
  print -u2 'error: expected PostgreSQL major version 17'; exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/locus-wallet-sui.XXXXXX")"
localnet_pid=""
cleanup() {
  local cleanup_result="${1:-$?}"
  trap - EXIT INT TERM
  if [[ -n "$localnet_pid" ]]; then
    kill "$localnet_pid" 2>/dev/null || true
    wait "$localnet_pid" 2>/dev/null || true
  fi
  # Sui's pg_ctl daemon survives termination of `sui start` and inherits the
  # execution lock. Its temp data is confined below this runner's TMPDIR, so
  # stop only those databases before removing their files/releasing the lock.
  local pid_file
  while IFS= read -r -d '' pid_file; do
    if ! pg_ctl -D "${pid_file:h}" -m fast -w -t 10 stop; then
      print -u2 'error: the isolated Sui PostgreSQL server did not stop'
      exit 1
    fi
  done < <(find "$temp_dir" -type f -name postmaster.pid -print0)
  # Only the runner-created temporary directory is removed, including fixture keys.
  find "$temp_dir" -depth -delete
  exit "$cleanup_result"
}
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
# Isolated test-only executable: no Locus signer library, production allowlist
# change, runtime key import, or release-artifact embedding. Fetch this separate
# locked graph explicitly: a clean CI runner's production signer cache does not
# contain every fixture version. The subsequent build remains locked/offline.
cargo fetch --locked \
  --manifest-path "$repo_root/Tools/Fixtures/SuiLocalSigner/Cargo.toml"
cargo build --offline --locked \
  --manifest-path "$repo_root/Tools/Fixtures/SuiLocalSigner/Cargo.toml" \
  --target-dir "$temp_dir/fixture-build"
fixture_signer="$temp_dir/fixture-build/debug/locus-sui-local-fixture-signer"
[[ -x "$fixture_signer" ]] || { print -u2 'error: independent Sui fixture signer is unavailable'; exit 1; }
archive="${LOCUS_SUI_ARCHIVE:-$temp_dir/$asset}"
if [[ ! -f "$archive" ]]; then
  curl -fL --proto '=https' --tlsv1.2 \
    "https://github.com/MystenLabs/sui/releases/download/testnet-v1.79.0/$asset" -o "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected" ]] || {
  print -u2 'error: Sui release archive does not match the reviewed SHA-256'; exit 1
}
mkdir "$temp_dir/bin"
tar -xzf "$archive" -C "$temp_dir/bin"
sui_bin="$(find "$temp_dir/bin" -type f -name sui -print -quit)"
[[ -x "$sui_bin" ]] || { print -u2 'error: reviewed archive has no sui executable'; exit 1; }
version_output="$("$sui_bin" --version)"
[[ "$version_output" == *"$pinned_version"* && "$version_output" == *"${pinned_commit[1,7]}"* ]] || {
  print -u2 'error: Sui executable identity does not match the reviewed release'; exit 1
}
ports=(${(f)"$(python3 -c 'import socket; sockets=[socket.socket() for _ in range(4)]; [s.bind(("127.0.0.1",0)) for s in sockets]; [print(s.getsockname()[1]) for s in sockets]')"})
graphql_url="http://127.0.0.1:${ports[1]}/graphql"
faucet_url="http://127.0.0.1:${ports[2]}"
# SUI_CONFIG_DIR prevents the CLI from updating a developer's real client.yaml.
TMPDIR="$temp_dir/" SUI_CONFIG_DIR="$temp_dir/config" "$sui_bin" start --force-regenesis \
  --with-graphql="127.0.0.1:${ports[1]}" \
  --with-faucet="127.0.0.1:${ports[2]}" \
  --with-consistent-store="127.0.0.1:${ports[3]}" \
  --fullnode-rpc-port "${ports[4]}" --epoch-duration-ms 3600000 \
  >"$temp_dir/localnet.log" 2>&1 &
localnet_pid="$!"
chain_identifier=""
for _ in {1..600}; do
  chain_identifier="$(curl -fsS --max-time 2 -H 'content-type: application/json' \
    --data '{"query":"{ chainIdentifier checkpoint { sequenceNumber } }"}' "$graphql_url" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",{}).get("chainIdentifier", "") if not d.get("errors") else "")' 2>/dev/null || true)"
  [[ -n "$chain_identifier" ]] && break
  kill -0 "$localnet_pid" 2>/dev/null || {
    print -u2 'error: Sui localnet exited before GraphQL was ready'; tail -50 "$temp_dir/localnet.log" >&2; exit 1
  }
  sleep 0.2
done
[[ -n "$chain_identifier" ]] || { print -u2 'error: Sui GraphQL did not become ready'; exit 1; }
cd "$repo_root"
LOCUS_BUNDLE_MODE=skip xcodebuild test -project Locus.xcodeproj \
  -scheme WalletChainIntegration -configuration Debug -destination 'platform=macOS' \
  -only-testing:LocusWalletChainTests/WalletSuiIntegrationTests \
  LOCUS_SUI_LOCALNET_GRAPHQL_URL="$graphql_url" \
  LOCUS_SUI_LOCALNET_FAUCET_URL="$faucet_url" \
  LOCUS_SUI_LOCALNET_CHAIN_IDENTIFIER="$chain_identifier" \
  LOCUS_SUI_FIXTURE_SIGNER_BIN="$fixture_signer" \
  LOCUS_SUI_LOCALNET_VERSION="$pinned_version" "$@"
