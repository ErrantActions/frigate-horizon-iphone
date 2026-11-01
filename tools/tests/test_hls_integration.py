import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

class TestHLSIntegration(unittest.TestCase):
    def test_api_cookie_bridge_does_not_drop_api_scoped_sessions_at_server_root(self):
        api = source("App/Networking/HorizonAPI.swift")
        self.assertIn("SavedSession.cookiesForMedia", api)
        self.assertNotIn("cookies(for: address.url)", api)
        self.assertIn("SavedCookie($0).restore(for: address)", source("Sources/HorizonCore/SavedSession.swift"))

    def test_viewing_has_no_legacy_players_or_transport_fallback(self):
        for name in ["LiveStream.swift", "HTTPSLiveStream.swift", "LivePiPVideoRenderer.swift"]:
            self.assertFalse((ROOT / "App/Media" / name).exists())
        session = source("App/Media/LivePlaybackSession.swift")
        self.assertIn("HLSRecoveryPolicy()", session)
        self.assertIn("HLSRecoveryCoordinator.shared.reserve", session)
        self.assertNotIn("webSocketTask", session)
        live = source("App/Views/LiveView.swift")
        self.assertNotIn('tag("webrtc")', live)
        self.assertNotIn("HTTPSVideoSurface", live)
        self.assertIn("grid: !expandedQuality", live)
        self.assertIn("exactHLSHeight", live)
        self.assertIn("tracksScrollVisibility: true", live)
        self.assertIn(".onScrollVisibilityChange(threshold: 0.01)", live)
        self.assertIn("if !isVisible { playback.deactivateInlineViewer(viewer) }", live)

    def test_recorded_viewing_is_hls_and_original_download_is_unchanged(self):
        exports = source("App/Views/ExportsView.swift")
        self.assertIn('["vod", "export", item.id, "index.m3u8"]', exports)
        self.assertIn('mediaFile(item.videoPath, root: "exports")', exports)
        events = source("App/Views/EventSearchView.swift")
        self.assertIn('["vod", "event", current.id, "index.m3u8"]', events)
        self.assertIn('"clip.mp4"', events)
        self.assertIn('"vod", "preview"', events)

    def test_camera_sd_session_is_closed_and_never_uses_direct_camera_mp4(self):
        replay = source("App/Views/CameraSDReplayView.swift")
        self.assertIn('"hls", "index.m3u8"', replay)
        self.assertIn('method: "DELETE"', replay)
        self.assertIn('.onDisappear { player.stop(); owner.close() }', replay)
        self.assertNotIn('"stream.mp4"', replay)

    def test_media_loading_is_cancelled_and_auth_expiry_coalesced(self):
        for file in ["App/Media/RecordingPlayer.swift", "App/Media/HLSLiveStream.swift"]:
            self.assertIn("asset.cancelLoading()", source(file))
            self.assertIn("source?.close()", source(file))
        self.assertIn("model.reportSessionExpiry(from: api)", source("App/HorizonApp.swift"))
        self.assertIn("!isConnecting", source("App/AppModel.swift"))
        recording = source("App/Media/RecordingPlayer.swift")
        self.assertIn("HLSBackgroundOwnership", recording)
        self.assertIn("retained[id] = known[id]?.value", recording)
        self.assertIn("releaseInline()", recording)

    def test_auth_resource_cases_are_actual_xctest_methods_not_nested_helpers(self):
        tests = source("Tests/HorizonCoreTests/AuthenticatedLiveHLSTests.swift")
        for name in [
            "testEveryPlaylistAndMediaResourceReauthenticatesWithoutSharedCache",
            "testAChild403DoesNotTriggerSignInAndAChild404IsNotRetriedByLoader",
        ]:
            self.assertIn("\n    func " + name, tests)
            self.assertNotIn("\n        func " + name, tests)

    def test_push_renewal_fetches_actual_camera_ids_and_explicit_empty_is_not_filtered(self):
        push = source("App/Notifications/NativePushController.swift")
        self.assertIn('["notifications", "apns", "devices"]', push)
        self.assertIn("actualSelection.renewalCameras()", push)
        self.assertIn("if !explicitCameraSave", push)
        self.assertIn("guard generation == session, registrationRequest == requestID", push)
        self.assertNotIn("cameraIDs: savedCameraIDs, features:", push)
        self.assertIn("Server selection: no cameras (explicit opt-out)", source("App/Notifications/NativePushSettingsView.swift"))

    def test_talkback_controls_are_hidden_but_ptz_is_preserved(self):
        controls = source("App/Views/CameraControlsView.swift")
        self.assertIn("ptz(capabilities)", controls)
        self.assertNotIn("microphone(capabilities)", controls)
        self.assertIn("Talkback is unsupported in this HLS-only release", controls)
