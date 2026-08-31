//! Network-isolated signing primitives for the Locus WalletSigner XPC service.
//!
//! The C surface exchanges UTF-8 JSON so Swift owns all transport and storage.
//! Secret-bearing responses are consumed only inside the XPC process.

use std::ffi::{CStr, CString, c_char};
use std::str::FromStr;

use alloy::consensus::{SignableTransaction, TxEip1559, TxEnvelope};
use alloy::dyn_abi::{JsonAbiExt, Specifier};
use alloy::eips::eip2718::Encodable2718;
use alloy::json_abi::JsonAbi;
use alloy::network::TxSignerSync;
use alloy::primitives::{Address, Bytes, TxKind, U256, keccak256};
use alloy::signers::local::MnemonicBuilder;
use alloy::signers::local::coins_bip39::English;
use base64::Engine;
use bip39::{Language, Mnemonic};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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

#[derive(Clone, Deserialize)]
struct SolanaNativeTransferRequest {
    fee_payer: String,
    recipient: String,
    recent_blockhash: String,
    amount_base_units: String,
}

#[derive(Clone, Deserialize)]
struct SolanaSplTransferRequest {
    fee_payer: String,
    source_token_account: String,
    mint: String,
    destination_token_account: String,
    recipient_owner: String,
    token_program_id: String,
    recent_blockhash: String,
    amount_base_units: String,
    decimals: u8,
}

#[derive(Serialize)]
struct PreparedSolanaTransaction {
    from: String,
    canonical_message_digest: String,
}

#[derive(Serialize)]
struct SignedSolanaTransaction {
    from: String,
    canonical_message_digest: String,
    transaction_id: String,
    signed_transaction: String,
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

/// Validate and canonicalize one 24-word English BIP-39 recovery phrase. The
/// phrase is accepted only by the network-isolated recovery/signer process;
/// callers receive entropy solely so it can be encrypted into the local vault.
///
/// # Safety
/// `phrase` must point to a live NUL-terminated UTF-8 string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn locus_wallet_restore_vault_json(phrase: *const c_char) -> *mut c_char {
    if phrase.is_null() {
        return json_pointer(&ErrorResponse {
            error: "missing recovery phrase",
        });
    }
    // SAFETY: The recovery service owns this NUL-terminated string for the
    // duration of the synchronous call.
    let bytes = unsafe { CStr::from_ptr(phrase) }.to_bytes();
    if bytes.len() > 512 {
        return json_pointer(&ErrorResponse {
            error: "recovery phrase is too large",
        });
    }
    let Ok(mut phrase_text) = std::str::from_utf8(bytes).map(str::to_owned) else {
        return json_pointer(&ErrorResponse {
            error: "recovery phrase is not UTF-8",
        });
    };
    let parsed = Mnemonic::parse_in_normalized(Language::English, &phrase_text);
    phrase_text.zeroize();
    let Ok(mnemonic) = parsed else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 recovery phrase",
        });
    };
    if mnemonic.word_count() != 24 {
        return json_pointer(&ErrorResponse {
            error: "Locus Vault requires exactly 24 recovery words",
        });
    }
    let mut entropy = mnemonic.to_entropy();
    let result = GeneratedVault {
        entropy_hex: hex::encode(&entropy),
        words: mnemonic.words().map(str::to_owned).collect(),
    };
    entropy.zeroize();
    json_pointer(&result)
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
    if ![1, 11_155_111].contains(&request.chain_id) {
        return Err("unsupported EVM chain ID");
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

fn solana_signing_key(mnemonic: &Mnemonic) -> SigningKey {
    let mut seed = mnemonic.to_seed("");
    let mut secret = derive_ed25519_private_key(&seed, &[44, 501, 0, 0]);
    let key = SigningKey::from_bytes(&secret);
    secret.zeroize();
    seed.zeroize();
    key
}

fn parse_solana_request(value: *const c_char) -> Result<SolanaNativeTransferRequest, &'static str> {
    if value.is_null() {
        return Err("missing Solana transaction");
    }
    // SAFETY: Callers provide a live NUL-terminated CString for this call.
    let json = unsafe { CStr::from_ptr(value) }.to_bytes();
    if json.len() > 16 * 1024 {
        return Err("Solana transaction is too large");
    }
    serde_json::from_slice(json).map_err(|_| "invalid Solana transaction JSON")
}

fn parse_solana_spl_request(
    value: *const c_char,
) -> Result<SolanaSplTransferRequest, &'static str> {
    if value.is_null() {
        return Err("missing SPL transaction");
    }
    // SAFETY: Callers provide a live NUL-terminated CString for this call.
    let json = unsafe { CStr::from_ptr(value) }.to_bytes();
    if json.len() > 16 * 1024 {
        return Err("SPL transaction is too large");
    }
    serde_json::from_slice(json).map_err(|_| "invalid SPL transaction JSON")
}

fn encode_shortvec(mut value: usize, output: &mut Vec<u8>) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        output.push(byte);
        if value == 0 {
            return;
        }
    }
}

fn build_solana_native_message(
    request: &SolanaNativeTransferRequest,
    signing_key: &SigningKey,
) -> Result<Vec<u8>, &'static str> {
    let payer = Pubkey::from_str(&request.fee_payer).map_err(|_| "invalid Solana fee payer")?;
    let recipient = Pubkey::from_str(&request.recipient).map_err(|_| "invalid Solana recipient")?;
    let expected_payer = Pubkey::new_from_array(signing_key.verifying_key().to_bytes());
    let system_program = Pubkey::new_from_array([0_u8; 32]);
    if payer != expected_payer || recipient == payer || recipient == system_program {
        return Err("Solana account roles do not match the reviewed transfer");
    }
    let amount = request
        .amount_base_units
        .parse::<u64>()
        .map_err(|_| "invalid SOL transfer amount")?;
    if amount == 0 || amount.to_string() != request.amount_base_units {
        return Err("SOL transfer amount must be a positive canonical u64");
    }
    let blockhash = bs58::decode(&request.recent_blockhash)
        .into_vec()
        .map_err(|_| "invalid Solana blockhash")?;
    if blockhash.len() != 32 || bs58::encode(&blockhash).into_string() != request.recent_blockhash {
        return Err("Solana blockhash must be canonical base58");
    }

    // Legacy message with exactly one System Program transfer instruction.
    // Accounts: fee payer (signer+writable), recipient (writable), System
    // Program (readonly). Instruction data is bincode enum tag 2 + u64 lamports.
    let mut message = vec![1, 0, 1];
    encode_shortvec(3, &mut message);
    message.extend_from_slice(payer.as_array());
    message.extend_from_slice(recipient.as_array());
    message.extend_from_slice(system_program.as_array());
    message.extend_from_slice(&blockhash);
    encode_shortvec(1, &mut message);
    message.push(2);
    encode_shortvec(2, &mut message);
    message.extend_from_slice(&[0, 1]);
    encode_shortvec(12, &mut message);
    message.extend_from_slice(&2_u32.to_le_bytes());
    message.extend_from_slice(&amount.to_le_bytes());
    Ok(message)
}

fn canonical_solana_pubkey(value: &str) -> Result<Pubkey, &'static str> {
    let key = Pubkey::from_str(value).map_err(|_| "invalid Solana public key")?;
    if key.to_string() != value {
        return Err("Solana public key must use canonical base58");
    }
    Ok(key)
}

fn canonical_solana_blockhash(value: &str) -> Result<Vec<u8>, &'static str> {
    let blockhash = bs58::decode(value)
        .into_vec()
        .map_err(|_| "invalid Solana blockhash")?;
    if blockhash.len() != 32 || bs58::encode(&blockhash).into_string() != value {
        return Err("Solana blockhash must be canonical base58");
    }
    Ok(blockhash)
}

fn build_solana_spl_message(
    request: &SolanaSplTransferRequest,
    signing_key: &SigningKey,
) -> Result<Vec<u8>, &'static str> {
    const SPL_TOKEN_PROGRAM: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
    if request.token_program_id != SPL_TOKEN_PROGRAM {
        return Err("only the classic SPL Token Program is reviewed");
    }
    let payer = canonical_solana_pubkey(&request.fee_payer)?;
    let source = canonical_solana_pubkey(&request.source_token_account)?;
    let mint = canonical_solana_pubkey(&request.mint)?;
    let destination = canonical_solana_pubkey(&request.destination_token_account)?;
    let recipient_owner = canonical_solana_pubkey(&request.recipient_owner)?;
    let token_program = canonical_solana_pubkey(&request.token_program_id)?;
    let expected_payer = Pubkey::new_from_array(signing_key.verifying_key().to_bytes());
    let distinct = [
        payer,
        source,
        mint,
        destination,
        recipient_owner,
        token_program,
    ]
    .into_iter()
    .collect::<std::collections::HashSet<_>>();
    if payer != expected_payer || distinct.len() != 6 {
        return Err("SPL account roles do not match the reviewed transfer");
    }
    let amount = request
        .amount_base_units
        .parse::<u64>()
        .map_err(|_| "invalid SPL transfer amount")?;
    if amount == 0 || amount.to_string() != request.amount_base_units {
        return Err("SPL transfer amount must be a positive canonical u64");
    }
    let blockhash = canonical_solana_blockhash(&request.recent_blockhash)?;

    // Legacy message with exactly one SPL Token TransferChecked instruction.
    // Message order: payer, source, destination, mint, program. The instruction
    // account order is source, mint, destination, authority.
    let mut message = vec![1, 0, 2];
    encode_shortvec(5, &mut message);
    message.extend_from_slice(payer.as_array());
    message.extend_from_slice(source.as_array());
    message.extend_from_slice(destination.as_array());
    message.extend_from_slice(mint.as_array());
    message.extend_from_slice(token_program.as_array());
    message.extend_from_slice(&blockhash);
    encode_shortvec(1, &mut message);
    message.push(4);
    encode_shortvec(4, &mut message);
    message.extend_from_slice(&[1, 3, 2, 0]);
    encode_shortvec(10, &mut message);
    message.push(12);
    message.extend_from_slice(&amount.to_le_bytes());
    message.push(request.decimals);
    Ok(message)
}

fn solana_message_digest(message: &[u8]) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(message)))
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

/// Independently rebuild one reviewed legacy System Program transfer and
/// return its exact message digest. No caller-supplied instructions or message
/// bytes cross this boundary.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_prepare_solana_native_transfer_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signing_key = solana_signing_key(&mnemonic);
        let request = parse_solana_request(transaction_json)?;
        let message = build_solana_native_message(&request, &signing_key)?;
        Ok::<_, &'static str>(PreparedSolanaTransaction {
            from: Pubkey::new_from_array(signing_key.verifying_key().to_bytes()).to_string(),
            canonical_message_digest: solana_message_digest(&message),
        })
    })();
    entropy.zeroize();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Rebuild and sign only the reviewed legacy System Program transfer shape.
/// The first Ed25519 signature is also the canonical Solana transaction ID.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_sign_solana_native_transfer_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signing_key = solana_signing_key(&mnemonic);
        let request = parse_solana_request(transaction_json)?;
        let message = build_solana_native_message(&request, &signing_key)?;
        let signature = signing_key.sign(&message).to_bytes();
        let mut transaction = Vec::with_capacity(1 + signature.len() + message.len());
        encode_shortvec(1, &mut transaction);
        transaction.extend_from_slice(&signature);
        transaction.extend_from_slice(&message);
        Ok::<_, &'static str>(SignedSolanaTransaction {
            from: Pubkey::new_from_array(signing_key.verifying_key().to_bytes()).to_string(),
            canonical_message_digest: solana_message_digest(&message),
            transaction_id: bs58::encode(signature).into_string(),
            signed_transaction: base64::engine::general_purpose::STANDARD.encode(transaction),
        })
    })();
    entropy.zeroize();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Independently rebuild one reviewed classic SPL Token TransferChecked
/// instruction. Token-2022 extensions, extra instructions, and caller-supplied
/// message bytes are not accepted by this boundary.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_prepare_solana_spl_transfer_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signing_key = solana_signing_key(&mnemonic);
        let request = parse_solana_spl_request(transaction_json)?;
        let message = build_solana_spl_message(&request, &signing_key)?;
        Ok::<_, &'static str>(PreparedSolanaTransaction {
            from: Pubkey::new_from_array(signing_key.verifying_key().to_bytes()).to_string(),
            canonical_message_digest: solana_message_digest(&message),
        })
    })();
    entropy.zeroize();
    match result {
        Ok(value) => json_pointer(&value),
        Err(error) => json_pointer(&ErrorResponse { error }),
    }
}

/// Rebuild and sign only the reviewed classic SPL TransferChecked shape.
#[unsafe(no_mangle)]
pub extern "C" fn locus_wallet_sign_solana_spl_transfer_json(
    entropy_hex: *const c_char,
    transaction_json: *const c_char,
) -> *mut c_char {
    let Ok((mnemonic, mut entropy)) = mnemonic_from_entropy_hex(entropy_hex) else {
        return json_pointer(&ErrorResponse {
            error: "invalid BIP-39 entropy",
        });
    };
    let result = (|| {
        let signing_key = solana_signing_key(&mnemonic);
        let request = parse_solana_spl_request(transaction_json)?;
        let message = build_solana_spl_message(&request, &signing_key)?;
        let signature = signing_key.sign(&message).to_bytes();
        let mut transaction = Vec::with_capacity(1 + signature.len() + message.len());
        encode_shortvec(1, &mut transaction);
        transaction.extend_from_slice(&signature);
        transaction.extend_from_slice(&message);
        Ok::<_, &'static str>(SignedSolanaTransaction {
            from: Pubkey::new_from_array(signing_key.verifying_key().to_bytes()).to_string(),
            canonical_message_digest: solana_message_digest(&message),
            transaction_id: bs58::encode(signature).into_string(),
            signed_transaction: base64::engine::general_purpose::STANDARD.encode(transaction),
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
                network_ids: vec!["eip155:1", "eip155:11155111"],
            },
            DerivedAccount {
                id: "locus-vault-solana-0",
                chain: "solana",
                address: solana_address,
                label: "Locus Vault Solana",
                network_ids: vec!["solana:mainnet-beta", "solana:devnet"],
            },
            DerivedAccount {
                id: "locus-vault-sui-0",
                chain: "sui",
                address: sui_address,
                label: "Locus Vault Sui",
                network_ids: vec!["sui:mainnet", "sui:testnet"],
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
    fn recovery_phrase_restores_canonical_entropy() {
        let phrase = CString::new(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        )
        .unwrap();
        let pointer = unsafe { locus_wallet_restore_vault_json(phrase.as_ptr()) };
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            value["entropy_hex"],
            "0000000000000000000000000000000000000000000000000000000000000000"
        );
        assert_eq!(value["words"].as_array().unwrap().len(), 24);
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
    fn solana_native_transfer_is_rebuilt_and_signed_deterministically() {
        use ed25519_dalek::{Signature, Verifier};

        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let recipient = Pubkey::new_from_array([7_u8; 32]).to_string();
        let blockhash = Pubkey::new_from_array([9_u8; 32]).to_string();
        let request = CString::new(
            serde_json::json!({
                "fee_payer": "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
                "recipient": recipient,
                "recent_blockhash": blockhash,
                "amount_base_units": "123456789"
            })
            .to_string(),
        )
        .unwrap();
        let prepared_pointer =
            locus_wallet_prepare_solana_native_transfer_json(entropy.as_ptr(), request.as_ptr());
        let prepared_json = unsafe { CStr::from_ptr(prepared_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(prepared_pointer) };
        let prepared: serde_json::Value = serde_json::from_str(&prepared_json).unwrap();
        assert_eq!(
            prepared["from"],
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        );
        assert_eq!(
            prepared["canonical_message_digest"],
            "sha256:f5d55dd7bde27c8ff2565f8867ded2ec84d5ca0b75ada68aec6c6b3ec305d59d"
        );

        let signed_pointer =
            locus_wallet_sign_solana_native_transfer_json(entropy.as_ptr(), request.as_ptr());
        let signed_json = unsafe { CStr::from_ptr(signed_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(signed_pointer) };
        let signed: serde_json::Value = serde_json::from_str(&signed_json).unwrap();
        assert_eq!(
            signed["canonical_message_digest"],
            prepared["canonical_message_digest"]
        );
        assert_eq!(
            bs58::decode(signed["transaction_id"].as_str().unwrap())
                .into_vec()
                .unwrap()
                .len(),
            64
        );
        let transaction = base64::engine::general_purpose::STANDARD
            .decode(signed["signed_transaction"].as_str().unwrap())
            .unwrap();
        assert_eq!(transaction[0], 1);
        let signature_bytes: [u8; 64] = transaction[1..65].try_into().unwrap();
        let signature = Signature::from_bytes(&signature_bytes);
        let (mnemonic, mut entropy_bytes) = mnemonic_from_entropy_hex(entropy.as_ptr()).unwrap();
        let signing_key = solana_signing_key(&mnemonic);
        signing_key
            .verifying_key()
            .verify(&transaction[65..], &signature)
            .unwrap();
        entropy_bytes.zeroize();
    }

    #[test]
    fn solana_native_transfer_rejects_foreign_fee_payer_and_self_transfer() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let foreign = Pubkey::new_from_array([4_u8; 32]).to_string();
        let blockhash = Pubkey::new_from_array([9_u8; 32]).to_string();
        for recipient in [
            Pubkey::new_from_array([7_u8; 32]).to_string(),
            foreign.clone(),
        ] {
            let request = CString::new(
                serde_json::json!({
                    "fee_payer": foreign,
                    "recipient": recipient,
                    "recent_blockhash": blockhash,
                    "amount_base_units": "1"
                })
                .to_string(),
            )
            .unwrap();
            let pointer = locus_wallet_prepare_solana_native_transfer_json(
                entropy.as_ptr(),
                request.as_ptr(),
            );
            let json = unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned();
            unsafe { locus_wallet_string_free(pointer) };
            let value: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert!(value["error"].as_str().is_some());
        }
    }

    #[test]
    fn solana_spl_transfer_checked_is_rebuilt_and_signed_deterministically() {
        use ed25519_dalek::{Signature, Verifier};

        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let request = CString::new(
            serde_json::json!({
                "fee_payer": "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
                "source_token_account": Pubkey::new_from_array([2_u8; 32]).to_string(),
                "mint": Pubkey::new_from_array([3_u8; 32]).to_string(),
                "destination_token_account": Pubkey::new_from_array([4_u8; 32]).to_string(),
                "recipient_owner": Pubkey::new_from_array([5_u8; 32]).to_string(),
                "token_program_id": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                "recent_blockhash": Pubkey::new_from_array([9_u8; 32]).to_string(),
                "amount_base_units": "123456789",
                "decimals": 6
            })
            .to_string(),
        )
        .unwrap();
        let prepared_pointer =
            locus_wallet_prepare_solana_spl_transfer_json(entropy.as_ptr(), request.as_ptr());
        let prepared_json = unsafe { CStr::from_ptr(prepared_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(prepared_pointer) };
        let prepared: serde_json::Value = serde_json::from_str(&prepared_json).unwrap();
        assert_eq!(
            prepared["from"],
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        );
        assert_eq!(
            prepared["canonical_message_digest"],
            "sha256:1e22ab87cedf350790b6bc80e98799dfe043aa04d0e7e1374b9e98b1a3390c7f"
        );

        let signed_pointer =
            locus_wallet_sign_solana_spl_transfer_json(entropy.as_ptr(), request.as_ptr());
        let signed_json = unsafe { CStr::from_ptr(signed_pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(signed_pointer) };
        let signed: serde_json::Value = serde_json::from_str(&signed_json).unwrap();
        assert_eq!(
            signed["canonical_message_digest"],
            prepared["canonical_message_digest"]
        );
        let transaction = base64::engine::general_purpose::STANDARD
            .decode(signed["signed_transaction"].as_str().unwrap())
            .unwrap();
        assert_eq!(transaction.len(), 279);
        assert_eq!(transaction[0], 1);
        let signature = Signature::from_bytes(&transaction[1..65].try_into().unwrap());
        let (mnemonic, mut entropy_bytes) = mnemonic_from_entropy_hex(entropy.as_ptr()).unwrap();
        solana_signing_key(&mnemonic)
            .verifying_key()
            .verify(&transaction[65..], &signature)
            .unwrap();
        entropy_bytes.zeroize();
    }

    #[test]
    fn solana_spl_transfer_rejects_unreviewed_programs_and_role_substitution() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx";
        let source = Pubkey::new_from_array([2_u8; 32]).to_string();
        let mint = Pubkey::new_from_array([3_u8; 32]).to_string();
        let destination = Pubkey::new_from_array([4_u8; 32]).to_string();
        let recipient = Pubkey::new_from_array([5_u8; 32]).to_string();
        let blockhash = Pubkey::new_from_array([9_u8; 32]).to_string();
        let foreign = Pubkey::new_from_array([8_u8; 32]).to_string();
        let token_2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
        let cases = [
            serde_json::json!({
                "fee_payer": payer, "source_token_account": source, "mint": mint,
                "destination_token_account": destination, "recipient_owner": recipient,
                "token_program_id": token_2022, "recent_blockhash": blockhash,
                "amount_base_units": "1", "decimals": 6
            }),
            serde_json::json!({
                "fee_payer": payer, "source_token_account": source, "mint": mint,
                "destination_token_account": destination, "recipient_owner": recipient,
                "token_program_id": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                "recent_blockhash": blockhash, "amount_base_units": "0", "decimals": 6
            }),
            serde_json::json!({
                "fee_payer": foreign, "source_token_account": source, "mint": mint,
                "destination_token_account": destination, "recipient_owner": recipient,
                "token_program_id": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                "recent_blockhash": blockhash, "amount_base_units": "1", "decimals": 6
            }),
            serde_json::json!({
                "fee_payer": payer, "source_token_account": source, "mint": mint,
                "destination_token_account": destination, "recipient_owner": payer,
                "token_program_id": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                "recent_blockhash": blockhash, "amount_base_units": "1", "decimals": 6
            }),
            serde_json::json!({
                "fee_payer": payer, "source_token_account": source, "mint": mint,
                "destination_token_account": source, "recipient_owner": recipient,
                "token_program_id": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                "recent_blockhash": blockhash, "amount_base_units": "1", "decimals": 6
            }),
        ];
        for value in cases {
            let request = CString::new(value.to_string()).unwrap();
            let pointer =
                locus_wallet_prepare_solana_spl_transfer_json(entropy.as_ptr(), request.as_ptr());
            let json = unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned();
            unsafe { locus_wallet_string_free(pointer) };
            assert!(
                serde_json::from_str::<serde_json::Value>(&json).unwrap()["error"]
                    .as_str()
                    .is_some()
            );
        }
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
    fn evm_transaction_core_accepts_ethereum_mainnet() {
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
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["from"], "0xF278cF59F82eDcf871d630F28EcC8056f25C1cdb");
    }

    #[test]
    fn evm_transaction_core_rejects_unknown_chain() {
        let entropy =
            CString::new("0000000000000000000000000000000000000000000000000000000000000000")
                .unwrap();
        let transaction = CString::new(
            r#"{"chain_id":31337,"nonce":0,"gas_limit":21000,"max_fee_per_gas":"1","max_priority_fee_per_gas":"1","to":"0x1111111111111111111111111111111111111111","value":"0","input":"0x"}"#,
        )
        .unwrap();
        let pointer =
            locus_wallet_prepare_evm_transaction_json(entropy.as_ptr(), transaction.as_ptr());
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        assert!(json.contains("unsupported EVM chain ID"));
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
    fn universal_router_outer_call_encodes_typed_bytes_array() {
        let request = CString::new(
            r#"{"normalized_abi":"[{\"type\":\"function\",\"name\":\"execute\",\"stateMutability\":\"payable\",\"inputs\":[{\"name\":\"commands\",\"type\":\"bytes\"},{\"name\":\"inputs\",\"type\":\"bytes[]\"},{\"name\":\"deadline\",\"type\":\"uint256\"}],\"outputs\":[]}]","function":"execute(bytes,bytes[],uint256)","arguments":[{"type":"bytes","value":"0x08"},{"type":"bytes[]","value":"[0x00]"},{"type":"uint256","value":"2000000000"}]}"#,
        )
        .unwrap();
        let pointer = unsafe { locus_wallet_encode_contract_call_json(request.as_ptr()) };
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { locus_wallet_string_free(pointer) };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(value["input"].as_str().unwrap().starts_with("0x3593564c"));
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
