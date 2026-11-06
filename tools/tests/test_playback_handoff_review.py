import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class TestPlaybackHandoffReview(unittest.TestCase):
    def test_selected_camera_retains_running_grid_preview_before_sheet_opens(self):
        live = source("App/Views/LiveView.swift")
        self.assertIn("Button { selectCamera(camera) }", live)
        select = live.split("private func selectCamera(")[1].split("\n    }")[0]
        self.assertLess(select.index("LiveCameraHandoff"), select.index("selected = camera"))
        self.assertIn("handoff: selectedHandoff", live)
        self.assertIn("LiveCameraHandoffSurface(handoff: handoff", live)
        self.assertIn("handoff?.release()", live)

    def test_recorded_controller_survives_loading_to_ready_and_has_stable_ownership_container(self):
        player = source("App/Media/RecordingPlayer.swift")
        surface = player.split("struct NativeRecordingSurface:")[1].split("private struct NativeRecordedController:")[0]
        self.assertIn("ZStack {", surface)
        self.assertNotIn("Group {", surface)
        self.assertLess(surface.index("NativeRecordedController(owner: owner)"), surface.index("if owner.loading"))
        self.assertIn(".onDisappear { owner.releaseInline() }", surface)

    def test_failure_diagnostics_remain_available_after_capabilities_are_cleared(self):
        player = source("App/Media/RecordingPlayer.swift")
        controls = player.split("struct RecordedPlaybackControls:")[1].split("private extension RecordedHTTPQuality")[0]
        self.assertNotIn("ShareLink", controls.split("if let caps = owner.capabilities")[1].split("}.disabled(owner.loading)")[0])
        self.assertIn("ShareLink(item: owner.metrics.report)", controls)
        self.assertIn("metrics.failureDomain", player)
        self.assertIn("metrics.stage", player)

    def test_preview_handoff_is_bounded_and_never_opens_an_extra_grid_connection(self):
        source_text = source("App/Media/LiveCameraHandoff.swift")
        for token in ["retainGridHandoff(viewer", ".seconds(25)", "session.detach(viewer)", "timeout?.cancel()"]:
            self.assertIn(token, source_text)
        for token in ["viewerRequest(", "rtcViewer.start(", "peerConnection(", "api.get("]:
            self.assertNotIn(token, source_text)
        session = source("App/Media/LivePlaybackSession.swift")
        hold = session.split("func retainGridHandoff(")[1].split("func detach(")[0]
        self.assertIn("belongs(to: api", hold)
        self.assertIn("viewerConfiguration?.grid == true", hold)
        self.assertIn("viewers[viewer] = true", hold)
        live = source("App/Views/LiveView.swift")
        self.assertIn("if phase != .active { handoff?.release() }", live)
        self.assertIn("if !allowed { handoff?.release() }", live)
        self.assertIn("if value { handoff?.release() }", live)

    def test_review_refreshes_its_day_range_and_awaits_departing_live_cleanup(self):
        review = source("App/Views/ReviewWorkspaceView.swift")
        self.assertIn("range = try ReviewTimeRange(day: day)", review)
        self.assertNotIn("if let existing = self.range", review)
        player = source("App/Media/RecordingPlayer.swift")
        prepare = player.split("private func replace(")[1].split("private func prepareResolved")[0]
        self.assertLess(prepare.index("ViewerCleanupStore.shared.drain(using: api)"), prepare.index("prepareResolved("))
        cleanup = source("App/Media/OwnedWebRTCViewer.swift").split("func drain(")[1].split("func unidentifiedCreation")[0]
        self.assertIn("return !unidentified", cleanup)
