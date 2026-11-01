import Foundation

public enum RecordedHTTPError: LocalizedError, Sendable {
    case unavailable, invalidContract, invalidWindow, gap, expired, preparationFailed, rangeUnsupported, invalidRange, uncertainCreation
    public var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "review.httpUnavailable", defaultValue: "Recorded HTTPS MP4 review requires the finalized server discovery and range contract. Original downloads remain available.")
        case .invalidContract: return String(localized: "review.invalidContract", defaultValue: "The server did not provide a supported, qualified recorded HTTP contract.")
        case .invalidWindow: return String(localized: "review.invalidWindow", defaultValue: "The recorded window or source/media timeline is invalid.")
        case .gap: return String(localized: "review.gap", defaultValue: "No recorded footage maps to this position. Choose another recorded span.")
        case .expired: return String(localized: "review.expired", defaultValue: "The prepared recorded window expired. Reopen a bounded window.")
        case .preparationFailed: return String(localized: "review.preparationFailed", defaultValue: "The recorded window could not be prepared. Check server readiness and retry.")
        case .rangeUnsupported: return String(localized: "review.rangeUnsupported", defaultValue: "The MP4 resource did not provide the required immutable byte-range behavior.")
        case .invalidRange: return String(localized: "review.invalidRange", defaultValue: "The server returned an invalid or inconsistent MP4 byte range.")
        case .uncertainCreation: return String(localized: "review.uncertainCreation", defaultValue: "Recorded window creation could not be accounted for. New preparation is blocked until server ownership is reconciled.")
        }
    }
}

public enum RecordedHTTPQualification: Equatable, Sendable {
    case unavailable, fixture, finalized(contractID: String)
    public var usable: Bool {
        switch self {
        case .unavailable: return false
        case .fixture: return true
        case .finalized(let id): return !id.isEmpty
        }
    }
}

public enum RecordedHTTPQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case auto, original, h360 = "360", h720 = "720", h1080 = "1080", h2160 = "2160"
    public var height: Int? { Int(rawValue) }
}

public struct RecordedHTTPCapability: Codable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let available: Bool
    public let transport: String
    public let seek: String
    public let maxWindowSeconds: Double
    public let originalsUnchanged: Bool
    public let hlsFallback: Bool
    public let qualities: [RecordedHTTPQuality]
    enum CodingKeys: String, CodingKey {
        case version, enabled, available, transport, seek, qualities
        case maxWindowSeconds = "max_window_seconds", originalsUnchanged = "original_recordings_unchanged"
        case hlsFallback = "hls_fallback"
    }
    public init(maxWindowSeconds: Double, qualities: [RecordedHTTPQuality]) {
        version = 1; enabled = true; available = true; transport = "https_mp4"; seek = "http_byte_range"
        self.maxWindowSeconds = maxWindowSeconds; originalsUnchanged = true; hlsFallback = false; self.qualities = qualities
    }
    public func validate() throws {
        guard version == 1, transport == "https_mp4", seek == "http_byte_range",
              originalsUnchanged, !hlsFallback, maxWindowSeconds.isFinite,
              (0.1...120).contains(maxWindowSeconds), !qualities.isEmpty,
              Set(qualities).count == qualities.count else { throw RecordedHTTPError.invalidContract }
        guard enabled && available else { throw RecordedHTTPError.unavailable }
    }
    public func quality(_ requested: RecordedHTTPQuality, dataSaver: Bool) throws -> RecordedHTTPQuality {
        try validate()
        if dataSaver && requested == .auto {
            guard let lowest = qualities.filter({ $0.height != nil }).min(by: { $0.height! < $1.height! }) else {
                throw RecordedHTTPError.unavailable
            }
            return lowest
        }
        guard qualities.contains(requested) else { throw RecordedHTTPError.invalidContract }
        return requested
    }
}

public struct RecordedHTTPSpan: Codable, Equatable, Sendable {
    public let sourceStart: Double
    public let sourceEnd: Double
    public let mediaStart: Double
    public let mediaEnd: Double
    enum CodingKeys: String, CodingKey {
        case sourceStart = "source_start", sourceEnd = "source_end", mediaStart = "media_start", mediaEnd = "media_end"
    }
    public init(sourceStart: Double, sourceEnd: Double, mediaStart: Double, mediaEnd: Double) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.mediaStart = mediaStart; self.mediaEnd = mediaEnd
    }
}

public struct RecordedHTTPMapping: Equatable, Sendable {
    public let spans: [RecordedHTTPSpan]
    public init(spans: [RecordedHTTPSpan]) throws {
        guard !spans.isEmpty else { throw RecordedHTTPError.invalidWindow }
        var previous: RecordedHTTPSpan?
        for span in spans {
            guard [span.sourceStart, span.sourceEnd, span.mediaStart, span.mediaEnd].allSatisfy(\.isFinite),
                  span.sourceStart >= 0, span.mediaStart >= 0,
                  span.sourceEnd > span.sourceStart, span.mediaEnd > span.mediaStart else {
                throw RecordedHTTPError.invalidWindow
            }
            if let previous {
                guard span.sourceStart >= previous.sourceEnd, span.mediaStart >= previous.mediaEnd else {
                    throw RecordedHTTPError.invalidWindow
                }
            }
            previous = span
        }
        self.spans = spans
    }
    public func mediaTime(for source: Double) -> Double? {
        guard source.isFinite, let span = spans.first(where: { source >= $0.sourceStart && source < $0.sourceEnd }) else { return nil }
        return span.mediaStart + (source - span.sourceStart) / (span.sourceEnd - span.sourceStart) * (span.mediaEnd - span.mediaStart)
    }
    public func sourceTime(for media: Double) -> Double? {
        guard media.isFinite, let span = spans.first(where: { media >= $0.mediaStart && media < $0.mediaEnd }) else { return nil }
        return span.sourceStart + (media - span.mediaStart) / (span.mediaEnd - span.mediaStart) * (span.sourceEnd - span.sourceStart)
    }
    public func runEnd(at media: Double) -> Double? {
        guard let index = spans.firstIndex(where: { media >= $0.mediaStart && media < $0.mediaEnd }) else { return nil }
        var end = spans[index].mediaEnd
        var previous = spans[index]
        for span in spans.dropFirst(index + 1) {
            guard abs(span.sourceStart - previous.sourceEnd) < 0.000001,
                  abs(span.mediaStart - previous.mediaEnd) < 0.000001 else { break }
            end = span.mediaEnd; previous = span
        }
        return end
    }
}

public struct RecordedHTTPWindowRequest: Encodable, Equatable, Sendable {
    public let version = 1
    public let after: Double
    public let before: Double
    public let startTimestamp: Double
    public let quality: RecordedHTTPQuality
    enum CodingKeys: String, CodingKey { case version, after, before, quality; case startTimestamp = "start_timestamp" }
    public init(after: Double, before: Double, startTimestamp: Double, quality: RecordedHTTPQuality, maximum: Double = 120) throws {
        guard [after,before,startTimestamp,maximum].allSatisfy(\.isFinite), after >= 0,
              (0.1...120).contains(before - after), before - after <= maximum,
              startTimestamp >= after, startTimestamp < before else { throw RecordedHTTPError.invalidWindow }
        self.after = after; self.before = before; self.startTimestamp = startTimestamp; self.quality = quality
    }
    public static func bounded(sourceRange: ClosedRange<Double>, at source: Double, maximum: Double,
                               quality: RecordedHTTPQuality) throws -> Self {
        guard source >= sourceRange.lowerBound, source < sourceRange.upperBound else { throw RecordedHTTPError.gap }
        let width = min(30, maximum)
        let after = max(sourceRange.lowerBound, source - min(5, width / 4))
        return try Self(after: after, before: min(sourceRange.upperBound, after + width),
            startTimestamp: source, quality: quality, maximum: maximum)
    }
}

public struct RecordedHTTPWindow: Codable, Sendable {
    public enum State: String, Codable, Sendable { case preparing, ready, failed, cleanupPending = "cleanup_pending" }
    public let sessionID: String
    public let camera: String
    public let state: State
    public let quality: RecordedHTTPQuality
    public let audio: Bool
    public let statusURL: URL
    public let closeURL: URL
    public let mediaURL: URL?
    public let hardExpiresAt: Double
    public let timeline: [RecordedHTTPSpan]
    public let width: Int?
    public let height: Int?
    enum CodingKeys: String, CodingKey {
        case camera,state,quality,audio,timeline,width,height
        case sessionID = "session_id", statusURL = "status_url", closeURL = "close_url", mediaURL = "media_url"
        case hardExpiresAt = "hard_expires_at"
    }
    public init(sessionID: String, camera: String, state: State, quality: RecordedHTTPQuality, audio: Bool,
                statusURL: URL, closeURL: URL, mediaURL: URL?, hardExpiresAt: Double, timeline: [RecordedHTTPSpan],
                width: Int? = nil, height: Int? = nil) {
        self.sessionID=sessionID; self.camera=camera; self.state=state; self.quality=quality; self.audio=audio
        self.statusURL=statusURL; self.closeURL=closeURL; self.mediaURL=mediaURL; self.hardExpiresAt=hardExpiresAt
        self.timeline=timeline; self.width=width; self.height=height
    }
    public func validate(policy: RecordedHTTPResourcePolicy, camera: String, now: Double) throws {
        guard self.camera == camera, NativeNotificationRoute.isValidIdentifier(sessionID) else { throw RecordedHTTPError.invalidWindow }
        guard hardExpiresAt.isFinite, hardExpiresAt > now else { throw RecordedHTTPError.expired }
        _ = try policy.validate(statusURL); _ = try policy.validate(closeURL)
        if let mediaURL { _ = try policy.validate(mediaURL) }
        if state == .ready {
            guard mediaURL != nil,
                  width.map({ $0 > 0 }) ?? true, height.map({ $0 > 0 }) ?? true else { throw RecordedHTTPError.invalidWindow }
            _ = try RecordedHTTPMapping(spans: timeline)
        }
        public func resolved(policy: RecordedHTTPResourcePolicy) throws -> Self {
            Self(sessionID: sessionID, camera: camera, state: state, quality: quality, audio: audio,
                statusURL: try policy.resolve(statusURL.relativeString), closeURL: try policy.resolve(closeURL.relativeString),
                mediaURL: try mediaURL.map { try policy.resolve($0.relativeString) }, hardExpiresAt: hardExpiresAt,
                timeline: timeline, width: width, height: height)
        }
    }
}

public struct RecordedHTTPMediaInfo: Sendable {
    public let length: Int64
    public let complete: Bool
    public let immutable: Bool
    public let fastStart: Bool
    public let rangeSupported: Bool
    public init(length: Int64, complete: Bool, immutable: Bool, fastStart: Bool, rangeSupported: Bool) {
        self.length=length; self.complete=complete; self.immutable=immutable; self.fastStart=fastStart; self.rangeSupported=rangeSupported
    }
    public func validate() throws {
        guard length > 0, complete, immutable, fastStart, rangeSupported else { throw RecordedHTTPError.rangeUnsupported }
    }
}

public struct RecordedHTTPResourcePolicy: Sendable {
    public let address: ServerAddress
    public init(address: ServerAddress) throws {
        guard address.url.scheme == "https" else { throw RecordedHTTPError.invalidContract }
        self.address = address
    }
    public func validate(_ url: URL) throws -> URL {
        guard address.hasSameOrigin(as: url), url.scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasPrefix(URLComponents(url: address.endpoint(["api"]),
                resolvingAgainstBaseURL: false)!.percentEncodedPath + "/") else { throw RecordedHTTPError.invalidContract }
        for segment in components.percentEncodedPath.split(separator: "/") {
            guard segment != ".", segment != "..", let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.contains("%"), decoded.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw RecordedHTTPError.invalidContract
            }
        }
        return url
    }
    public func resolve(_ returned: String) throws -> URL {
        guard let base = URL(string: address.endpoint(["api"]).absoluteString + "/"),
              let url = URL(string: returned, relativeTo: base)?.absoluteURL else { throw RecordedHTTPError.invalidContract }
        // Validate before URL resolution can normalize a traversal out of view.
        let path = URLComponents(string: returned)?.percentEncodedPath ?? ""
        for part in path.split(separator: "/") {
            let decoded = String(part).removingPercentEncoding
            guard decoded != ".", decoded != ".." else { throw RecordedHTTPError.invalidContract }
        }
        return try validate(url)
    }
}

public protocol RecordedHTTPTransport: Sendable {
    var qualification: RecordedHTTPQualification { get }
    var address: ServerAddress { get }
    func discover(camera: String) async throws -> RecordedHTTPCapability
    func sourceRange(selection: RecordedViewingSelection) async throws -> ClosedRange<Double>
    func create(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest) async throws -> RecordedHTTPWindow
    func status(window: RecordedHTTPWindow) async throws -> RecordedHTTPWindow
    func mediaInfo(window: RecordedHTTPWindow) async throws -> RecordedHTTPMediaInfo
    func close(window: RecordedHTTPWindow) async throws
}

public struct UnavailableRecordedHTTPTransport: RecordedHTTPTransport {
    public let qualification: RecordedHTTPQualification = .unavailable
    public let address: ServerAddress
    public init(address: ServerAddress) { self.address = address }
    public func discover(camera: String) async throws -> RecordedHTTPCapability { throw RecordedHTTPError.unavailable }
    public func sourceRange(selection: RecordedViewingSelection) async throws -> ClosedRange<Double> { throw RecordedHTTPError.unavailable }
    public func create(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest) async throws -> RecordedHTTPWindow { throw RecordedHTTPError.unavailable }
    public func status(window: RecordedHTTPWindow) async throws -> RecordedHTTPWindow { throw RecordedHTTPError.unavailable }
    public func mediaInfo(window: RecordedHTTPWindow) async throws -> RecordedHTTPMediaInfo { throw RecordedHTTPError.unavailable }
    public func close(window: RecordedHTTPWindow) async throws { throw RecordedHTTPError.unavailable }
}

public struct PreparedRecordedHTTPWindow: Sendable {
    public let window: RecordedHTTPWindow
    public let mapping: RecordedHTTPMapping
    public let info: RecordedHTTPMediaInfo
    public let request: RecordedHTTPWindowRequest
    public let playingIntent: Bool
    public func seekDecision(at source: Double) -> RecordedHTTPSeekDecision {
        if let time = mapping.mediaTime(for: source) { return .native(mediaTime: time) }
        if !source.isFinite || (source >= request.after && source < request.before) { return .gap }
        return .replacement
    }
}

public enum RecordedHTTPSeekDecision: Equatable, Sendable {
    case native(mediaTime: Double), gap, replacement
}

public actor RecordedHTTPWindowManager {
    private let transport: any RecordedHTTPTransport
    private var worker: Task<PreparedRecordedHTTPWindow, Error>?
    private var current: PreparedRecordedHTTPWindow?
    private var generation = UUID()
    private var pendingCleanup: Task<Void, Error>?
    private var cleanupDebt: [String: RecordedHTTPWindow] = [:]
    private var uncertainCreation = false
    private var closing: [String: Task<Void, Error>] = [:]
    private var closed: Set<String> = []
    public init(transport: any RecordedHTTPTransport) { self.transport = transport }
    public func prepare(selection: RecordedViewingSelection, request: RecordedHTTPWindowRequest,
                        playing: Bool) async throws -> PreparedRecordedHTTPWindow {
        guard transport.qualification.usable else { throw RecordedHTTPError.unavailable }
        let token = UUID(); generation = token
        let previous = worker
        previous?.cancel()
        let old = current; current = nil
        if let old { cleanupDebt[old.window.sessionID] = old.window }
        let cleanup = pendingCleanup
        let transport = self.transport
        let task = Task {
            _ = await previous?.result
            try await cleanup?.value
            try Task.checkCancellation()
            if let old { try await self.closeOwned(old.window) }
            try await self.drainCleanup()
            let policy = try RecordedHTTPResourcePolicy(address: transport.address)
            let caps = try await transport.discover(camera: selection.camera)
            try caps.validate()
            guard request.before - request.after <= caps.maxWindowSeconds,
                  caps.qualities.contains(request.quality) else { throw RecordedHTTPError.invalidContract }
            try Task.checkCancellation()
            // A late create result remains awaited so its opaque session can be released.
            let creation = Task { try await transport.create(selection: selection, request: request) }
            var window: RecordedHTTPWindow
            do { window = try await creation.value }
            catch {
                if ![401,403,422,429].contains((error as? HorizonError)?.httpStatusCode ?? 0) {
                    await self.quarantineCreation()
                }
                throw error
            }
            do {
                window = try window.resolved(policy: policy)
                for attempt in 0..<30 {
                    try Task.checkCancellation()
                    try window.validate(policy: policy, camera: selection.camera, now: Date().timeIntervalSince1970)
                    if window.state == .ready { break }
                    guard window.state == .preparing else { throw RecordedHTTPError.preparationFailed }
                    try await Task.sleep(for: .seconds(min(1, 0.1 * Double(attempt + 1))))
                    let next = try await transport.status(window: window).resolved(policy: policy)
                    guard next.sessionID == window.sessionID, next.closeURL == window.closeURL,
                          next.statusURL == window.statusURL else { throw RecordedHTTPError.invalidWindow }
                    window = try next.resolved(policy: policy)
                }
                guard window.state == .ready else { throw RecordedHTTPError.preparationFailed }
                guard window.quality == request.quality ||
                    (request.quality == .auto && caps.qualities.contains(window.quality)) else { throw RecordedHTTPError.invalidWindow }
                let info = try await transport.mediaInfo(window: window)
                try info.validate()
                let mapping = try RecordedHTTPMapping(spans: window.timeline)
                guard mapping.spans.allSatisfy({ $0.sourceStart >= request.after && $0.sourceEnd <= request.before }) else {
                    throw RecordedHTTPError.invalidWindow
                }
                guard mapping.mediaTime(for: request.startTimestamp) != nil else { throw RecordedHTTPError.gap }
                try Task.checkCancellation()
                return PreparedRecordedHTTPWindow(window: window, mapping: mapping, info: info,
                    request: request, playingIntent: playing)
            } catch {
                try await self.closeOwned(window)
                throw error
            }
        }
        worker = task
        let result = try await task.value
        guard generation == token else {
            try await closeOwned(result.window)
            throw CancellationError()
        }
        current = result
        return result
    }
    public func cancel() {
        generation = UUID()
        let work = worker; worker = nil
        work?.cancel()
        let old = current; current = nil
        let previousCleanup = pendingCleanup
        pendingCleanup = Task {
            _ = await previousCleanup?.result
            if let result = await work?.result, case .success(let value) = result { try await self.closeOwned(value.window) }
            if let old { try await self.closeOwned(old.window) }
            try await self.drainCleanup()
        }
    }
    public func finishCleanup() async throws { try await pendingCleanup?.value }
    public func retryCleanup() async throws {
        try await drainCleanup()
        pendingCleanup = nil
    }
    private func quarantineCreation() { uncertainCreation = true }
    private func closeOwned(_ window: RecordedHTTPWindow) async throws {
        guard !closed.contains(window.sessionID) else { return }
        if let task = closing[window.sessionID] { try await task.value; return }
        cleanupDebt[window.sessionID] = window
        let transport = self.transport
        let task = Task { try await transport.close(window: window) }
        closing[window.sessionID] = task
        do {
            try await task.value
            closed.insert(window.sessionID)
            cleanupDebt.removeValue(forKey: window.sessionID)
            closing.removeValue(forKey: window.sessionID)
        } catch {
            closing.removeValue(forKey: window.sessionID)
            throw error
        }
    }
    private func drainCleanup() async throws {
        guard !uncertainCreation else { throw RecordedHTTPError.uncertainCreation }
        for window in Array(cleanupDebt.values) { try await closeOwned(window) }
    }
}
