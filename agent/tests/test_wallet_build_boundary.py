"""Exercise the real shell matching helper using synthetic output, never binaries."""

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/AuditWalletBuildBoundary.sh"
DISTRIBUTION = ROOT / "Tools/AuditDistribution.sh"


@pytest.fixture(params=[SCRIPT, DISTRIBUTION], ids=["build-boundary", "distribution"])
def script(request):
    return request.param


def invoke(tmp_path, producer, pattern="SyntheticForbiddenIdentity", *, script=SCRIPT):
    source = script.read_text()
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
def test_large_forbidden_producer_is_rejected_without_sigpipe_false_negative(tmp_path, position, script):
    producer = (
        "import sys; padding='synthetic-clean-line\\n'*100000; "
        "forbidden='SyntheticForbiddenIdentity\\n'; "
        f"sys.stdout.write(forbidden+padding if {position!r} == 'first' else padding+forbidden)"
    )
    result = invoke(tmp_path, producer, script=script)
    assert result.returncode == 1
    assert "forbidden synthetic output" in result.stderr
    assert result.stdout == ""
    assert (tmp_path / "inspection.stdout").stat().st_size > 1_000_000


def test_large_clean_producer_passes(tmp_path, script):
    result = invoke(tmp_path, "import sys; sys.stdout.write('synthetic-clean-line\\n'*100000)", script=script)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ""


@pytest.mark.parametrize("output", ["", "synthetic-clean", "SyntheticForbiddenIdentity"])
def test_producer_error_is_never_treated_as_absent_forbidden_content(tmp_path, output, script):
    result = invoke(tmp_path, f"import sys; print({output!r}); raise SystemExit(7)", script=script)
    assert result.returncode == 1
    assert "inspection tool failed" in result.stderr


def test_matcher_error_fails_closed(tmp_path, script):
    result = invoke(tmp_path, "print('synthetic-clean')", pattern="[", script=script)
    assert result.returncode == 1
    assert "output inspection failed" in result.stderr


def test_all_forbidden_patterns_stay_under_checked_producer_helper():
    source = SCRIPT.read_text()
    assert "| /usr/bin/grep -Eq" not in source
    assert 'wallet_audit_reject_matching_output "${mas_forbidden}"' in source
    assert source.count('wallet_audit_reject_matching_output "${mas_forbidden}"') == 2
    assert '    /usr/bin/plutil -p "${mas_app}/Contents/Info.plist"' in source


def test_distribution_forbidden_patterns_stay_under_checked_producer_helper():
    source = DISTRIBUTION.read_text()
    assert "| /usr/bin/grep -Eq" not in source
    assert source.count('wallet_audit_reject_matching_output "${mas_connector_forbidden}"') == 2
    assert '    wallet_audit_reject_matching_output \'^  "SU[^" ]*"\'' in source


def invoke_ci(tmp_path, producer, expectation, pattern="SyntheticForbiddenIdentity"):
    source = (ROOT / ".github/workflows/ci.yml").read_text()
    helper = source.split("          # BEGIN release_audit_output\n", 1)[1].split(
        "          # END release_audit_output", 1
    )[0]
    body = (
        "set -euo pipefail\n" + textwrap.dedent(helper)
        + '\nrelease_inspection_dir="$1"; expectation="$2"; pattern="$3"; shift 3\n'
        + 'release_audit_output "$expectation" "$pattern" "$@"\n'
    )
    return subprocess.run(
        ["/bin/bash", "-c", body, "synthetic-ci-inspection", str(tmp_path), expectation, pattern,
         sys.executable, "-c", producer],
        capture_output=True, text=True, timeout=10,
    )


@pytest.mark.parametrize("expectation", ["present", "absent"])
@pytest.mark.parametrize("position", ["first", "last", "missing"])
def test_ci_inspection_checks_complete_large_output(tmp_path, expectation, position):
    producer = (
        "import sys; padding='synthetic-clean-line\\n'*100000; "
        "marker='SyntheticForbiddenIdentity\\n'; "
        f"sys.stdout.write(marker+padding if {position!r}=='first' else "
        f"padding+marker if {position!r}=='last' else padding)"
    )
    result = invoke_ci(tmp_path, producer, expectation)
    expected = 0 if (expectation == "present") == (position != "missing") else 1
    assert result.returncode == expected
    assert result.stdout == ""
    assert (tmp_path / "inspection.stdout").stat().st_size > 1_000_000


@pytest.mark.parametrize("expectation", ["present", "absent"])
@pytest.mark.parametrize("output", ["", "synthetic-clean", "SyntheticForbiddenIdentity"])
def test_ci_inspection_producer_failure_cannot_satisfy_any_expectation(tmp_path, expectation, output):
    result = invoke_ci(tmp_path, f"import sys; print({output!r}); raise SystemExit(7)", expectation)
    assert result.returncode == 1
    assert "producer failed" in result.stderr
    assert result.stdout == ""


@pytest.mark.parametrize("expectation", ["present", "absent"])
def test_ci_inspection_invalid_pattern_fails_closed(tmp_path, expectation):
    result = invoke_ci(tmp_path, "print('synthetic-clean')", expectation, pattern="[")
    assert result.returncode == 1


def test_ci_release_boundary_has_no_early_exit_inspection_pipelines():
    source = (ROOT / ".github/workflows/ci.yml").read_text()
    body = source.split("      - name: Direct and App Store release configurations compile\n", 1)[1].split(
        "\n  mobile:\n", 1
    )[0]
    assert "| grep -q" not in body
    assert "| grep -Eq" not in body
    assert body.count("release_audit_output absent ") == 3
    assert body.count("release_audit_output present ") == 1
