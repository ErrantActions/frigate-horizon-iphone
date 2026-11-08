import Foundation

public struct RecordedHTTPResolveRequest: Encodable, Equatable, Sendable {
    public let version = 1
    public let after: Double
    public let before: Double
    public let startTimestamp: Double
    enum CodingKeys: String, CodingKey { case version,after,before; case startTimestamp = "start_timestamp" }
    public init(after: Double, before: Double, startTimestamp: Double) throws {
        guard [after,before,startTimestamp].allSatisfy(\.isFinite), after >= 0,
              before > after, before - after <= 3600, startTimestamp >= after, startTimestamp < before else {
            throw RecordedHTTPError.invalidWindow
        }
        self.after=after; self.before=before; self.startTimestamp=startTimestamp
    }
}

public struct RecordedHTTPResolution: Decodable, Sendable {
    public let version: Int
    public let after: Double
    public let before: Double
    public let startTimestamp: Double
    public let effectiveStartTimestamp: Double?
    public let exhausted: Bool
    public let searchedBefore: Double
    public let reason: String
    enum CodingKeys: String, CodingKey {
        case version,after,before,exhausted,reason
        case startTimestamp = "start_timestamp", effectiveStartTimestamp = "effective_start_timestamp", searchedBefore = "searched_before"
    }
    public func validate(request: RecordedHTTPResolveRequest) throws {
        guard version == 1, after == request.after, before == request.before, startTimestamp == request.startTimestamp,
              searchedBefore.isFinite, searchedBefore >= after, searchedBefore <= before else { throw RecordedHTTPError.invalidContract }
        if let effectiveStartTimestamp {
            guard effectiveStartTimestamp.isFinite, effectiveStartTimestamp >= startTimestamp,
                  effectiveStartTimestamp < before, !exhausted, reason == "frame_found" else { throw RecordedHTTPError.invalidContract }
        } else {
            guard reason == (exhausted ? "no_frame_in_range" : "search_limit") else { throw RecordedHTTPError.invalidContract }
        }
    }
    public func usableTimestamp() throws -> Double {
        if let effectiveStartTimestamp { return effectiveStartTimestamp }
        throw exhausted ? RecordedHTTPError.gap : RecordedHTTPError.searchLimit
    }
}

public struct RecordedHTTPControlResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String]) {
        self.data=data; self.status=status
        self.headers=headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}

public protocol RecordedHTTPControlClient: Sendable {
    var address: ServerAddress { get }
    var cookies: [HTTPCookie] { get }
    var mediaConfiguration: URLSessionConfiguration { get }
    var decoderCapabilities: RecordedHTTPDecoderCapabilities { get }
    func mediaCookies() async throws -> [HTTPCookie]
    func request(_ url: URL, method: String, body: Data?, success: Set<Int>) async throws -> RecordedHTTPControlResponse
}

public extension RecordedHTTPControlClient {
    var mediaConfiguration: URLSessionConfiguration { .ephemeral }
    var decoderCapabilities: RecordedHTTPDecoderCapabilities { .baseline }
    func mediaCookies() async throws -> [HTTPCookie] { cookies }
}

public actor RecordedHTTPAPITransport: RecordedHTTPTransport {
    // Compile-time protocol qualification is separate from per-camera authenticated discovery.
    public nonisolated let qualification: RecordedHTTPQualification = .finalized(contractID: "recorded-http-v1@7c6782c")
    public nonisolated let address: ServerAddress
    private let client: any RecordedHTTPControlClient
    private let policy: RecordedHTTPResourcePolicy
    private var discoveries: [String: RecordedHTTPCapability] = [:]
    private var deliveryContract: RecordedHTTPDeliveryContract?
    public init(client: any RecordedHTTPControlClient) throws {
        self.client=client; address=client.address
        policy=try RecordedHTTPResourcePolicy(address: client.address)
    }
    private func endpoint(camera: String, tail: [String]) throws -> URL {
        guard NativeNotificationRoute.isValidIdentifier(camera) else { throw RecordedHTTPError.invalidContract }
        return try policy.validate(address.endpoint(["api",camera,"recordings","http"] + tail))
    }
    private func ownedURL(camera: String, id: String, media: Bool = false) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw RecordedHTTPError.invalidWindow }
        return try endpoint(camera: camera, tail: ["sessions",uuid.uuidString.lowercased()] + (media ? ["media.mp4"] : []))
    }
    private func validate(_ window: RecordedHTTPWindow) throws -> RecordedHTTPWindow {
        let resolved = try window.resolved(policy: policy)
        try resolved.validate(policy: policy, camera: window.camera, now: Date().timeIntervalSince1970)
        let owned = try ownedURL(camera: window.camera, id: window.sessionID)
        guard resolved.statusURL == owned, resolved.closeURL == owned,
              resolved.mediaURL == (try ownedURL(camera: window.camera, id: window.sessionID, media: true)) else {
            throw RecordedHTTPError.invalidContract
        }
        return resolved
    }
    public func discover(camera: String) async throws -> RecordedHTTPCapability {
        let response = try await client.request(endpoint(camera: camera, tail: ["status"]), method: "GET", body: nil, success: [200])
        var caps = try JSONDecoder().decode(RecordedHTTPCapability.self, from: response.data)
        guard caps.enabled && caps.available else { throw RecordedHTTPError.unavailable }
        try caps.validate()
        guard caps.maxWindowSeconds == 30, let session = caps.sessionURL, let resolve = caps.resolveURL,
              try policy.resolve(session) == endpoint(camera: camera, tail: ["sessions"]),
              try policy.resolve(resolve) == endpoint(camera: camera, tail: ["resolve"]) else { throw RecordedHTTPError.invalidContract }
        if let deliveryContract { caps.deliveryContract = deliveryContract }
        else {
            do {
                let url = try policy.validate(address.endpoint(["api","openapi.json"]))
                let metadata = try await client.request(url, method: "GET", body: nil, success: [200])
                caps.deliveryContract = try RecordedHTTPDeliveryContract.inspect(openAPI: metadata.data)
            } catch {
                guard let code = (error as? HorizonError)?.httpStatusCode, [403,404,405,501].contains(code) else { throw error }
                caps.deliveryContract = .metadataUnavailable(code)
            }
            deliveryContract = caps.deliveryContract
        }
        discoveries[camera]=caps
        return caps
    }
    private func discovery(camera: String) async throws -> RecordedHTTPCapability {
        if let value = discoveries[camera] { return value }
        return try await discover(camera: camera)
    }
    public func sourceRange(selection: RecordedViewingSelection) async throws -> ClosedRange<Double> {
        guard case .timeRange(let start, let end) = selection.identity,
              start.isFinite, end.isFinite, start >= 0, end > start else { throw RecordedHTTPError.unsupportedSource }
        return start...end
    }
    public func create(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest) async throws -> RecordedHTTPWindow {
        switch selection.identity {
        case .timeRange, .event: break
        case .export, .cameraSD: throw RecordedHTTPError.unsupportedSource
        }
        let caps = try await discovery(camera: selection.camera)
        guard caps.qualities.contains(request.quality), request.before - request.after <= caps.maxWindowSeconds,
              let returned = caps.sessionURL else { throw RecordedHTTPError.invalidContract }
        let negotiated = try request.negotiating(contract: caps.deliveryContract, decoders: client.decoderCapabilities)
        let response = try await client.request(policy.resolve(returned), method: "POST",
            body: JSONEncoder().encode(negotiated), success: [202])
        struct Identity: Decodable { let session_id: String; let camera: String }
        let identity = try JSONDecoder().decode(Identity.self, from: response.data)
        guard identity.camera == selection.camera, UUID(uuidString: identity.session_id) != nil else {
            throw RecordedHTTPError.uncertainCreation
        }
        do {
            let window = try validate(JSONDecoder().decode(RecordedHTTPWindow.self, from: response.data))
            try window.validate(request: request)
            guard window.delivery != .originalFile || caps.deliveryContract.supportsDirectOriginal else {
                throw RecordedHTTPError.invalidContract
            }
            return window
        } catch {
            let url = try ownedURL(camera: selection.camera, id: identity.session_id)
            try await closeURL(url)
            throw RecordedHTTPError.rejectedCreation
        }
    }
    public func status(window: RecordedHTTPWindow) async throws -> RecordedHTTPWindow {
        let owned = try validate(window)
        let response = try await client.request(owned.statusURL, method: "GET", body: nil, success: [200])
        let next = try validate(JSONDecoder().decode(RecordedHTTPWindow.self, from: response.data))
        let originalTransition = window.state != .ready && next.state == .ready && next.delivery == .originalFile
        guard next.sessionID == window.sessionID, next.camera == window.camera, next.after == window.after,
              next.startTimestamp == window.startTimestamp,
              originalTransition ? next.before <= window.before : next.before == window.before,
              originalTransition || next.nextTimestamp == window.nextTimestamp else { throw RecordedHTTPError.invalidContract }
        if next.delivery == .originalFile {
            guard try await discovery(camera: window.camera).deliveryContract.supportsDirectOriginal else { throw RecordedHTTPError.invalidContract }
        }
        return next
    }
    public func resolve(camera: String, request: RecordedHTTPResolveRequest) async throws -> RecordedHTTPResolution {
        let caps = try await discovery(camera: camera)
        guard let url = caps.resolveURL else { throw RecordedHTTPError.invalidContract }
        let response = try await client.request(policy.resolve(url), method: "POST",
            body: JSONEncoder().encode(request), success: [200])
        let value = try JSONDecoder().decode(RecordedHTTPResolution.self, from: response.data)
        try value.validate(request: request)
        return value
    }
    public func mediaInfo(window: RecordedHTTPWindow) async throws -> RecordedHTTPMediaInfo {
        let owned = try validate(window)
        guard owned.state == .ready, let url = owned.mediaURL else { throw RecordedHTTPError.preparationFailed }
        let head = try await client.request(url, method: "HEAD", body: nil, success: [200])
        guard let lengthText = head.headers["content-length"], let length = Int64(lengthText), length > 0,
              head.headers["content-type"]?.lowercased().split(separator: ";").first == "video/mp4",
              head.headers["accept-ranges"]?.lowercased() == "bytes",
              let etag = head.headers["etag"], etag.hasPrefix("\""), etag.hasSuffix("\"") else {
            throw RecordedHTTPError.rangeUnsupported
        }
        let reader = try AuthenticatedRecordedMP4Reader(mediaURL: url, verificationLength: length,
            policy: policy, cookies: client.cookies, configuration: client.mediaConfiguration,
            cookieProvider: { [client] in try await client.mediaCookies() })
        defer { reader.close() }
        let fastStart = try await RecordedMP4Faststart.verifyIndex(reader: reader, allowTail: owned.delivery == .originalFile)
        let confirmed = try await client.request(url, method: "HEAD", body: nil, success: [200])
        guard confirmed.headers["content-length"] == lengthText, confirmed.headers["etag"] == etag else {
            throw RecordedHTTPError.rangeUnsupported
        }
        return RecordedHTTPMediaInfo(length: length, complete: true, immutable: true, fastStart: fastStart, rangeSupported: true, indexed: true)
    }
    private func closeURL(_ url: URL) async throws {
        do { _ = try await client.request(url, method: "DELETE", body: nil, success: [204]) }
        catch {
            guard let code = (error as? HorizonError)?.httpStatusCode, [404,410].contains(code) else { throw error }
        }
    }
    public func close(window: RecordedHTTPWindow) async throws {
        let canonical = try ownedURL(camera: window.camera, id: window.sessionID)
        guard try policy.resolve(window.closeURL.relativeString) == canonical else { throw RecordedHTTPError.invalidContract }
        try await closeURL(canonical)
    }
}

public enum RecordedMP4Faststart {
    public static func verify(reader: AuthenticatedRecordedMP4Reader) async throws {
        _ = try await verifyIndex(reader: reader, allowTail: false)
    }
    public static func verifyIndex(reader: AuthenticatedRecordedMP4Reader, allowTail: Bool) async throws -> Bool {
        var offset: Int64 = 0
        var foundType = false
        var foundMedia = false
        for _ in 0..<32 {
            guard offset <= reader.length - 8 else { throw RecordedHTTPError.rangeUnsupported }
            let header = try await reader.read(RecordedMP4Range(offset: offset, count: Int(min(16, reader.length - offset))))
            guard header.count >= 8 else { throw RecordedHTTPError.invalidRange }
            let bytes = Array(header)
            var size = bytes.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: bytes[4..<8], encoding: .ascii)
            if size == 1 {
                guard bytes.count >= 16 else { throw RecordedHTTPError.invalidRange }
                size = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard size >= 8, size <= UInt64(reader.length - offset) else { throw RecordedHTTPError.rangeUnsupported }
            if type == "ftyp" { foundType = true }
            if type == "moov" {
                guard foundType else { throw RecordedHTTPError.rangeUnsupported }
                return !foundMedia
            }
            if type == "mdat" {
                guard allowTail else { throw RecordedHTTPError.rangeUnsupported }
                foundMedia = true
            }
            offset += Int64(size)
        }
        throw RecordedHTTPError.rangeUnsupported
    }
}
