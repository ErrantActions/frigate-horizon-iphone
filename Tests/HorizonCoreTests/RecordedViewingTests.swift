import XCTest
@testable import HorizonCore

// Contract test double only. There is deliberately no production recorded-session endpoint.
private actor FakeRecordedSession: RecordedViewingSession {
    private(set) var closed = false
    private(set) var encoding = false
    func capabilities() async throws -> RecordedViewingCapabilities {
        .init(renditions: [.init(height: 720, bitrate: 1200)], playbackRates: [1,2],
            pauseSupported: true, seekSupported: true)
    }
    func positionEvents() async -> AsyncThrowingStream<RecordedViewingPosition, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func play() async throws { encoding = true }
    func pause() async throws { encoding = false }
    func seek(sourceTimestamp: Double, generation: UUID) async throws -> RecordedViewingPosition {
        .init(sourceTimestamp: sourceTimestamp, generation: generation, sequence: 1, playing: encoding)
    }
    func setRate(_ rate: Double) async throws {
        guard [1,2].contains(rate) else { throw HorizonError.message(ViewingMessage.recorded) }
    }
    func setQuality(_ height: Int?) async throws {
        guard height == nil || height == 720 else { throw HorizonError.message(ViewingMessage.recorded) }
    }
    func close() async throws { encoding = false; closed = true }
}

final class RecordedViewingTests: XCTestCase {
    func testOnlyAcknowledgedCurrentGenerationCanSupplyTheSourcePlayhead() {
        var state = RecordedViewingTimeline()
        let old = state.beginSeek()
        let current = state.beginSeek()
        XCTAssertFalse(state.accept(.init(sourceTimestamp: 123, generation: old, sequence: 9, playing: true)))
        XCTAssertFalse(state.acceptsFrame(generation: current))
        XCTAssertTrue(state.accept(.init(sourceTimestamp: 500, generation: current, sequence: 1, playing: false)))
        XCTAssertTrue(state.acceptsFrame(generation: current))
        XCTAssertFalse(state.acceptsFrame(generation: old))
        XCTAssertFalse(state.accept(.init(sourceTimestamp: 100, generation: current, sequence: 0, playing: true)))
        XCTAssertEqual(state.position?.sourceTimestamp, 500)
        XCTAssertFalse(state.position?.playing ?? true)
    }
    func testInvalidTimelineUpdatesDoNotFabricateARecordingPosition() {
        var state = RecordedViewingTimeline()
        XCTAssertFalse(state.accept(.init(sourceTimestamp: .nan, generation: state.generation, sequence: 1, playing: true)))
        XCTAssertFalse(state.accept(.init(sourceTimestamp: -1, generation: state.generation, sequence: 1, playing: true)))
        XCTAssertNil(state.position)
    }
    func testMockSeekAcknowledgementIsExplicitlyNotProductionPlayback() async throws {
        let mock = FakeRecordedSession()
        let caps = try await mock.capabilities()
        XCTAssertTrue(caps.seekSupported)
        try await mock.play()
        var timeline = RecordedViewingTimeline()
        let generation = timeline.beginSeek()
        let ack = try await mock.seek(sourceTimestamp: 1234.5, generation: generation)
        XCTAssertTrue(timeline.accept(ack))
        XCTAssertEqual(timeline.position?.sourceTimestamp, 1234.5)
        try await mock.pause()
        let paused = await mock.encoding
        XCTAssertFalse(paused)
        try await mock.close()
        let closed = await mock.closed
        XCTAssertTrue(closed)
        XCTAssertTrue(ViewingMessage.recorded.contains("not available"))
    }
}
