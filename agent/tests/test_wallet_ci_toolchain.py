"""Keep the reviewed connector resolver identical in both wallet CI inputs."""

import re
import subprocess
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SETUP_NODE = "actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38"


@pytest.mark.parametrize("invalid", [None, "Tools/z final script.sh", "agent/run.sh"])
def test_release_syntax_gate_checks_each_quoted_file_without_executing_it(tmp_path, invalid):
    source = (ROOT / ".github/workflows/ci.yml").read_text()
    step = source.split("      - name: Release script syntax\n", 1)[1].split("\n\n", 1)[0]
    assert step.startswith("        run: |\n")
    body = textwrap.dedent(step.split("\n", 1)[1])
    for relative in ("Tools/a.sh", "Tools/z final script.sh", "agent/run.sh"):
        path = tmp_path / relative
        path.parent.mkdir(exist_ok=True)
        path.write_text("if then\n" if relative == invalid else "printf 'MUST NOT EXECUTE'\n")
    result = subprocess.run(
        ["/bin/bash", "-e", "-o", "pipefail", "-c", body],
        cwd=tmp_path, capture_output=True, text=True, timeout=10,
    )
    assert result.stdout == "", "The syntax gate must never execute script contents"
    if invalid is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0, "An invalid late-listed script must fail the gate"
        assert invalid in result.stderr


def test_native_failure_evidence_upload_matches_only_actual_test_result_directories():
    source = (ROOT / ".github/workflows/ci.yml").read_text()
    swift_job = source.split("\n  swift:\n", 1)[1].split("\n  mobile:\n", 1)[0]
    commands, upload = swift_job.split(
        "      - name: Retain native and local-chain result bundles on success or failure\n", 1
    )
    produced = set(re.findall(r'-derivedDataPath "\$RUNNER_TEMP/(locus-debug-[^"/]+)"', commands))
    assert produced == {"locus-debug-tests", "locus-debug-anvil", "locus-debug-solana", "locus-debug-sui"}
    paths = {
        line.strip() for line in upload.splitlines()
        if line.strip().startswith("${{ runner.temp }}")
    }
    assert paths == {f"${{{{ runner.temp }}}}/{directory}/Logs/Test/*.xcresult/**" for directory in produced}
    assert "        if: always()\n" in upload
    assert "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" in upload
    assert "if-no-files-found: error" in upload
    assert "retention-days: 90" in upload
    assert "${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}" in upload
    assert "continue-on-error" not in swift_job
    assert "|| true" not in commands
    assert "if: success()" not in upload


@pytest.mark.parametrize("workflow", ["ci.yml", "wallet-fuzz.yml"])
def test_only_superseded_pr_revisions_preempt_runs_not_explicit_campaigns(workflow):
    source = (ROOT / ".github/workflows" / workflow).read_text()
    before_jobs = source.split("\njobs:", 1)[0]
    assert "\nconcurrency:\n" in before_jobs
    assert "group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}" in before_jobs
    assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in before_jobs
    assert "cancel-in-progress: true" not in before_jobs


@pytest.mark.parametrize(
    "workflow,job", [("ci.yml", "wallet-signer"), ("wallet-fuzz.yml", "inputs")]
)
def test_wallet_inputs_pin_and_verify_the_reviewed_node_and_npm(workflow, job):
    source = (ROOT / ".github/workflows" / workflow).read_text()
    start = re.search(rf"^  {re.escape(job)}:\n", source, re.MULTILINE)
    assert start is not None
    body = re.split(
        r"^  [a-z][a-z0-9_-]*:\n", source[start.end() :], maxsplit=1, flags=re.MULTILINE
    )[0]
    assert body.count(SETUP_NODE) == 1
    assert "node-version: '24.20.0'" in body
    assert "check-latest: false" in body
    assert "package-manager-cache: false" in body
    resolver_install = next(
        line.strip() for line in body.splitlines() if line.strip().startswith("npm install ")
    )
    assert resolver_install.endswith("npm@11.8.0")
    for option in (
        "--no-save",
        "--package-lock=false",
        "--ignore-scripts",
        "--registry=https://registry.npmjs.org",
    ):
        assert option in resolver_install
    assert '--prefix "$RUNNER_TEMP/locus-wallet-npm"' in resolver_install
    assert 'echo "$RUNNER_TEMP/locus-wallet-npm/node_modules/.bin" >> "$GITHUB_PATH"' in body
    for check in ['test "$(node --version)" = "v24.20.0"', 'test "$(npm --version)" = "11.8.0"']:
        assert body.index(SETUP_NODE) < body.index(check) < body.index("npm ci ")
        assert body.index(resolver_install) < body.index(check)
    install = next(line.strip() for line in body.splitlines() if line.strip().startswith("npm ci "))
    assert "--ignore-scripts" in install
    assert "--legacy-peer-deps" not in install
    assert "--omit" not in install
    assert "npm audit --audit-level=high" in body
    assert "npm audit --omit" not in body
    if job == "wallet-signer":
        assert "npm --ignore-scripts run build" in body
        assert "cargo install cargo-audit --version 0.22.2 --locked" in body
