import XCTest
@testable import HorizonCore

// Draft DTO fixtures only; these resource names are not production endpoints.
private actor FixtureHTTPWindows: RecordedHTTPTransport {
    nonisolated let qualification: RecordedHTTPQualification = .fixture
    nonisolated let address = try! ServerAddress("https://dvr.invalid/proxy")
    private(set) var creates = 0
    private(set) var closes: [String] = []
    private(set) var activeCreates = 0
    private(set) var maximumActiveCreates = 0
    var delay = false
    var createError: HorizonError?
    var closeFailures = 0
    var immutable = true
    private var started: [CheckedContinuation<Void, Never>] = []
    func configure(delay: Bool = false, error: HorizonError? = nil, closeFailures: Int = 0, immutable: Bool = true) {
        self.delay=delay; createError=error; self.closeFailures=closeFailures; self.immutable=immutable
    }
    func waitForCreation() async {
        if creates > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }
    func discover(camera: String) async throws -> RecordedHTTPCapability {
        .init(maxWindowSeconds: 120, qualities: [.auto,.h360,.h720,.h1080,.original])
    }
    func sourceRange(selection: RecordedViewingSelection) async throws -> ClosedRange<Double> { 100...500 }
    func create(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest) async throws -> RecordedHTTPWindow {
        creates += 1; let id = "fixture-\(creates)"
        activeCreates += 1; maximumActiveCreates = max(maximumActiveCreates, activeCreates)
        for continuation in started { continuation.resume() }; started.removeAll()
        defer { activeCreates -= 1 }
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if let createError { throw createError }
        return .init(sessionID: id, camera: selection.camera, state: .ready, quality: request.quality, audio: true,
            statusURL: address.endpoint(["api","fixtures",id,"status"]),
            closeURL: address.endpoint(["api","fixtures",id]),
            mediaURL: address.endpoint(["api","fixtures",id,"content.mp4"]),
            hardExpiresAt: Date().timeIntervalSince1970 + 60,
            timeline: [.init(sourceStart: request.after, sourceEnd: request.before, mediaStart: 0, mediaEnd: request.before - request.after)])
    }
    func status(window: RecordedHTTPWindow) async throws -> RecordedHTTPWindow { window }
    func mediaInfo(window: RecordedHTTPWindow) async throws -> RecordedHTTPMediaInfo {
        .init(length: 4096, complete: true, immutable: immutable, fastStart: true, rangeSupported: true)
    }
    func close(window: RecordedHTTPWindow) async throws {
        if closeFailures > 0 { closeFailures -= 1; throw HorizonError.http(503) }
        closes.append(window.sessionID)
    }
}

final class RecordedViewingTests: XCTestCase {
    private let selection = RecordedViewingSelection(camera: "front", identity: .timeRange(start: 100, end: 500))
    private func request(_ at: Double = 125, quality: RecordedHTTPQuality = .auto) throws -> RecordedHTTPWindowRequest {
        try .bounded(sourceRange: 100...500, at: at, maximum: 120, quality: quality)
    }
    func testUnknownProductionContractCannotBeEnabledByAServerVersion() async throws {
        let transport = UnavailableRecordedHTTPTransport(address: try ServerAddress("https://dvr.invalid"))
        XCTAssertFalse(transport.qualification.usable)
        XCTAssertFalse(RecordedHTTPQualification.finalized(contractID: "").usable)
        let manager = RecordedHTTPWindowManager(transport: transport)
        do { _ = try await manager.prepare(selection: selection, request: request(), playing: true); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.unavailable.localizedDescription) }
    }
    func testDraftCapabilityRequiresHTTPSMP4RangeAndUnchangedOriginalsWithoutHLS() throws {
        let valid = try JSONEncoder().encode(RecordedHTTPCapability(maxWindowSeconds: 120, qualities: [.auto,.h720]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for change in [["version":2],["transport":"webrtc"],["seek":"clock"],["hls_fallback":true],
                       ["original_recordings_unchanged":false],["max_window_seconds":121],["enabled":false],
                       ["available":false],["qualities":[]]] as [[String: Any]] {
            var value = object; value.merge(change) { _, new in new }
            let caps = try JSONDecoder().decode(RecordedHTTPCapability.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try caps.validate())
        }
    }
    func testAPIResourceResolutionKeepsProxySubpathAndRejectsEscapes() throws {
        let policy = try RecordedHTTPResourcePolicy(address: ServerAddress("https://dvr.invalid/proxy"))
        XCTAssertEqual(try policy.resolve("fixtures/a/movie.mp4").absoluteString, "https://dvr.invalid/proxy/api/fixtures/a/movie.mp4")
        for url in ["http://dvr.invalid/proxy/api/a.mp4", "https://other.invalid/proxy/api/a.mp4",
                    "/vod/a.mp4", "/api/a.mp4", "../a.mp4", "a/%2e%2e/secret.mp4",
                    "a/%2Fsecret.mp4", "a.mp4?token=secret", "https://u:p@dvr.invalid/proxy/api/a.mp4",
                    "a.mp4#x", "a/%252e%252e/file.mp4"] {
            XCTAssertThrowsError(try policy.resolve(url), url)
        }
    }
    func testTimelineMapsDifferentDurationsAndBothKindsOfGapsWithoutInterpolation() throws {
        let map = try RecordedHTTPMapping(spans: [
            .init(sourceStart: 100, sourceEnd: 110, mediaStart: 5, mediaEnd: 13),
            .init(sourceStart: 120, sourceEnd: 130, mediaStart: 13, mediaEnd: 23),
            .init(sourceStart: 130, sourceEnd: 140, mediaStart: 25, mediaEnd: 35)])
        XCTAssertEqual(map.mediaTime(for: 105), 9)
        XCTAssertEqual(map.sourceTime(for: 9), 105)
        XCTAssertNil(map.mediaTime(for: 115))
        XCTAssertNil(map.sourceTime(for: 24))
        XCTAssertEqual(map.sourceTime(for: 13), 120)
        XCTAssertEqual(map.runEnd(at: 9), 13)
        XCTAssertEqual(map.runEnd(at: 14), 23)
        XCTAssertNil(map.mediaTime(for: .nan))
    }
    func testInvalidOverlappingAndReversedTimelinesFail() {
        XCTAssertThrowsError(try RecordedHTTPMapping(spans: []))
        XCTAssertThrowsError(try RecordedHTTPMapping(spans: [.init(sourceStart: 2, sourceEnd: 1, mediaStart: 0, mediaEnd: 1)]))
        XCTAssertThrowsError(try RecordedHTTPMapping(spans: [
            .init(sourceStart: 1, sourceEnd: 3, mediaStart: 0, mediaEnd: 2),
            .init(sourceStart: 2, sourceEnd: 4, mediaStart: 2, mediaEnd: 4)]))
    }
    func testWindowDefaultsToThirtySecondsNotTheMaximumAndHonorsTheExclusiveEnd() throws {
        XCTAssertEqual(try request().before - request().after, 30)
        let short = try RecordedHTTPWindowRequest.bounded(sourceRange: 100...500, at: 125, maximum: 10, quality: .h720)
        XCTAssertEqual(short.before - short.after, 10)
        XCTAssertThrowsError(try RecordedHTTPWindowRequest(after: 100, before: 220.1, startTimestamp: 110, quality: .auto))
        XCTAssertThrowsError(try RecordedHTTPWindowRequest(after: 100, before: 130, startTimestamp: 130, quality: .auto))
        XCTAssertThrowsError(try request(500))
    }
    func testDataSaverAndPinsUseOnlyAdvertisedQualities() throws {
        let caps = RecordedHTTPCapability(maxWindowSeconds: 120, qualities: [.auto,.h360,.h720])
        XCTAssertEqual(try caps.quality(.auto, dataSaver: true), .h360)
        XCTAssertEqual(try caps.quality(.h720, dataSaver: false), .h720)
        XCTAssertThrowsError(try caps.quality(.h2160, dataSaver: false))
        XCTAssertThrowsError(try RecordedHTTPCapability(maxWindowSeconds: 120, qualities: [.original]).quality(.auto, dataSaver: true))
    }
    func testReadyImmutableWindowAndQualityReplacementPreservePausedIntent() async throws {
        let fixture = FixtureHTTPWindows()
        let manager = RecordedHTTPWindowManager(transport: fixture)
        let first = try await manager.prepare(selection: selection, request: request(), playing: false)
        let second = try await manager.prepare(selection: selection, request: request(125, quality: .h720), playing: false)
        XCTAssertFalse(first.playingIntent); XCTAssertFalse(second.playingIntent)
        XCTAssertEqual(second.request.startTimestamp, first.request.startTimestamp)
        XCTAssertEqual(second.window.quality, .h720)
        let closed = await fixture.closes
        XCTAssertEqual(closed, [first.window.sessionID])
        await manager.cancel(); try await manager.finishCleanup()
        let final = await fixture.closes
        XCTAssertEqual(final.count, 2)
    }
    func testRepeatedInWindowSeeksKeepTheSameOwnedAssetAndOnlyOutsideSeeksReplace() async throws {
        let fixture = FixtureHTTPWindows()
        let actual = RecordedHTTPWindowManager(transport: fixture)
        let ready = try await actual.prepare(selection: selection, request: request(), playing: false)
        for time in [125.0,126,130] {
            guard case .native = ready.seekDecision(at: time) else { return XCTFail("In-window seek must stay native") }
        }
        XCTAssertEqual(ready.seekDecision(at: 250), .replacement)
        XCTAssertEqual(ready.seekDecision(at: .nan), .gap)
        let count = await fixture.creates; XCTAssertEqual(count, 1)
        await actual.cancel(); try await actual.finishCleanup()
    }
    func testLateCreationAfterNavigationIsClosedExactlyOnce() async throws {
        let fixture = FixtureHTTPWindows(); await fixture.configure(delay: true)
        let manager = RecordedHTTPWindowManager(transport: fixture)
        let pending = Task { try await manager.prepare(selection: selection, request: request(), playing: true) }
        await fixture.waitForCreation()
        await manager.cancel()
        do { _ = try await pending.value; XCTFail() } catch is CancellationError {}
        try await manager.finishCleanup()
        let closed = await fixture.closes
        XCTAssertEqual(closed, ["fixture-1"])
    }
    func testReplacementSerializesCreationAndLatestIntentWins() async throws {
        let fixture = FixtureHTTPWindows(); await fixture.configure(delay: true)
        let manager = RecordedHTTPWindowManager(transport: fixture)
        let first = Task { try await manager.prepare(selection: selection, request: request(125), playing: true) }
        await fixture.waitForCreation()
        let result = try await manager.prepare(selection: selection, request: request(220, quality: .h1080), playing: false)
        do { _ = try await first.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(result.request.startTimestamp, 220)
        XCTAssertFalse(result.playingIntent)
        let maximum = await fixture.maximumActiveCreates
        XCTAssertEqual(maximum, 1)
        await manager.cancel(); try await manager.finishCleanup()
    }
    func testIncompleteOrMutableFilesNeverBecomeReadyAssets() async throws {
        let fixture = FixtureHTTPWindows(); await fixture.configure(immutable: false)
        let manager = RecordedHTTPWindowManager(transport: fixture)
        do { _ = try await manager.prepare(selection: selection, request: request(), playing: true); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.rangeUnsupported.localizedDescription) }
        let closed = await fixture.closes
        XCTAssertEqual(closed.count, 1)
    }
    func testCleanupFailureIsRetainedAndRetryable() async throws {
        let fixture = FixtureHTTPWindows()
        let manager = RecordedHTTPWindowManager(transport: fixture)
        _ = try await manager.prepare(selection: selection, request: request(), playing: true)
        await fixture.configure(closeFailures: 1)
        await manager.cancel()
        do { try await manager.finishCleanup(); XCTFail() } catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, 503) }
        try await manager.retryCleanup()
        let closed = await fixture.closes
        XCTAssertEqual(closed, ["fixture-1"])
    }
    func testAuthExpiryAndDenialAreDistinctAndDoNotReplayCreation() async throws {
        for expected in [HorizonError.unauthorized, .forbidden] {
            let fixture = FixtureHTTPWindows(); await fixture.configure(error: expected)
            let manager = RecordedHTTPWindowManager(transport: fixture)
            do { _ = try await manager.prepare(selection: selection, request: request(), playing: true); XCTFail() }
            catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, expected.httpStatusCode) }
            let count = await fixture.creates
            XCTAssertEqual(count, 1)
        }
    }
    func testUnknownCreationIsQuarantinedRatherThanReplayed() async throws {
        let fixture = FixtureHTTPWindows(); await fixture.configure(error: .http(502))
        let manager = RecordedHTTPWindowManager(transport: fixture)
        do { _ = try await manager.prepare(selection: selection, request: request(), playing: true); XCTFail() }
        catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, 502) }
        do { _ = try await manager.prepare(selection: selection, request: request(), playing: true); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.uncertainCreation.localizedDescription) }
        let count = await fixture.creates; XCTAssertEqual(count, 1)
    }
}
