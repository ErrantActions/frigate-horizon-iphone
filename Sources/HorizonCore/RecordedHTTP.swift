import Foundation

public enum RecordedHTTPError: LocalizedError, Sendable {
    case unavailable, invalidContract, invalidWindow, gap, expired, preparationFailed, rangeUnsupported, invalidRange, uncertainCreation
    case emptyWindow(nextTimestamp: Double), searchLimit, unsupportedSource, rejectedCreation
    public var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "review.httpUnavailable", defaultValue: "Recorded HTTP viewing is disabled or unavailable for this camera. Check server readiness and retry. Original downloads remain available.")
        case .invalidContract: return String(localized: "review.invalidContract", defaultValue: "The server did not provide a supported, qualified recorded HTTP contract.")
        case .invalidWindow: return String(localized: "review.invalidWindow", defaultValue: "The recorded window or source/media timeline is invalid.")
        case .gap: return String(localized: "review.gap", defaultValue: "No recorded footage maps to this position. Choose another recorded span.")
        case .expired: return String(localized: "review.expired", defaultValue: "The prepared recorded window expired. Reopen a bounded window.")
        case .preparationFailed: return String(localized: "review.preparationFailed", defaultValue: "The recorded window could not be prepared. Check server readiness and retry.")
        case .rangeUnsupported: return String(localized: "review.rangeUnsupported", defaultValue: "The MP4 resource did not provide the required immutable byte-range behavior.")
        case .invalidRange: return String(localized: "review.invalidRange", defaultValue: "The server returned an invalid or inconsistent MP4 byte range.")
        case .uncertainCreation: return String(localized: "review.uncertainCreation", defaultValue: "Recorded window creation could not be accounted for. New preparation is blocked until server ownership is reconciled.")
        case .emptyWindow: return String(localized: "review.empty", defaultValue: "This prepared window has no playable frame. Looking for the next usable frame.")
        case .searchLimit: return String(localized: "review.searchLimit", defaultValue: "The bounded frame search reached its limit. This does not prove footage is missing. Advance the timeline and try again.")
        case .unsupportedSource: return String(localized: "review.unsupportedSource", defaultValue: "The server's recorded HTTP API supports camera recording ranges, not this media source. Original downloads remain available.")
        case .rejectedCreation: return String(localized: "review.invalidContract", defaultValue: "The server did not provide a supported, qualified recorded HTTP contract.")
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
    public let sessionURL: String?
    public let resolveURL: String?
    public let reason: String?
    public var deliveryContract: RecordedHTTPDeliveryContract = .preparedLegacy
    enum CodingKeys: String, CodingKey {
        case version, enabled, available, transport, seek, qualities
        case maxWindowSeconds = "max_window_seconds", originalsUnchanged = "original_recordings_unchanged"
        case hlsFallback = "hls_fallback"
        case sessionURL = "session_url", resolveURL = "resolve_url", reason
    }
    public init(maxWindowSeconds: Double, qualities: [RecordedHTTPQuality], sessionURL: String? = nil, resolveURL: String? = nil) {
        version = 1; enabled = true; available = true; transport = "https_mp4"; seek = "http_byte_range"
        self.maxWindowSeconds = maxWindowSeconds; originalsUnchanged = true; hlsFallback = false; self.qualities = qualities
        self.sessionURL = sessionURL; self.resolveURL = resolveURL; reason = nil
    }
    public func validate() throws {
        guard version == 1, transport == "https_mp4", seek == "http_byte_range",
              originalsUnchanged, !hlsFallback, maxWindowSeconds.isFinite,
              (0.1...30).contains(maxWindowSeconds), !qualities.isEmpty,
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
    public let startPolicy = "next"
    public let deliveryRequest: RecordedHTTPDeliveryRequest?
    enum CodingKeys: String, CodingKey {
        case version, after, before, quality
        case startTimestamp = "start_timestamp", startPolicy = "start_policy"
        case delivery, videoCodecs = "video_codecs", audioCodecs = "audio_codecs"
    }
    public init(after: Double, before: Double, startTimestamp: Double, quality: RecordedHTTPQuality, maximum: Double = 30,
                deliveryRequest: RecordedHTTPDeliveryRequest? = nil) throws {
        guard [after,before,startTimestamp,maximum].allSatisfy(\.isFinite), after >= 0,
              (0.1...30).contains(before - after), before - after <= maximum,
              startTimestamp >= after, startTimestamp < before else { throw RecordedHTTPError.invalidWindow }
        self.after = after; self.before = before; self.startTimestamp = startTimestamp; self.quality = quality
        self.deliveryRequest = deliveryRequest
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(version, forKey: .version)
        try fields.encode(after, forKey: .after); try fields.encode(before, forKey: .before)
        try fields.encode(startTimestamp, forKey: .startTimestamp); try fields.encode(startPolicy, forKey: .startPolicy)
        try fields.encode(quality, forKey: .quality)
        if let deliveryRequest {
            try fields.encode(deliveryRequest.delivery, forKey: .delivery)
            try fields.encode(deliveryRequest.decoders.video, forKey: .videoCodecs)
            try fields.encode(deliveryRequest.decoders.audio, forKey: .audioCodecs)
        }
    }
    public func negotiating(contract: RecordedHTTPDeliveryContract, decoders: RecordedHTTPDecoderCapabilities) throws -> Self {
        guard contract.supportsDirectOriginal else {
            guard deliveryRequest?.delivery != .direct else { throw RecordedHTTPError.unsupportedSource }
            return try Self(after: after, before: before, startTimestamp: startTimestamp, quality: quality)
        }
        let mode: RecordedHTTPRequestedDelivery = deliveryRequest?.delivery ?? (quality.height == nil ? .auto : .prepared)
        return try Self(after: after, before: before, startTimestamp: startTimestamp, quality: quality,
            deliveryRequest: RecordedHTTPDeliveryRequest(delivery: mode, decoders: decoders))
    }
    public static func bounded(sourceRange: ClosedRange<Double>, at source: Double, maximum: Double,
                               quality: RecordedHTTPQuality, duration: Double = 10) throws -> Self {
        guard source >= sourceRange.lowerBound, source < sourceRange.upperBound else { throw RecordedHTTPError.gap }
        let width = min(duration, maximum, sourceRange.upperBound - sourceRange.lowerBound)
        let after = max(sourceRange.lowerBound, min(source, sourceRange.upperBound - width))
        return try Self(after: after, before: after + width,
            startTimestamp: source, quality: quality, maximum: maximum)
    }
    public static func continuation(sourceRange: ClosedRange<Double>, after anchor: Double,
                                    maximum: Double, quality: RecordedHTTPQuality) throws -> Self {
        guard anchor >= sourceRange.lowerBound, anchor < sourceRange.upperBound else { throw RecordedHTTPError.gap }
        return try Self(after: anchor, before: min(sourceRange.upperBound, anchor + min(20, maximum)),
            startTimestamp: anchor, quality: quality, maximum: maximum)
    }
}

public struct RecordedHTTPWindow: Codable, Sendable {
    public enum State: String, Codable, Sendable { case preparing, ready, empty, failed, cleanupPending = "cleanup_pending" }
    public let version: Int
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
    public let after: Double
    public let before: Double
    public let startTimestamp: Double
    public let effectiveStartTimestamp: Double?
    public let nextTimestamp: Double
    public let error: String?
    public let delivery: RecordedHTTPActualDelivery?
    public let preparationReason: String?
    enum CodingKeys: String, CodingKey {
        case version,camera,state,quality,audio,timeline,width,height,after,before,error
        case sessionID = "session_id", statusURL = "status_url", closeURL = "close_url", mediaURL = "media_url"
        case hardExpiresAt = "hard_expires_at"
        case startTimestamp = "start_timestamp", effectiveStartTimestamp = "effective_start_timestamp", nextTimestamp = "next_timestamp"
        case delivery, preparationReason = "preparation_reason"
    }
    public init(sessionID: String, camera: String, state: State, quality: RecordedHTTPQuality, audio: Bool,
                statusURL: URL, closeURL: URL, mediaURL: URL?, hardExpiresAt: Double, timeline: [RecordedHTTPSpan],
                after: Double, before: Double, startTimestamp: Double, effectiveStartTimestamp: Double?,
                nextTimestamp: Double, width: Int? = nil, height: Int? = nil, error: String? = nil,
                delivery: RecordedHTTPActualDelivery? = nil, preparationReason: String? = nil) {
        version = 1
        self.sessionID=sessionID; self.camera=camera; self.state=state; self.quality=quality; self.audio=audio
        self.statusURL=statusURL; self.closeURL=closeURL; self.mediaURL=mediaURL; self.hardExpiresAt=hardExpiresAt
        self.timeline=timeline; self.width=width; self.height=height
        self.after=after; self.before=before; self.startTimestamp=startTimestamp
        self.effectiveStartTimestamp=effectiveStartTimestamp; self.nextTimestamp=nextTimestamp; self.error=error
        self.delivery=delivery; self.preparationReason=preparationReason
    }
    public func validate(policy: RecordedHTTPResourcePolicy, camera: String, now: Double) throws {
        guard version == 1, self.camera == camera, NativeNotificationRoute.isValidIdentifier(sessionID),
              [after,before,startTimestamp,nextTimestamp].allSatisfy(\.isFinite),
              after >= 0, before > after, before - after <= 30,
              delivery == .originalFile || before - after >= 0.1, startTimestamp >= after,
              startTimestamp < before, nextTimestamp == before else { throw RecordedHTTPError.invalidWindow }
        guard hardExpiresAt.isFinite, hardExpiresAt > now else { throw RecordedHTTPError.expired }
        _ = try policy.validate(statusURL); _ = try policy.validate(closeURL)
        if let mediaURL { _ = try policy.validate(mediaURL) }
        if state == .ready {
            guard mediaURL != nil,
                  width.map({ $0 > 0 }) ?? true, height.map({ $0 > 0 }) ?? true else { throw RecordedHTTPError.invalidWindow }
            _ = try RecordedHTTPMapping(spans: timeline)
            guard let effectiveStartTimestamp, effectiveStartTimestamp.isFinite,
                  effectiveStartTimestamp >= startTimestamp, effectiveStartTimestamp < before,
                  try RecordedHTTPMapping(spans: timeline).mediaTime(for: effectiveStartTimestamp) != nil else {
                throw RecordedHTTPError.invalidWindow
            }
        }
        if state == .empty {
            guard timeline.isEmpty, effectiveStartTimestamp == nil else { throw RecordedHTTPError.invalidWindow }
        }
    }
    public func resolved(policy: RecordedHTTPResourcePolicy) throws -> Self {
        Self(sessionID: sessionID, camera: camera, state: state, quality: quality, audio: audio,
            statusURL: try policy.resolve(statusURL.relativeString), closeURL: try policy.resolve(closeURL.relativeString),
            mediaURL: try mediaURL.map { try policy.resolve($0.relativeString) }, hardExpiresAt: hardExpiresAt,
            timeline: timeline, after: after, before: before, startTimestamp: startTimestamp,
            effectiveStartTimestamp: effectiveStartTimestamp, nextTimestamp: nextTimestamp,
            width: width, height: height, error: error, delivery: delivery, preparationReason: preparationReason)
    }
    public func validate(request: RecordedHTTPWindowRequest) throws {
        guard after == request.after, startTimestamp == request.startTimestamp, before <= request.before,
              delivery == .originalFile || before == request.before else { throw RecordedHTTPError.invalidWindow }
    }
}

public struct RecordedHTTPMediaInfo: Sendable {
    public let length: Int64
    public let complete: Bool
    public let immutable: Bool
    public let fastStart: Bool
    public let rangeSupported: Bool
    public let indexed: Bool
    public init(length: Int64, complete: Bool, immutable: Bool, fastStart: Bool, rangeSupported: Bool, indexed: Bool = false) {
        self.length=length; self.complete=complete; self.immutable=immutable; self.fastStart=fastStart; self.rangeSupported=rangeSupported
        self.indexed = indexed
    }
    public func validate() throws {
        guard length > 0, complete, immutable, fastStart || indexed, rangeSupported else { throw RecordedHTTPError.rangeUnsupported }
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
    func resolve(camera: String, request: RecordedHTTPResolveRequest) async throws -> RecordedHTTPResolution
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
    public func resolve(camera: String, request: RecordedHTTPResolveRequest) async throws -> RecordedHTTPResolution { throw RecordedHTTPError.unavailable }
}

public struct PreparedRecordedHTTPWindow: Sendable {
    public let window: RecordedHTTPWindow
    public let mapping: RecordedHTTPMapping
    public let info: RecordedHTTPMediaInfo
    public let request: RecordedHTTPWindowRequest
    public let playingIntent: Bool
    public let preparationSeconds: Double
    public func seekDecision(at source: Double) -> RecordedHTTPSeekDecision {
        if let time = mapping.mediaTime(for: source) { return .native(mediaTime: time) }
        if !source.isFinite || (source >= window.after && source < window.before) { return .gap }
        return .replacement
    }
}

public enum RecordedHTTPSeekDecision: Equatable, Sendable {
    case native(mediaTime: Double), gap, replacement
}

public enum RecordedHTTPContinuationPolicy {
    public static func leadSeconds(preparationSeconds: Double, windowSeconds: Double,
                                   nextWindowSeconds: Double, playbackRate: Double, originalFile: Bool = false) throws -> Double {
        guard [preparationSeconds,windowSeconds,nextWindowSeconds,playbackRate].allSatisfy(\.isFinite),
              preparationSeconds >= 0, windowSeconds > 0, nextWindowSeconds > 0, playbackRate > 0 else {
            throw RecordedHTTPError.invalidWindow
        }
        return (preparationSeconds * (originalFile ? 1 : nextWindowSeconds / windowSeconds) + 2) * playbackRate
    }
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
            let started = ProcessInfo.processInfo.systemUptime
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
                let local = error as? RecordedHTTPError
                let noCreation: Bool
                switch local {
                case .rejectedCreation?, .unsupportedSource?, .invalidContract?: noCreation = true
                default: noCreation = false
                }
                if !noCreation, ![401,403,422,429].contains((error as? HorizonError)?.httpStatusCode ?? 0) {
                    await self.quarantineCreation()
                }
                throw error
            }
            do {
                window = try window.resolved(policy: policy)
                for attempt in 0..<45 {
                    try Task.checkCancellation()
                    try window.validate(policy: policy, camera: selection.camera, now: Date().timeIntervalSince1970)
                    if window.state == .ready { break }
                    if window.state == .empty { throw RecordedHTTPError.emptyWindow(nextTimestamp: window.nextTimestamp) }
                    guard window.state == .preparing else { throw RecordedHTTPError.preparationFailed }
                    try await Task.sleep(for: .seconds(min(1, 0.1 * Double(attempt + 1))))
                    let next = try await transport.status(window: window).resolved(policy: policy)
                    guard next.sessionID == window.sessionID, next.closeURL == window.closeURL,
                          next.statusURL == window.statusURL else {
                        throw RecordedHTTPError.invalidWindow
                    }
                    try next.validate(request: request)
                    window = try next.resolved(policy: policy)
                }
                guard window.state == .ready else { throw RecordedHTTPError.preparationFailed }
                let derivativeFallback = caps.deliveryContract.supportsDirectOriginal && request.quality == .original &&
                    window.delivery == .prepared && window.preparationReason != nil && caps.qualities.contains(window.quality)
                guard window.quality == request.quality || derivativeFallback ||
                    (request.quality == .auto && caps.qualities.contains(window.quality)) else { throw RecordedHTTPError.invalidWindow }
                let info = try await transport.mediaInfo(window: window)
                try info.validate()
                let mapping = try RecordedHTTPMapping(spans: window.timeline)
                try window.validate(request: request)
                guard mapping.spans.allSatisfy({ $0.sourceEnd <= request.before + 0.000001 }) else {
                    throw RecordedHTTPError.invalidWindow
                }
                guard let effective = window.effectiveStartTimestamp, mapping.mediaTime(for: effective) != nil else { throw RecordedHTTPError.gap }
                try Task.checkCancellation()
                return PreparedRecordedHTTPWindow(window: window, mapping: mapping, info: info,
                    request: request, playingIntent: playing,
                    preparationSeconds: ProcessInfo.processInfo.systemUptime - started)
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
