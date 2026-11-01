import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class TestLiveCameraOrder(unittest.TestCase):
    def test_native_reorder_has_drag_handles_save_and_discard_without_server_writes(self):
        editor = (ROOT / "App/Views/LiveCameraOrderView.swift").read_text(encoding="utf-8")
        self.assertIn(".onMove", editor)
        self.assertIn(".environment(\\.editMode, .constant(.active))", editor)
        self.assertIn("setCurrentCameraOrder", editor)
        self.assertIn("Discard camera order changes?", editor)
        self.assertNotIn("api.action", editor)
        self.assertNotIn("HorizonAPI(", editor)

    def test_grid_pauses_for_reorder_and_save_revalidates_account_and_snapshot(self):
        live = (ROOT / "App/Views/LiveView.swift").read_text(encoding="utf-8")
        self.assertIn('Button("Reorder"', live)
        self.assertIn("!showCameraOrder", live)
        self.assertIn("cameraOrderScope == preferenceScope", live)
        self.assertIn("currentPreferences == snapshot", live)
        self.assertIn("cameraOrderSnapshot = nil", live)
        self.assertIn("model.cameras.filter(\\.isLiveDashboardCamera)", live)

    def test_live_grid_groups_and_tour_share_enabled_dashboard_policy(self):
        preferences = (ROOT / "Sources/HorizonCore/CameraDashboardPreferences.swift").read_text(encoding="utf-8")
        self.assertIn("settings.enabled && settings.ui?.dashboard != false", preferences)
        self.assertIn("available.filter(\\.isLiveDashboardCamera)", preferences)
        groups = (ROOT / "App/Views/SavedCameraGroupsView.swift").read_text(encoding="utf-8")
        self.assertNotIn("settings.ui?.dashboard", groups)
        self.assertIn("cameras.filter(\\.isLiveDashboardCamera)", groups)
        tour = (ROOT / "Sources/HorizonCore/CameraTour.swift").read_text(encoding="utf-8")
        self.assertIn("isLiveDashboardCamera", tour)

    def test_disabled_camera_history_and_saved_account_namespace_remain_available(self):
        recordings = (ROOT / "App/Views/RecordingsView.swift").read_text(encoding="utf-8")
        self.assertNotIn("isLiveDashboardCamera", recordings)
        live = (ROOT / "App/Views/LiveView.swift").read_text(encoding="utf-8")
        self.assertIn('"liveDashboard.v2."', live)
        self.assertIn("HorizonAccountScope.key", live)
        self.assertIn("UserDefaults.standard.set(data, forKey: scope)", live)
