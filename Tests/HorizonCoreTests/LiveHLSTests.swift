import Foundation
import XCTest
@testable import HorizonCore

final class LiveHLSTests: XCTestCase {
    private func policy(_ root: String = "https://example.com/base") throws -> LiveHLSResourcePolicy {
        try LiveHLSResourcePolicy(address: ServerAddress(root), camera: "front")
    }

    private func status(_ replacement: String? = nil) throws -> LiveHLSStatus {
        let data = replacement.map { Data($0.utf8) } ?? LiveHLSFixtures.status
        return try JSONDecoder().decode(LiveHLSStatus.self, from: data)
    }

    func testLiveHLSUIFlagDefaultsFalseAndDecodesSnakeCase() throws {
        for ui in [#"{}"#, #"{"order":1,"dashboard":true}"#] {
            XCTAssertFalse(try JSONDecoder().decode(CameraUI.self, from: Data(ui.utf8)).liveHLS)
        }
        XCTAssertTrue(try JSONDecoder().decode(CameraUI.self, from: Data(#"{"live_hls":true}"#.utf8)).liveHLS)
    }

    func testAutomaticProbeRequiresEnabledCameraOptInAutomaticAndHTTPSChoice() {
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: true, transport: "https"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: false, optedIn: true, automatic: true, transport: "https"))
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: false, automatic: true, transport: "https"))
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: false, transport: "https"))
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: true, transport: "webrtc"))
    }

    func testExplicitHLSOnlySelectionDoesNotRequireLegacyFlagOrAutomaticStream() {
        for optedIn in [false, true] {
            for automatic in [false, true] {
                XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: optedIn,
                    automatic: automatic, transport: "hls"))
            }
        }
    }

    func testExplicitHLSStillRequiresAnEnabledCameraAndKnownTransport() {
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: false, optedIn: true, automatic: true, transport: "hls"))
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: true, transport: "unknown"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: false, optedIn: false, automatic: false, transport: "hls"))
    }

    func testHLSOnlyCameraCanOpenWithoutAnyCompatibilityStreamNames() throws {
        let config = try JSONDecoder().decode(HorizonConfiguration.self,
            from: Data(#"{"cameras":{"front":{"enabled":true,"live":{"streams":{}}}}}"#.utf8))
        let camera = try XCTUnwrap(config.orderedCameras.first)
        XCTAssertNil(camera.playbackQuality(expanded: true))
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: camera.settings.enabled,
            optedIn: camera.settings.ui?.liveHLS == true, automatic: false, transport: "hls"))
    }

    func testExplicitHLSOnlyNeverPermitsCompatibilityFallback() {
        XCTAssertFalse(LiveHLSGate.permitsCompatibilityFallback(.init(requiresHLS: true)))
        XCTAssertFalse(LiveHLSGate.permitsCompatibilityFallback(.init()))
        XCTAssertFalse(LiveHLSGate.permitsCompatibilityFallback(nil))
    }

    func testExplicitHLSRetentionSurvivesMissingLegacyFlagButNotDisabledCamera() {
        let explicit = LiveHLSConfiguration(requiresHLS: true)
        XCTAssertTrue(LiveHLSGate.mayRetain(cameraEnabled: true, optedIn: false, configuration: explicit))
        XCTAssertFalse(LiveHLSGate.mayRetain(cameraEnabled: false, optedIn: true, configuration: explicit))
        XCTAssertFalse(LiveHLSGate.mayRetain(cameraEnabled: true, optedIn: true, configuration: nil))
        XCTAssertTrue(LiveHLSGate.mayRetain(cameraEnabled: true, optedIn: false, configuration: .init()))
        XCTAssertTrue(LiveHLSGate.mayRetain(cameraEnabled: true, optedIn: true, configuration: .init()))
    }

    func testHLSOnlyConfigurationKeepsTheSelectedQualityCeiling() {
        let value = LiveHLSConfiguration(maximumHeight: 720, requiresHLS: true)
        XCTAssertEqual(value.maximumHeight, 720)
        XCTAssertTrue(value.requiresHLS)
        XCTAssertEqual(value, LiveHLSConfiguration(maximumHeight: 720))
    }

    func testSwitchingToHLSKeepsKnownManualQualityCeilingWithoutRequiringGeneration() throws {
        let config = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{"front":{"enabled":true,"live":{"streams":{
          "Main":"front","Low":"front_transcode_720p","High":"front_transcode_1080p"},
          "transcode":{"enabled":false,"qualities":[{"height":720},{"height":1080}]}}}}}
        """.utf8))
        let camera = try XCTUnwrap(config.orderedCameras.first)
        XCTAssertEqual(camera.hlsMaximumHeight(pinnedStream: "front_transcode_720p", selectedMaximum: nil), 720)
        XCTAssertEqual(camera.hlsMaximumHeight(pinnedStream: "front_transcode_1080p", selectedMaximum: 720), 720)
        XCTAssertEqual(camera.hlsMaximumHeight(pinnedStream: "front_transcode_720p", selectedMaximum: 1080), 720)
        XCTAssertEqual(camera.playbackQuality(expanded: true, pinnedStream: "front_transcode_720p")?.requestedStream,
            "front_transcode_720p")
    }

    func testHLSCeilingDoesNotInventAHeightForAnUnknownLegacyStream() throws {
        let config = try JSONDecoder().decode(HorizonConfiguration.self,
            from: Data(#"{"cameras":{"front":{"enabled":true,"live":{"streams":{"Main":"front"}}}}}"#.utf8))
        let camera = try XCTUnwrap(config.orderedCameras.first)
        XCTAssertNil(camera.hlsMaximumHeight(pinnedStream: "front", selectedMaximum: nil))
        XCTAssertEqual(camera.hlsMaximumHeight(pinnedStream: "front", selectedMaximum: 1080), 1080)
    }

    func testStatusUsesVersionedContractWithoutTreatingTargetsAsBandwidth() throws {
        let status = try status()
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.renditions.map(\.bitrate), [1200, 2500])
        let policy = try policy()
        let url = try policy.masterURL(status.playlist)
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url)
        XCTAssertEqual(master.lowestBandwidth, 1_876_000)
        XCTAssertEqual(master.variants.map(\.bandwidth), [1_876_000, 3_631_000])
        XCTAssertTrue(master.playlist.contains("AVERAGE-BANDWIDTH=1200000"))
        XCTAssertTrue(master.playlist.contains("FRAME-RATE=15.000"))
    }

    func testDisabledUnavailableAndUnknownVersionUseCompatibility() throws {
        for json in [
            #"{"version":1,"protocol":"ll-hls","enabled":false,"available":false}"#,
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":false}"#,
            #"{"version":2,"protocol":"future-hls"}"#,
            #"{"version":1,"protocol":"other"}"#,
        ] {
            XCTAssertFalse(try status(json).isAvailable)
        }
    }

    func testMalformedAvailableContractIsNotACompatibilitySuccess() {
        for json in [
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":true}"#,
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":true,"playlist":"front/live/hls/master.m3u8","renditions":[{"height":720,"bitrate":0}]}"#,
        ] {
            XCTAssertThrowsError(try status(json))
        }
    }

    func testOnlyUnsupportedHTTPResponsesPermitFallbackNotAuthenticationOrTLS() {
        for code in [404, 405, 410, 501] { XCTAssertTrue(LiveHLSGate.isUnsupportedHTTP(code)) }
        for code in [401, 403, 429, 500, 502, 503] { XCTAssertFalse(LiveHLSGate.isUnsupportedHTTP(code)) }
    }

    func testMasterPathIsRelativeToAPIBaseAndCameraScoped() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        XCTAssertEqual(master.absoluteString, "https://example.com/base/api/front/live/hls/master.m3u8")
        XCTAssertThrowsError(try policy.masterURL("garden/live/hls/master.m3u8"))
        XCTAssertThrowsError(try policy.masterURL("front/live/hls/master.m3u8?token=secret"))
        XCTAssertThrowsError(try self.policy("http://example.com/base"))
    }

    func testEveryPlaylistAudioInitSegmentAndPartStaysInTheCameraRoot() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        let child = try policy.resolve("720p/index.m3u8", relativeTo: master)
        for ref in ["720p/audio.m3u8", "720p/init.mp4", "720p/segment-1.mp4", "720p/part-1.mp4"] {
            let url = try policy.resolve(ref, relativeTo: master)
            XCTAssertTrue(url.path.hasPrefix("/base/api/front/live/hls/"))
            XCTAssertEqual(try policy.networkURL(policy.assetURL(url)), url)
        }
        let rewrite = try policy.rewritePlaylist(LiveHLSFixtures.safeChild, url: child)
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/720p/init.mp4"))
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/720p/part-2.mp4"))
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/720p/audio.m3u8"))
        XCTAssertNoThrow(try policy.rewritePlaylist(LiveHLSFixtures.child, url: child))
    }

    func testCredentialQueryOriginCameraAndTraversalEscapesAreRejected() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        for ref in [
            "https://attacker.invalid/segment.m4s", "http://example.com/base/api/front/live/hls/segment.m4s",
            "https://user:password@example.com/base/api/front/live/hls/segment.m4s",
            "/base/api/garden/live/hls/segment.m4s", "/base/api/config",
            "../../config", "%2e%2e/config.m3u8", "%252e%252e/config.m3u8",
            "720p%2fother/index.m3u8", "720p\\index.m3u8", "segment.m4s?token=secret",
            "720p/index.m3u8?session=private", "720p/index.m3u8#fragment",
        ] {
            XCTAssertThrowsError(try policy.resolve(ref, relativeTo: master), ref)
        }
        for ref in ["720p/part.m4s", "720p/segment.ts", "720p/audio.aac", "720p/key.key",
                    "audio/part.mp4", "720p/nested/part.mp4", "part.mp4"] {
            XCTAssertThrowsError(try policy.resolve(ref, relativeTo: master), ref)
        }
        let child = try policy.resolve("720p/arbitrary-track.m3u8", relativeTo: master)
        XCTAssertNoThrow(try policy.resolve("another-track-17.mp4", relativeTo: child))
        XCTAssertNoThrow(try policy.resolve("../1080p/primary.m3u8", relativeTo: child))
    }

    func testLLHLSReloadQueryAllowlistIsBoundedAndDuplicateFree() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        XCTAssertNoThrow(try policy.resolve("720p/index.m3u8?_HLS_msn=12&_HLS_part=2&_HLS_skip=YES", relativeTo: master))
        XCTAssertNoThrow(try policy.resolve("720p/index.m3u8?_HLS_msn=9223372036854775807&_HLS_part=1000000&_HLS_skip=v2", relativeTo: master))
        for ref in [
            "720p/index.m3u8?_HLS_msn=-1", "720p/index.m3u8?_HLS_msn=1&_HLS_msn=2",
            "720p/index.m3u8?_HLS_skip=secret", "part.m4s?_HLS_msn=1",
            "720p/index.m3u8?_HLS_part=1", "720p/index.m3u8?_HLS_msn=0&_HLS_part=1000001",
            "720p/index.m3u8?_HLS_msn=9223372036854775808",
            "720p/index.m3u8?session=private", "720p/index.m3u8?cookieCheck=private",
        ] { XCTAssertThrowsError(try policy.resolve(ref, relativeTo: master)) }
    }

    func testMasterMaximumFiltersOnlyActualVariantsAndRetainsAudio() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url, maximumHeight: 720)
        XCTAssertEqual(master.variants.map(\.height), [720])
        XCTAssertTrue(master.playlist.contains("TYPE=AUDIO"))
        XCTAssertFalse(master.playlist.contains("1080p/primary.m3u8"))
        XCTAssertThrowsError(try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url, maximumHeight: 360))
    }

    func testCRLFMasterAndPlaylistHaveTheSameRenditions() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master.replacingOccurrences(of: "\n", with: "\r\n"),
            policy: policy, url: url)
        XCTAssertEqual(master.variants.map(\.height), [720, 1080])
    }

    func testUnsafePlaylistURIAttributesAreNotLeftForAVPlayerToFetch() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        for text in [
            LiveHLSFixtures.master.replacingOccurrences(of: "720p/audio.m3u8", with: "https://attacker.invalid/audio.m3u8"),
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"secret.key\"\n",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://attacker.invalid/\"\n",
        ] { XCTAssertThrowsError(try policy.rewritePlaylist(text, url: url)) }
    }

    func testMalformedMasterDoesNotInventVariantsOrUseTargetKbps() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        for text in [
            "<html>Sign in</html>", "#EXTM3U\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=0,RESOLUTION=1280x720\n720p/index.m3u8\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1876000,RESOLUTION=invalid\n720p/index.m3u8\n",
        ] { XCTAssertThrowsError(try LiveHLSMaster(text: text, policy: policy, url: url)) }
    }

    func testOptionalPackagerMetadataIsNotInvented() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1876000\n720p/actual-track.m3u8\n"
        let master = try LiveHLSMaster(text: text, policy: policy, url: url, maximumHeight: 720)
        XCTAssertEqual(master.lowestBandwidth, 1_876_000)
        XCTAssertEqual(master.variants.first?.height, 720)
        XCTAssertNil(master.variants.first?.width)
        XCTAssertFalse(master.playlist.contains("RESOLUTION"))
        XCTAssertFalse(master.playlist.contains("CODECS"))
        XCTAssertFalse(master.playlist.contains("FRAME-RATE"))
    }

    func testStartupCapRequiresDecodedVideoAndSustainedHealthyBuffer() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 1_876_000)
        XCTAssertEqual(state.preferredPeakBitRate, 1_876_000)
        state.observe(now: 0, decodedVideo: false, bufferedAhead: 3, playing: true, restrictedNetwork: false)
        state.observe(now: 20, decodedVideo: true, bufferedAhead: 0.2, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
        state.observe(now: 21, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        state.observe(now: 23.9, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
        state.observe(now: 24, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        XCTAssertTrue(state.released)
        XCTAssertEqual(state.preferredPeakBitRate, 0)
    }

    func testLowDataModeRetainsOrReappliesLowestCapWithoutReplacingPlayer() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 1_876_000)
        state.observe(now: 0, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 3, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        XCTAssertTrue(state.released)
        state.observe(now: 4, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: true)
        XCTAssertEqual(state.preferredPeakBitRate, 1_876_000)
        state.observe(now: 30, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: true)
        XCTAssertFalse(state.released)
    }

    func testStallAndInvalidClockResetHealthyStartupWindow() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 100)
        state.observe(now: 0, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 2, decodedVideo: true, bufferedAhead: 2, playing: false, restrictedNetwork: false)
        state.observe(now: 3, decodedVideo: true, bufferedAhead: .nan, playing: true, restrictedNetwork: false)
        state.observe(now: 4, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 6.9, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
    }

    func testExistingPiPOwnershipPolicyAppliesWithoutBackgroundAutoplay() {
        XCTAssertFalse(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: true, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: false))
        XCTAssertTrue(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: true, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: true))
        XCTAssertFalse(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: false, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: true))
    }
}
