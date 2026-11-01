import XCTest
@testable import HorizonCore

final class WebRTCViewingTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private func policy(_ camera: String = "front") throws -> ViewerResourcePolicy {
        try ViewerResourcePolicy(address: ServerAddress("https://dvr.invalid/proxy"), camera: camera)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func status() throws -> LiveWebRTCStatus {
        try decode(LiveWebRTCStatus.self, [
            "version":1,"protocol":"webrtc","enabled":true,"available":true,
            "session_url":"front/live/webrtc/sessions","grid_height":360,
            "grid_rendition":["height":360,"bitrate":500],"relay_available":true,
            "renditions":[["height":360,"bitrate":500],["height":720,"bitrate":1200],["height":1080,"bitrate":2500]],
        ])
    }
    private func session(_ changes: [String: Any] = [:]) throws -> ViewerSessionDescription {
        let prefix = "front/live/webrtc/sessions/" + id.uuidString.lowercased()
        var object: [String: Any] = [
            "version":1,"protocol":"webrtc","session_id":id.uuidString,"expires_at":1030,"heartbeat_seconds":10,
            "answer_url":prefix + "/answer","candidates_url":prefix + "/candidates","heartbeat_url":prefix,
            "close_url":prefix,"quality_url":prefix + "/quality","ice_servers":[],
            "offer":["type":"offer","sdp":"v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=sendonly\r\n"],
            "ice_candidates":[],"ice_transport_policy":"all",
            "renditions":[["height":720,"bitrate":1200],["height":1080,"bitrate":2500]],"initial_height":720,
        ]
        object.merge(changes) { _, value in value }
        return try decode(ViewerSessionDescription.self, object)
    }

    func testMissingUnsupportedDisabledFeaturesNeverAdvertiseViewing() throws {
        XCTAssertThrowsError(try decode(ViewingFeatures.self, [:]).requireLive())
        var live: [String: Any] = ["version":1,"enabled":true,"available":true,
            "status_url_template":"{camera_name}/live/webrtc/status","signaling":"frigate-rest-offer-answer-v1",
            "on_demand":true,"recordings":"original_source"]
        XCTAssertNoThrow(try decode(ViewingFeatures.self, ["live_webrtc":live]).requireLive())
        for change in [["version":2],["enabled":false],["available":false],["signaling":"whep"],
                       ["status_url_template":"https://engine.invalid/ws"]] as [[String: Any]] {
            var invalid = live; invalid.merge(change) { _, new in new }
            XCTAssertThrowsError(try decode(ViewingFeatures.self, ["live_webrtc":invalid]).requireLive())
        }
        live["recordings"] = "original_source"
        XCTAssertEqual(try decode(ViewingFeatures.self, ["live_webrtc":live]).requireLive().recordings, "original_source")
    }

    func testCameraIsEncodedAsOneSegmentAndAPIBaseRetainsSubpath() throws {
        let policy = try policy("Front & Yard")
        XCTAssertEqual(policy.apiBase.absoluteString, "https://dvr.invalid/proxy/api/")
        XCTAssertEqual(policy.statusURL.absoluteString, "https://dvr.invalid/proxy/api/Front%20%26%20Yard/live/webrtc/status")
        XCTAssertTrue(try self.policy("front/side").statusURL.absoluteString.contains("front%2Fside"))
        XCTAssertThrowsError(try self.policy(".."))
    }

    func testOnlyExactOwnedSameOriginResourceURLsAreAccepted() throws {
        let policy = try policy()
        let expected = policy.owned(id, operation: "answer")
        XCTAssertEqual(try policy.resolve("front/live/webrtc/sessions/\(id.uuidString.lowercased())/answer", expected: expected), expected)
        for url in [
            "https://engine.invalid/answer", "http://dvr.invalid/proxy/api/front/answer",
            "/api/front/live/webrtc/sessions/\(id)/answer", "/proxy/api/config",
            "front/live/webrtc/sessions/\(id)/answer?token=secret", "front/live/webrtc/sessions/\(id)/answer#fragment",
        ] { XCTAssertThrowsError(try policy.resolve(url, expected: expected)) }
    }

    func testGridUsesOnlyDiscoveredGridRungWithoutAudioOrForcedRelay() throws {
        let config = ViewerConfiguration(grid: true, maximumHeight: 2160, exactHeight: 1080, audio: true)
        let body = try config.creation(status: status())
        XCTAssertEqual(body.view, "grid"); XCTAssertEqual(body.height, 360)
        XCTAssertFalse(body.audio); XCTAssertFalse(body.forceRelay)
        XCTAssertNil(config.exactHeight); XCTAssertNil(config.maximumHeight)
    }

    func testDetailAutoAndDataSaverNeverSelectGridOnlyRung() throws {
        let auto = try ViewerConfiguration(grid: false).creation(status: status())
        XCTAssertEqual(auto.view, "detail"); XCTAssertNil(auto.height); XCTAssertEqual(auto.maxHeight, 1080)
        let saver = try ViewerConfiguration(grid: false, maximumHeight: 2160, dataSaver: true).creation(status: status())
        XCTAssertEqual(saver.height, 720); XCTAssertEqual(saver.maxHeight, 720)
        XCTAssertThrowsError(try ViewerConfiguration(grid: false, exactHeight: 360).creation(status: status()))
        XCTAssertThrowsError(try ViewerConfiguration(grid: false, exactHeight: 2160).creation(status: status()))
    }

    func testAutoIsEncodedAsExplicitNullNotAMissingQuality() throws {
        let body = try ViewerConfiguration(grid: false).creation(status: status())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertTrue(object["height"] is NSNull)
        XCTAssertEqual(object["max_height"] as? Int, 1080)
    }

    func testSessionValidatesAllOwnedResourcesAndCurrentLease() throws {
        try session().validate(policy: policy(), configuration: .init(grid: false), now: 1000)
        for changes in [
            ["answer_url":"https://engine.invalid/answer"], ["quality_url":"/proxy/api/config"],
            ["expires_at":999], ["ice_transport_policy":"none"], ["heartbeat_seconds":0],
            ["initial_height":2160], ["protocol":"hls"], ["version":2],
        ] as [[String: Any]] {
            XCTAssertThrowsError(try session(changes).validate(policy: policy(), configuration: .init(grid: false), now: 1000))
        }
    }

    func testDataSaverRejectsAnUnauthorizedDetailLadderAndRelayPolicyMustMatch() throws {
        XCTAssertThrowsError(try session().validate(policy: policy(),
            configuration: .init(grid: false, maximumHeight: 720, dataSaver: true), now: 1000))
        XCTAssertThrowsError(try session().validate(policy: policy(),
            configuration: .init(grid: false, forceRelay: true), now: 1000))
        XCTAssertNoThrow(try session(["ice_transport_policy":"relay",
            "ice_servers":[["urls":["turns:relay.invalid:5349?transport=tcp"],"username":"temporary","credential":"ephemeral"]]]).validate(policy: policy(),
            configuration: .init(grid: false, forceRelay: true), now: 1000))
    }

    func testStandardICEStringsAndListsRequireTemporaryTurnCredentials() throws {
        let cases: [Any] = ["turns:relay.invalid:5349?transport=tcp", ["turn:relay.invalid:3478?transport=udp"]]
        for urls in cases {
            let server = try decode(ICEServer.self, ["urls":urls,"username":"temporary","credential":"ephemeral"])
            XCTAssertNoThrow(try ViewerSessionDescription.validateICE(server))
        }
        for urls in ["https://engine.invalid", "turn:relay.invalid", "turns:user:secret@relay.invalid"] {
            let server = try decode(ICEServer.self, ["urls":[urls]])
            XCTAssertThrowsError(try ViewerSessionDescription.validateICE(server))
        }
    }

    func testCandidateQueueWaitsForAnswerAndBatchesAtMost32PreservingSDKFields() throws {
        var queue = ViewerCandidateQueue()
        for index in 0..<35 {
            try queue.append(ViewerCandidate(candidate: "candidate:\(index)", sdpMLineIndex: Int32(index % 2),
                sdpMid: index % 2 == 0 ? "v-original" : "a-original", usernameFragment: "ufrag"))
        }
        XCTAssertTrue(queue.takeBatch().isEmpty)
        queue.acceptAnswer()
        let first = queue.takeBatch()
        XCTAssertEqual(first.count, 32); XCTAssertEqual(first[1].sdpMid, "a-original")
        XCTAssertEqual(first[1].sdpMLineIndex, 1)
        XCTAssertEqual(first[0].usernameFragment, "ufrag")
        XCTAssertEqual(queue.takeBatch().count, 3); XCTAssertFalse(queue.hasReadyBatch)
        XCTAssertThrowsError(try ViewerCandidate(candidate: "", sdpMLineIndex: 0, sdpMid: nil))
    }

    func testCandidateQueueIsBoundedWithoutDroppingOrPostingAnEndMarker() throws {
        var queue = ViewerCandidateQueue()
        let candidate = try ViewerCandidate(candidate: "candidate:test", sdpMLineIndex: 0, sdpMid: nil)
        for _ in 0..<256 { try queue.append(candidate) }
        XCTAssertThrowsError(try queue.append(candidate))
    }

    func testLateCreationCannotAcquireOwnershipAfterNavigationOrAccountChange() {
        var state = ViewerOwnershipState()
        let generation = state.generation
        state.invalidate()
        XCTAssertFalse(state.acceptCreated(id, generation: generation))
        XCTAssertNil(state.activeID)
        XCTAssertTrue(state.acceptCreated(id, generation: state.generation))
        state.invalidate()
        XCTAssertNil(state.activeID)
    }

    func testHeartbeatCannotResurrectExpiredOrDifferentViewer() throws {
        var lease = ViewerLeaseState()
        try lease.accept(id: id, expiresAt: 1030, interval: 10, now: 1000)
        let update = try decode(ViewerHeartbeat.self, ["session_id":id.uuidString,"expires_at":1040])
        try lease.renew(update, now: 1010)
        XCTAssertEqual(lease.expiresAt, 1040)
        XCTAssertThrowsError(try lease.renew(update, now: 1040))
        let wrong = try decode(ViewerHeartbeat.self, ["session_id":UUID().uuidString,"expires_at":1050])
        XCTAssertThrowsError(try lease.renew(wrong, now: 1020))
    }

    func testServerOfferAndReceiveOnlyAnswerAreNotClientOfferSignaling() throws {
        XCTAssertNoThrow(try ViewerSDP(type: "offer", sdp: "v=0\r\nm=video 9 RTP/SAVPF 96\r\na=sendonly\r\n").validate(expected: "offer"))
        XCTAssertNoThrow(try ViewerSDP(type: "answer", sdp: "v=0\r\nm=video 9 RTP/SAVPF 96\r\na=recvonly\r\n").validate(expected: "answer", receiveOnly: true))
        XCTAssertThrowsError(try ViewerSDP(type: "answer", sdp: "v=0\r\nm=video 9 RTP/SAVPF 96\r\na=sendrecv\r\n").validate(expected: "answer", receiveOnly: true))
    }

    func testHTTPFailuresHaveDistinctActionableMessages() {
        let statuses = [401,403,404,409,410,422,429,503]
        XCTAssertEqual(Set(statuses.map { viewingFailureMessage(HorizonError.http($0)) }).count, statuses.count)
        XCTAssertTrue(viewingFailureMessage(HorizonError.http(401)).contains("Sign in"))
        XCTAssertFalse(viewingFailureMessage(HorizonError.http(403)).contains("Sign in"))
    }

    func testTourSwitchesWithoutRetainingAnInvisibleIncomingViewer() {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden"])
        playback.selectWithoutPreload("garden")
        XCTAssertEqual(playback.current?.cameraID, "garden")
        XCTAssertEqual(playback.slots.count, 1)
        XCTAssertNil(playback.incoming)
        XCTAssertFalse(playback.current?.ready ?? true)
        let original = playback
        playback.selectWithoutPreload("not_allowed")
        XCTAssertEqual(playback, original)
    }
}
