import XCTest
@testable import HorizonCore

private final class AuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var status: Int
        var responseHeaders: [String:String]
        var delay: Double
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    private static var fixtures: [String: State] = [:]
    private var stopped = false
    private let stateLock = NSLock()
    static func install(status: Int = 202, headers: [String:String] = ["remote-user":"owner","remote-role":"admin"],
                        delay: Double = 0) -> ServerAddress {
        let host = UUID().uuidString.lowercased() + ".invalid"
        lock.lock(); fixtures[host] = State(status: status, responseHeaders: headers, delay: delay); lock.unlock()
        return try! ServerAddress("https://" + host + "/proxy")
    }
    static func requests(_ address: ServerAddress) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return fixtures[address.url.host!]?.requests ?? []
    }
    static func remove(_ address: ServerAddress) {
        lock.lock(); fixtures.removeValue(forKey: address.url.host!); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        guard var fixture = Self.fixtures[url.host!] else { Self.lock.unlock(); client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        fixture.requests.append(request); Self.fixtures[url.host!] = fixture
        Self.lock.unlock()
        let status = fixture.status, headers = fixture.responseHeaders
        let send: @Sendable () -> Void = { [self] in
            stateLock.lock(); let stopped = self.stopped; stateLock.unlock()
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        if fixture.delay == 0 { send() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay, execute: send) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

final class SessionRenewalCoordinatorTests: XCTestCase {
    private func session(address: ServerAddress, expires: Date = Date().addingTimeInterval(60)) throws -> URLSession {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name:"session",.value:"fixture-old",.domain:address.url.host!,.path:"/proxy/api",.secure:"TRUE",.expires:expires]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFixtureProtocol.self]
        configuration.urlCache = nil; configuration.httpCookieStorage?.setCookie(cookie)
        return URLSession(configuration: configuration)
    }
    func testSupportedAuthRouteReceivesCookieAndStoresRotatedSessionWithoutAPassword() async throws {
        let address = AuthFixtureProtocol.install(headers: ["remote-user":"owner","remote-role":"admin",
            "Set-Cookie":"session=fixture-renewed; Path=/proxy/api; Secure; HttpOnly; Max-Age=3600"])
        defer { AuthFixtureProtocol.remove(address) }
        let session = try session(address: address); defer { session.invalidateAndCancel() }
        let coordinator = SessionRenewalCoordinator(session: session, address: address)
        let receipt = try await coordinator.check()
        XCTAssertEqual(receipt.username, "owner"); XCTAssertEqual(receipt.role, "admin")
        let requests = AuthFixtureProtocol.requests(address)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/proxy/api/auth")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertNil(requests.first?.url?.query)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "session=fixture-old")
        let renewed = try XCTUnwrap(session.configuration.httpCookieStorage?.cookies?.first { $0.name == "session" })
        XCTAssertEqual(renewed.value, "fixture-renewed")
        XCTAssertGreaterThan(try XCTUnwrap(renewed.expiresDate).timeIntervalSinceNow, 3500)
        let saved = SavedSession(server: address.url.absoluteString, cookies: [SavedSession.SavedCookie(renewed)])
        XCTAssertEqual(try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(saved)), saved)
    }
    func testConcurrentGridAndProfileChecksPerformOneAuthenticationRequest() async throws {
        let address = AuthFixtureProtocol.install(delay: 0.1); defer { AuthFixtureProtocol.remove(address) }
        let session = try session(address: address); defer { session.invalidateAndCancel() }
        let coordinator = SessionRenewalCoordinator(session: session, address: address)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<32 { group.addTask { try await coordinator.check(force: true).username } }
            for try await username in group { XCTAssertEqual(username, "owner") }
        }
        XCTAssertEqual(AuthFixtureProtocol.requests(address).count, 1)
        _ = try await coordinator.check()
        XCTAssertEqual(AuthFixtureProtocol.requests(address).count, 1)
    }
    func testExpiryAnd403AreDistinctAndSharedFailureDoesNotBecomeSuccess() async throws {
        for status in [401,403] {
            let address = AuthFixtureProtocol.install(status: status, headers: [:], delay: 0.02)
            defer { AuthFixtureProtocol.remove(address) }
            let session = try session(address: address); defer { session.invalidateAndCancel() }
            let coordinator = SessionRenewalCoordinator(session: session, address: address)
            for _ in 0..<5 {
                do { _ = try await coordinator.check(force: true); XCTFail() }
                catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, status) }
            }
            XCTAssertEqual(AuthFixtureProtocol.requests(address).count, 1)
        }
    }
    func testCancelledTileDoesNotCancelOtherTilesSessionRecovery() async throws {
        let address = AuthFixtureProtocol.install(delay: 0.15); defer { AuthFixtureProtocol.remove(address) }
        let session = try session(address: address); defer { session.invalidateAndCancel() }
        let coordinator = SessionRenewalCoordinator(session: session, address: address)
        let obsolete = Task { try await coordinator.check() }
        try await Task.sleep(for: .milliseconds(30))
        obsolete.cancel()
        let healthy = try await coordinator.check()
        XCTAssertEqual(healthy.username, "owner")
        do { _ = try await obsolete.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(AuthFixtureProtocol.requests(address).count, 1)
    }
    func testExpiredCookiesAreNotResentOrReplacedWithInventedCredentials() async throws {
        let address = AuthFixtureProtocol.install(status: 401, headers: [:]); defer { AuthFixtureProtocol.remove(address) }
        let session = try session(address: address, expires: Date().addingTimeInterval(-60)); defer { session.invalidateAndCancel() }
        let coordinator = SessionRenewalCoordinator(session: session, address: address)
        do { _ = try await coordinator.check(); XCTFail() } catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, 401) }
        let sent = try XCTUnwrap(AuthFixtureProtocol.requests(address).first)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sent.httpBody)
    }
    func testMissingIdentityAndWrongStatusAreNotSuccessfulRenewal() async throws {
        for status in [200,202,302] {
            let address = AuthFixtureProtocol.install(status: status, headers: ["Location":"https://other.invalid/login"])
            defer { AuthFixtureProtocol.remove(address) }
            let session = try session(address: address); defer { session.invalidateAndCancel() }
            let coordinator = SessionRenewalCoordinator(session: session, address: address)
            do { _ = try await coordinator.check(); XCTFail() }
            catch { XCTAssertTrue(error is HorizonError) }
        }
    }
    func testRequestCookiesKeepOriginPathSecureAndExpiryRestrictions() throws {
        let address = try ServerAddress("https://session.invalid/proxy")
        let cookies = try [
            ("good","session.invalid","/proxy/api",60.0),
            ("foreign","other.invalid","/proxy/api",60.0),
            ("wrong","session.invalid","/proxy/apix",60.0),
            ("expired","session.invalid","/proxy/api",-60.0),
        ].map { name,domain,path,expiry in
            try XCTUnwrap(HTTPCookie(properties: [.name:name,.value:"fixture",.domain:domain,
                .path:path,.secure:"TRUE",.expires:Date().addingTimeInterval(expiry)]))
        }
        XCTAssertEqual(SavedSession.cookiesForRequest(cookies, address: address, url: address.endpoint(["api","auth"])).map(\.name), ["good"])
        XCTAssertTrue(SavedSession.cookiesForRequest(cookies, address: address, url: URL(string:"https://other.invalid/proxy/api/auth")!).isEmpty)
    }
}
