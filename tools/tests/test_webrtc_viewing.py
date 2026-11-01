import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

class TestWebRTCViewing(unittest.TestCase):
    def test_no_hls_or_original_url_asset_viewing_survives(self):
        for file in (ROOT / "App").rglob("*.swift"):
            text = file.read_text(encoding="utf-8")
            for retired in ["AVURLAsset(", "AuthenticatedLiveHLS", "NativeLiveHLSSurface", "master.m3u8", "index.m3u8"]:
                self.assertNotIn(retired, text, str(file))
        self.assertFalse((ROOT / "App/Media/HLSLiveStream.swift").exists())
        self.assertFalse((ROOT / "Sources/HorizonCore/LiveHLSLoopbackProxy.swift").exists())

    def test_live_discovery_precedes_creation_and_missing_backend_is_an_upgrade(self):
        peer = source("App/Media/OwnedWebRTCViewer.swift")
        self.assertLess(peer.index('["native", "features"]'), peer.index("let creation = Task"))
        self.assertIn("features.requireLive()", peer)
        self.assertIn("status.validate(policy: policy)", peer)
        self.assertIn("ViewingMessage.upgrade", peer)
        self.assertNotIn("webSocketTask", peer)

    def test_signaling_is_server_offer_client_answer_with_sdk_mid_and_no_capture(self):
        peer = source("App/Media/OwnedWebRTCViewer.swift")
        self.assertIn("RTCSessionDescription(type: .offer", peer)
        self.assertIn('ViewerSDP(type: "answer"', peer)
        self.assertIn("peer.answer(", peer)
        self.assertIn("candidate.sdpMLineIndex", peer)
        self.assertIn("candidate.sdpMid", peer)
        self.assertIn("candidateQueue.acceptAnswer()", peer)
        for capture in ["audioSource(", "audioTrack(with", "videoSource(", "createOffer(", "RTCCameraVideoCapturer"]:
            self.assertNotIn(capture, peer)

    def test_owned_lifecycle_accounts_for_late_creation_and_awaits_cleanup(self):
        peer = source("App/Media/OwnedWebRTCViewer.swift")
        self.assertIn("let creation = Task", peer)
        self.assertIn("created = try await creation.value", peer)
        self.assertIn("ownership.acceptCreated", peer)
        self.assertIn("await previousWorker?.value", peer)
        self.assertIn("ViewerCleanupStore.shared.drain(using: api)", peer)
        self.assertIn("account == owner.api.viewingAccountKey", peer)
        self.assertIn("currentAPI.address == owner.api.address", peer)
        self.assertIn('method: "DELETE"', peer)
        self.assertIn("self.lease.renew(update", peer)
        self.assertIn("self.lease.isValid", peer)
        self.assertIn("ViewerCleanupStore.shared.unidentifiedCreation()", peer)

    def test_quality_patch_does_not_create_a_new_peer_or_offer(self):
        peer = source("App/Media/OwnedWebRTCViewer.swift")
        quality = peer.split("func setQuality(")[1].split("private func reportStats")[0]
        self.assertIn('operation: "quality"', quality)
        self.assertIn('method: "PATCH"', quality)
        self.assertNotIn("peerConnection(", quality)
        self.assertNotIn("negotiate(", quality)
        self.assertIn("sameEnvelope", source("App/Media/LivePlaybackSession.swift"))
        self.assertIn("pendingQuality = QualityIntent(height: height)", peer)
        self.assertIn("self.setQuality(next.height)", peer)

    def test_recorded_http_is_gated_without_guessed_routes_or_mock_adapter(self):
        player = source("App/Media/RecordingPlayer.swift")
        self.assertIn("ViewingMessage.recorded", player)
        self.assertNotIn("URLSession", player)
        self.assertNotIn("AVURLAsset", player)
        self.assertTrue("UnavailableRecordedHTTPTransport(address: api.address)" in player)
        self.assertTrue("transport.qualification.usable" in player)
        self.assertTrue("player.seek(to:" in player)
        sd = source("App/Views/CameraSDReplayView.swift")
        self.assertNotIn("api.get", sd)
        self.assertNotIn("api.send", sd)
        self.assertNotIn("FakeRecorded", "".join(p.read_text(encoding="utf-8") for p in (ROOT / "App").rglob("*.swift")))

    def test_recorded_asset_uses_supported_resource_loading_and_bounded_authenticated_ranges(self):
        asset = source("Sources/HorizonCore/RecordedMP4Asset.swift")
        reader = source("Sources/HorizonCore/RecordedMP4Reader.swift")
        for token in ["AVAssetResourceLoaderDelegate", "isByteRangeAccessSupported = true",
                      "reader.length", "didCancel request", "job?.cancel()", "reader.close()",
                      "RecordedMP4Range.maximumRead", "request.isCancelled"]:
            self.assertTrue(token in asset, token)
        for token in ['forHTTPHeaderField: "Range"', "configuration.httpShouldSetCookies = true",
                      "configuration.urlCache = nil", "completionHandler(nil)", "withTaskCancellationHandler",
                      "data.count > read.range.count - read.data.count"]:
            self.assertTrue(token in reader, token)
        self.assertTrue("HTTPCookie.requestHeaderFields(with: scoped)" in reader)
        self.assertTrue("SavedSession.cookiesForMedia(values, address: address)" in reader)
        self.assertTrue("AVURLAssetHTTPHeaderFieldsKey" not in asset + reader)
        self.assertTrue("serverTrust" not in asset + reader)

    def test_recorded_ui_maps_catalog_time_and_has_explicit_pip_and_scope_ownership(self):
        player = source("App/Media/RecordingPlayer.swift")
        review = source("App/Views/ReviewWorkspaceView.swift")
        for token in ["prepared.mapping.mediaTime", "mapping.sourceTime", "item.cancelPendingSeeks()",
                      "seekGeneration", "autoplay: wantsToPlay", "asset.cancel", "canStartPictureInPictureAutomaticallyFromInline = false"]:
            if token == "asset.cancel":
                self.assertTrue("media?.cancel()" in player)
            else:
                self.assertTrue(token in player, token)
        self.assertTrue("store.timeline.timestamp(for:" not in review)
        self.assertTrue("floor(timestamp / 300)" not in review)
        self.assertTrue("RecordedViewingRegistry.background()" in source("App/HorizonApp.swift"))
        self.assertTrue("RecordedViewingRegistry.stopAll()" in source("App/AppModel.swift"))

    def test_recorded_webrtc_control_contract_is_retired(self):
        core = source("Sources/HorizonCore/RecordedViewing.swift")
        self.assertTrue("RecordedViewingSession" not in core)
        self.assertTrue("positionEvents" not in core)

    def test_recorded_http_public_helpers_are_not_nested_local_declarations(self):
        core = source("Sources/HorizonCore/RecordedHTTP.swift")
        self.assertTrue("\n    public func resolved(policy:" in core)
        self.assertTrue("\n        public func" not in core)

    def test_pip_has_a_sample_buffer_renderer_not_an_avplayer_rtc_assumption(self):
        pip = source("App/Media/LivePictureInPictureController.swift")
        self.assertIn("sampleBufferDisplayLayer:", pip)
        self.assertIn("rtcViewer.pipRenderer.follow(track)", pip)
        self.assertNotIn("playerLayer:", pip)
        renderer = source("App/Media/RTCViewerRendering.swift")
        self.assertIn("CMSampleBufferCreateReadyWithImageBuffer", renderer)
        self.assertIn("RTCMTLVideoView", renderer)
        self.assertIn("layer.addSublayer(pipLayer)", renderer)
        self.assertIn("view.video.renderFrame(nil)", renderer)

    def test_viewer_auth_disallows_redirects_and_preserves_csrf_cookie_session(self):
        api = source("App/Networking/HorizonAPI.swift")
        self.assertIn("ViewerTaskDelegate", api)
        self.assertIn("viewerRequest ? ViewerTaskDelegate() : nil", api)
        self.assertIn('"X-CSRF-TOKEN": "1"', api)
        self.assertIn("address.hasSameOrigin(as: url)", api)
        self.assertNotIn("serverTrust", api)

    def test_sdk_pin_and_localized_messages_are_present(self):
        self.assertIn("exactVersion: 156.0.0", source("project.yml"))
        strings = source("App/en.lproj/Localizable.strings")
        for key in ["viewer.upgrade", "viewer.recorded", "viewer.denied", "viewer.capacity"]:
            self.assertIn(key, strings)

    def test_private_ice_and_sdp_are_not_written_to_logs_or_preferences(self):
        peer = source("App/Media/OwnedWebRTCViewer.swift")
        self.assertNotIn("print(", peer)
        self.assertNotIn("UserDefaults", peer)
        self.assertNotIn("SessionVault", peer)
        self.assertIn('"candidateType"', peer)
        self.assertIn('"relayProtocol"', peer)

    def test_tour_does_not_open_an_invisible_incoming_pipeline(self):
        tour = source("App/Views/CameraTourView.swift")
        self.assertNotIn("playback.preload(", tour)
        self.assertIn("playback.selectWithoutPreload", tour)
        self.assertIn("ForEach(playback.current.map", tour)

    def test_ownership_helpers_are_top_level_not_nested_unused_declarations(self):
        core = source("Sources/HorizonCore/WebRTCViewing.swift")
        self.assertIn("\npublic struct ViewerOwnershipState", core)
        self.assertIn("\npublic func viewingFailureMessage", core)
        self.assertNotIn("\n        public struct ViewerOwnershipState", core)
