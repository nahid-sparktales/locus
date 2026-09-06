"""Artifact edition audit using synthetic files, never real credentials or apps."""

import importlib.util
import sys
from pathlib import Path

import pytest
from artifact_fixtures import make_synthetic_app, write_info

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("app_edition_audit", ROOT / "Tools/AuditAppEdition.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


@pytest.fixture
def artifact(tmp_path, monkeypatch):
    monkeypatch.setattr(audit, "inspect_output", lambda _command: "_main\n")
    return lambda edition="locus", **options: make_synthetic_app(tmp_path, edition, **options)


@pytest.mark.parametrize("edition,mode", [("locus", "manual"), ("locus", "appStore"), ("locusx", "manual")])
def test_valid_artifact_edition_and_distribution_are_independent(artifact, edition, mode):
    app, _ = artifact(edition, mode=mode)
    result = audit.audit(app, edition)
    assert result["passed"] is True
    assert result["edition"] == edition
    assert result["bundled_backend"] is True
    assert result["mach_o_files"] > 0


@pytest.mark.parametrize("edition", ["locus", "locusx"])
def test_audit_accepts_the_factory_from_the_actual_staging_tool(tmp_path, edition):
    staging_spec = importlib.util.spec_from_file_location("edition_staging", ROOT / "Tools/StageBackendEdition.py")
    staging = importlib.util.module_from_spec(staging_spec)
    staging_spec.loader.exec_module(staging)
    staged = tmp_path / "ollama_code"
    staging.stage_backend(ROOT / "agent/ollama_code", staged, edition)
    audit.audit_backend_factory(staged / "product_build.py", edition)


@pytest.mark.parametrize("edition", ["locus", "locusx"])
def test_another_editions_backend_factory_cannot_pass_the_artifact_audit(artifact, edition):
    app, _ = artifact(edition)
    other = "locusx" if edition == "locus" else "locus"
    other_app, _ = artifact(other)
    relative = "Contents/Resources/AgentRuntime/source/ollama_code/product_build.py"
    (app / relative).write_bytes((other_app / relative).read_bytes())
    with pytest.raises(audit.AuditError, match="factory does not match"):
        audit.audit(app, edition)


@pytest.mark.parametrize("change", ["bundle_identity", "callback_scheme", "constructor", "rebound_constructor", "runtime_toggle"])
def test_fixed_backend_factory_rejects_identity_or_execution_changes(artifact, change):
    app, _ = artifact()
    factory = app / "Contents/Resources/AgentRuntime/source/ollama_code/product_build.py"
    source = factory.read_text()
    if change == "bundle_identity":
        source = source.replace("io.sparktales.locus", "io.sparktales.locusx")
    elif change == "callback_scheme":
        source = source.replace("PRODUCT_URL_SCHEME = 'locus'", "PRODUCT_URL_SCHEME = 'locusx'")
    elif change == "constructor":
        source = source.replace("return ProductFeatures(registry)", "return None")
    elif change == "rebound_constructor":
        source += "\nProductFeatures = dict\n"
    else:
        source += "\nimport os\nPRODUCT_NAME = os.environ.get('LOCUS_EDITION', PRODUCT_NAME)\n"
    factory.write_text(source)
    with pytest.raises(audit.AuditError, match="factory does not match"):
        audit.audit(app, "locus")


def test_backend_factory_inspection_never_executes_its_contents(artifact, tmp_path):
    app, _ = artifact()
    factory = app / "Contents/Resources/AgentRuntime/source/ollama_code/product_build.py"
    marker = tmp_path / "must-not-exist"
    factory.write_text(factory.read_text() + f"\nopen({str(marker)!r}, 'w').write('executed')\n")
    with pytest.raises(audit.AuditError, match="factory does not match"):
        audit.audit(app, "locus")
    assert not marker.exists()


@pytest.mark.parametrize("field,value", [
    ("CFBundleIdentifier", "io.sparktales.locusx"),
    ("CFBundleName", "LocusX"),
    ("CFBundleName", "LocusX Experimental"),
    ("LocusEdition", "locusx"),
    ("LocusUpdateMode", "automatic"),
    ("SUFeedURL", "https://example.invalid/legacy-wallet/appcast.xml"),
    ("LocusWalletReleaseActivationURL", "https://example.invalid/activation.json"),
])
def test_standard_artifact_rejects_wrong_identity_or_live_update_configuration(artifact, field, value):
    app, info = artifact()
    info[field] = value
    write_info(app, info)
    with pytest.raises(audit.AuditError):
        audit.audit(app, "locus")


@pytest.mark.parametrize("schemes", [[], ["locusx"], ["locus", "locusx"], ["locus", "locus-wallet"]])
def test_standard_artifact_rejects_missing_or_cross_edition_callbacks(artifact, schemes):
    app, info = artifact()
    info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": schemes}]
    write_info(app, info)
    with pytest.raises(audit.AuditError):
        audit.audit(app, "locus")


@pytest.mark.parametrize("relative", [
    "XPCServices/WalletSigner.xpc/payload",
    "Helpers/WalletRecovery.app/payload",
    "Resources/WalletConnections.bundle.js",
    "Resources/LocusReownSwift_WalletConnectSign.bundle/payload",
    "Resources/AgentRuntime/source/ollama_code/_locusx/wallet.py",
])
def test_standard_artifact_rejects_wallet_payloads_anywhere_in_bundle(artifact, relative):
    app, _ = artifact()
    path = app / "Contents" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("synthetic payload")
    with pytest.raises(audit.AuditError, match="Wallet payload"):
        audit.audit(app, "locus")


@pytest.mark.parametrize("suffix,content", [
    (".py", "WALLET_TOOL_SCHEMAS = []"),
    (".json", '{"name":"wallet_prepare_transaction"}'),
    (".js", "globalThis.locusWallet = {}"),
])
def test_standard_artifact_rejects_wallet_content_under_innocent_filenames(artifact, suffix, content):
    app, _ = artifact()
    (app / "Contents/Resources" / f"shared{suffix}").write_text(content)
    with pytest.raises(audit.AuditError, match="Wallet content"):
        audit.audit(app, "locus")


@pytest.mark.parametrize("inspection", ["/usr/bin/nm", "/usr/bin/strings"])
def test_standard_artifact_audits_hidden_debug_library_symbols(artifact, monkeypatch, inspection):
    app, _ = artifact()
    library = app / "Contents/MacOS/Locus.debug.dylib"
    library.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic debug library")
    inspected = []

    def output(command):
        inspected.append(command)
        return "WalletGateway" if command == [inspection, str(library)] else "_main\n"

    monkeypatch.setattr(audit, "inspect_output", output)
    with pytest.raises(audit.AuditError, match="Wallet code in MacOS/Locus.debug.dylib"):
        audit.audit(app, "locus")
    assert [inspection, str(library)] in inspected


def test_inspection_failure_is_not_treated_as_no_wallet_code():
    with pytest.raises(audit.AuditError, match="Inspection failed"):
        audit.inspect_output([sys.executable, "-c", "print('clean'); raise SystemExit(7)"])


def test_internal_framework_symlinks_remain_valid_but_external_links_are_rejected(artifact, tmp_path):
    app, _ = artifact()
    resources = app / "Contents/Resources"
    (resources / "alias").symlink_to("AgentRuntime", target_is_directory=True)
    assert audit.audit(app, "locus")["passed"]
    external = tmp_path / "outside.py"
    external.write_text("WALLET_TOOL_SCHEMAS = []")
    (resources / "shared.py").symlink_to(external)
    with pytest.raises(audit.AuditError, match="symlink escapes"):
        audit.audit(app, "locus")


def test_broken_bundle_symlink_is_not_an_uninspected_payload(artifact):
    app, _ = artifact()
    (app / "Contents/Resources/shared.py").symlink_to("absent.py")
    with pytest.raises(audit.AuditError, match="Broken bundle symlink"):
        audit.audit(app, "locus")


def test_compile_only_runtime_waiver_does_not_waive_wallet_or_identity_checks(artifact):
    app, info = artifact(runtime=False)
    with pytest.raises(audit.AuditError, match="Bundled backend source is missing"):
        audit.audit(app, "locus")
    assert audit.audit(app, "locus", allow_missing_runtime=True)["passed"]
    info["CFBundleIdentifier"] = "io.sparktales.locusx"
    write_info(app, info)
    with pytest.raises(audit.AuditError, match="identity"):
        audit.audit(app, "locus", allow_missing_runtime=True)


@pytest.mark.parametrize("relative", [
    "XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
    "Helpers/WalletRecovery.app/Contents/MacOS/WalletRecovery",
    "Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner",
    "Resources/WalletConnections.bundle.js",
    "Resources/AgentRuntime/source/ollama_code/_locusx/wallet.py",
])
def test_wallet_edition_still_requires_its_signing_recovery_and_backend_components(artifact, relative):
    app, _ = artifact("locusx")
    (app / "Contents" / relative).unlink()
    with pytest.raises(audit.AuditError, match="missing"):
        audit.audit(app, "locusx")
