//! Network-isolated signing primitives for the Locus WalletSigner XPC service.
//!
//! The C surface exchanges UTF-8 JSON so Swift owns all transport and storage.
//! Secret-bearing responses are consumed only inside the XPC process.

use std::ffi::{CStr, CString, c_char};

use alloy::consensus::{SignableTransaction, TxEip1559, TxEnvelope};
use alloy::dyn_abi::{JsonAbiExt, Specifier};
use alloy::eips::eip2718::Encodable2718;
use alloy::json_abi::JsonAbi;
use alloy::network::TxSignerSync;
use alloy::primitives::{Address, Bytes, TxKind, U256, keccak256};
use alloy::signers::local::MnemonicBuilder;
use alloy::signers::local::coins_bip39::English;
use bip39::{Language, Mnemonic};
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use slip10_ed25519::derive_ed25519_private_key;
use solana_pubkey::Pubkey;
use sui_crypto::ed25519::Ed25519PrivateKey;
use zeroize::Zeroize;

#[derive(Serialize)]
struct GeneratedVault {
    entropy_hex: String,
    words: Vec<String>,
}

#[derive(Serialize)]
struct ErrorResponse<'a> {
    error: &'a str,
}

#[derive(Serialize)]
struct DerivedAccount {
    id: &'static str,
    chain: &'static str,
    address: String,
    label: &'static str,
    network_ids: Vec<&'static str>,
}

#[derive(Serialize)]
struct DerivedAccounts {
    accounts: Vec<DerivedAccount>,
}

#[derive(Clone, Deserialize)]
struct EvmTransactionRequest {
    chain_id: u64,
    nonce: u64,
    gas_limit: u64,
    max_fee_per_gas: String,
    max_priority_fee_per_gas: String,
    to: String,
    value: String,
    input: String,
}

#[derive(Serialize)]
struct PreparedEvmTransaction {
    from: String,
    digest: String,
}

#[derive(Serialize)]
struct SignedEvmTransaction {
    from: String,
    digest: String,
    raw_transaction: String,
    transaction_hash: String,
}

#[derive(Deserialize)]
struct TypedContractArgument {
    #[serde(rename = "type")]
    ty: String,
    value: String,
}

#[derive(Deserialize)]
struct ContractCallRequest {
    normalized_abi: String,
    function: String,
    arguments: Vec<TypedContractArgument>,
}

#[derive(Serialize)]
struct EncodedContractCall {
    input: String,
}

fn json_pointer<T: Serialize>(value: &T) -> *mut c_char {
    let json = serde_json::to_string(value)
        .unwrap_or_else(|_| "{\"error\":\"serialization failed\"}".into());
    CString::new(json).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Generate 256 bits of entropy and the corresponding 24 English BIP-39 words.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_generate_vault_json() -> *mut c_char {
    match Mnemonic::generate_in_with(&mut bip39::rand::thread_rng(), Language::English, 24) {
        Ok(mnemonic) => {
            let mut entropy = mnemonic.to_entropy();
            let result = GeneratedVault {
                entropy_hex: hex::encode(&entropy),
                words: mnemonic.words().map(str::to_owned).collect(),
            };
            entropy.zeroize();
            json_pointer(&result)
        }
        Err(_) => json_pointer(&ErrorResponse {
            error: "secure mnemonic generation failed",
        }),
    }
}

fn mnemonic_from_entropy_hex(value: *const c_char) -> Result<(Mnemonic, Vec<u8>), &'static str> {
    if value.is_null() {
        return Err("missing entropy");
    }
    // SAFETY: Callers provide a live NUL-terminated CString for the duration
    // of the synchronous FFI call.
    let text = unsafe { CStr::from_ptr(value) }.to_string_lossy();
    let entropy = hex::decode(text.as_ref()).map_err(|_| "invalid entropy")?;
    let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy)
        .map_err(|_| "invalid BIP-39 entropy")?;
    Ok((mnemonic, entropy))
}

fn evm_signer(
    mnemonic: &Mnemonic,
) -> Result<alloy::signers::local::PrivateKeySigner, &'static str> {
    let mut phrase = mnemonic.to_string();
    let result = MnemonicBuilder::<English>::default()
        .phrase(phrase.clone())
        .derivation_path("m/44'/60'/0'/0/0")
        .and_then(|builder| builder.build())
        .map_err(|_| "EVM derivation failed");
    phrase.zeroize();
    result
}

fn parse_evm_request(value: *const c_char) -> Result<EvmTransactionRequest, &'static str> {
    if value.is_null() {
        return Err("missing transaction");
    }
    // SAFETY: Callers provide a live NUL-terminated CString for this call.
    let json = unsafe { CStr::from_ptr(value) }.to_bytes();
    serde_json::from_slice(json).map_err(|_| "invalid transaction JSON")
}

fn build_evm_transaction(request: &EvmTransactionRequest) -> Result<TxEip1559, &'static str> {
    if request.chain_id != 11_155_111 {
        return Err("only Sepolia transactions are supported");
    }
    let to = request
        .to
        .parse::<Address>()
        .map_err(|_| "invalid recipient address")?;
    let value =
        U256::from_str_radix(&request.value, 10).map_err(|_| "invalid transaction value")?;
    let max_fee_per_gas = request
        .max_fee_per_gas
        .parse::<u128>()
        .map_err(|_| "invalid max fee per gas")?;
    let max_priority_fee_per_gas = request
        .max_priority_fee_per_gas
        .parse::<u128>()
        .map_err(|_| "invalid priority fee")?;
    if max_priority_fee_per_gas > max_fee_per_gas {
        return Err("priority fee exceeds max fee");
    }
    let input_text = request.input.strip_prefix("0x").unwrap_or(&request.input);
    let input = hex::decode(input_text).map_err(|_| "invalid transaction input")?;
    Ok(TxEip1559 {
        chain_id: request.chain_id,
        nonce: request.nonce,
        gas_limit: request.gas_limit,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        to: TxKind::Call(to),
        value,
        access_list: Default::default(),
        input: Bytes::from(input),
    })
}

/// Resolve a registered JSON ABI function and encode typed string arguments.
/// This is deliberately separate from transaction signing so native code can
/// simulate the signer-produced calldata before asking the signer to store an
/// immutable intent.
///
/// # Safety
/// `request_json` must point to a live NUL-terminated string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn locus_wallet_encode_contract_call_json(
    request_json: *const c_char,
) -> *mut c_char {
    if request_json.is_null() {
        return json_pointer(&ErrorResponse {
            error: "missing contract call",
        });
    }
    // SAFETY: The XPC caller owns this NUL-terminated string for the call.
    let request_bytes = unsafe { CStr::from_ptr(request_json) }.to_bytes();
    if request_bytes.len() > 512 * 1024 {
        return json_pointer(&ErrorResponse {
            error: "contract call is too large",
        });
    }
    let result = (|| {
        let request: ContractCallRequest =
            serde_json::from_slice(request_bytes).map_err(|_| "invalid contract call JSON")?;
        if request.arguments.len() > 64 {
            return Err("too many contract arguments");
        }
        let abi: JsonAbi = serde_json::from_str(&request.normalized_abi)
            .map_err(|_| "invalid registered JSON ABI")?;
        let function = abi
            .functions()
            .find(|candidate| candidate.signature() == request.function)
            .ok_or("function is absent from the registered ABI")?;
        if function.inputs.len() != request.arguments.len() {
            return Err("contract argument count does not match the ABI");
        }
        let mut values = Vec::with_capacity(request.arguments.len());
        for (parameter, argument) in function.inputs.iter().zip(&request.arguments) {
            let ty = parameter
                .resolve()
                .map_err(|_| "unsupported ABI parameter type")?;
            if ty.sol_type_name().as_ref() != argument.ty {
                return Err("typed argument does not match the canonical ABI type");
            }
            values.push(
                ty.coerce_str(&argument.value)
                    .map_err(|_| "argument value is invalid for its ABI type")?,
            );
        }
        let input = function
            .abi_encode_input(&values)
            .map_err(|_| "ABI input encoding failed")?;
        Ok::<_, &'static str>(EncodedContractCall {
            input: format!("0x{}", hex::encode(input)),
        })
    })();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Canonically encode an unsigned EIP-1559 transaction and return its exact
/// signing digest. The XPC service stores the validated fields associated with
/// this digest; callers never get a signing primitive for arbitrary messages.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_prepare_evm_transaction_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signer = evm_signer(&mnemonic)?;
        let transaction = build_evm_transaction(&parse_evm_request(transaction_json)?)?;
        Ok::<_, &'static str>(PreparedEvmTransaction {
            from: signer.address().to_string(),
            digest: transaction.signature_hash().to_string(),
        })
    })();
    entropy.zeroize();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Rebuild and sign the exact validated EIP-1559 fields. Returning signed bytes
/// is the only operation that releases transaction material from the signer.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_sign_evm_transaction_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signer = evm_signer(&mnemonic)?;
        let mut transaction = build_evm_transaction(&parse_evm_request(transaction_json)?)?;
        let digest = transaction.signature_hash();
        let signature = signer
            .sign_transaction_sync(&mut transaction)
            .map_err(|_| "EVM transaction signing failed")?;
        let envelope = TxEnvelope::Eip1559(transaction.into_signed(signature));
        let raw = envelope.encoded_2718();
        Ok::<_, &'static str>(SignedEvmTransaction {
            from: signer.address().to_string(),
            digest: digest.to_string(),
            transaction_hash: keccak256(&raw).to_string(),
            raw_transaction: format!("0x{}", hex::encode(raw)),
        })
    })();
    entropy.zeroize();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Derive one public account for each supported chain. Private keys and the
/// BIP-39 seed are zeroized before this function returns.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_derive_accounts_json(entropy_hex: *const c_char) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let mut phrase = mnemonic.to_string();
    let mut seed = mnemonic.to_seed("");

    let evm_signer = match evm_signer(&mnemonic) {
        Ok(value) => value,
        Err(_) => {
            entropy.zeroize();
            seed.zeroize();
            phrase.zeroize();
            return json_pointer(&ErrorResponse {
                error: "EVM derivation failed",
            });
        }
    };

    let mut solana_secret = derive_ed25519_private_key(&seed, &[44, 501, 0, 0]);
    let solana_public = SigningKey::from_bytes(&solana_secret)
        .verifying_key()
        .to_bytes();
    let solana_address = Pubkey::new_from_array(solana_public).to_string();

    let mut sui_secret = derive_ed25519_private_key(&seed, &[44, 784, 0, 0, 0]);
    let sui_private = Ed25519PrivateKey::new(sui_secret);
    let sui_address = sui_private.public_key().derive_address().to_string();

    let result = DerivedAccounts {
        accounts: vec![
            DerivedAccount {
                id: "locus-vault-evm-0",
                chain: "evm",
                address: evm_signer.address().to_string(),
                label: "Locus Vault EVM",
                network_ids: vec!["eip155:11155111"],
            },
            DerivedAccount {
                id: "locus-vault-solana-0",
                chain: "solana",
                address: solana_address,
                label: "Locus Vault Solana",
                network_ids: vec!["solana:devnet"],
            },
            DerivedAccount {
                id: "locus-vault-sui-0",
                chain: "sui",
                address: sui_address,
                label: "Locus Vault Sui",
                network_ids: vec!["sui:testnet"],
            },
        ],
    };

    solana_secret.zeroize();
    sui_secret.zeroize();
    seed.zeroize();
    phrase.zeroize();
    entropy.zeroize();
    json_pointer(&result)
}

/// Release a string returned by this library.
///
/// # Safety
/// `value` must be a pointer returned by this library and must be freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn locus_wallet_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: `value` must be returned exactly once by `CString::into_raw`
        // in this library. Swift wraps every call in `defer`.
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_vault_has_256_bit_entropy_and_24_words() {
        let pointer = locus_wallet_generate_vault_json();
        assert!(!pointer.is_null());
        // SAFETY: pointer is live until the matching free below.
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["entropy_hex"].as_str().unwrap().len(), 64);
        assert_eq!(value["words"].as_array().unwrap().len(), 24);
    }

    #[test]
    fn bip39_vector_round_trips() {
        let mut entropy = vec![0_u8; 32];
        let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy).unwrap();
        assert_eq!(mnemonic.words().count(), 24);
        assert_eq!(
            mnemonic.to_string(),
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
        );
        assert_eq!(mnemonic.to_entropy(), entropy);
        entropy.zeroize();
    }

    #[test]
    fn all_three_paths_are_deterministic() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let first = locus_wallet_derive_accounts_json(entropy.as_ptr());
        // SAFETY: pointer is live until freed.
        let first_json = unsafe { CStr::from_ptr(first) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(first) };
        let second = locus_wallet_derive_accounts_json(entropy.as_ptr());
        // SAFETY: pointer is live until freed.
        let second_json = unsafe { CStr::from_ptr(second) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(second) };
        assert_eq!(first_json, second_json);
        let value: serde_json::Value = serde_json::from_str(&first_json).unwrap();
        assert_eq!(value["accounts"].as_array().unwrap().len(), 3);
        assert_eq!(
            value["accounts"][0]["address"],
            "0xF278cF59F82eDcf871d630F28EcC8056f25C1cdb"
        );
        assert_eq!(
            value["accounts"][1]["address"],
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        );
        assert_eq!(
            value["accounts"][2]["address"],
            "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
        );
    }

    #[test]
    fn evm_signature_recovers_to_derived_address() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let (mnemonic, mut entropy_bytes) = mnemonic_from_entropy_hex(entropy.as_ptr()).unwrap();
        let signer = evm_signer(&mnemonic).unwrap();
        let request = EvmTransactionRequest {
            chain_id: 11_155_111,
            nonce: 7,
            gas_limit: 21_000,
            max_fee_per_gas: "3000000000".into(),
            max_priority_fee_per_gas: "1000000000".into(),
            to: "0x1111111111111111111111111111111111111111".into(),
            value: "12345".into(),
            input: "0x".into(),
        };
        let mut transaction = build_evm_transaction(&request).unwrap();
        let digest = transaction.signature_hash();
        let signature = signer.sign_transaction_sync(&mut transaction).unwrap();
        assert_eq!(
            signature.recover_address_from_prehash(&digest).unwrap(),
            signer.address()
        );
        entropy_bytes.zeroize();
    }

    #[test]
    fn eip1559_prepare_and_sign_use_the_same_canonical_digest() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let transaction = CString::new(
            r#"{"chain_id":11155111,"nonce":7,"gas_limit":21000,"max_fee_per_gas":"3000000000","max_priority_fee_per_gas":"1000000000","to":"0x1111111111111111111111111111111111111111","value":"12345","input":"0x"}"#,
        )
        .unwrap();
        let prepared_pointer =
            locus_wallet_prepare_evm_transaction_json(entropy.as_ptr(), transaction.as_ptr());
        let prepared_json = unsafe { CStr::from_ptr(prepared_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(prepared_pointer) };
        let signed_pointer =
            locus_wallet_sign_evm_transaction_json(entropy.as_ptr(), transaction.as_ptr());
        let signed_json = unsafe { CStr::from_ptr(signed_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(signed_pointer) };
        let prepared: serde_json::Value = serde_json::from_str(&prepared_json).unwrap();
        let signed: serde_json::Value = serde_json::from_str(&signed_json).unwrap();
        assert_eq!(prepared["digest"], signed["digest"]);
        assert_eq!(prepared["from"], signed["from"]);
        assert!(
            signed["raw_transaction"]
                .as_str()
                .unwrap()
                .starts_with("0x02")
        );
        assert_eq!(signed["transaction_hash"].as_str().unwrap().len(), 66);
    }

    #[test]
    fn evm_transaction_core_rejects_non_sepolia_chain() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let transaction = CString::new(
            r#"{"chain_id":1,"nonce":0,"gas_limit":21000,"max_fee_per_gas":"1","max_priority_fee_per_gas":"1","to":"0x1111111111111111111111111111111111111111","value":"0","input":"0x"}"#,
        )
        .unwrap();
        let pointer =
            locus_wallet_prepare_evm_transaction_json(entropy.as_ptr(), transaction.as_ptr());
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        assert!(json.contains("only Sepolia"));
    }

    #[test]
    fn registered_abi_call_is_encoded_from_typed_arguments() {
        let request = CString::new(
            r#"{"normalized_abi":"[{\"type\":\"function\",\"name\":\"transfer\",\"stateMutability\":\"nonpayable\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\"}]}]","function":"transfer(address,uint256)","arguments":[{"type":"address","value":"0x1111111111111111111111111111111111111111"},{"type":"uint256","value":"42"}]}"#,
        )
        .unwrap();
        let pointer = unsafe { locus_wallet_encode_contract_call_json(request.as_ptr()) };
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let input = value["input"].as_str().unwrap();
        assert!(input.starts_with("0xa9059cbb"));
        assert_eq!(input.len(), 2 + 8 + 64 + 64);
    }

    #[test]
    fn registered_abi_call_rejects_mismatched_argument_type() {
        let request = CString::new(
            r#"{"normalized_abi":"[{\"type\":\"function\",\"name\":\"set\",\"stateMutability\":\"nonpayable\",\"inputs\":[{\"name\":\"value\",\"type\":\"uint256\"}],\"outputs\":[]}]","function":"set(uint256)","arguments":[{"type":"address","value":"0x1111111111111111111111111111111111111111"}]}"#,
        )
        .unwrap();
        let pointer = unsafe { locus_wallet_encode_contract_call_json(request.as_ptr()) };
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        assert!(json.contains("typed argument does not match"));
    }
}
