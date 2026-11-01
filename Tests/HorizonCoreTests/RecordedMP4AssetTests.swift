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
    static func install(_ body: Data, status: Int? = nil, delay: Bool = false) -> URL {
        let url = URL(string: "https://fixture.invalid/proxy/api/fixtures/\(UUID().uuidString)/window.mp4")!
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
        let status = fixture.status ?? (start >= fixture.body.count ? 416 : 206)
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
    private func makeVideoFixture() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
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
