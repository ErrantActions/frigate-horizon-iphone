import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class TestGroupPiP(unittest.TestCase):
    def test_existing_grid_sessions_are_reused_without_new_peers_or_streams(self):
        controller = source("App/Media/LiveGroupPictureInPictureController.swift")
        for token in ["LiveGroupPiPGeometry.accepts", "viewerConfiguration?.grid == true",
                      "viewerConfiguration?.audio == false", "renderer.follow(camera.session.rtcViewer.videoTrack",
                      "retainedSession(api:", "groupPictureInPictureEnded()"]:
            self.assertIn(token, controller)
        for token in ["viewerRequest(", "api.get(", "peerConnection(", "rtcViewer.start(", "webSocket", "audioTrack(with"]:
            self.assertNotIn(token, controller)
        session = source("App/Media/LivePlaybackSession.swift")
        self.assertIn("!LiveGroupPictureInPictureController.shared.isPlaying(self)", session)
        self.assertIn("|| LiveGroupPictureInPictureController.shared.isPlaying(self)", session)

    def test_mosaic_is_native_bounded_and_stale_slots_are_cleared(self):
        renderer = source("App/Media/RTCGroupPiPRenderer.swift")
        for token in ["AVSampleBufferDisplayLayer()", "LiveGroupPiPGeometry.isFresh", "guard !busy",
                      ".milliseconds(100)", "CMSampleBufferCreateReadyWithImageBuffer",
                      "slots[index].clear()", "tracks[index]?.remove", "flushAndRemoveImage",
                      "guard self.generation == token"]:
            self.assertIn(token, renderer)
        self.assertNotIn("AVPlayer(", renderer)
        self.assertNotIn("AVAssetWriter", renderer)
        self.assertIn("RTCViewerPixelConverter()", renderer)
        self.assertIn("RTCViewerPixelConverter()", source("App/Media/RTCViewerRendering.swift"))

    def test_group_scope_revocation_and_exclusive_pip_ownership_are_wired(self):
        app = source("App/HorizonApp.swift")
        self.assertIn("LiveGroupPictureInPictureController.shared.updateScope", app)
        for path in ["App/AppModel.swift", "App/Media/RecordingPlayer.swift",
                     "App/Media/LivePictureInPictureController.swift", "App/Media/CameraTalkbackController.swift"]:
            self.assertIn("LiveGroupPictureInPictureController.shared.stop()", source(path), path)
        controller = source("App/Media/LiveGroupPictureInPictureController.swift")
        self.assertIn("RecordedViewingRegistry.stopPiP()", controller)
        self.assertIn("LivePictureInPictureController.shared.stop()", controller)
        self.assertIn("members = []", controller)
        self.assertIn("self.controller === value", controller)

    def test_ui_starts_explicitly_from_all_dashboard_cameras_and_has_native_preview(self):
        view = source("App/Views/LiveView.swift")
        self.assertIn("private func startGroupPiP()", view)
        self.assertIn("let cameras = dashboardCameras", view)
        self.assertIn("groupPiP.start(api: api", view)
        self.assertIn("LiveGroupPiPPreview(controller: groupPiP)", view)
        self.assertIn("participatesInGroupPiP: true", view)
        self.assertIn("attachment.adoptGroupSession(", view)
        controller = source("App/Media/LiveGroupPictureInPictureController.swift")
        self.assertIn("canStartPictureInPictureAutomaticallyFromInline = false", controller)
        self.assertIn("sampleBufferDisplayLayer: renderer.displayLayer", controller)
        self.assertIn("self.members.allSatisfy({ $0.session.hasInlineViewer })", controller)
        root = source("App/Views/HorizonRoot.swift")
        self.assertIn("groupPiP.restoreUserInterface = { selection = .live; restoredCamera = nil }", root)
