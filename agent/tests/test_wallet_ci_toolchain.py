"""Keep the reviewed connector resolver identical in both wallet CI inputs."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SETUP_NODE = "actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38"


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
