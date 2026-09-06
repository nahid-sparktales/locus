#!/usr/bin/env python3
"""Materialize binary seeds from reviewed public fixtures; never mutate source corpora."""
import base64
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "FuzzCorpus"


def main() -> None:
    output = Path(sys.argv[1]).resolve()
    source_map = {
        "evm_ffi": ["rust-ffi/evm-transaction.json"],
        "solana_ffi": ["rust-ffi/solana-native.json"],
        "sui_ffi": ["rust-ffi/sui-native.json"],
        "authorization_ffi": ["rust-ffi/authorization.json"],
        "calldata_ffi": ["rust-ffi/calldata.json"],
        "connections": ["connections/public-record.json"],
        "metadata": ["metadata/public-asset.json"],
        "namespaces": ["connections/namespace-proposal.json"],
        "authorization": ["authorization/siwe.txt", "authorization/siws.txt"],
        "quote_math": ["quote/integer-operands.txt"],
    }
    seeds: dict[str, list[bytes]] = {
        target: [(CORPUS / name).read_bytes() for name in names]
        for target, names in source_map.items()
    }
    seeds["evm_decoder"] = [bytes.fromhex((CORPUS / "evm/erc20-transfer.hex").read_text().strip().removeprefix("0x"))]
    seeds["sui_decoder"] = [base64.b64decode((CORPUS / "sui/native-transfer.b64").read_text().strip(), validate=True)]
    # Canonical legacy System transfer, one zeroed signature and no lookup tables.
    seed = json.loads((CORPUS / "solana/native-transfer.json").read_text())
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    number = 0
    for char in seed["feePayer"]:
        number = number * 58 + alphabet.index(char)
    sender = number.to_bytes(32, "big")
    message = bytes([1, 0, 1, 3]) + sender + bytes([seed["recipientByte"]]) * 32 + bytes(32)
    message += bytes([seed["recentBlockhashByte"]]) * 32
    message += bytes([1, 2, 2, 0, 1, 12]) + (2).to_bytes(4, "little") + int(seed["amountBaseUnits"]).to_bytes(8, "little")
    seeds["solana_decoder"] = [bytes([1]) + bytes(64) + message]
    branches = json.loads((CORPUS / "transactions/decoder-branches.json").read_text())
    if not isinstance(branches, list) or not 1 <= len(branches) <= 64:
        raise ValueError("Invalid synthetic decoder branch catalog")
    names = set()
    for branch in branches:
        target, name = branch["target"], branch["name"]
        if target not in ("solana_decoder", "sui_decoder") or (target, name) in names:
            raise ValueError("Unknown or duplicate synthetic decoder branch")
        names.add((target, name))
        value = base64.b64decode(branch["transactionBase64"], validate=True)
        if not value or len(value) > 16_384 or base64.b64encode(value).decode() != branch["transactionBase64"]:
            raise ValueError("Invalid synthetic decoder transaction")
        seeds[target].append(value)
    for target, values in seeds.items():
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        for value in values:
            (directory / hashlib.sha256(value).hexdigest()).write_bytes(value)
    print(f"Materialized public seeds for {len(seeds)} production fuzz targets")


if __name__ == "__main__":
    main()
