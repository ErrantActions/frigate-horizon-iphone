import XCTest
@testable import HorizonCore

final class HLSPlaybackHealthTests: XCTestCase {
    func testAutoCapReleasesForSustainedPlaybackEvenWithAShortLLHLSBuffer() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 1_876_000)
        state.observe(now: 0, decodedVideo: true, bufferedAhead: 0.25, playing: true, restrictedNetwork: false)
        state.observe(now: 7.9, decodedVideo: true, bufferedAhead: 0.25, playing: true, restrictedNetwork: false)
        XCTAssertEqual(state.preferredPeakBitRate, 1_876_000)
        state.observe(now: 8, decodedVideo: true, bufferedAhead: 0.25, playing: true, restrictedNetwork: false)
        XCTAssertEqual(state.preferredPeakBitRate, 0)
    }

    func testNoCapReleaseBeforeDecodedVideoOrWhilePausedAndRestricted() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 100)
        for time in [0.0, 10, 30] {
            state.observe(now: time, decodedVideo: false, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        }
        XCTAssertFalse(state.released)
        state.observe(now: 40, decodedVideo: true, bufferedAhead: 0.2, playing: true, restrictedNetwork: false)
        state.observe(now: 45, decodedVideo: true, bufferedAhead: 0.2, playing: false, restrictedNetwork: false)
        state.observe(now: 50, decodedVideo: true, bufferedAhead: 0.2, playing: true, restrictedNetwork: false)
        state.observe(now: 59, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: true)
        XCTAssertFalse(state.released)
    }

    func testReliableLiveDelayAndBufferTargetsDoNotAlterMediaClocks() {
        XCTAssertEqual(HLSPlaybackTuning.liveDelay, 6)
        XCTAssertEqual(HLSPlaybackTuning.forwardBuffer(grid: true), 3)
        XCTAssertEqual(HLSPlaybackTuning.forwardBuffer(grid: false), 6)
    }

    func testGridCannotInheritAnExact4KPinOrAudioPreference() throws {
        let status = try JSONDecoder().decode(LiveHLSStatus.self, from: Data("""
        {"version":1,"protocol":"ll-hls","enabled":true,"available":true,
        "playlist":"front/live/hls/master.m3u8",
        "renditions":[{"height":720,"bitrate":1200},{"height":2160,"bitrate":10000}]}
        """.utf8))
        let policy = try LiveHLSResourcePolicy(address: ServerAddress("https://dvr.invalid/base"), camera: "front")
        let tile = LiveHLSConfiguration(maximumHeight: 2160, exactHeight: 2160, grid: true, audio: true)
        XCTAssertNil(tile.exactHeight)
        XCTAssertFalse(tile.audio)
        let url = try tile.masterURL(status: status, policy: policy)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [.init(name: "audio", value: "false"), .init(name: "height", value: "720")])
        XCTAssertEqual(try tile.masterURL(status: status, policy: policy),
            try LiveHLSConfiguration(grid: true).masterURL(status: status, policy: policy))
    }

    func testTransientRecoveryUsesTwoRetriesAndBoundedBackoffOnly() {
        var state = HLSRecoveryPolicy()
        XCTAssertEqual(state.nextDelay(for: HorizonError.http(404), jitter: 0), 1)
        XCTAssertEqual(state.nextDelay(for: URLError(.networkConnectionLost), jitter: 1), 4)
        XCTAssertNil(state.nextDelay(for: HorizonError.http(503), jitter: 0))
        XCTAssertEqual(state.attempts, 2)
    }

    func testAuthDenialTLSAndPackagingFailuresNeverConsumeRetryBudget() {
        let errors: [Error] = [HorizonError.unauthorized, HorizonError.forbidden,
            URLError(.serverCertificateUntrusted), HorizonError.unexpectedResponse,
            HorizonError.http(422), CancellationError()]
        for error in errors {
            var state = HLSRecoveryPolicy()
            XCTAssertNil(state.nextDelay(for: error, jitter: 0.5))
            XCTAssertEqual(state.attempts, 0)
        }
    }

    func testGatewayTimeoutOfflineAndStallFailuresAreEligibleButBounded() {
        let errors: [Error] = [HorizonError.http(408), HorizonError.http(429), HorizonError.http(502),
            HorizonError.http(503), HorizonError.http(504), URLError(.notConnectedToInternet),
            HLSPlaybackFailure.stalled, HLSPlaybackFailure.startupTimedOut]
        for error in errors {
            var state = HLSRecoveryPolicy()
            XCTAssertNotNil(state.nextDelay(for: error, jitter: -2))
            XCTAssertNotNil(state.nextDelay(for: error, jitter: .nan))
            XCTAssertNil(state.nextDelay(for: error, jitter: 0))
        }
    }

    func testConcurrentCameraRecoveryReservationsAreStaggered() {
        var schedule = HLSRecoverySchedule()
        let waits = (0..<8).map { _ in schedule.reserve(now: 100, backoff: 1) }
        XCTAssertEqual(waits.first, 1)
        for index in 1..<waits.count { XCTAssertEqual(waits[index] - waits[index - 1], 0.75) }
        XCTAssertEqual(schedule.reserve(now: 200, backoff: 3), 3)
    }

    func testStageTimingsAreIndependentFirstObservationsAndPrivacySafe() {
        var state = HLSStartupMeasurements()
        state.record(.statusFetch, seconds: 0.2)
        state.record(.statusFetch, seconds: 10)
        state.record(.request(.init(kind: .master, elapsed: 0.4, firstByte: 0.1, status: 200, bytes: 300)))
        state.record(.request(.init(kind: .childPlaylist, elapsed: 0.1, firstByte: 0.05, status: 200, bytes: 200)))
        state.record(.request(.init(kind: .initialization, elapsed: 0.3, firstByte: 0.1, status: 200, bytes: 400)))
        state.record(.playerReady, seconds: 1.2)
        state.record(.firstDisplayedFrame, seconds: 1.5)
        XCTAssertEqual(state.stages[.statusFetch], 0.2)
        XCTAssertEqual(state.stages[.masterFetch], 0.4)
        XCTAssertEqual(state.stages[.initFetch], 0.3)
        XCTAssertEqual(state.stages[.firstDisplayedFrame], 1.5)
        XCTAssertEqual(state.requestCount, 3)
        XCTAssertFalse(state.report.contains("http"))
        XCTAssertFalse(state.report.contains("Cookie"))
    }

    func testPartTargetChangesAndHTTPFailuresAreEvidenceNotFakeFrameTiming() {
        var state = HLSStartupMeasurements()
        state.record(.partTarget(0.25))
        state.record(.partTarget(0.5))
        state.record(.partTarget(0.25))
        state.record(.partTarget(.nan))
        state.record(.request(.init(kind: .initialization, elapsed: 0.2, firstByte: nil, status: 403, bytes: 0)))
        XCTAssertEqual(state.partTargets, [0.25, 0.5])
        XCTAssertEqual(state.httpFailures, [403])
        XCTAssertNil(state.stages[.initFetch])
        XCTAssertNil(state.stages[.firstDisplayedFrame])
        XCTAssertTrue(state.report.contains("firstDisplayedFrame: not observed"))
    }
}
