import XCTest
@testable import HorizonCore

private actor FrameSearchFixture: RecordedHTTPTransport {
    nonisolated let qualification: RecordedHTTPQualification = .fixture
    nonisolated let address = try! ServerAddress("https://dvr.invalid/proxy")
    let frame: Double?
    let limited: Bool
    let partial: Bool
    let delay: Bool
    private(set) var requests: [RecordedHTTPResolveRequest] = []
    private var start: CheckedContinuation<Void, Never>?
    init(frame: Double? = nil, limited: Bool = false, partial: Bool = false, delay: Bool = false) {
        self.frame=frame; self.limited=limited; self.partial=partial; self.delay=delay
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { start = $0 }
    }
    func resolve(camera: String, request: RecordedHTTPResolveRequest) async throws -> RecordedHTTPResolution {
        requests.append(request); start?.resume(); start = nil
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        let found = frame.flatMap { $0 >= request.startTimestamp && $0 < request.before ? $0 : nil }
        return try JSONDecoder().decode(RecordedHTTPResolution.self, from: JSONSerialization.data(withJSONObject: [
            "version":1,"after":request.after,"before":request.before,"start_timestamp":request.startTimestamp,
            "effective_start_timestamp": found.map { $0 as Any } ?? NSNull(),
            "exhausted":found == nil && !limited,
            "searched_before":partial ? request.startTimestamp : request.before,
            "reason":found != nil ? "frame_found" : (limited ? "search_limit" : "no_frame_in_range"),
        ]))
    }
    func discover(camera: String) async throws -> RecordedHTTPCapability { throw RecordedHTTPError.unsupportedSource }
    func sourceRange(selection: RecordedViewingSelection) async throws -> ClosedRange<Double> { throw RecordedHTTPError.unsupportedSource }
    func create(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest) async throws -> RecordedHTTPWindow { throw RecordedHTTPError.unsupportedSource }
    func status(window: RecordedHTTPWindow) async throws -> RecordedHTTPWindow { throw RecordedHTTPError.unsupportedSource }
    func mediaInfo(window: RecordedHTTPWindow) async throws -> RecordedHTTPMediaInfo { throw RecordedHTTPError.unsupportedSource }
    func close(window: RecordedHTTPWindow) async throws { throw RecordedHTTPError.unsupportedSource }
}

final class RecordedHTTPFrameSearchTests: XCTestCase {
    func testReproducesCodeFourWhenOldCallerStopsAfterFirstEmptyHour() async throws {
        let old = FrameSearchFixture(frame: 8200)
        let request = try RecordedHTTPResolveRequest(after: 1000, before: 4600, startTimestamp: 1000)
        let result = try await old.resolve(camera: "front", request: request)
        do { _ = try result.usableTimestamp(); XCTFail() }
        catch { XCTAssertEqual((error as NSError).code, 4) }
        let fixed = FrameSearchFixture(frame: 8200)
        let frame = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000, before: 10000, transport: fixed)
        XCTAssertEqual(frame, 8200)
        let calls = await fixed.requests
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.after), [1000,4600,8200])
        XCTAssertTrue(calls.allSatisfy { $0.before - $0.after <= 3600 && $0.startTimestamp < $0.before })
    }

    func testCanFindFootageAcrossTheWholeTwentyFiveHourReviewDay() async throws {
        let fixture = FrameSearchFixture(frame: 1000 + 24 * 3600 + 15)
        let frame = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000,
            before: 1000 + 25 * 3600, transport: fixture)
        XCTAssertEqual(frame, 1000 + 24 * 3600 + 15)
        let calls = await fixture.requests
        XCTAssertEqual(calls.count, 25)
    }

    func testOnlyFullyExhaustedSelectedRangeIsMissingFootage() async throws {
        let fixture = FrameSearchFixture()
        do {
            _ = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000, before: 8300, transport: fixture)
            XCTFail()
        } catch { XCTAssertEqual((error as? RecordedHTTPError)?.diagnosticIdentifier, "gap") }
        let calls = await fixture.requests
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last?.before, 8300)
    }

    func testServerSearchLimitNeverSkipsUnsearchedFootageOrClaimsItMissing() async throws {
        for partial in [true,false] {
            let fixture = FrameSearchFixture(limited: !partial, partial: partial)
            do {
                _ = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000, before: 20000, transport: fixture)
                XCTFail()
            } catch { XCTAssertEqual((error as? RecordedHTTPError)?.diagnosticIdentifier, "search-limit") }
            let calls = await fixture.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testClientRequestBoundIsExplicitSearchLimitNotMissingFootage() async throws {
        let fixture = FrameSearchFixture()
        do {
            _ = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000,
                before: 1000 + 30 * 3600, transport: fixture)
            XCTFail()
        } catch { XCTAssertEqual((error as? RecordedHTTPError)?.diagnosticIdentifier, "search-limit") }
        let calls = await fixture.requests
        XCTAssertEqual(calls.count, RecordedHTTPFrameSearch.maximumRequests)
    }

    func testCancellationStopsFurtherSearchRequests() async throws {
        let fixture = FrameSearchFixture(delay: true)
        let task = Task {
            try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: 1000, before: 10000, transport: fixture)
        }
        await fixture.waitForRequest(); task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let calls = await fixture.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testInvalidOrExclusiveEndTargetsDoNotSendARequest() async throws {
        let fixture = FrameSearchFixture()
        for value in [Double.nan, -1, 2000, 2001] {
            do {
                _ = try await RecordedHTTPFrameSearch.nextFrame(camera: "front", at: value, before: 2000, transport: fixture)
                XCTFail()
            } catch { XCTAssertEqual((error as? RecordedHTTPError)?.diagnosticIdentifier, "invalid-window") }
        }
        let calls = await fixture.requests
        XCTAssertTrue(calls.isEmpty)
    }
}
