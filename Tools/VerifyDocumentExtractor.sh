#!/bin/zsh
# Exercises the real PDFKit/Vision helper without UI permissions. Set
# LOCUS_TEST_DOCUMENT_EXTRACTOR to verify an already signed app helper.
set -euo pipefail
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/locus-document-check.XXXXXX")"
trap '/bin/rm -rf "${work}"' EXIT
extractor="${LOCUS_TEST_DOCUMENT_EXTRACTOR:-${work}/extractor}"
if [[ -z "${LOCUS_TEST_DOCUMENT_EXTRACTOR:-}" ]]; then
    /usr/bin/xcrun swiftc -target arm64-apple-macosx14.0 \
        -framework AppKit -framework PDFKit -framework Vision -framework CryptoKit \
        "${repo_root}/DocumentExtractor/main.swift" -o "${extractor}"
fi
[[ -x "${extractor}" ]] || { echo "error: document helper is not executable" >&2; exit 1; }
/usr/bin/xcrun swift "${repo_root}/DocumentExtractor/Tests/Fixtures.swift" "${work}"
python="${LOCUS_TEST_PYTHON:-${repo_root}/.agent-runtime/cpython/bin/python3}"
"${python}" - "${work}" "${extractor}" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
extractor = pathlib.Path(sys.argv[2])
def extract(name, mode="auto"):
    path = root / name
    request = {
        "protocol_version": 1, "request_id": "native-test", "path": str(path),
        "expected_hash": hashlib.sha256(path.read_bytes()).hexdigest(),
        "ocr_mode": mode, "ocr_languages": ["en-US"],
    }
    result = subprocess.run([str(extractor)], input=json.dumps(request)+"\n", text=True, capture_output=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    records = [json.loads(line) for line in result.stdout.splitlines()]
    assert records[-1]["type"] == "result" and records[-1]["ok"]
    return records

mixed = extract("mixed.pdf")
segments = [item for item in mixed if item["type"] == "segment"]
assert any("24680" in item["text"] and item["method"] == "embedded" and item["locator"]["page"] == 1 for item in segments), segments
assert any("12345" in item["text"] and item["method"] == "ocr" and item["locator"]["page_index"] == 1 for item in segments), segments
assert any("67890" in item["text"] and item["method"] == "ocr" and item["locator"]["page"] == 3 for item in segments), segments
for item in segments:
    bounds = item["locator"].get("bounds")
    if bounds:
        assert all(0 <= value <= 1 for value in bounds.values()), bounds
forced = extract("mixed.pdf", "always")
assert all(item["method"] == "ocr" for item in forced if item["type"] == "segment")
bounded = extract("page-limit.pdf")
assert bounded[-1]["truncated"] and any("500" in warning for warning in bounded[-1]["warnings"])
assert max(item["locator"]["page"] for item in bounded if item["type"] == "segment") == 500
print("Document helper: embedded text, scanned OCR, rotation, forced OCR, page locators and 500-page limit passed.")
PY
