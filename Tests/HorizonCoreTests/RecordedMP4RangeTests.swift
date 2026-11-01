import XCTest
@testable import HorizonCore

final class RecordedMP4RangeTests: XCTestCase {
    func testExact206AndClippedLastRange() throws {
        let range = try RecordedMP4Range(offset: 10, count: 20)
        XCTAssertEqual(range.header, "bytes=10-29")
        XCTAssertNoThrow(try range.validate(status: 206, contentRange: "bytes 10-29/100", length: 100, bodyCount: 20))
        XCTAssertNoThrow(try range.validate(status: 206, contentRange: "bytes 10-19/20", length: 20, bodyCount: 10))
    }
    func test416OnlyDescribesAnActualEOFWithTheStableLength() throws {
        let range = try RecordedMP4Range(offset: 100, count: 10)
        XCTAssertNoThrow(try range.validate(status: 416, contentRange: "bytes */100", length: 100, bodyCount: 0))
        XCTAssertThrowsError(try range.validate(status: 416, contentRange: "bytes */110", length: 100, bodyCount: 0))
        XCTAssertThrowsError(try RecordedMP4Range(offset: 90, count: 10).validate(status: 416, contentRange: "bytes */100", length: 100, bodyCount: 0))
    }
    func testNoLiveFull200RuleIsAppliedToRecordedRangeReads() throws {
        XCTAssertThrowsError(try RecordedMP4Range(offset: 0, count: 10).validate(status: 200, contentRange: nil, length: 10, bodyCount: 10))
    }
    func testInconsistentRangeTruncatedBodyAndGrowingLengthFail() throws {
        let range = try RecordedMP4Range(offset: 10, count: 20)
        for header in ["bytes 0-19/100", "bytes 10-29/101", "bytes 10-30/100", "bytes 10-29/*", "HTML"] {
            XCTAssertThrowsError(try range.validate(status: 206, contentRange: header, length: 100, bodyCount: 20))
        }
        XCTAssertThrowsError(try range.validate(status: 206, contentRange: "bytes 10-29/100", length: 100, bodyCount: 19))
    }
    func testAuthErrorsDoNotDependOnAJSONResponseBody() throws {
        let range = try RecordedMP4Range(offset: 0, count: 10)
        for code in [401,403] {
            do { try range.validate(status: code, contentRange: nil, length: 100, bodyCount: 0); XCTFail() }
            catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, code) }
        }
    }
    func testReadsAreBoundedAndOverflowSafe() {
        XCTAssertThrowsError(try RecordedMP4Range(offset: -1, count: 10))
        XCTAssertThrowsError(try RecordedMP4Range(offset: Int64.max, count: 10))
        XCTAssertThrowsError(try RecordedMP4Range(offset: 0, count: RecordedMP4Range.maximumRead + 1))
        XCTAssertThrowsError(try RecordedMP4Range(offset: 0, count: 0))
    }
}
