"""Personal-mainnet build/source boundaries, without signing or launching an app."""

import plistlib
import re
import subprocess
from pathlib import Path

import pytest
from artifact_fixtures import make_synthetic_app, write_info

ROOT = Path(__file__).resolve().parents[2]
FLAG = "LocusWalletExperimentalMainnetEnabled"
MACRO = "LOCUS_EXPERIMENTAL_MAINNET"


def block(source: str, header: str) -> str:
    """Read an exact indentation-bounded project.yml block without a YAML dependency."""
    match = re.search(r"^" + re.escape(header) + r"\n", source, re.MULTILINE)
    assert match is not None, header
    indentation = len(header) - len(header.lstrip())
    lines = []
    for line in source[match.end() :].splitlines():
        if line.strip() and len(line) - len(line.lstrip()) <= indentation:
            break
        lines.append(line)
    return "\n".join(lines)


def test_experimental_configuration_preserves_release_compilation_and_signing_boundary():
    source = (ROOT / "project.yml").read_text()
    assert "  ReleaseExperimental: release" in block(source, "configs:")
    global_settings = block(source, "settings:")
    settings = block(global_settings, "    ReleaseExperimental:")
    for setting in (
        "ARCHS: arm64",
        "CODE_SIGN_STYLE: Automatic",
        'CODE_SIGN_IDENTITY: "Apple Development"',
        "DEVELOPMENT_TEAM: 4X4RJA7GMD",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO",
        "ENABLE_HARDENED_RUNTIME: YES",
    ):
        assert setting in settings
    assert "DEBUG" not in settings
    assert MACRO not in global_settings
    assert MACRO not in block(source, "targetTemplates:")
    scheme = block(block(source, "schemes:"), "  LocusExperimental:")
    assert "LocusX: all" in scheme
    assert scheme.count("config: ReleaseExperimental") == 2


def test_only_direct_and_signer_targets_receive_experimental_opt_in():
    targets = block((ROOT / "project.yml").read_text(), "targets:")
    direct = block(targets, "  LocusX:")
    signer = block(targets, "  WalletSignerService:")
    for name in ("Locus", "LocusMAS", "WalletRecoveryApplication", "LocusTests", "LocusUITests"):
        assert MACRO not in block(targets, f"  {name}:")
    assert targets.count(MACRO) == 2
    app_settings = block(direct, "        ReleaseExperimental:")
    signer_settings = block(signer, "        ReleaseExperimental:")
    assert MACRO in app_settings and MACRO in signer_settings
    assert "LOCUS_DIRECT_DOWNLOAD" in app_settings
    assert "PRODUCT_NAME: LocusX Experimental" in app_settings
    assert "PRODUCT_MODULE_NAME: Locus" in app_settings
    assert "EXECUTABLE_NAME: LocusX" in app_settings
    assert "INFOPLIST_FILE: Config/LocusExperimental-Info.plist" in app_settings
    assert "INFOPLIST_FILE: Config/WalletSignerExperimental-Info.plist" in signer_settings
    assert 'LOCUS_WALLET_RELEASE_ACTIVATION_URL: ""' in app_settings
    assert "CODE_SIGN_ENTITLEMENTS" not in app_settings + signer_settings


@pytest.mark.parametrize(
    "base,experimental,is_app",
    [
        ("Config/LocusX-Info.plist", "Config/LocusExperimental-Info.plist", True),
        ("WalletSignerService/Info.plist", "Config/WalletSignerExperimental-Info.plist", False),
    ],
)
def test_experimental_plist_has_only_explicit_channel_differences(base, experimental, is_app):
    expected = plistlib.loads((ROOT / base).read_bytes())
    actual = plistlib.loads((ROOT / experimental).read_bytes())
    assert FLAG not in expected
    assert actual.pop(FLAG) is True
    if is_app:
        for key in ("SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks"):
            expected[key] = False
    assert actual == expected
    mas = plistlib.loads((ROOT / "Config/LocusMAS-Info.plist").read_bytes())
    assert FLAG not in mas


def test_signer_opt_in_is_sealed_and_not_inferred_from_the_request():
    source = (ROOT / "WalletSignerService/WalletSignerService.swift").read_text()
    apply_history = source.split("    func applyReleaseHistory(", 1)[1].split(
        "    func beginRecoveryCeremony(", 1
    )[0]
    assert source.count("WalletReleaseHistoryVerifier.verify(") == 1
    assert (
        apply_history.count("allowExperimentalMainnet: WalletExperimentalMainnetBuild.isEnabled()")
        == 1
    )
    assert "WalletInstalledReleaseIdentity.current(" in apply_history
    assert "WalletSignerReleaseAuthorityStore.store(verified.checkpoint)" in apply_history
    assert "clearActivationBoundAuthority()" in apply_history


def test_signer_policy_authorizes_its_resolved_chain_before_reading_accounts():
    source = (ROOT / "WalletSignerService/WalletSignerService.swift").read_text()
    validation = source.split("    private func validatePolicy(", 1)[1].split(
        "    private func validAutomaticPolicyID(", 1
    )[0]
    resolved = validation.index(
        "guard let descriptor = WalletNetworkCatalog.descriptor(id: policy.networkID)"
    )
    authorized = validation.index(
        "try authorizeNetwork(policy.networkID, chain: descriptor.chain, capability: .autonomousPolicy)"
    )
    accounts = validation.index("let accounts = try store.accounts()")
    assert resolved < authorized < accounts
    assert "authorizeNetwork(policy.networkID, capability:" not in validation
    assert "case .sui: { _ in false }" in validation
    assert "guard nativeEVMPolicy || nativeSolanaPolicy || solanaTokenPolicy" in validation


@pytest.mark.parametrize("script", ["AuditWalletBuildBoundary.sh", "AuditDistribution.sh"])
def test_mas_audits_forbid_experimental_configuration_resources_and_code(script):
    source = (ROOT / "Tools" / script).read_text()
    for forbidden in (
        FLAG,
        MACRO,
        "WalletExperimentalMainnetBuild",
        "*wallet*experimental*",
        "LocusExperimental*",
    ):
        assert forbidden in source


@pytest.mark.parametrize(
    "relative",
    [
        "Contents/Info.plist",
        "Contents/XPCServices/WalletSigner.xpc/Contents/Info.plist",
        "Contents/Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/Info.plist",
    ],
)
def test_production_distribution_audit_rejects_an_experimental_app_before_other_checks(
    tmp_path, relative
):
    app, info = make_synthetic_app(tmp_path, "locusx")
    plist = app / relative
    if relative == "Contents/Info.plist":
        info[FLAG] = True
        write_info(app, info)
    else:
        plist.write_bytes(plistlib.dumps({FLAG: True}))
    result = subprocess.run(
        ["/bin/zsh", str(ROOT / "Tools/AuditDistribution.sh"), str(app)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 1
    assert "personal experimental wallet build is not a production distribution" in result.stderr
    assert result.stdout == ""
