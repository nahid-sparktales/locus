use std::ffi::{CStr, CString, c_char};

/// Public deterministic fixture entropy only. No user key material enters fuzzing.
#[allow(dead_code)] // The calldata-only target deliberately has no key input.
pub const ENTROPY: &CStr = c"0000000000000000000000000000000000000000000000000000000000000000";

pub fn request(bytes: &[u8]) -> Option<CString> {
    if bytes.len() > 16 * 1024 {
        return None;
    }
    CString::new(bytes).ok()
}

pub fn check_response(pointer: *mut c_char) {
    assert!(!pointer.is_null(), "FFI must return an owned JSON response");
    // libFuzzer + ASan check the production allocator/free pair and terminator.
    let bytes = unsafe { CStr::from_ptr(pointer) }.to_bytes().to_vec();
    unsafe { locus_wallet_signer_core::locus_wallet_string_free(pointer) };
    assert!(bytes.len() <= 64 * 1024, "unbounded FFI response");
    let value: serde_json::Value = serde_json::from_slice(&bytes).expect("FFI JSON");
    assert!(value.is_object(), "FFI response must be an object");
}
