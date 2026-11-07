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
        self.assertIn("canStartPictureInPictureAutomaticallyFromInline = true", controller)
        self.assertIn("sampleBufferDisplayLayer: renderer.displayLayer", controller)
        self.assertIn("self.members.allSatisfy({ $0.session.hasInlineViewer })", controller)
        root = source("App/Views/HorizonRoot.swift")
        self.assertIn("groupPiP.restoreUserInterface = { selection = .live; restoredCamera = nil }", root)

    def test_start_waits_for_layout_and_first_frame_and_retains_the_explicit_pending_request(self):
        controller = source("App/Media/LiveGroupPictureInPictureController.swift")
        self.assertIn("startupState.retainsPlayers", controller)
        self.assertIn("startupState.requestIfReady", controller)
        self.assertIn("firstFrame: renderer.hasRenderedFrame", controller)
        self.assertIn("startupState.expire", controller)
        start = controller.split("private func startIfPossible(")[1].split("private func began")[0]
        self.assertLess(start.index("requestIfReady"), start.index("startPictureInPicture()"))
        preview = source("App/Views/LiveGroupPiPPreview.swift")
        self.assertIn("controller.attachPreview(size: bounds.size)", preview)
        self.assertIn("else if wasAttached", preview)
        self.assertIn("private var wasAttached = false", preview.split("final class Host: UIView")[1])
        self.assertNotIn("wasAttached = false", preview.split("final class Host: UIView")[0])
        self.assertIn("any RTCI420BufferProtocol", source("App/Media/RTCViewerRendering.swift"))
        self.assertIn("setForeground(phase == .active)", source("App/HorizonApp.swift"))

    def test_background_group_composition_is_cpu_only_and_inline_metal_views_detach(self):
        mosaic = source("Sources/HorizonCore/LiveGroupPiPMosaic.swift")
        converter = source("Sources/HorizonCore/LiveGroupPiPImage.swift")
        renderer = source("App/Media/RTCGroupPiPRenderer.swift")
        self.assertNotIn("CIContext", mosaic)
        self.assertIn("CGContext(", mosaic)
        self.assertIn("vImageConvert_420Yp8_CbCr8ToARGB8888", converter)
        self.assertIn("converter.groupImage(", renderer)
        self.assertIn("onFirstFrame?()", renderer)
        self.assertIn("active && visible && scenePhase == .active ? rtc.videoTrack : nil", source("App/Views/LiveView.swift"))

    def test_cpu_pixel_test_helper_is_not_a_nested_local_declaration(self):
        tests = source("Tests/HorizonCoreTests/LiveGroupPiPMosaicTests.swift")
        self.assertIn("\n    private func pixel(", tests)
        self.assertNotIn("\n        private func pixel(", tests)
