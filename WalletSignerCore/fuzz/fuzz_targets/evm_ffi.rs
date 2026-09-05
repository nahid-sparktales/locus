#![no_main]
mod common;
use libfuzzer_sys::fuzz_target;
use locus_wallet_signer_core::*;
fuzz_target!(|bytes: &[u8]| {
    if let Some(request) = common::request(bytes) {
        common::check_response(locus_wallet_prepare_evm_transaction_json(
            common::ENTROPY.as_ptr(),
            request.as_ptr(),
        ));
        common::check_response(locus_wallet_sign_evm_transaction_json(
            common::ENTROPY.as_ptr(),
            request.as_ptr(),
        ));
    }
});
