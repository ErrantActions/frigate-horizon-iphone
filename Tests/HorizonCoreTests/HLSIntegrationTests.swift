import XCTest
@testable import HorizonCore

final class HLSIntegrationTests: XCTestCase {
    private func status() throws -> LiveHLSStatus {
        try JSONDecoder().decode(LiveHLSStatus.self, from: Data("""
        {"version":1,"protocol":"ll-hls","enabled":true,"available":true,
         "playlist":"Backyard/live/hls/master.m3u8",
         "renditions":[{"height":720,"bitrate":1200},{"height":1080,"bitrate":2500},{"height":2160,"bitrate":10000}]}
        """.utf8))
    }
    private func policy() throws -> LiveHLSResourcePolicy {
        try LiveHLSResourcePolicy(address: ServerAddress("https://dvr.invalid/proxy"), camera: "Backyard")
    }
    private func query(_ configuration: LiveHLSConfiguration) throws -> [String: String] {
        let url = try configuration.masterURL(status: status(), policy: policy())
        XCTAssertEqual(url.path, "/proxy/api/Backyard/live/hls/master.m3u8")
        return Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.map {
            ($0.name, $0.value ?? "")
        } ?? [])
    }
    func testGridUsesOnlyOneAdvertisedLowRungWithoutAudioOrWarming() throws {
        XCTAssertEqual(try query(.init(grid: true)), ["audio":"false", "height":"720"])
    }
    func testAutoUsesCappedLadderWhileExact4KUsesHeightNotMaximum() throws {
        XCTAssertEqual(try query(.init(maximumHeight: 1080)), ["max_height":"1080"])
        XCTAssertEqual(try query(.init(exactHeight: 2160)), ["height":"2160"])
        XCTAssertTrue(try query(.init()).isEmpty)
    }
    func testUnavailablePinsAndPinsAboveDataSaverAreRejected() {
        XCTAssertThrowsError(try query(.init(exactHeight: 1440)))
        XCTAssertThrowsError(try query(.init(maximumHeight: 720, exactHeight: 2160)))
        XCTAssertThrowsError(try query(.init(maximumHeight: 100)))
    }
    func testWarmMaximumAndBlockingReloadQueriesRemainIntact() throws {
        let policy = try policy()
        let url = try policy.resolve("2160p/rotated-239.m3u8?warm_max_height=2160&_HLS_msn=9223372036854775807&_HLS_part=1000000&_HLS_skip=v2",
            relativeTo: policy.canonicalMaster)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 4)
        XCTAssertEqual(try policy.networkURL(policy.assetURL(url)), url)
        let child = try policy.rewritePlaylist("""
        #EXTM3U
        #EXT-X-PART-INF:PART-TARGET=0.25
        #EXT-X-MAP:URI="rotated-init-239.mp4"
        #EXT-X-PART:DURATION=0.25,URI="rotated-part-239.mp4"
        """, url: url)
        XCTAssertTrue(child.contains("rotated-init-239.mp4"))
        XCTAssertTrue(child.contains("PART-TARGET=0.25"))
    }
    func testWarmMaximumCannotBeBelowActiveRungOrOutsideBounds() throws {
        let policy = try policy()
        for suffix in ["2160p/a.m3u8?warm_max_height=720", "720p/a.m3u8?warm_max_height=2161",
                       "720p/a.m3u8?session=secret", "720p/a.m3u8?cookieCheck=true",
                       "720p/a.m3u8?height=720", "720p/a.m3u8?warm_max_height=0"] {
            XCTAssertThrowsError(try policy.resolve(suffix, relativeTo: policy.canonicalMaster))
        }
    }
    func test4KMasterPreservesActualResolutionCodecsAndNoInventedFrameRate() throws {
        let policy = try policy()
        let master = try LiveHLSMaster(text: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1876000,AVERAGE-BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.640029"
        720p/v-82.m3u8?warm_max_height=2160
        #EXT-X-STREAM-INF:BANDWIDTH=13756000,AVERAGE-BANDWIDTH=10000000,RESOLUTION=3840x2160,CODECS="avc1.640033"
        2160p/v-83.m3u8?warm_max_height=2160
        """, policy: policy, url: policy.canonicalMaster)
        XCTAssertEqual(master.variants.last?.width, 3840)
        XCTAssertEqual(master.variants.last?.height, 2160)
        XCTAssertEqual(master.lowestBandwidth, 1_876_000)
        XCTAssertFalse(master.playlist.contains("FRAME-RATE"))
        XCTAssertTrue(master.playlist.contains("avc1.640033"))
    }
    func testVODAndSDChildrenUseTheirOwnServerOriginSubtrees() throws {
        let address = try ServerAddress("https://dvr.invalid/proxy")
        for path in [
            ["vod", "Backyard", "start", "1", "end", "2", "master.m3u8"],
            ["vod", "event", "abc", "index.m3u8"],
            ["vod", "export", "abc", "index.m3u8"],
            ["vod", "preview", "Backyard", "start", "1", "end", "2", "index.m3u8"],
            ["api", "onvif", "cameras", "Backyard", "replay", "sessions", "abc", "hls", "index.m3u8"],
        ] {
            let url = address.endpoint(path)
            let policy = try LiveHLSResourcePolicy(address: address, mediaURL: url)
            XCTAssertFalse(policy.isLive)
            XCTAssertEqual(try policy.resolve("init.mp4", relativeTo: url), url.deletingLastPathComponent().appendingPathComponent("init.mp4"))
            XCTAssertThrowsError(try policy.resolve("https://camera.invalid/a.mp4", relativeTo: url))
            XCTAssertThrowsError(try policy.resolve("../../../../api/config", relativeTo: url))
        }
        XCTAssertThrowsError(try LiveHLSResourcePolicy(address: address,
            mediaURL: address.endpoint(["api", "onvif", "cameras", "Backyard", "config.m3u8"])))
        XCTAssertThrowsError(try LiveHLSResourcePolicy(address: address,
            mediaURL: address.endpoint(["api", "onvif", "cameras", "Backyard", "replay", "sessions", "abc", "stream.mp4"])))
    }
    func testPartTargetChangesArePreservedNotRebasedOrMisclassifiedAsAuthentication() throws {
        let policy = try policy()
        let url = try policy.resolve("2160p/live.m3u8", relativeTo: policy.canonicalMaster)
        for target in ["0.25", "0.5"] {
            let manifest = "#EXTM3U\n#EXT-X-PART-INF:PART-TARGET=\(target)\n#EXT-X-MEDIA-SEQUENCE:98765\n#EXTINF:2,\ns-93.mp4\n"
            let result = try policy.rewritePlaylist(manifest, url: url)
            XCTAssertTrue(result.contains("PART-TARGET=\(target)"))
            XCTAssertTrue(result.contains("MEDIA-SEQUENCE:98765"))
        }
        XCTAssertFalse(LiveHLSGate.requiresReauthentication(HorizonError.unexpectedResponse))
    }
    func testNotificationMetadataPreservesEmptyNullAndSpecificSelections() throws {
        let id = UUID()
        for (json, expected) in [("[]", Optional<[String]>([])), ("null", nil), (#"["Backyard"]"#, ["Backyard"])] {
            let record = try JSONDecoder().decode(NativePushDeviceMetadata.self,
                from: Data("{\"installation_id\":\"\(id)\",\"camera_ids\":\(json)}".utf8))
            var selection = NativePushSelection()
            selection.confirm(record.cameraIDs)
            XCTAssertTrue(selection.known)
            XCTAssertEqual(try selection.renewalCameras(), expected)
        }
    }
    func testUnknownNotificationChoicesBlockRenewalInsteadOfOptingInOrOut() {
        XCTAssertThrowsError(try NativePushSelection().renewalCameras())
        XCTAssertThrowsError(try JSONDecoder().decode(NativePushDeviceMetadata.self,
            from: Data("{\"installation_id\":\"\(UUID())\"}".utf8)))
    }
}
