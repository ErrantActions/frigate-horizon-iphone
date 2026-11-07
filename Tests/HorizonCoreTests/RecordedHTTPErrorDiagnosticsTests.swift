import XCTest
@testable import HorizonCore

final class RecordedHTTPErrorDiagnosticsTests: XCTestCase {
    func testNativeErrorCodesAreMeasuredRatherThanInferredFromDeclarationOrder() {
        let failures: [(String, RecordedHTTPError)] = [
            ("unavailable", .unavailable), ("invalidContract", .invalidContract),
            ("invalidWindow", .invalidWindow), ("gap", .gap), ("expired", .expired),
            ("preparationFailed", .preparationFailed), ("rangeUnsupported", .rangeUnsupported),
            ("invalidRange", .invalidRange), ("uncertainCreation", .uncertainCreation),
            ("emptyWindow", .emptyWindow(nextTimestamp: 100)), ("searchLimit", .searchLimit),
            ("unsupportedSource", .unsupportedSource), ("rejectedCreation", .rejectedCreation),
        ]
        let codes = failures.map { name, failure -> Int in
            let native = failure as NSError
            print("RecordedHTTPError bridge: \(name) = \(native.code)")
            XCTAssertEqual(native.domain, "HorizonCore.RecordedHTTPError")
            return native.code
        }
        XCTAssertEqual(Set(codes).count, failures.count)
    }
}
