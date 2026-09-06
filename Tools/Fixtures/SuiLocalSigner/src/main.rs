//! Isolated localnet fixture signer. Never link this into a shipped product.
//! It has one deliberately public test key, no key import and no network I/O.
use std::io::{self, Read};
use sui_crypto::{SuiSigner, ed25519::Ed25519PrivateKey};
use sui_sdk_types::{Command, Transaction, TransactionKind, bcs::FromBcs};

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    operation: String,
    transaction_bcs: Option<String>,
}

fn run() -> Result<serde_json::Value, &'static str> {
    if std::env::args().collect::<Vec<_>>() != [
        std::env::args().next().unwrap_or_default(), "--local-fixture-only".to_owned(),
    ] {
        return Err("explicit local fixture invocation is required");
    }
    let mut data = Vec::new();
    io::stdin().take(65_537).read_to_end(&mut data).map_err(|_| "fixture input failed")?;
    if data.len() > 65_536 { return Err("fixture input is excessive"); }
    let request: Request = serde_json::from_slice(&data).map_err(|_| "invalid fixture input")?;
    let key = Ed25519PrivateKey::new([9; 32]); // Public test fixture; never fund outside localnet.
    let address = key.public_key().derive_address();
    if request.operation == "address" && request.transaction_bcs.is_none() {
        return Ok(serde_json::json!({ "address": address.to_string() }));
    }
    if request.operation != "sign" { return Err("unsupported fixture operation"); }
    let bcs = request.transaction_bcs.ok_or("missing fixture transaction")?;
    let transaction = Transaction::from_bcs_base64(&bcs).map_err(|_| "invalid fixture BCS")?;
    if transaction.sender != address || transaction.gas_payment.owner != address {
        return Err("fixture sender or gas owner mismatch");
    }
    let TransactionKind::ProgrammableTransaction(program) = &transaction.kind else {
        return Err("fixture transaction kind is unavailable");
    };
    if program.inputs.len() > 3 || program.commands.is_empty() || program.commands.len() > 2
        || !program.commands.iter().all(|command| matches!(command,
            Command::TransferObjects(_) | Command::SplitCoins(_))) {
        return Err("fixture supports only narrow transfer commands");
    }
    let signature = key.sign_transaction(&transaction).map_err(|_| "fixture signing failed")?;
    Ok(serde_json::json!({
        "address": address.to_string(),
        "transaction_digest": transaction.digest().to_string(),
        "signature": signature.to_base64(),
    }))
}

fn main() {
    match run() {
        Ok(result) => println!("{result}"),
        Err(error) => {
            // Never echo input BCS or signature material on failure.
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
