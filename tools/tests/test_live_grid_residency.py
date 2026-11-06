import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TestLiveGridResidency(unittest.TestCase):
    def test_dashboard_eagerly_instantiates_every_filtered_camera_with_stable_identity(self):
        source = (ROOT / "App/Views/LiveView.swift").read_text(encoding="utf-8")
        dashboard = source.split("@MainActor\nstruct LiveVideoView:")[0]
        self.assertIn("LiveCameraGridLayout(", dashboard)
        self.assertIn("ForEach(dashboardCameras) { camera in", dashboard)
        self.assertNotIn("LazyVGrid", dashboard)
        self.assertNotIn("tracksScrollVisibility", source)
        self.assertNotIn("onScrollVisibilityChange", source)
        self.assertIn("currentPreferences.cameras(from: model.cameras)", dashboard)
        self.assertIn("adaptiveQuality: true", dashboard)

    def test_grid_lifetime_still_ends_when_main_live_or_account_is_inactive(self):
        source = (ROOT / "App/Views/LiveView.swift").read_text(encoding="utf-8")
        self.assertIn("active: active && selected == nil && !showCameraTour", source)
        self.assertIn("!showCameraGroups && !showIncidentReplay && !showCameraOrder", source)
        self.assertIn(".onAppear { visible = true; playback.attach(viewer) }", source)
        self.assertIn("playback.detach(viewer)", source)
        self.assertIn("if phase != .active { playback.deactivateInlineViewer(viewer) }", source)
        self.assertIn("if !value { playback.deactivateInlineViewer(viewer) }", source)
        root = (ROOT / "App/Views/HorizonRoot.swift").read_text(encoding="utf-8")
        self.assertIn("active: selection == .live && restoredCamera == nil", root)
        session = (ROOT / "App/Media/LivePlaybackSession.swift").read_text(encoding="utf-8")
        self.assertIn("pip.permitsInlinePlayback(api: api, cameraID: cameraID)", session)
        self.assertIn("guard hasInlineViewer || pip.isPlaying(self)", session)

    def test_layout_places_all_tiles_not_just_viewport_rows(self):
        source = (ROOT / "App/Views/LiveCameraGridLayout.swift").read_text(encoding="utf-8")
        self.assertIn("for (index, subview) in subviews.enumerated()", source)
        self.assertIn("LiveCameraGridGeometry(", source)
        self.assertNotIn("ScrollView", source)
        self.assertNotIn("visible", source)
