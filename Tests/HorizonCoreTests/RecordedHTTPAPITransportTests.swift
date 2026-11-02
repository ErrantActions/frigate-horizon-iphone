import XCTest
@testable import HorizonCore

private actor HTTPV1FixtureClient: RecordedHTTPControlClient {
    nonisolated let address = try! ServerAddress("https://dvr.invalid/proxy")
    nonisolated let cookies: [HTTPCookie] = []
    private(set) var methods: [String] = []
    private(set) var bodies: [Data] = []
    private var windows: [String: [String: Any]] = [:]
    var badSessionURL: String?
    var enabled = true
    var available = true
    var empty = false
    var directSupport = false
    var metadataStatus: Int?
    func configure(sessionURL: String? = nil, enabled: Bool = true, available: Bool = true, empty: Bool = false,
                   directSupport: Bool = false, metadataStatus: Int? = nil) {
        badSessionURL=sessionURL; self.enabled=enabled; self.available=available; self.empty=empty
        self.directSupport=directSupport; self.metadataStatus=metadataStatus
    }
    func request(_ url: URL, method: String, body: Data?, success: Set<Int>) async throws -> RecordedHTTPControlResponse {
        methods.append(method + " " + url.path)
        if let body { bodies.append(body) }
        let base = "front/recordings/http"
        var result: [String: Any] = [:]
        var status = 200
        if url.path.hasSuffix("/openapi.json") {
            if let metadataStatus { throw HorizonError.http(metadataStatus) }
            var properties: [String: Any] = Dictionary(uniqueKeysWithValues: ["version","after","before","start_timestamp","quality","start_policy"].map { ($0, [:] as [String: Any]) })
            var statusProperties: [String: Any] = [:]
            if directSupport {
                properties["delivery"]=["enum":["prepared","auto","direct"]]
                properties["video_codecs"]=["items":["enum":["h264","hevc"]]]
                properties["audio_codecs"]=["items":["enum":["aac","mp3","opus"]]]
                statusProperties=["delivery":["enum":["prepared","original_file"]],"preparation_reason":[:]]
            }
            result=["paths":["/{camera_name}/recordings/http/sessions":["post":[
                "requestBody":["content":["application/json":["schema":["$ref":"#/components/schemas/RecordedHTTPCreate"]]]],
                "responses":["202":["content":["application/json":["schema":["$ref":"#/components/schemas/RecordedHTTPStatus"]]]]]]]],
                "components":["schemas":["RecordedHTTPCreate":["properties":properties],"RecordedHTTPStatus":["properties":statusProperties]]]]
        } else if url.path.hasSuffix("/status") {
            result = ["version":1,"enabled":enabled,"available":available,"transport":"https_mp4","seek":"http_byte_range",
                "max_window_seconds":30,"original_recordings_unchanged":true,"hls_fallback":false,
                "session_url":badSessionURL ?? base + "/sessions","resolve_url":base + "/resolve",
                "qualities":["auto","original","360","720","1080","2160"]]
        } else if url.path.hasSuffix("/resolve") {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
            XCTAssertNil(request["quality"])
            result = request
            result["effective_start_timestamp"] = try XCTUnwrap(request["start_timestamp"] as? Double) + 0.25
            result["exhausted"]=false; result["searched_before"]=request["before"]; result["reason"]="frame_found"
        } else if method == "POST" {
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
            XCTAssertEqual(request["start_policy"] as? String, "next")
            let id = UUID().uuidString.lowercased()
            let path = base + "/sessions/" + id
            let quality = try XCTUnwrap(request["quality"] as? String)
            let original = request["delivery"] as? String == "auto" && (quality == "auto" || quality == "original")
            result = ["version":1,"session_id":id,"camera":"front","state":"preparing",
                "quality":quality == "auto" ? "720" : quality,
                "audio":true,"status_url":path,"close_url":path,"media_url":path + "/media.mp4",
                "hard_expires_at":Date().timeIntervalSince1970 + 120,"timeline":[],
                "after":request["after"]!,"before":request["before"]!,"start_timestamp":request["start_timestamp"]!,
                "effective_start_timestamp":NSNull(),"next_timestamp":request["before"]!,
                "error":NSNull(),"width":NSNull(),"height":NSNull(),
                "delivery": original ? "original_file" : "prepared",
                "preparation_reason":NSNull()]
            if original {
                let before = try XCTUnwrap(request["before"] as? Double) - 5
                result["before"]=before; result["next_timestamp"]=before; result["quality"]="original"
                result["state"]="ready"; result["effective_start_timestamp"]=request["start_timestamp"]
                let after = try XCTUnwrap(request["after"] as? Double)
                result["timeline"]=[["source_start":after,"source_end":before,"media_start":4,"media_end":4 + before - after]]
            }
            windows[id]=result; status=202
        } else if method == "DELETE" {
            windows.removeValue(forKey: url.lastPathComponent)
            status=204
        } else {
            let id = url.lastPathComponent
            result = try XCTUnwrap(windows[id])
            let after = try XCTUnwrap(result["after"] as? Double), before = try XCTUnwrap(result["before"] as? Double)
            let start = try XCTUnwrap(result["start_timestamp"] as? Double)
            result["state"]=empty ? "empty" : "ready"
            result["effective_start_timestamp"]=empty ? NSNull() : start
            let lead = result["quality"] as? String == "original" ? 2.0 : 0.0
            result["timeline"] = empty ? [] : [["source_start":after - lead,"source_end":before - 0.02,
                "media_start":5.0,"media_end":5 + before - after + lead - 0.02]]
            result["width"]=1280; result["height"]=720
        }
        guard success.contains(status) else { throw HorizonError.http(status) }
        return RecordedHTTPControlResponse(data: try JSONSerialization.data(withJSONObject: result), status: status, headers: [:])
    }
}

final class RecordedHTTPAPITransportTests: XCTestCase {
    private let selection = RecordedViewingSelection(camera: "front", identity: .timeRange(start: 100, end: 200))
    func testPublished202PreparingPollAndCanonicalNextAreWiredExactly() async throws {
        let client = HTTPV1FixtureClient()
        let actual = try RecordedHTTPAPITransport(client: client)
        let caps = try await actual.discover(camera: "front")
        XCTAssertEqual(caps.maxWindowSeconds, 30)
        let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: .auto)
        let preparing = try await actual.create(selection: selection, request: request)
        XCTAssertEqual(preparing.state, .preparing)
        let ready = try await actual.status(window: preparing)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.nextTimestamp, 120)
        XCTAssertEqual(ready.timeline.last?.sourceEnd, 119.98)
        XCTAssertEqual(ready.effectiveStartTimestamp, 105)
        XCTAssertTrue(ready.mediaURL?.path.hasPrefix("/proxy/api/front/recordings/http/sessions/") == true)
        try await actual.close(window: ready)
        let methods = await client.methods
        XCTAssertTrue(methods.contains("POST /proxy/api/front/recordings/http/sessions"))
        XCTAssertTrue(methods.contains(where: { $0.hasPrefix("DELETE /proxy/api/front/recordings/http/sessions/") }))
    }
    func testDiscoveryCannotAuthorizeAResourceOutsideItsCameraProxyScope() async throws {
        for url in ["https://other.invalid/api/sessions", "/api/front/recordings/http/sessions",
                    "other/recordings/http/sessions", "front/recordings/webrtc/sessions"] {
            let client = HTTPV1FixtureClient(); await client.configure(sessionURL: url)
            let transport = try RecordedHTTPAPITransport(client: client)
            do { _ = try await transport.discover(camera: "front"); XCTFail() }
            catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.invalidContract.localizedDescription) }
            let methods = await client.methods; XCTAssertEqual(methods.count, 1)
        }
    }
    func testUnavailableDiscoveryDoesNotCreateOrResolve() async throws {
        let client = HTTPV1FixtureClient(); await client.configure(available: false)
        let transport = try RecordedHTTPAPITransport(client: client)
        do { _ = try await transport.discover(camera: "front"); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.unavailable.localizedDescription) }
        let methods = await client.methods; XCTAssertEqual(methods.count, 1)
    }
    func testResolverUsesNoQualityAndValidatesEffectiveFrameAndSearchBounds() async throws {
        let client = HTTPV1FixtureClient()
        let actual = try RecordedHTTPAPITransport(client: client)
        let request = try RecordedHTTPResolveRequest(after: 100, before: 3700, startTimestamp: 101)
        let result = try await actual.resolve(camera: "front", request: request)
        XCTAssertEqual(try result.usableTimestamp(), 101.25)
        XCTAssertThrowsError(try RecordedHTTPResolveRequest(after: 100, before: 3700.1, startTimestamp: 101))
        XCTAssertThrowsError(try RecordedHTTPResolveRequest(after: 100, before: 120, startTimestamp: 120))
    }
    func testEmptyAndOriginalGOPLeadAreNotFakeReadinessOrRebasedTime() async throws {
        let client = HTTPV1FixtureClient()
        let actual = try RecordedHTTPAPITransport(client: client)
        let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: .original)
        let created = try await actual.create(selection: selection, request: request)
        let ready = try await actual.status(window: created)
        let map = try RecordedHTTPMapping(spans: ready.timeline)
        XCTAssertEqual(try XCTUnwrap(map.mediaTime(for: 105)), 12, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(map.sourceTime(for: 12)), 105, accuracy: 0.000000001)
        await client.configure(empty: true)
        let empty = try await actual.status(window: created)
        XCTAssertEqual(empty.state, .empty); XCTAssertNil(empty.effectiveStartTimestamp)
        XCTAssertTrue(empty.timeline.isEmpty)
        try await actual.close(window: empty)
    }
    func testNullUnexhaustedIsSearchLimitNotMissingFootage() throws {
        for exhausted in [true,false] {
            let request = try RecordedHTTPResolveRequest(after: 100, before: 120, startTimestamp: 101)
            let result = try JSONDecoder().decode(RecordedHTTPResolution.self, from: JSONSerialization.data(withJSONObject: [
                "version":1,"after":100,"before":120,"start_timestamp":101,
                "effective_start_timestamp":NSNull(),"exhausted":exhausted,
                "searched_before":120,"reason":exhausted ? "no_frame_in_range" : "search_limit"]))
            try result.validate(request: request)
            do { _ = try result.usableTimestamp(); XCTFail() }
            catch { XCTAssertEqual(error.localizedDescription, (exhausted ? RecordedHTTPError.gap : .searchLimit).localizedDescription) }
        }
    }
    func testRequestsAndContinuationLeadMatchThePublishedContract() throws {
        let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: .h720)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["version","after","before","start_timestamp","quality","start_policy"]))
        let next = try RecordedHTTPWindowRequest.continuation(sourceRange: 100...500, after: 120, maximum: 30, quality: .auto)
        XCTAssertEqual(next.after, 120); XCTAssertEqual(next.before, 140); XCTAssertEqual(next.startTimestamp, 120)
        XCTAssertEqual(try RecordedHTTPContinuationPolicy.leadSeconds(preparationSeconds: 4.5, windowSeconds: 10,
            nextWindowSeconds: 20, playbackRate: 1), 11)
        XCTAssertThrowsError(try RecordedHTTPContinuationPolicy.leadSeconds(preparationSeconds: .nan, windowSeconds: 10,
            nextWindowSeconds: 20, playbackRate: 1))
    }
    func testUpdatedOpenAPINegotiatesAutoOriginalAndClippedFileBoundary() async throws {
        let client = HTTPV1FixtureClient(); await client.configure(directSupport: true)
        let transport = try RecordedHTTPAPITransport(client: client)
        let caps = try await transport.discover(camera: "front")
        XCTAssertTrue(caps.deliveryContract.supportsDirectOriginal)
        let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: .auto)
        let window = try await transport.create(selection: selection, request: request)
        XCTAssertEqual(window.delivery, .originalFile); XCTAssertEqual(window.quality, .original)
        XCTAssertEqual(window.before, 115); XCTAssertEqual(window.nextTimestamp, 115)
        try window.validate(request: request)
        let sent = await client.bodies.last
        let encoded = try XCTUnwrap(sent)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(body["delivery"] as? String, "auto")
        XCTAssertEqual(body["video_codecs"] as? [String], ["h264"])
        XCTAssertEqual(body["audio_codecs"] as? [String], ["aac","mp3"])
        try await transport.close(window: window)
    }
    func testOlderOpenAPIAndUnavailableMetadataOmitAllNewFields() async throws {
        for unavailable in [false,true] {
            let client = HTTPV1FixtureClient()
            await client.configure(metadataStatus: unavailable ? 403 : nil)
            let transport = try RecordedHTTPAPITransport(client: client)
            let caps = try await transport.discover(camera: "front")
            XCTAssertFalse(caps.deliveryContract.supportsDirectOriginal)
            XCTAssertEqual(caps.deliveryContract.notice != nil, unavailable)
            let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: .auto)
            let window = try await transport.create(selection: selection, request: request)
            let sent = await client.bodies.last
            let encoded = try XCTUnwrap(sent)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(Set(body.keys), Set(["version","after","before","start_timestamp","quality","start_policy"]))
            try await transport.close(window: window)
        }
    }
    func testScaledDataSaverUsesPreparedOnUpdatedContract() async throws {
        let client = HTTPV1FixtureClient(); await client.configure(directSupport: true)
        let transport = try RecordedHTTPAPITransport(client: client)
        let caps = try await transport.discover(camera: "front")
        let saver = try caps.quality(.auto, dataSaver: true)
        let request = try RecordedHTTPWindowRequest(after: 100, before: 120, startTimestamp: 105, quality: saver)
        let window = try await transport.create(selection: selection, request: request)
        let sent = await client.bodies.last
        let encoded = try XCTUnwrap(sent)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(body["delivery"] as? String, "prepared")
        XCTAssertEqual(body["quality"] as? String, "360")
        try await transport.close(window: window)
    }
    func testDirectClippedWindowCanBeShorterThanMinimumCreationRange() throws {
        let url = URL(string: "https://dvr.invalid/proxy/api/front/recordings/http/sessions/x")!
        let request = try RecordedHTTPWindowRequest(after: 100, before: 110, startTimestamp: 100.01, quality: .original)
        let window = RecordedHTTPWindow(sessionID: "fixture", camera: "front", state: .ready, quality: .original,
            audio: false, statusURL: url, closeURL: url, mediaURL: url.appendingPathComponent("media.mp4"),
            hardExpiresAt: Date().timeIntervalSince1970 + 60,
            timeline: [.init(sourceStart: 100, sourceEnd: 100.05, mediaStart: 3, mediaEnd: 3.05)],
            after: 100, before: 100.05, startTimestamp: 100.01, effectiveStartTimestamp: 100.01,
            nextTimestamp: 100.05, delivery: .originalFile)
        try window.validate(policy: RecordedHTTPResourcePolicy(address: ServerAddress("https://dvr.invalid/proxy")),
            camera: "front", now: Date().timeIntervalSince1970)
        try window.validate(request: request)
        XCTAssertThrowsError(try RecordedHTTPWindowRequest(after: 100, before: 100.05, startTimestamp: 100.01, quality: .auto))
    }
    func testDirectLeadUsesMeasuredReadinessWithoutDurationScaling() throws {
        XCTAssertEqual(try RecordedHTTPContinuationPolicy.leadSeconds(preparationSeconds: 0.56, windowSeconds: 10,
            nextWindowSeconds: 20, playbackRate: 1, originalFile: true), 2.56, accuracy: 0.000001)
    }
}
