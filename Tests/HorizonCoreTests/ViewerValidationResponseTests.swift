import XCTest
@testable import HorizonCore

final class ViewerValidationResponseTests: XCTestCase {
    private func detail(_ text: String, mime: String? = "application/json") -> String {
        ViewerValidationResponse.detail(data: Data(text.utf8), mimeType: mime)
    }
    func testActualNullGridCapValidationDetailSurvivesBothErrorLayers() {
        let message = detail(#"{"detail":[{"type":"literal_error","loc":["body","max_height"],"msg":"Input should be 720, 1080 or 2160","input":null,"ctx":{"expected":"720, 1080 or 2160"}}]}"#)
        XCTAssertEqual(message, "body.max_height: Input should be 720, 1080 or 2160 (literal_error)")
        let error = HorizonError.server(status: 422, message: message)
        XCTAssertEqual(error.httpStatusCode, 422)
        XCTAssertEqual(viewingFailureMessage(error), "HTTP 422: " + message)
        XCTAssertFalse(viewingFailureMessage(error).contains("server rejected"))
    }
    func testExtraFieldErrorsAndMultipleLocationsRemainActionable() {
        let value = detail(#"{"detail":[{"type":"extra_forbidden","loc":["body","version"],"msg":"Extra inputs are not permitted","input":1},{"type":"missing","loc":["body","view"],"msg":"Field required"}],"message":"generic rejected"}"#)
        XCTAssertTrue(value.contains("body.version: Extra inputs are not permitted (extra_forbidden)"))
        XCTAssertTrue(value.contains("body.view: Field required (missing)"))
        XCTAssertFalse(value.contains("generic rejected"))
    }
    func testInputContextAndSensitiveMessagesAreNeverIncluded() {
        let value = detail(#"{"detail":[{"type":"literal_error","loc":["body","max_height"],"msg":"Input should be 720, 1080 or 2160","input":{"cookie":"private-cookie","sdp":"private-offer"},"ctx":{"credential":"private-turn"}},{"type":"value_error","loc":["body","sdp"],"msg":"private-offer"},{"type":"value_error","loc":["headers","authorization"],"msg":"Bearer private-cookie"}]}"#)
        for secret in ["private-cookie","private-offer","private-turn"] { XCTAssertFalse(value.contains(secret)) }
        XCTAssertTrue(value.contains("body.max_height"))
        XCTAssertTrue(value.contains("redacted"))
    }
    func testProxyTextAndHTMLAreBoundedAndDoNotExposeURLsOrTokens() {
        let plain = detail("Invalid max_height; token=private-token https://private.invalid/secret /media/frigate/private.mp4", mime: "text/plain")
        for secret in ["private-token","private.invalid","private.mp4"] { XCTAssertFalse(plain.contains(secret)) }
        XCTAssertTrue(plain.contains("Invalid max_height"))
        let html = detail("<html><script>private-script</script><body>Invalid max_height</body></html>", mime: "text/html")
        XCTAssertTrue(html.contains("Invalid max_height")); XCTAssertFalse(html.contains("private-script"))
    }
    func testMalformedOrOversizedDetailsAreExplicitlyUnavailableNotSuccess() {
        for text in ["", "{", #"{"detail":{"unexpected":true}}"#] {
            XCTAssertTrue(detail(text).contains("could not be read"))
        }
        let long = ViewerValidationResponse.detail(data: Data(repeating: 65, count: 65_537), mimeType: "text/plain")
        XCTAssertTrue(long.contains("could not be read"))
        XCTAssertTrue(viewingFailureMessage(HorizonError.http(422)).contains("details are unavailable"))
    }
}
