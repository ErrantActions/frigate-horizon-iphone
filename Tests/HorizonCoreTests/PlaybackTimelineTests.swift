import XCTest
@testable import HorizonCore

final class PlaybackTimelineTests: XCTestCase {
    func testReopeningReviewRebuildsBoundsForNewDayAndNewlyElapsedFootage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6)))
        let first = try ReviewTimeRange(day: day, now: day.addingTimeInterval(3600), calendar: calendar)
        let refreshed = try ReviewTimeRange(day: day, now: day.addingTimeInterval(7200), calendar: calendar)
        XCTAssertEqual(refreshed.start, first.start)
        XCTAssertEqual(refreshed.end - first.end, 3600)
        let nextDay = day.addingTimeInterval(86400)
        let other = try ReviewTimeRange(day: nextDay, now: nextDay.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(other.start - first.start, 86400)
        XCTAssertGreaterThan(try other.clamped(nextDay.timeIntervalSince1970 + 15), first.end)
    }
    func testScrubbingIncludesKeyframeLeadInButNeverCollapsesAGap() throws {
        let spans = try JSONDecoder().decode([PlaybackSpan].self, from: Data("""
        [{"start_time":100,"end_time":110,"duration":12000},
         {"start_time":120,"end_time":130,"duration":10000}]
        """.utf8))
        let timeline = PlaybackTimeline(spans: spans)
        XCTAssertEqual(timeline.position(for: 100), 2)
        XCTAssertEqual(timeline.position(for: 105), 7)
        XCTAssertNil(timeline.position(for: 115))
        XCTAssertEqual(timeline.position(for: 120), 12)
        XCTAssertEqual(timeline.timestamp(for: 0), 100)
        XCTAssertEqual(timeline.timestamp(for: 7), 105)
        XCTAssertEqual(timeline.timestamp(for: 12), 120)
        XCTAssertNil(timeline.position(for: 130))
        XCTAssertNil(timeline.timestamp(for: 22))
    }

    func testExplicitLeadInAndSkippedClips() throws {
        let spans = try JSONDecoder().decode([PlaybackSpan].self, from: Data("""
        [{"start_time":100,"end_time":110,"duration":0},
         {"start_time":120,"end_time":130,"duration":11000,"lead_in_ms":1000}]
        """.utf8))
        let timeline = PlaybackTimeline(spans: spans)
        XCTAssertNil(timeline.position(for: 105))
        XCTAssertEqual(timeline.position(for: 120), 1)
        XCTAssertEqual(timeline.timestamp(for: 6), 125)
        XCTAssertNil(timeline.position(for: .nan))
        XCTAssertNil(timeline.timestamp(for: -.infinity))
    }

    func testCoverageHalfOpenIntervalsKeepMissingFootageExplicit() throws {
        let coverage = try JSONDecoder().decode(RecordingCoverage.self, from: Data("""
        {"spans":[{"start_time":100,"end_time":110,"streams":["main"]},
                  {"start_time":120,"end_time":130,"streams":["main"]}]}
        """.utf8))
        XCTAssertTrue(coverage.contains(100))
        XCTAssertFalse(coverage.contains(110))
        XCTAssertFalse(coverage.contains(115))
        XCTAssertTrue(coverage.contains(120))
    }

    func testExistingMainDerivedRenditionCanBeSelectedWhenGenerationIsDisabled() throws {
        let config = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{"front":{"enabled":true,"live":{"streams":{
        "Main":"front_main","720p":"front_transcode_720p","1080p":"front_transcode_1080p"},
        "transcode":{"enabled":false,"source":"front_main",
        "qualities":[{"height":720},{"height":1080}]}}}}}
        """.utf8))
        XCTAssertEqual(config.orderedCameras.first?.preferredStream(expanded: false), "front_transcode_720p")
        XCTAssertEqual(config.orderedCameras.first?.preferredStream(expanded: true), "front_transcode_1080p")
    }

    func testReviewRangeFreezesNowAndClampsInsideTheSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27)))
        let now = day.addingTimeInterval(3600)
        let range = try ReviewTimeRange(day: day, now: now, calendar: calendar)
        XCTAssertEqual(range.start, day.timeIntervalSince1970)
        XCTAssertEqual(range.end, now.timeIntervalSince1970)
        XCTAssertEqual(try range.clamped(range.start - 15), range.start)
        XCTAssertEqual(try range.clamped(range.start + 20), range.start + 20)
        XCTAssertLessThan(try range.clamped(range.end + 15), range.end)
        XCTAssertEqual(range.end, now.timeIntervalSince1970, "Clamping must not move the time ruler.")
        XCTAssertThrowsError(try range.clamped(.nan))
        XCTAssertThrowsError(try range.clamped(.infinity))
    }

    func testReviewRangeUsesCalendarDaysAcrossDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let range = try ReviewTimeRange(day: date, now: date.addingTimeInterval(172800), calendar: calendar)
            XCTAssertEqual(range.end - range.start, Double(hours * 3600))
        }
    }

    func testReviewRangeRejectsFutureDaysAndInvalidDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27)))
        XCTAssertThrowsError(try ReviewTimeRange(day: day, now: day, calendar: calendar))
        XCTAssertThrowsError(try ReviewTimeRange(day: day, now: day.addingTimeInterval(-1), calendar: calendar))
        XCTAssertThrowsError(try ReviewTimeRange(day: Date(timeIntervalSince1970: .nan), now: day, calendar: calendar))
    }

    func testRepeatedReviewSeeksPreserveIntentAndRemainDistinctRequests() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1793130000))
        let range = try ReviewTimeRange(day: day, now: day.addingTimeInterval(3600))
        let first = try ReviewSeekRequest(timestamp: range.start + 15, autoplay: false, range: range)
        let retry = try ReviewSeekRequest(timestamp: range.start + 15, autoplay: false, range: range)
        XCTAssertEqual(first.timestamp, retry.timestamp)
        XCTAssertNotEqual(first, retry, "Retrying the same time must still trigger a seek.")
        XCTAssertFalse(first.autoplay)
        XCTAssertFalse(retry.autoplay)
        let playing = try ReviewSeekRequest(timestamp: range.end + 20, autoplay: true, range: range)
        XCTAssertTrue(playing.autoplay)
        XCTAssertLessThan(playing.timestamp, range.end)
    }
}
