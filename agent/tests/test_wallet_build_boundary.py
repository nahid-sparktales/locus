"""Exercise the real shell matching helper using synthetic output, never binaries."""

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/AuditWalletBuildBoundary.sh"


def invoke(tmp_path, producer, pattern="SyntheticForbiddenIdentity"):
    source = SCRIPT.read_text()
    helper = source.split("# BEGIN wallet_audit_reject_matching_output\n", 1)[1].split(
        "# END wallet_audit_reject_matching_output", 1
    )[0]
    body = (
        'set -euo pipefail\n' + helper
        + '\naudit_temp_dir="$1"; pattern="$2"; shift 2\n'
        + 'wallet_audit_reject_matching_output "$pattern" "forbidden synthetic output" "$@"\n'
    )
    return subprocess.run(
        ["/bin/zsh", "-c", body, "synthetic-boundary-test", str(tmp_path), pattern,
         sys.executable, "-c", producer],
        capture_output=True, text=True, timeout=10,
    )


@pytest.mark.parametrize("position", ["first", "last"])
def test_large_forbidden_producer_is_rejected_without_sigpipe_false_negative(tmp_path, position):
    producer = (
        "import sys; padding='synthetic-clean-line\\n'*100000; "
        "forbidden='SyntheticForbiddenIdentity\\n'; "
        f"sys.stdout.write(forbidden+padding if {position!r} == 'first' else padding+forbidden)"
    )
    result = invoke(tmp_path, producer)
    assert result.returncode == 1
    assert "forbidden synthetic output" in result.stderr
    assert result.stdout == ""
    assert (tmp_path / "inspection.stdout").stat().st_size > 1_000_000


def test_large_clean_producer_passes(tmp_path):
    result = invoke(tmp_path, "import sys; sys.stdout.write('synthetic-clean-line\\n'*100000)")
    assert result.returncode == 0
    assert result.stdout == result.stderr == ""


@pytest.mark.parametrize("output", ["", "synthetic-clean", "SyntheticForbiddenIdentity"])
def test_producer_error_is_never_treated_as_absent_forbidden_content(tmp_path, output):
    result = invoke(tmp_path, f"import sys; print({output!r}); raise SystemExit(7)")
    assert result.returncode == 1
    assert "inspection tool failed" in result.stderr


def test_matcher_error_fails_closed(tmp_path):
    result = invoke(tmp_path, "print('synthetic-clean')", pattern="[")
    assert result.returncode == 1
    assert "output inspection failed" in result.stderr


def test_all_forbidden_patterns_stay_under_checked_producer_helper():
    source = SCRIPT.read_text()
    assert "| /usr/bin/grep -Eq" not in source
    assert 'wallet_audit_reject_matching_output "${mas_forbidden}"' in source
    assert source.count('wallet_audit_reject_matching_output "${mas_forbidden}"') == 2
    assert '    /usr/bin/plutil -p "${mas_app}/Contents/Info.plist"' in source
