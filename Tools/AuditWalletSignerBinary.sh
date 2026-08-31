#!/bin/zsh
# The production Rust FFI is deliberately smaller than the in-process signing
# core. Any new exported Locus wallet capability requires security review.
set -euo pipefail

binary="${1:?usage: AuditWalletSignerBinary.sh <WalletSigner executable>}"
[[ -x "${binary}" ]] || {
    echo "error: WalletSigner executable is missing" >&2
    exit 1
}

actual="$(/usr/bin/nm -gU "${binary}" \
    | /usr/bin/awk '$NF ~ /^_locus_wallet_/ { print substr($NF, 2) }' \
    | /usr/bin/sort -u)"
expected="$(/usr/bin/printf '%s\n' \
    locus_wallet_derive_accounts_json \
    locus_wallet_derive_solana_associated_token_json \
    locus_wallet_encode_contract_call_json \
    locus_wallet_generate_vault_json \
    locus_wallet_prepare_evm_transaction_json \
    locus_wallet_prepare_solana_native_transfer_json \
    locus_wallet_prepare_solana_spl_transfer_json \
    locus_wallet_restore_vault_json \
    locus_wallet_sign_evm_transaction_json \
    locus_wallet_sign_solana_native_transfer_json \
    locus_wallet_sign_solana_spl_transfer_json \
    locus_wallet_string_free)"

[[ "${actual}" == "${expected}" ]] || {
    echo "error: WalletSigner exported capability surface changed" >&2
    echo "expected:" >&2
    echo "${expected}" >&2
    echo "actual:" >&2
    echo "${actual:-<none>}" >&2
    exit 1
}

echo "WalletSigner exported capability surface is locked."
