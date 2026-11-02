import XCTest
import AVFoundation
@testable import HorizonCore

private final class MP4FixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture {
        let body: Data
        var status: Int?
        var delay: Bool
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    private static var fixtures: [URL: Fixture] = [:]
    private var cancelled = false
    private let stateLock = NSLock()
    static func install(_ body: Data, status: Int? = nil, delay: Bool = false, at address: URL? = nil) -> URL {
        let url = address ?? URL(string: "https://fixture.invalid/proxy/api/fixtures/\(UUID().uuidString)/window.mp4")!
        lock.lock(); fixtures[url] = Fixture(body: body, status: status, delay: delay); lock.unlock()
        return url
    }
    static func requests(for url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return fixtures[url]?.requests ?? []
    }
    static func remove(_ url: URL) { lock.lock(); fixtures.removeValue(forKey: url); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        guard var fixture = Self.fixtures[url] else { Self.lock.unlock(); client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        fixture.requests.append(request); Self.fixtures[url] = fixture
        Self.lock.unlock()
        let parts = request.value(forHTTPHeaderField: "Range")?.dropFirst(6).split(separator: "-")
        let start = parts.flatMap { Int($0[0]) } ?? 0
        let end = min(fixture.body.count - 1, parts.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? fixture.body.count - 1)
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let authenticated = cookie.contains("session=fixture-only") || cookie.contains("good=fixture-only")
        let status = fixture.status ?? (!authenticated ? 401 : (start >= fixture.body.count ? 416 : 206))
        let body = status == 206 && start <= end ? fixture.body.subdata(in: start..<end + 1) : Data()
        let headers = ["Content-Type": "video/mp4", "Content-Length": String(body.count),
            "Content-Range": status == 416 ? "bytes */\(fixture.body.count)" : "bytes \(start)-\(end)/\(fixture.body.count)"]
        let deliver: @Sendable () -> Void = { [self] in
            stateLock.lock(); let cancelled = self.cancelled; stateLock.unlock()
            guard !cancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if fixture.delay { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { stateLock.lock(); cancelled = true; stateLock.unlock() }
}

private struct MP4HeadFixtureClient: RecordedHTTPControlClient {
    let address = try! ServerAddress("https://fixture.invalid/proxy")
    let cookies: [HTTPCookie]
    let length: Int
    var mediaConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MP4FixtureProtocol.self]
        return configuration
    }
    func request(_ url: URL, method: String, body: Data?, success: Set<Int>) async throws -> RecordedHTTPControlResponse {
        guard method == "HEAD", success.contains(200) else { throw HorizonError.unexpectedResponse }
        return RecordedHTTPControlResponse(data: Data(), status: 200, headers: [
            "Content-Type":"video/mp4","Accept-Ranges":"bytes","Content-Length":String(length),"ETag":"\"fixture-only\""])
    }
}

final class RecordedMP4AssetTests: XCTestCase {
    private func reader(_ url: URL, body: Data, expiredCookie: Bool = false) throws -> AuthenticatedRecordedMP4Reader {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain:"fixture.invalid", .path:"/proxy/api",
            .name:"session", .value:"fixture-only", .secure:"TRUE",
            .expires: Date().addingTimeInterval(expiredCookie ? -60 : 300)]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MP4FixtureProtocol.self]
        return try AuthenticatedRecordedMP4Reader(mediaURL: url,
            info: .init(length: Int64(body.count), complete: true, immutable: true, fastStart: true, rangeSupported: true),
            policy: RecordedHTTPResourcePolicy(address: ServerAddress("https://fixture.invalid/proxy")),
            cookies: [cookie], configuration: configuration)
    }
    func testAllIndependentNativeRangeReadsReceiveTheAPIScopedSessionCookie() async throws {
        let body = Data(repeating: 42, count: 4096), url = MP4FixtureProtocol.install(Data(repeating: 42, count: 4096))
        defer { MP4FixtureProtocol.remove(url) }
        let reader = try reader(url, body: body); defer { reader.close() }
        let first = try await reader.read(RecordedMP4Range(offset: 0, count: 10))
        let tail = try await reader.read(RecordedMP4Range(offset: 4090, count: 100))
        XCTAssertEqual(first.count, 10); XCTAssertEqual(tail.count, 6)
        let requests = MP4FixtureProtocol.requests(for: url)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture-only") == true })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") != nil })
    }
    func testCookiePropagationDoesNotIncludeExpiredForeignOrWrongPathCookies() async throws {
        let body = Data(repeating: 0, count: 100), url = MP4FixtureProtocol.install(Data(repeating: 0, count: 100))
        defer { MP4FixtureProtocol.remove(url) }
        let cookies = try [
            ("good", "fixture.invalid", "/proxy/api", 300.0),
            ("expired", "fixture.invalid", "/proxy/api", -300.0),
            ("foreign", "elsewhere.invalid", "/proxy/api", 300.0),
            ("wrongpath", "fixture.invalid", "/proxy/apix", 300.0),
        ].map { name, domain, path, expiry in
            try XCTUnwrap(HTTPCookie(properties: [.name:name, .value:"fixture-only", .domain:domain,
                .path:path, .secure:"TRUE", .expires:Date().addingTimeInterval(expiry)]))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MP4FixtureProtocol.self]
        let reader = try AuthenticatedRecordedMP4Reader(mediaURL: url,
            info: .init(length: 100, complete: true, immutable: true, fastStart: true, rangeSupported: true),
            policy: RecordedHTTPResourcePolicy(address: ServerAddress("https://fixture.invalid/proxy")),
            cookies: cookies, configuration: config)
        defer { reader.close() }
        _ = try await reader.read(RecordedMP4Range(offset: 0, count: 10))
        XCTAssertEqual(MP4FixtureProtocol.requests(for: url).first?.value(forHTTPHeaderField: "Cookie"), "good=fixture-only")
    }
    func testExpiredSessionAndCameraDenialSurfaceWithoutAutomaticRefreshOrFallback() async throws {
        for status in [401,403] {
            let body = Data(repeating: 0, count: 100), url = MP4FixtureProtocol.install(Data(repeating: 0, count: 100), status: status)
            defer { MP4FixtureProtocol.remove(url) }
            let reader = try reader(url, body: body, expiredCookie: status == 401); defer { reader.close() }
            do { _ = try await reader.read(RecordedMP4Range(offset: 0, count: 10)); XCTFail() }
            catch { XCTAssertEqual((error as? HorizonError)?.httpStatusCode, status) }
            XCTAssertEqual(MP4FixtureProtocol.requests(for: url).count, 1)
        }
    }
    func testFull200IsRejectedBeforeBufferingAnUnboundedObject() async throws {
        let body = Data(repeating: 0, count: 2_000_000), url = MP4FixtureProtocol.install(Data(repeating: 0, count: 2_000_000), status: 200)
        defer { MP4FixtureProtocol.remove(url) }
        let reader = try reader(url, body: body); defer { reader.close() }
        do { _ = try await reader.read(RecordedMP4Range(offset: 0, count: 10)); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, RecordedHTTPError.rangeUnsupported.localizedDescription) }
    }
    func testRangeTaskCancellationStopsTheUnderlyingURLSessionRead() async throws {
        let body = Data(repeating: 0, count: 100), url = MP4FixtureProtocol.install(Data(repeating: 0, count: 100), delay: true)
        defer { MP4FixtureProtocol.remove(url) }
        let reader = try reader(url, body: body); defer { reader.close() }
        let task = Task { try await reader.read(RecordedMP4Range(offset: 0, count: 10)) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
    }
    func testNativeAVFoundationLoadsFiniteFaststartMP4ThroughAuthenticatedRangeLoader() async throws {
        let body = try await makeVideoFixture()
        let url = MP4FixtureProtocol.install(body)
        defer { MP4FixtureProtocol.remove(url) }
        let reader = try reader(url, body: body)
        let resource = try RecordedMP4Asset(reader: reader)
        defer { resource.cancel() }
        let duration = try await resource.asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.9)
        let tracks = try await resource.asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let requests = MP4FixtureProtocol.requests(for: url)
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture-only") == true })
        XCTAssertEqual(resource.asset.url.scheme, "horizon-review")
    }
    func testPublishedReadyMediaIsVerifiedWithHEADAndAuthenticatedFaststartRanges() async throws {
        let body = try await makeVideoFixture()
        let client = MP4HeadFixtureClient(cookies: [try XCTUnwrap(HTTPCookie(properties: [
            .domain:"fixture.invalid",.path:"/proxy/api",.name:"session",.value:"fixture-only",.secure:"TRUE"]))], length: body.count)
        let id = UUID().uuidString.lowercased()
        let url = client.address.endpoint(["api","front","recordings","http","sessions",id])
        let media = MP4FixtureProtocol.install(body, at: url.appendingPathComponent("media.mp4"))
        defer { MP4FixtureProtocol.remove(media) }
        let window = RecordedHTTPWindow(sessionID: id, camera: "front", state: .ready, quality: .h720, audio: false,
            statusURL: url, closeURL: url, mediaURL: media, hardExpiresAt: Date().timeIntervalSince1970 + 60,
            timeline: [.init(sourceStart: 100, sourceEnd: 110, mediaStart: 0, mediaEnd: 10)],
            after: 100, before: 110, startTimestamp: 100, effectiveStartTimestamp: 100, nextTimestamp: 110)
        let transport = try RecordedHTTPAPITransport(client: client)
        let info = try await transport.mediaInfo(window: window)
        XCTAssertTrue(info.fastStart); XCTAssertTrue(info.immutable); XCTAssertEqual(info.length, Int64(body.count))
        XCTAssertTrue(MP4FixtureProtocol.requests(for: media).allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture-only") == true
        })
    }
    @MainActor
    func testClosedOriginalTailIndexDecodesAndSeeksWithoutFaststartOrNewItem() async throws {
        let body = try await makeVideoFixture(faststart: false)
        let client = MP4HeadFixtureClient(cookies: [try XCTUnwrap(HTTPCookie(properties: [
            .domain:"fixture.invalid",.path:"/proxy/api",.name:"session",.value:"fixture-only",.secure:"TRUE"]))], length: body.count)
        let id = UUID().uuidString.lowercased()
        let url = client.address.endpoint(["api","front","recordings","http","sessions",id])
        let media = MP4FixtureProtocol.install(body, at: url.appendingPathComponent("media.mp4"))
        defer { MP4FixtureProtocol.remove(media) }
        let window = RecordedHTTPWindow(sessionID: id, camera: "front", state: .ready, quality: .original, audio: false,
            statusURL: url, closeURL: url, mediaURL: media, hardExpiresAt: Date().timeIntervalSince1970 + 60,
            timeline: [.init(sourceStart: 100, sourceEnd: 101, mediaStart: 0, mediaEnd: 1)],
            after: 100, before: 101, startTimestamp: 100.2, effectiveStartTimestamp: 100.2,
            nextTimestamp: 101, delivery: .originalFile)
        let transport = try RecordedHTTPAPITransport(client: client)
        let info = try await transport.mediaInfo(window: window)
        XCTAssertFalse(info.fastStart); XCTAssertTrue(info.indexed)
        let reader = try AuthenticatedRecordedMP4Reader(mediaURL: media, info: info,
            policy: RecordedHTTPResourcePolicy(address: client.address), cookies: client.cookies,
            configuration: client.mediaConfiguration)
        let resource = try RecordedMP4Asset(reader: reader)
        let item = AVPlayerItem(asset: resource.asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil); resource.cancel() }
        player.playImmediately(atRate: 1)
        func decoded() async throws -> Bool {
            for _ in 0..<200 {
                let time = player.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { return true }
                if item.status == .failed { throw item.error ?? RecordedHTTPError.preparationFailed }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        let first = try await decoded(); XCTAssertTrue(first)
        for seconds in [0.2,0.6] {
            player.pause()
            let finished = await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertTrue(finished); player.playImmediately(atRate: 1)
            let frame = try await decoded(); XCTAssertTrue(frame); XCTAssertTrue(player.currentItem === item)
        }
        XCTAssertTrue(MP4FixtureProtocol.requests(for: media).allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture-only") == true
        })
    }
    @MainActor
    func testNativeAVPlayerDecodesAndSeeksFixtureWithoutReplacingItsItem() async throws {
        let body = try await makeVideoFixture()
        let url = MP4FixtureProtocol.install(body)
        defer { MP4FixtureProtocol.remove(url) }
        let reader = try reader(url, body: body)
        let resource = try RecordedMP4Asset(reader: reader)
        let item = AVPlayerItem(asset: resource.asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil); resource.cancel() }
        func decoded() async throws -> Bool {
            for _ in 0..<200 {
                let time = player.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time),
                   output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { return true }
                if item.status == .failed { throw item.error ?? RecordedHTTPError.preparationFailed }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        player.playImmediately(atRate: 1)
        let first = try await decoded()
        XCTAssertTrue(first, "Native AVPlayer must actually decode the local HTTP fixture")
        for seconds in [0.2,0.6] {
            player.pause()
            let finished = await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertTrue(finished)
            player.playImmediately(atRate: 1)
            let frame = try await decoded()
            XCTAssertTrue(frame)
            XCTAssertTrue(player.currentItem === item)
        }
        XCTAssertTrue(MP4FixtureProtocol.requests(for: url).allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie")?.contains("session=fixture-only") == true
        })
    }
    private func makeVideoFixture(faststart: Bool = true) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = faststart
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordedHTTPError.preparationFailed }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 500 { try await Task.sleep(for: .milliseconds(10)); attempts += 1 }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? RecordedHTTPError.preparationFailed }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw RecordedHTTPError.preparationFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(index * 8), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? RecordedHTTPError.preparationFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecordedHTTPError.preparationFailed }
        return try Data(contentsOf: url)
    }
}
