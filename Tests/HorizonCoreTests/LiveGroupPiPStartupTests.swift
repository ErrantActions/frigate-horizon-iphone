import XCTest
@testable import HorizonCore

final class LiveGroupPiPStartupTests: XCTestCase {
    func testOrdinaryAppDepartureNeverRetainsAnUnarmedGroup() {
        let state = LiveGroupPiPStartup()
        XCTAssertFalse(state.retainsPlayers(now: 100))
        XCTAssertEqual(state.phase, .idle)
    }
    func testExplicitStartupRetainsFramesBeforeTheAsyncWillStartCallback() {
        var state = LiveGroupPiPStartup()
        state.begin(now: 100)
        XCTAssertTrue(state.retainsPlayers(now: 101))
        XCTAssertTrue(state.requestIfReady(now: 101, previewReady: true, firstFrame: true, possible: true))
        XCTAssertEqual(state.phase, .requested)
        XCTAssertTrue(state.retainsPlayers(now: 102), "Leaving the app before willStart must not close the camera sessions.")
        state.willStart(); state.didStart()
        XCTAssertTrue(state.retainsPlayers(now: 1000))
        XCTAssertEqual(state.phase, .active)
    }
    func testSizedPreviewFirstMosaicAndSystemPossibilityAreAllRequired() {
        for preview in [false,true] {
            for frame in [false,true] {
                for possible in [false,true] {
                    var state = LiveGroupPiPStartup(); state.begin(now: 100)
                    XCTAssertEqual(state.requestIfReady(now: 101, previewReady: preview,
                        firstFrame: frame, possible: possible), preview && frame && possible)
                }
            }
        }
    }
    func testStartupHasOneRequestAndAnExactTenSecondDeadline() {
        var state = LiveGroupPiPStartup(); state.begin(now: 100)
        XCTAssertTrue(state.requestIfReady(now: 101, previewReady: true, firstFrame: true, possible: true))
        XCTAssertFalse(state.requestIfReady(now: 102, previewReady: true, firstFrame: true, possible: true))
        XCTAssertTrue(state.retainsPlayers(now: 109.999))
        XCTAssertFalse(state.retainsPlayers(now: 110))
        XCTAssertTrue(state.expire(now: 110))
        XCTAssertEqual(state.phase, .idle)
        state.willStart(); state.didStart()
        XCTAssertFalse(state.retainsPlayers(now: 111), "Late callbacks must not revive a cancelled owner.")
    }
    func testArmedAutomaticStartCanBeAcceptedWithoutAManualStartCallback() {
        var state = LiveGroupPiPStartup(); state.begin(now: 100)
        state.willStart(); state.didStart()
        XCTAssertEqual(state.phase, .active)
        XCTAssertFalse(state.expire(now: 120))
        state.cancel()
        XCTAssertFalse(state.retainsPlayers(now: 121))
    }
    func testPreviewDepartureCancelsPreparationOnlyWhenStillNavigatingInForeground() {
        var state = LiveGroupPiPStartup(); state.begin(now: 100)
        XCTAssertTrue(state.shouldCancelDetachedPreview(foreground: true))
        XCTAssertFalse(state.shouldCancelDetachedPreview(foreground: false))
        _ = state.requestIfReady(now: 101, previewReady: true, firstFrame: true, possible: true)
        XCTAssertFalse(state.shouldCancelDetachedPreview(foreground: true))
    }
}
