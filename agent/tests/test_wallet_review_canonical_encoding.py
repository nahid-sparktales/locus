"""Real CLI signatures must match the typed runtime JSONEncoder domain.

Only disposable keys and non-activating empty review ceilings are used. The
independent Swift oracle has typed fields matching WalletReviewCeiling and an
empty WalletReviewScope; it does not use either CLI's dynamic JSON adapter.
"""

from __future__ import annotations

import base64
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
ORACLE = r'''
import CryptoKit
import Foundation

struct EmptyRecord: Codable {}
struct RuntimeScope: Codable {
    let assets: [EmptyRecord]
    let evmContracts: [EmptyRecord]
    let explorerTemplates: [String: String]
    let adapterIDs: [String]
    let connectors: [EmptyRecord]
    let providerIdentities: [EmptyRecord]
    let signInAdapters: [EmptyRecord]
    let programIdentities: [EmptyRecord]
    let uniswapConfigurations: [EmptyRecord]
}
struct RuntimeCeiling: Codable {
    let schemaVersion: Int
    let domain: String
    let reviewRevision: Int
    let reviewedAt: Date
    let scope: RuntimeScope
}
struct RuntimeSignedCeiling: Codable {
    let ceiling: RuntimeCeiling
    let signatureBase64: String
}
struct JSONNull: Codable {
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encodeNil()
    }
    init() {}
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard value.decodeNil() else { throw CocoaError(.coderReadCorrupt) }
    }
}
struct RuntimeVector: Encodable {
    let reviewRevision: Int64 = 9_007_199_254_740_993
    let reviewedAt = "2024-01-01T00:00:00Z"
    let maxUnsigned = UInt64.max
    let minSigned = Int64.min
    let maxSigned = Int64.max
    let beyondUnsigned = Decimal(string: "18446744073709551616")!
    let flag = true
    let falseFlag = false
    let null = JSONNull()
    let text = "slash/ quote\" backslash\\ control\n café \u{2028}"
    let array: [Int64] = [0, -1, 9_007_199_254_740_993, Int64.max, Int64.min]
    let empty: [Int] = []
    let object: [String: UInt64] = ["reviewedAt": UInt64.max, "reviewRevision": 0,
                                  "Z": 1, "a": 2, "a10": 10, "a2": 2, "é": 3]
    let fraction = 1.25
}
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let mode = CommandLine.arguments[1]
if mode == "vector" {
    FileHandle.standardOutput.write(try encoder.encode(RuntimeVector()))
    exit(0)
}
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
if mode == "key" {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedData().write(to: keyURL, options: .atomic)
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation:
    Data(base64Encoded: Data(contentsOf: keyURL))!)
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
if mode == "sign" || mode == "legacy-sign" {
    let ceiling = try decoder.decode(RuntimeCeiling.self, from: bytes)
    let payload = mode == "sign" ? try encoder.encode(ceiling)
        : try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes),
            options: [.sortedKeys, .withoutEscapingSlashes])
    let signed = RuntimeSignedCeiling(ceiling: ceiling,
        signatureBase64: try key.signature(for: payload).base64EncodedString())
    FileHandle.standardOutput.write(try encoder.encode(signed))
} else {
    let signed = try decoder.decode(RuntimeSignedCeiling.self, from: bytes)
    let payload = try encoder.encode(signed.ceiling)
    let signature = Data(base64Encoded: signed.signatureBase64)!
    guard key.publicKey.isValidSignature(signature, for: payload) else { exit(2) }
    let result = ["canonicalBase64": payload.base64EncodedString(),
                  "signedCanonicalBase64": try encoder.encode(signed).base64EncodedString(),
                  "sha256": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()]
    FileHandle.standardOutput.write(try encoder.encode(result))
}
'''


def run(*arguments: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(value) for value in arguments], capture_output=True, text=True, timeout=90, check=False
    )


@pytest.fixture(scope="module")
def canonical_tools(tmp_path_factory):
    if sys.platform != "darwin" or shutil.which("xcrun") is None:
        pytest.skip("the signing CLI requires macOS Swift/CryptoKit")
    folder = tmp_path_factory.mktemp("review-canonical-runtime")
    oracle_source = folder / "typed-runtime-oracle.swift"
    oracle_source.write_text(ORACLE)
    binaries = {"oracle": folder / "oracle", "review": folder / "review"}
    sources = {"oracle": oracle_source, "review": ROOT / "Tools/SignWalletReviewManifest.swift"}
    for name, filename, marker, function in [
        ("review-canonical", "SignWalletReviewManifest.swift", "\ndo {\n", "canonicalObject"),
        ("activation-canonical", "SignWalletReleaseActivation.swift", "\nif CommandLine.arguments.count", "canonical"),
    ]:
        source = (ROOT / "Tools" / filename).read_text()
        assert marker in source
        # Keep the real definitions intact; replace only the top-level CLI
        # invocation to exercise canonical JSON types outside the review schema.
        harness = source.split(marker, 1)[0] + f'''
let input = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), options: [.fragmentsAllowed])
FileHandle.standardOutput.write(try {function}(input))
'''
        sources[name] = folder / f"{name}.swift"
        sources[name].write_text(harness)
        binaries[name] = folder / name
    for name, source in sources.items():
        result = run("xcrun", "swiftc", source, "-o", binaries[name])
        assert result.returncode == 0, result.stderr
    key = folder / "disposable-test-key.base64"
    generated = run(binaries["oracle"], "key", key)
    assert generated.returncode == 0, generated.stderr
    key.chmod(0o600)
    binaries.update(key=key, public=generated.stdout.strip())
    return binaries


def ceiling(revision: int) -> dict:
    return {
        "schemaVersion": 1,
        "domain": "locus-wallet-review-ceiling-v1",
        "reviewRevision": revision,
        "reviewedAt": "2024-01-01T00:00:00Z",
        "scope": {
            "assets": [], "evmContracts": [], "explorerTemplates": {}, "adapterIDs": [],
            "connectors": [], "providerIdentities": [], "signInAdapters": [],
            "programIdentities": [], "uniswapConfigurations": [],
        },
    }


@pytest.mark.parametrize("revision", [1, 2**53 + 1, 2**63 - 1])
def test_actual_review_cli_signs_typed_runtime_bytes_digest_and_signature(
    canonical_tools, tmp_path, revision
):
    source, signed = tmp_path / "ceiling.json", tmp_path / "signed.json"
    source.write_text(json.dumps(ceiling(revision)))
    result = run(canonical_tools["review"], "--sign-ceiling", source, canonical_tools["key"], signed)
    assert result.returncode == 0, result.stderr
    oracle = run(canonical_tools["oracle"], "verify", canonical_tools["key"], signed)
    assert oracle.returncode == 0, oracle.stderr
    info = json.loads(oracle.stdout)
    payload = base64.b64decode(info["canonicalBase64"])
    assert b'"reviewRevision"' in payload
    assert payload.index(b'"reviewRevision"') < payload.index(b'"reviewedAt"')
    assert json.loads(payload)["reviewRevision"] == revision
    assert info["sha256"] == hashlib.sha256(payload).hexdigest()
    assert f"review_ceiling_sha256={info['sha256']}" in result.stdout
    verified = run(canonical_tools["review"], "--verify-ceiling", signed, canonical_tools["public"])
    assert verified.returncode == 0, verified.stderr
    assert signed.read_bytes() == base64.b64decode(info["signedCanonicalBase64"]), (
        "The same signed value must have identical CLI and typed runtime bytes"
    )


def test_review_cli_accepts_typed_runtime_signature_but_not_legacy_sorted_keys(
    canonical_tools, tmp_path
):
    source = tmp_path / "ceiling.json"
    source.write_text(json.dumps(ceiling(1)))
    for mode, expected_success in [("sign", True), ("legacy-sign", False)]:
        signed = tmp_path / f"{mode}.json"
        generated = run(canonical_tools["oracle"], mode, canonical_tools["key"], source)
        assert generated.returncode == 0, generated.stderr
        signed.write_text(generated.stdout)
        result = run(canonical_tools["review"], "--verify-ceiling", signed, canonical_tools["public"])
        assert (result.returncode == 0) is expected_success
        if not expected_success:
            assert "signature differs" in result.stderr


@pytest.mark.parametrize("tool", ["review-canonical", "activation-canonical"])
def test_canonical_json_matches_typed_numeric_boolean_null_string_array_object_vector(
    canonical_tools, tmp_path, tool
):
    expected = run(canonical_tools["oracle"], "vector")
    assert expected.returncode == 0, expected.stderr
    source = tmp_path / "vector.json"
    source.write_text(expected.stdout)
    actual = run(canonical_tools[tool], source)
    assert actual.returncode == 0, actual.stderr
    assert actual.stdout == expected.stdout
    values = json.loads(actual.stdout)
    assert values["reviewRevision"] == 2**53 + 1
    assert values["maxSigned"] == 2**63 - 1
    assert values["minSigned"] == -(2**63)
    assert values["maxUnsigned"] == 2**64 - 1
    assert values["beyondUnsigned"] == 2**64
    assert values["flag"] is True and values["falseFlag"] is False
    assert values["null"] is None


@pytest.mark.parametrize("value", [2**53, 2**53 + 1, 2**63 - 1, 2**63, 2**64 - 1, -(2**63)])
def test_distinct_large_integer_values_are_never_rounded(canonical_tools, tmp_path, value):
    source = tmp_path / "integer.json"
    source.write_text(str(value))
    outputs = [run(canonical_tools[name], source) for name in ("review-canonical", "activation-canonical")]
    for output in outputs:
        assert output.returncode == 0, output.stderr
        assert output.stdout == str(value)
