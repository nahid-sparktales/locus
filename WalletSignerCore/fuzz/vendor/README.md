# Reviewed Rust fuzz-engine input

This is the exact locked `libfuzzer-sys` 0.4.13 crate, with one explicit
test-only patch to stop and join its RSS monitor at normal exit. The signer
production workspace does not consume this local override. Do not edit the
global Cargo registry or silently update this input.

`provenance.json` binds the upstream archive/commit, exact patch, full patched
tree and all retained license texts. The crate's older NCSA declaration and
newer LLVM source-header notices are both preserved; license inventory does
not represent counsel approval. The additional upstream compiler-rt license
contains the modern LLVM exceptions and legacy NCSA terms.

`Tools/WalletRustFuzzerDependency.py` verifies that every extracted upstream
file is byte-identical except the one exact patched driver, and rejects a
custom runtime override. The Rust runner records this dependency identity in
every run manifest/receipt before building. Any source or digest change needs
new review and fresh affected downstream evidence; prior findings remain
failures and never gain campaign credit retrospectively.

The monitor still checks RSS every second. Normal shutdown signals and joins
the thread; failure callbacks retain their upstream immediate nonzero exit
behavior. No leak suppressions or sanitizer/limit reductions are introduced.

The opt-in `Tools/TestWalletRustFuzzerMonitor.py --compiler /absolute/reviewed/clang++ --output /absolute/new/path`
requires Homebrew Clang 21.1.8, records its exact compiler/runtime identities,
and passes an ASan/LSan startup probe before running any engine controls.
It builds this engine and runs clean, intentional-leak,
crash, timeout and RSS negative controls under the shared execution lock.
Those synthetic results are not a Rust-target campaign, do not use the
production signer, and cannot count toward release CPU hours. Real pinned
Rust replay and timed smoke still must pass on the exact clean candidate.
