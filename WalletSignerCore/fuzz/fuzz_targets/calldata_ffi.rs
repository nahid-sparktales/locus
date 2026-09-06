#![no_main]
mod common;
use libfuzzer_sys::fuzz_target;
use locus_wallet_signer_core::*;
fuzz_target!(|bytes: &[u8]| {
    if let Some(request) = common::request(bytes) {
        common::check_response(unsafe { locus_wallet_encode_contract_call_json(request.as_ptr()) });
    }
});
