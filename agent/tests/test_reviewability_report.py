from Tools import ReviewabilityReport as report


def test_app_model_growth_reports_published_state_and_view_actions() -> None:
    patch = """\
diff --git a/Locus/AppModel.swift b/Locus/AppModel.swift
--- a/Locus/AppModel.swift
+++ b/Locus/AppModel.swift
@@ -1,0 +1,3 @@
+    @Published var newFeatureState = false
+    func startNewFeature() {}
+    private func connectNewFeature() {}
"""

    finding = report._composition_root_patch_finding(report.APP_MODEL_PATH, patch)

    assert finding is not None
    assert finding.level == "attention"
    assert "1 published state declaration" in finding.detail
    assert "1 view-facing action" in finding.detail


def test_composition_wiring_does_not_report_app_model_growth() -> None:
    patch = """\
diff --git a/Locus/AppModel.swift b/Locus/AppModel.swift
--- a/Locus/AppModel.swift
+++ b/Locus/AppModel.swift
@@ -1,0 +1,3 @@
+    let workspaceFiles = WorkspaceFileModel()
+    private var workspaceFilesBridge: AnyCancellable?
+        workspaceFiles.configure(workspacePath: { self.workspacePath })
"""

    assert report._composition_root_patch_finding(report.APP_MODEL_PATH, patch) is None


def test_server_growth_reports_only_registered_route_handlers() -> None:
    patch = """\
diff --git a/agent/ollama_code/server.py b/agent/ollama_code/server.py
--- a/agent/ollama_code/server.py
+++ b/agent/ollama_code/server.py
@@ -1,0 +1,5 @@
+def create_app():
+    pass
+
+async def evaluation_restart():
+    pass
"""

    finding = report._composition_root_patch_finding(
        report.SERVER_PATH,
        patch,
        registered_server_handlers={"evaluation_restart"},
    )

    assert finding is not None
    assert "1 registered API handler" in finding.detail


def test_server_composition_helpers_are_not_treated_as_route_handlers() -> None:
    patch = "+def create_app():\n+    pass\n"

    assert (
        report._composition_root_patch_finding(
            report.SERVER_PATH,
            patch,
            registered_server_handlers={"health"},
        )
        is None
    )
