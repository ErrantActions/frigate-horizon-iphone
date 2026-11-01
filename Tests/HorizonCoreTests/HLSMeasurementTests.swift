import Foundation
import XCTest
@testable import HorizonCore

private final class HLSMeasurementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HLSMeasurement] = []
    func add(_ value: HLSMeasurement) { lock.lock(); values.append(value); lock.unlock() }
    var events: [HLSMeasurement] { lock.lock(); defer { lock.unlock() }; return values }
}

final class HLSMeasurementTests: XCTestCase {
    func testAuthenticatedFetchStagesUseActualRequestDurationsAndAdvertisedMapURI() async throws {
        let policy = try LiveHLSResourcePolicy(address: ServerAddress("https://dvr.invalid/base"), camera: "front")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSFixtureProtocol.self]
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "frigate_token", .value: "synthetic-only", .domain: "dvr.invalid", .path: "/", .secure: "TRUE",
        ]))
        let client = AuthenticatedLiveHLSClient(policy: policy, cookies: [cookie], configuration: configuration)
        defer { client.invalidate(); HLSFixtureProtocol.handler = nil }
        let trace = HLSMeasurementRecorder()
        client.setMeasurementHandler { trace.add($0) }
        HLSFixtureProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-only") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            Thread.sleep(forTimeInterval: 0.03)
            if request.url?.lastPathComponent == "master.m3u8" {
                return (200, ["Content-Type":"application/vnd.apple.mpegurl"], Data("""
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=1876000,RESOLUTION=1280x720
                720p/video-19.m3u8?warm_max_height=2160
                """.utf8))
            }
            if request.url?.pathExtension == "m3u8" {
                XCTAssertTrue(request.url?.query?.contains("warm_max_height=2160") == true)
                return (200, ["Content-Type":"application/vnd.apple.mpegurl"], Data("""
                #EXTM3U
                #EXT-X-PART-INF:PART-TARGET=0.5
                #EXT-X-MAP:URI="arbitrary-rotated-header-19.mp4"
                #EXT-X-PART:DURATION=0.5,URI="part-19.mp4"
                """.utf8))
            }
            return (200, ["Content-Type":"video/mp4"], Data([1, 2, 3, 4]))
        }
        _ = try await client.prepareMaster()
        let child = try policy.resolve("720p/video-19.m3u8?warm_max_height=2160", relativeTo: policy.canonicalMaster)
        _ = try await client.load(child)
        _ = try await client.load(policy.resolve("arbitrary-rotated-header-19.mp4", relativeTo: child))
        var requests: [HLSRequestMeasurement] = []
        var targets: [Double] = []
        for event in trace.events {
            switch event {
            case .request(let request): requests.append(request)
            case .partTarget(let target): targets.append(target)
            }
        }
        XCTAssertEqual(requests.map(\.kind), [.master, .childPlaylist, .initialization])
        XCTAssertEqual(targets, [0.5])
        for request in requests {
            XCTAssertEqual(request.status, 200)
            XCTAssertGreaterThanOrEqual(request.elapsed, 0.02)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(request.firstByte), 0.02)
            XCTAssertGreaterThan(request.bytes, 0)
        }
    }

    func testChildTargetChangesRemainEvidenceAndDoNotChangePlaylistText() async throws {
        let policy = try LiveHLSResourcePolicy(address: ServerAddress("https://dvr.invalid"), camera: "front")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSFixtureProtocol.self]
        let client = AuthenticatedLiveHLSClient(policy: policy, cookies: [], configuration: configuration)
        defer { client.invalidate(); HLSFixtureProtocol.handler = nil }
        let trace = HLSMeasurementRecorder()
        client.setMeasurementHandler { trace.add($0) }
        let child = try policy.resolve("2160p/rotating.m3u8?warm_max_height=2160", relativeTo: policy.canonicalMaster)
        for target in ["0.25", "0.5"] {
            HLSFixtureProtocol.handler = { _ in
                (200, ["Content-Type":"application/vnd.apple.mpegurl"], Data("""
                #EXTM3U
                #EXT-X-PART-INF:PART-TARGET=\(target)
                #EXT-X-MEDIA-SEQUENCE:98765
                #EXT-X-PART:DURATION=\(target),URI="rotated.mp4"
                """.utf8))
            }
            let result = try await client.load(child)
            let text = String(decoding: result.data, as: UTF8.self)
            XCTAssertTrue(text.contains("PART-TARGET=\(target)"))
            XCTAssertTrue(text.contains("MEDIA-SEQUENCE:98765"))
        }
        let targets = trace.events.compactMap { event -> Double? in
            if case .partTarget(let value) = event { return value }
            return nil
        }
        XCTAssertEqual(targets, [0.25, 0.5])
    }
}
