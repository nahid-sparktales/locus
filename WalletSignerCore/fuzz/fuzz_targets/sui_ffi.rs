#![no_main]
mod common;
use libfuzzer_sys::fuzz_target;
use locus_wallet_signer_core::*;
fuzz_target!(|bytes: &[u8]| {
    if let Some(request) = common::request(bytes) {
        for operation in [
            locus_wallet_prepare_sui_native_transfer_json,
            locus_wallet_sign_sui_native_transfer_json,
            locus_wallet_prepare_sui_coin_transfer_json,
            locus_wallet_sign_sui_coin_transfer_json,
            locus_wallet_prepare_sui_object_transfer_json,
            locus_wallet_sign_sui_object_transfer_json,
        ] {
            common::check_response(operation(common::ENTROPY.as_ptr(), request.as_ptr()));
        }
    }
});
