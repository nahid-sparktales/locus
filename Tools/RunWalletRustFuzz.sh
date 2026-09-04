#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
duration="${LOCUS_FUZZ_SECONDS:-60}"
[[ "$duration" == <1-> ]] || { print -u2 'error: LOCUS_FUZZ_SECONDS must be positive'; exit 1; }
[[ "$(cargo fuzz --version)" == 'cargo-fuzz 0.13.2' ]] || {
  print -u2 'error: install cargo-fuzz 0.13.2 with --locked'; exit 1
}
rustup run nightly-2026-09-01 rustc --version >/dev/null
cd "$repo_root/WalletSignerCore"
cargo +nightly-2026-09-01 fetch --locked --manifest-path fuzz/Cargo.toml
lock_digest="$(shasum -a 256 fuzz/Cargo.lock | awk '{print $1}')"
export CARGO_NET_OFFLINE=true
output="${LOCUS_FUZZ_OUTPUT:-$repo_root/build/wallet-fuzz-rust}"
mkdir -p "$output"
python3 "$repo_root/Tools/WalletFuzzCorpus.py" "$output/corpus"
targets=(evm_ffi solana_ffi sui_ffi authorization_ffi calldata_ffi)
if [[ -n "${LOCUS_FUZZ_TARGET:-}" ]]; then targets=("$LOCUS_FUZZ_TARGET"); fi
for fuzz_target in "${targets[@]}"; do
  [[ " $fuzz_target " == ' evm_ffi ' || " $fuzz_target " == ' solana_ffi ' ||
     " $fuzz_target " == ' sui_ffi ' || " $fuzz_target " == ' authorization_ffi ' ||
     " $fuzz_target " == ' calldata_ffi ' ]] || { print -u2 'error: unknown fuzz target'; exit 1; }
  mkdir -p "$output/artifacts/$fuzz_target"
  # cargo-fuzz enables checked Rust arithmetic and ASan on the production
  # signer. Instrumenting libFuzzer's own trace runtime with UBSan recursively
  # instruments sanitizer internals and is not a valid production UB check.
  cargo +nightly-2026-09-01 fuzz run --sanitizer address "$fuzz_target" \
    "$output/corpus/$fuzz_target" -- -runs=0 -max_len=16384 \
    -artifact_prefix="$output/artifacts/$fuzz_target/"
  cargo +nightly-2026-09-01 fuzz run --sanitizer address "$fuzz_target" \
    "$output/corpus/$fuzz_target" -- -max_total_time="$duration" -timeout=10 \
    -max_len=16384 -rss_limit_mb=4096 -print_final_stats=1 \
    -artifact_prefix="$output/artifacts/$fuzz_target/" 2>&1 | tee "$output/$fuzz_target.log"
done
[[ "$(shasum -a 256 fuzz/Cargo.lock | awk '{print $1}')" == "$lock_digest" ]] || {
  print -u2 'error: fuzz dependency lock changed'; exit 1
}
