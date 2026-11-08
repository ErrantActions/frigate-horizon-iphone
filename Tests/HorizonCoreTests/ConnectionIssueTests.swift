import Foundation
import XCTest
@testable import HorizonCore

final class ConnectionIssueTests: XCTestCase {
    func testNetworkFailuresHaveSpecificRecoveryCategories() {
        let cases: [(URLError.Code, ConnectionIssue.Kind)] = [
            (.notConnectedToInternet, .offline), (.dataNotAllowed, .offline),
            (.internationalRoamingOff, .offline), (.cannotFindHost, .dns),
            (.dnsLookupFailed, .dns), (.cannotConnectToHost, .unreachable),
            (.networkConnectionLost, .unreachable), (.timedOut, .timedOut),
            (.serverCertificateHasBadDate, .certificate),
            (.serverCertificateUntrusted, .certificate),
            (.serverCertificateHasUnknownRoot, .certificate),
            (.serverCertificateNotYetValid, .certificate),
            (.clientCertificateRejected, .certificate),
            (.clientCertificateRequired, .certificate),
            (.secureConnectionFailed, .secureConnection),
            (.appTransportSecurityRequiresSecureConnection, .secureConnection),
            (.cancelled, .cancelled),
        ]
        for (code, expected) in cases {
            let issue = ConnectionIssue(error: URLError(code))
            XCTAssertEqual(issue.kind, expected, "\(code)")
            XCTAssertEqual(issue.networkCode, code.rawValue)
            XCTAssertNil(issue.httpStatus)
        }
    }

    func testWrappedNetworkErrorKeepsItsCauseWithoutLeakingDetails() {
        let privateURL = "https://private.example.com/api?token=do-not-share"
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.cannotFindHost.rawValue,
            userInfo: [NSURLErrorFailingURLStringErrorKey: privateURL,
                       NSLocalizedDescriptionKey: "cookie=do-not-share"])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -1,
            userInfo: [NSUnderlyingErrorKey: underlying])
        let issue = ConnectionIssue(error: outer)
        XCTAssertEqual(issue.kind, .dns)
        XCTAssertFalse(issue.diagnosticSummary.contains("private.example.com"))
        XCTAssertFalse(issue.diagnosticSummary.contains("do-not-share"))
        XCTAssertFalse(issue.guidance.contains("cookie"))
    }

    func testServerJSONErrorsRetainHTTPStatusAndExistingDescription() {
        let error = HorizonError.server(status: 502, message: "Upstream unavailable")
        XCTAssertEqual(error.httpStatusCode, 502)
        XCTAssertEqual(error.localizedDescription, "HTTP 502: Upstream unavailable")
        let issue = ConnectionIssue(error: error)
        XCTAssertEqual(issue.kind, .serverUnavailable)
        XCTAssertEqual(issue.httpStatus, 502)
        XCTAssertFalse(issue.diagnosticSummary.contains("Upstream unavailable"))
    }

    func testHTTPFailuresAreNotMistakenForAnOfflineDevice() {
        let cases: [(Int, ConnectionIssue.Kind)] = [
            (401, .authentication), (403, .accessDenied), (404, .unexpectedResponse),
            (408, .timedOut), (429, .rateLimited), (500, .serverUnavailable),
            (502, .serverUnavailable), (503, .serverUnavailable), (504, .timedOut),
            (409, .other),
        ]
        for (status, expected) in cases {
            let plain = ConnectionIssue(error: HorizonError.http(status))
            let json = ConnectionIssue(error: HorizonError.server(status: status, message: "private detail"))
            XCTAssertEqual(plain.kind, expected, "\(status)")
            XCTAssertEqual(json, plain)
        }
    }

    func testAuthenticationRequiresSignInInsteadOfSavedSessionRetry() {
        let issue = ConnectionIssue(error: HorizonError.unauthorized)
        XCTAssertEqual(issue.kind, .authentication)
        XCTAssertFalse(issue.allowsSavedSessionRetry)
        XCTAssertEqual(issue.httpStatus, 401)
    }
    func testPermissionDenialDoesNotRecommendSigningInAgain() {
        let issue = ConnectionIssue(error: HorizonError.forbidden)
        XCTAssertEqual(issue.kind, .accessDenied)
        XCTAssertEqual(issue.httpStatus, 403)
        XCTAssertFalse(issue.title.contains("Sign in"))
        XCTAssertTrue(issue.guidance.contains("not proof"))
    }

    func testCertificateFailureNeverSuggestsWeakeningTrust() {
        let issue = ConnectionIssue(error: URLError(.serverCertificateUntrusted))
        XCTAssertFalse(issue.allowsSavedSessionRetry)
        XCTAssertTrue(issue.guidance.contains("trusted by this iPhone"))
        XCTAssertTrue(issue.guidance.contains("has not been bypassed"))
    }

    func testTransientFailuresCanRetryWithoutClearingSession() {
        for error in [URLError(.cannotFindHost), URLError(.notConnectedToInternet),
                      URLError(.timedOut), URLError(.cannotConnectToHost)] {
            XCTAssertTrue(ConnectionIssue(error: error).allowsSavedSessionRetry)
        }
        XCTAssertTrue(ConnectionIssue(error: HorizonError.http(502)).allowsSavedSessionRetry)
        XCTAssertTrue(ConnectionIssue(error: HorizonError.http(429)).allowsSavedSessionRetry)
    }

    func testInvalidAddressesAndDecodingFailuresHaveActionableGuidance() {
        XCTAssertEqual(ConnectionIssue(error: HorizonError.invalidAddress).kind, .invalidAddress)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private"))
        let issue = ConnectionIssue(error: decoding)
        XCTAssertEqual(issue.kind, .unexpectedResponse)
        XCTAssertFalse(issue.diagnosticSummary.contains("private"))
        XCTAssertEqual(ConnectionIssue(error: HorizonError.unexpectedResponse).kind, .unexpectedResponse)
    }

    func testCancellationIsRecognizedSeparatelyFromFailure() {
        XCTAssertEqual(ConnectionIssue(error: CancellationError()).kind, .cancelled)
        XCTAssertFalse(ConnectionIssue(error: CancellationError()).allowsSavedSessionRetry)
    }

    func testUnknownErrorsDoNotExposeUserInfoInSharedDiagnostics() {
        let error = NSError(domain: "private-server-or-account", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "password=secret; camera=bedroom"])
        let issue = ConnectionIssue(error: error)
        XCTAssertEqual(issue.kind, .other)
        XCTAssertEqual(issue.diagnosticSummary, "Horizon connection check\nCategory: other")
    }

    func testUnderlyingErrorSearchIsBounded() {
        var error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        for _ in 0..<10 {
            error = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error])
        }
        XCTAssertEqual(ConnectionIssue(error: error).kind, .other)
    }
}
