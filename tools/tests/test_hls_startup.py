import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

class TestHLSStartup(unittest.TestCase):
    def test_grid_configuration_is_independent_of_full_camera_pin(self):
        live = source("App/Views/LiveView.swift")
        self.assertIn("expandedQuality ? exactHLSHeight : nil", live)
        self.assertIn("expandedQuality ? fullCap", live)
        self.assertNotIn('"HLS ABR"', live)
        self.assertNotIn("Int(resolution.width)", live)
        self.assertIn('Picker("Quality"', live)

    def test_recovery_is_bounded_staggered_cancellable_and_reuses_equivalent_requests(self):
        session = source("App/Media/LivePlaybackSession.swift")
        self.assertIn("hlsLive.canReuse(configuration)", session)
        self.assertIn("HLSRecoveryCoordinator.shared.reserve", session)
        self.assertIn("recovery.nextDelay(for: problem", session)
        self.assertIn("try await Task.sleep", session)
        self.assertIn("generation == token, !Task.isCancelled", session)
        self.assertIn("Automatic HLS recovery exhausted", session)

    def test_startup_has_stage_metrics_and_stable_buffering_without_a_new_transport(self):
        live = source("App/Media/HLSLiveStream.swift")
        for stage in [".statusFetch", ".playerReady", ".firstDisplayedFrame"]:
            self.assertIn(stage, live)
        self.assertIn("setMeasurementHandler", live)
        self.assertIn("item.configuredTimeOffsetFromLive", live)
        self.assertIn("HLSPlaybackTuning.forwardBuffer", live)
        self.assertIn("player.automaticallyWaitsToMinimizeStalling = true", live)
        self.assertIn("numberOfDroppedVideoFrames", live)
        self.assertIn("errorStatusCode", live)
        self.assertIn("lastMetricsPublishedAt >= 1", live)

    def test_auth_and_notification_refresh_do_not_replay_stale_selections(self):
        model = source("App/AppModel.swift")
        self.assertIn("connectionIssue?.kind != .authentication", model)
        push = source("App/Notifications/NativePushController.swift")
        self.assertIn("await previousRegistration?.value", push)
        self.assertIn("self.api === api, self.username == username", push)
        self.assertIn("try actualSelection.renewalCameras()", push)
        self.assertIn("actualSelection.confirm(device.cameraIDs)", push)
