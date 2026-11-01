import XCTest
@testable import HorizonCore

final class CameraTourTests: XCTestCase {
    func testHLSTourCandidatesExcludeDisabledHiddenWithoutRequiringLegacyStreamAliases() throws {
        let configuration = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{
          "front":{"enabled":true,"live":{"streams":{"Main":"front_main"}}},
          "disabled":{"enabled":false,"live":{"streams":{"Main":"disabled_main"}}},
          "hidden":{"enabled":true,"live":{"streams":{"Main":"hidden_main"}},"ui":{"dashboard":false}},
          "missing":{"enabled":true,"live":{"streams":{}}}
        }}
        """.utf8))
        XCTAssertEqual(configuration.orderedCameras.filter(\.isTourCandidate).map(\.id), ["front", "missing"])
    }

    func testTourUsesTheProvidedCameraOrderAndWrapsBothDirections() {
        var tour = CameraTourState(cameraIDs: ["front", "garden", "garage"])
        XCTAssertEqual(tour.currentID, "front")
        XCTAssertEqual(tour.position, 1)
        tour.previous()
        XCTAssertEqual(tour.currentID, "garage")
        XCTAssertEqual(tour.position, 3)
        tour.next()
        XCTAssertEqual(tour.currentID, "front")
        tour.next()
        XCTAssertEqual(tour.currentID, "garden")
    }

    func testDuplicateAndEmptyIDsDoNotRepeatOrCreateMissingCameras() {
        let tour = CameraTourState(cameraIDs: ["front", "front", "", "garden", "front"])
        XCTAssertEqual(tour.cameraIDs, ["front", "garden"])
        XCTAssertEqual(tour.currentID, "front")
    }

    func testPermissionOrConfigurationChangesDiscardUnavailableCameras() {
        var tour = CameraTourState(cameraIDs: ["front", "garden"])
        tour.next()
        tour.update(cameraIDs: ["garage", "garden", "front"])
        XCTAssertEqual(tour.currentID, "garden")
        XCTAssertEqual(tour.position, 2)
        tour.update(cameraIDs: ["front"])
        XCTAssertEqual(tour.currentID, "front")
        XCTAssertEqual(tour.position, 1)
        tour.update(cameraIDs: [])
        XCTAssertNil(tour.currentID)
        XCTAssertNil(tour.position)
    }

    func testEmptyAndSingleCameraToursCannotAdvanceToInvalidPositions() {
        var empty = CameraTourState()
        empty.next()
        empty.previous()
        XCTAssertNil(empty.currentID)
        var single = CameraTourState(cameraIDs: ["front"])
        single.next()
        single.previous()
        XCTAssertEqual(single.currentID, "front")
        XCTAssertEqual(single.position, 1)
    }

    func testConnectingDoesNotConsumeTheCameraViewingInterval() {
        XCTAssertNil(schedule(ready: false).advanceAfterSeconds)
        XCTAssertEqual(schedule(ready: true).advanceAfterSeconds, 15)
    }

    func testUnavailableCameraDoesNotSilentlyAdvance() {
        XCTAssertNil(schedule(ready: false, failed: true).advanceAfterSeconds)
        XCTAssertNil(schedule(ready: true, failed: true).advanceAfterSeconds)
    }

    func testPausedBackgroundSingleAndEmptyToursHaveNoAutomaticAdvance() {
        XCTAssertNil(schedule(cycling: false).advanceAfterSeconds)
        XCTAssertNil(schedule(foreground: false).advanceAfterSeconds)
        XCTAssertNil(schedule(count: 1).advanceAfterSeconds)
        XCTAssertNil(schedule(count: 0).advanceAfterSeconds)
        XCTAssertNil(schedule(cameraID: nil).advanceAfterSeconds)
    }

    func testEveryIntervalIsMeasuredInSecondsAfterReadiness() {
        XCTAssertEqual(CameraTourInterval.allCases.map(\.rawValue), [5, 10, 15, 30, 60])
        for interval in CameraTourInterval.allCases {
            XCTAssertEqual(schedule(interval: interval).advanceAfterSeconds, interval.rawValue)
        }
    }

    func testCameraIntervalAndLifecycleChangesInvalidateAnOldSchedule() {
        let current = schedule()
        XCTAssertNotEqual(current, schedule(cameraID: "garden"))
        XCTAssertNotEqual(current, schedule(interval: .thirty))
        XCTAssertNotEqual(current, schedule(cycling: false))
        XCTAssertNotEqual(current, schedule(foreground: false))
        XCTAssertNotEqual(current, schedule(ready: false))
        XCTAssertNotEqual(current, schedule(failed: true))
    }

    func testScreenStaysAwakeOnlyForAVisibleForegroundCameraTour() {
        XCTAssertTrue(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: false, visible: true, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: false, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: false, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: true, hasCamera: false))
    }

    func testCustomCycleTimeValidatesWholeSecondsIncludingBounds() {
        XCTAssertEqual(CameraTourTiming.seconds(from: "1"), 1)
        XCTAssertEqual(CameraTourTiming.seconds(from: " 3600\n"), 3600)
        XCTAssertEqual(CameraTourTiming.seconds(from: "27"), 27)
        for value in ["", " ", "0", "3601", "-1", "+1", "1.5", "1e2", "１２", String(repeating: "9", count: 100)] {
            XCTAssertNil(CameraTourTiming.seconds(from: value), value)
        }
    }

    func testPreloadDoesNotSwitchUntilDeadlineAndDecodedReadiness() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden"])
        let currentID = try XCTUnwrap(playback.current?.id)
        playback.setReady(true, slotID: currentID)
        playback.preload("garden")
        let incomingID = try XCTUnwrap(playback.incoming?.id)
        XCTAssertEqual(playback.slots.count, 2)
        XCTAssertEqual(playback.current?.id, currentID)
        playback.setReady(true, slotID: incomingID)
        XCTAssertEqual(playback.current?.id, currentID)
        playback.request("garden")
        XCTAssertEqual(playback.current?.id, incomingID, "Promotion must reuse the decoded stream's identity.")
        XCTAssertEqual(playback.current?.ready, true)
        XCTAssertEqual(playback.slots.count, 1)
        XCTAssertNil(playback.incoming)
    }

    func testSwitchRequestKeepsCurrentVideoUntilIncomingIsReady() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden"])
        let currentID = try XCTUnwrap(playback.current?.id)
        playback.request("garden")
        let incomingID = try XCTUnwrap(playback.incoming?.id)
        XCTAssertTrue(playback.handoffRequested)
        XCTAssertEqual(playback.current?.id, currentID)
        playback.setReady(false, slotID: incomingID)
        XCTAssertEqual(playback.current?.id, currentID)
        playback.setReady(true, slotID: incomingID)
        XCTAssertEqual(playback.current?.cameraID, "garden")
        XCTAssertEqual(playback.current?.id, incomingID)
        XCTAssertFalse(playback.handoffRequested)
    }

    func testCancelledOrReplacedIncomingGenerationsCannotSwitchOrReportFailure() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden", "garage"])
        playback.request("garden")
        let staleID = try XCTUnwrap(playback.incoming?.id)
        playback.request("garage")
        let replacementID = try XCTUnwrap(playback.incoming?.id)
        XCTAssertEqual(playback.slots.count, 2)
        playback.setReady(true, slotID: staleID)
        XCTAssertNil(playback.fail(slotID: staleID))
        XCTAssertEqual(playback.current?.cameraID, "front")
        XCTAssertEqual(playback.incoming?.id, replacementID)
        playback.cancelIncoming()
        playback.setReady(true, slotID: replacementID)
        XCTAssertEqual(playback.current?.cameraID, "front")
        XCTAssertEqual(playback.slots.count, 1)
    }

    func testOldOutgoingCallbackCannotInvalidatePromotedStream() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden"])
        let oldID = try XCTUnwrap(playback.current?.id)
        playback.request("garden")
        let incomingID = try XCTUnwrap(playback.incoming?.id)
        playback.setReady(true, slotID: incomingID)
        playback.setReady(false, slotID: oldID)
        XCTAssertNil(playback.fail(slotID: oldID))
        XCTAssertEqual(playback.current?.ready, true)
        XCTAssertEqual(playback.current?.id, incomingID)
    }

    func testIncomingFailureKeepsCurrentAndRetryUsesANewGeneration() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden"])
        let currentID = try XCTUnwrap(playback.current?.id)
        playback.setReady(true, slotID: currentID)
        playback.request("garden")
        let failedID = try XCTUnwrap(playback.incoming?.id)
        XCTAssertEqual(playback.fail(slotID: failedID), "garden")
        XCTAssertEqual(playback.current?.id, currentID)
        XCTAssertEqual(playback.current?.ready, true)
        XCTAssertNil(playback.incoming)
        playback.request("garden")
        XCTAssertNotEqual(playback.incoming?.id, failedID)
        playback.setReady(true, slotID: failedID)
        XCTAssertEqual(playback.current?.id, currentID)
    }

    func testPermissionChangesCancelPreloadAndDiscardRemovedActiveCamera() throws {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden", "garage"])
        playback.request("garden")
        let staleID = try XCTUnwrap(playback.incoming?.id)
        playback.update(cameraIDs: ["front", "garage"])
        XCTAssertNil(playback.incoming)
        playback.setReady(true, slotID: staleID)
        playback.request("garden")
        XCTAssertNil(playback.incoming)
        XCTAssertEqual(playback.current?.cameraID, "front")
        playback.update(cameraIDs: ["garage"])
        XCTAssertEqual(playback.current?.cameraID, "garage")
        XCTAssertEqual(playback.current?.ready, false)
        playback.update(cameraIDs: [])
        XCTAssertTrue(playback.slots.isEmpty)
    }

    func testManualSelectionWrapsFromPendingAndCanCancelBackToCurrent() {
        var playback = CameraTourPlayback(cameraIDs: ["front", "garden", "garage"])
        XCTAssertEqual(playback.neighbor(offset: -1), "garage")
        playback.request("garden")
        XCTAssertEqual(playback.neighbor(offset: 1, fromPending: true), "garage")
        XCTAssertEqual(playback.neighbor(offset: -1, fromPending: true), "front")
        playback.request("front")
        XCTAssertNil(playback.incoming)
        XCTAssertFalse(playback.handoffRequested)
        XCTAssertEqual(playback.current?.cameraID, "front")
    }

    func testMotionParserOnlyAcceptsExactPermittedMotionTopicsAndStates() {
        XCTAssertEqual(message(#"{"topic":"front/motion","payload":"ON"}"#),
            .event(CameraMotionEvent(cameraID: "front", active: true)))
        XCTAssertEqual(message(#"{"topic":"front/motion","payload":"OFF"}"#),
            .event(CameraMotionEvent(cameraID: "front", active: false)))
        for topic in ["front/motion_mask/one/state", "front/motion/state", "front/motion/", "hidden/motion", "front/detect/state"] {
            XCTAssertEqual(message("{\"topic\":\"\(topic)\",\"payload\":\"ON\"}"), .ignored)
        }
        for payload in [#""on""#, #""ON ""#, "true", "1", "null", "{}"] {
            XCTAssertEqual(message("{\"topic\":\"front/motion\",\"payload\":\(payload)}"), .malformed)
        }
        XCTAssertEqual(message(#"{"topic":"unrelated","payload":{"anything":true}}"#), .ignored)
        XCTAssertEqual(message("not json"), .malformed)
        XCTAssertEqual(CameraMotionParser.parse(Data(repeating: 32, count: CameraMotionParser.maximumMessageBytes + 1),
            allowedCameraIDs: ["front"]), .malformed)
    }

    func testMotionSnapshotIsRestrictedAndSeedsWithoutBecomingNewActivity() {
        let parsed = message(#"{"topic":"camera_activity","payload":"{\"front\":{\"motion\":true},\"garden\":{\"motion\":false},\"hidden\":{\"motion\":true}}"}"#)
        XCTAssertEqual(parsed, .snapshot(["front": true, "garden": false]))
        XCTAssertEqual(message(#"{"topic":"camera_activity","payload":{"front":{"motion":false}}}"#),
            .snapshot(["front": false]))
        XCTAssertEqual(message(#"{"topic":"camera_activity","payload":{"front":{"motion":"ON"}}}"#), .malformed)
        var selection = motionSelection()
        selection.seed(["garden": true, "hidden": true])
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garden", active: false), currentID: "front")
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertEqual(selection.queuedCameraID, "garden")
    }

    func testMotionIgnoresCurrentNonpermittedAndRepeatedOnButAcceptsNewRises() {
        var selection = motionSelection()
        selection.receive(CameraMotionEvent(cameraID: "front", active: true), currentID: "front")
        selection.receive(CameraMotionEvent(cameraID: "hidden", active: true), currentID: "front")
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertEqual(selection.takeTarget(currentID: "front", at: Date()), "garden")
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garden", active: false), currentID: "front")
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertEqual(selection.queuedCameraID, "garden")
    }

    func testMostRecentNewMotionWinsAfterStableDecodedVideoHold() {
        var selection = motionSelection()
        let start = Date(timeIntervalSince1970: 1000)
        selection.displayed(at: start)
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        selection.receive(CameraMotionEvent(cameraID: "garage", active: true), currentID: "front")
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        XCTAssertEqual(selection.queuedCameraID, "garage", "A repeated ON must not displace newer motion.")
        XCTAssertNil(selection.takeTarget(currentID: "front", at: start.addingTimeInterval(7.99)))
        XCTAssertEqual(selection.takeTarget(currentID: "front", at: start.addingTimeInterval(8)), "garage")
        XCTAssertNil(selection.takeTarget(currentID: "front", at: start.addingTimeInterval(100)))
        selection.displayed(at: start.addingTimeInterval(10))
        selection.receive(CameraMotionEvent(cameraID: "garden", active: false), currentID: "garage")
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "garage")
        XCTAssertNil(selection.takeTarget(currentID: "garage", at: start.addingTimeInterval(17)))
        XCTAssertEqual(selection.takeTarget(currentID: "garage", at: start.addingTimeInterval(18)), "garden")
    }

    func testPermissionAndPauseDiscardMotionQueueWithoutTreatingRepeatedOnAsNew() {
        var selection = motionSelection()
        selection.receive(CameraMotionEvent(cameraID: "garden", active: true), currentID: "front")
        selection.update(allowedCameraIDs: ["front", "garage"])
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garage", active: true), currentID: "front")
        selection.discardQueued()
        XCTAssertNil(selection.queuedCameraID)
        selection.receive(CameraMotionEvent(cameraID: "garage", active: true), currentID: "front")
        XCTAssertNil(selection.queuedCameraID)
        selection.resetFeed()
        selection.seed(["garage": true])
        selection.receive(CameraMotionEvent(cameraID: "garage", active: true), currentID: "front")
        XCTAssertNil(selection.queuedCameraID)
    }

    func testMessageSocketPreservesServerRootBasePathAndSchemeWithoutMediaQuery() throws {
        XCTAssertEqual(try ServerAddress("https://example.test:8971").messageWebSocket().absoluteString,
            "wss://example.test:8971/ws")
        XCTAssertEqual(try ServerAddress("http://example.test:5000/frigate/").messageWebSocket().absoluteString,
            "ws://example.test:5000/frigate/ws")
        XCTAssertEqual(try ServerAddress("https://example.test/nested/base").messageWebSocket().absoluteString,
            "wss://example.test/nested/base/ws")
    }

    private func message(_ text: String) -> CameraMotionMessage {
        CameraMotionParser.parse(Data(text.utf8), allowedCameraIDs: ["front", "garden", "garage"])
    }

    private func motionSelection() -> CameraTourMotionSelection {
        var selection = CameraTourMotionSelection()
        selection.update(allowedCameraIDs: ["front", "garden", "garage"])
        return selection
    }

    private func schedule(cameraID: String? = "front", count: Int = 2,
                          interval: CameraTourInterval = .fifteen, cycling: Bool = true,
                          foreground: Bool = true, ready: Bool = true, failed: Bool = false) -> CameraTourSchedule {
        CameraTourSchedule(cameraID: cameraID, cameraCount: count, interval: interval,
            cycling: cycling, foreground: foreground, ready: ready, failed: failed)
    }
}
