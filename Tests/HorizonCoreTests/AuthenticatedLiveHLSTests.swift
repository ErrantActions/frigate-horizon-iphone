import Foundation
import AVFoundation
import XCTest
@testable import HorizonCore

final class HLSFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (code, headers, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AuthenticatedLiveHLSTests: XCTestCase {
    private var client: AuthenticatedLiveHLSClient!
    private var policy: LiveHLSResourcePolicy!

    override func setUpWithError() throws {
        policy = try LiveHLSResourcePolicy(address: ServerAddress("https://horizon.invalid/base"), camera: "front")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSFixtureProtocol.self]
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "frigate_token", .value: "synthetic-session", .domain: "horizon.invalid",
            .path: "/base", .secure: "TRUE",
        ]))
        client = AuthenticatedLiveHLSClient(policy: policy, cookies: [cookie], configuration: configuration)
    }

    override func tearDown() {
        client.invalidate()
        client = nil
        HLSFixtureProtocol.handler = nil
    }

    func testAuthenticatedMasterUsesActualBandwidthAndScopedRewrittenURIs() async throws {
        HLSFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/base/api/front/live/hls/master.m3u8")
            XCTAssertNil(request.url?.query)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("frigate_token=synthetic-session") == true)
            return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data(LiveHLSFixtures.master.utf8))
        }
        let master = try await client.prepareMaster()
        XCTAssertEqual(master.lowestBandwidth, 1_876_000)
        let resource = try await client.load(policy.canonicalMaster)
        let text = try XCTUnwrap(String(data: resource.data, encoding: .utf8))
        XCTAssertTrue(text.contains("horizon-hls://horizon.invalid/base/api/front/live/hls/720p/primary.m3u8"))
        XCTAssertFalse(text.contains("synthetic-session"))
    }

    func testPartsAndAudioUseTheSameAuthenticatedClient() async throws {
        HLSFixtureProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-session") == true)
            return (200, ["Content-Type": "video/mp4"], Data([1, 2, 3, 4]))
        }

        func testEveryPlaylistAndMediaResourceReauthenticatesWithoutSharedCache() async throws {
            var calls = 0
            HLSFixtureProtocol.handler = { request in
                calls += 1
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-session") == true)
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                let playlist = request.url?.pathExtension == "m3u8"
                return (200, ["Content-Type": playlist ? "application/vnd.apple.mpegurl" : "video/mp4"],
                    playlist ? Data("#EXTM3U\n#EXTINF:2,\nrotated.mp4\n".utf8) : Data([1, 2]))
            }
            for path in ["720p/video.m3u8", "720p/audio.m3u8", "720p/init.mp4",
                         "720p/segment.mp4", "720p/audio.mp4", "720p/part.mp4"] {
                _ = try await client.load(policy.resolve(path, relativeTo: policy.canonicalMaster))
            }
            XCTAssertEqual(calls, 6)
        }

        func testAChild403DoesNotTriggerSignInAndAChild404IsNotRetriedByLoader() async throws {
            for code in [401, 403, 404] {
                var calls = 0
                HLSFixtureProtocol.handler = { _ in
                    calls += 1
                    return (code, ["Content-Type":"text/html"], Data("<html>error</html>".utf8))
                }
                do {
                    _ = try await client.load(policy.resolve("720p/rotated.mp4", relativeTo: policy.canonicalMaster))
                    XCTFail("Child failure must not appear successful")
                } catch {
                    XCTAssertEqual((error as? HorizonError)?.httpStatusCode, code)
                    XCTAssertEqual(LiveHLSGate.requiresReauthentication(error), code == 401)
                }
                XCTAssertEqual(calls, 1)
            }
        }
        for path in ["720p/init.mp4", "720p/part-1.mp4", "720p/audio-part-1.mp4"] {
            let url = try policy.resolve(path, relativeTo: policy.canonicalMaster)
            let resource = try await client.load(url)
            XCTAssertEqual(resource.data, Data([1, 2, 3, 4]))
        }
    }

    func testAuthenticationExpiryIsExplicitAndNeverRetried() async throws {
        var calls = 0
        HLSFixtureProtocol.handler = { _ in
            calls += 1
            return (401, ["Content-Type": "text/html"], Data("<html>Authentication expired</html>".utf8))
        }
        do {
            _ = try await client.prepareMaster()
            XCTFail("Expired authentication must not become compatibility success")
        } catch HorizonError.unauthorized {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
    }

    func testComplete200OriginObjectsSupportLocalRangesWithoutRemoteRangeOrHEAD() async throws {
        HLSFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return (200, ["Content-Type": "video/mp4"], Data((0..<16).map(UInt8.init)))
        }
        let url = try policy.resolve("720p/part-1.mp4", relativeTo: policy.canonicalMaster)
        let resource = try await client.load(url)
        XCTAssertEqual(resource.totalLength, 16)
        XCTAssertEqual(try resource.bytes(at: 5, length: 2, toEnd: false), Data([5, 6]))
        XCTAssertThrowsError(try resource.bytes(at: 17, length: 2, toEnd: false))
    }

    func testForbiddenAndHTMLResponsesAreFailuresNotVideo() async throws {
        for code in [403, 502, 503, 200] {
            HLSFixtureProtocol.handler = { _ in (code, ["Content-Type": "text/html"], Data("<html>login</html>".utf8)) }
            do {
                _ = try await client.prepareMaster()
                XCTFail("Rejected response became usable HLS")
            } catch {
                let failure = error as? HorizonError
                XCTAssertNotNil(failure)
                if code == 403 {
                    if case .some(.forbidden) = failure {} else { XCTFail("Camera denial must not be a DVR logout") }
                }
                if code >= 500 { XCTAssertEqual(failure?.httpStatusCode, code) }
            }
        }
    }

    func testScopeAndTLSFailuresDoNotFallBackOrRelaxTrust() async throws {
        var calls = 0
        HLSFixtureProtocol.handler = { _ in calls += 1; throw URLError(.serverCertificateUntrusted) }
        do {
            _ = try await client.prepareMaster()
            XCTFail("Untrusted certificate must fail")
        } catch { XCTAssertEqual((error as NSError).code, URLError.serverCertificateUntrusted.rawValue) }
        XCTAssertEqual(calls, 1)
        do {
            _ = try await client.load(URL(string: "https://attacker.invalid/segment.mp4")!)
            XCTFail("Out-of-scope URL must fail before network")
        } catch HorizonError.invalidMediaPath {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
    }

    func testInvalidationPreventsFurtherLoads() async throws {
        client.invalidate()
        do {
            _ = try await client.prepareMaster()
            XCTFail("Closed ownership must not create another consumer")
        } catch {}
    }

    func testMediaStreamingPreservesOriginDeliveryChunksAndRangeMetadata() async throws {
        HLSFixtureProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-session") == true)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return (200, ["Content-Type": "video/mp4", "Content-Length": "4"], Data([1, 2, 3, 4]))
        }
        let url = try policy.resolve("720p/part-1.mp4", relativeTo: policy.canonicalMaster)
        var delivered = Data()
        var responses = 0
        for try await event in try client.streamMedia(url) {
            switch event {
            case .response(let status, let length, _):
                responses += 1
                XCTAssertEqual(status, 200)
                XCTAssertEqual(length, 4)
            case .data(let data): delivered.append(data)
            }
        }
        XCTAssertEqual(responses, 1)
        XCTAssertEqual(delivered, Data([1, 2, 3, 4]))
    }

    @MainActor
    func testLocalListenerRequiresItsCookieAndClosesWithOwnership() async throws {
        let source = try await AuthenticatedLiveHLSAsset(client: client)
        let url = source.asset.url
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); source.close() }
        let (_, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        source.close()
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            _ = try await session.data(for: request)
            XCTFail("Closed ownership left a listener available")
        } catch {}
    }

    @MainActor
    func testListenerDoesNotBindOtherLoopbackAddresses() async throws {
        let source = try await AuthenticatedLiveHLSAsset(client: client)
        defer { source.close() }
        var parts = try XCTUnwrap(URLComponents(url: source.asset.url, resolvingAgainstBaseURL: false))
        parts.host = "127.0.0.2"
        var request = URLRequest(url: try XCTUnwrap(parts.url))
        request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: request)
            XCTFail("The private adapter listened outside its exact loopback binding")
        } catch {}
    }

    @MainActor
    func testRealAVPlayerLoadsAuthenticatedFixtureInitAndSegment() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HorizonAppTests/native-live-synthetic.mp4")
        let fixture = try Data(contentsOf: fixtureURL)
        var offset = 0
        var initialization = Data()
        var segment = Data()
        while offset + 8 <= fixture.count {
            let size = fixture[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard size >= 8, offset + size <= fixture.count else { throw HorizonError.unexpectedResponse }
            let kind = String(data: fixture[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if kind == "ftyp" || kind == "moov" { initialization.append(fixture[offset..<(offset + size)]) }
            if kind == "moof" || kind == "mdat" { segment.append(fixture[offset..<(offset + size)]) }
            offset += size
        }
        XCTAssertFalse(initialization.isEmpty)
        XCTAssertFalse(segment.isEmpty)
        let trace = HLSFixtureTrace()
        let videoMaster = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=1876000
        720p/index.m3u8
        """
        let media = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.0,
        segment.mp4
        #EXT-X-ENDLIST
        """
        HLSFixtureProtocol.handler = { request in
            let path = request.url?.path ?? ""
            trace.add(path)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-session") == true)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            if path.hasSuffix("master.m3u8") {
                return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data(videoMaster.utf8))
            }
            if path.hasSuffix("index.m3u8") {
                return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data(media.utf8))
            }
            if path.hasSuffix("init.mp4") { return (200, ["Content-Type": "video/mp4"], initialization) }
            if path.hasSuffix("segment.mp4") { return (200, ["Content-Type": "video/mp4"], segment) }
            return (404, ["Content-Type": "text/plain"], Data())
        }
        _ = try await client.prepareMaster()
        let source = try await AuthenticatedLiveHLSAsset(client: client)
        defer { source.close() }
        let item = AVPlayerItem(asset: source.asset)
        item.preferredPeakBitRate = 1_876_000
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if item.status == .failed { break }
            if item.status == .readyToPlay && trace.paths.contains(where: { $0.hasSuffix("segment.mp4") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "Fixture HLS did not become ready")
        XCTAssertTrue(trace.paths.contains(where: { $0.hasSuffix("init.mp4") }), "\(trace.paths)")
        XCTAssertTrue(trace.paths.contains(where: { $0.hasSuffix("segment.mp4") }), "\(trace.paths)")
    }
}

private final class HLSFixtureTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ path: String) { lock.lock(); values.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
