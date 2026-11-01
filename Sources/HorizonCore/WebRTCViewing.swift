import Foundation

public enum ViewingMessage {
    public static var upgrade: String { String(localized: "viewer.upgrade", defaultValue: "This server needs the native WebRTC viewing upgrade. No alternate player will be started.") }
    public static var unavailable: String { String(localized: "viewer.unavailable", defaultValue: "WebRTC viewing is disabled or unavailable. Check server readiness and retry.") }
    public static var recorded: String { String(localized: "viewer.recorded", defaultValue: "Adaptive recorded WebRTC playback is not available. The server must advertise its recorded-session and timeline-control contract. Original downloads remain available.") }
    public static var invalid: String { String(localized: "viewer.invalid", defaultValue: "The server returned an invalid or out-of-scope viewing session.") }
    public static var expired: String { String(localized: "viewer.expired", defaultValue: "The viewing lease expired. Reconnect to create a new owned viewer.") }
    public static var failed: String { String(localized: "viewer.failed", defaultValue: "WebRTC playback could not connect. Check media runtime, ICE routes and relay readiness, then retry.") }
}

public enum ViewerTransportFailure: LocalizedError {
    case connectionLost, negotiationTimedOut
    public var errorDescription: String? { ViewingMessage.failed }
}

public struct ViewingFeatures: Decodable, Sendable {
    public let liveWebRTC: LiveWebRTCFeature?
    enum CodingKeys: String, CodingKey { case liveWebRTC = "live_webrtc" }
    public func requireLive() throws -> LiveWebRTCFeature {
        guard let feature = liveWebRTC, feature.version == 1,
              feature.signaling == "frigate-rest-offer-answer-v1", feature.onDemand,
              feature.recordings == "original_source",
              feature.statusTemplate == "{camera_name}/live/webrtc/status" else {
            throw HorizonError.message(ViewingMessage.upgrade)
        }
        guard feature.enabled, feature.available else { throw HorizonError.message(ViewingMessage.unavailable) }
        return feature
    }
}

public struct LiveWebRTCFeature: Decodable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let available: Bool
    public let statusTemplate: String
    public let signaling: String
    public let onDemand: Bool
    public let recordings: String
    enum CodingKeys: String, CodingKey {
        case version, enabled, available, signaling, recordings
        case statusTemplate = "status_url_template"; case onDemand = "on_demand"
    }
}

public struct ViewingRendition: Codable, Equatable, Sendable {
    public let height: Int
    public let bitrate: Int
    public func validate() throws {
        guard (144...2160).contains(height), bitrate > 0 else { throw HorizonError.message(ViewingMessage.invalid) }
    }
}

public struct LiveWebRTCStatus: Decodable, Sendable {
    public let version: Int
    public let protocolName: String
    public let enabled: Bool
    public let available: Bool
    public let sessionURL: String
    public let gridHeight: Int
    public let gridRendition: ViewingRendition
    public let relayAvailable: Bool
    public let renditions: [ViewingRendition]
    enum CodingKeys: String, CodingKey {
        case version, enabled, available, renditions
        case protocolName = "protocol"; case sessionURL = "session_url"
        case gridHeight = "grid_height"; case gridRendition = "grid_rendition"
        case relayAvailable = "relay_available"
    }
    public func validate(policy: ViewerResourcePolicy) throws {
        guard version == 1, protocolName == "webrtc" else { throw HorizonError.message(ViewingMessage.upgrade) }
        guard enabled, available else { throw HorizonError.message(ViewingMessage.unavailable) }
        try gridRendition.validate()
        for rendition in renditions { try rendition.validate() }
        guard gridHeight == gridRendition.height, renditions.contains(gridRendition),
              Set(renditions.map(\.height)).count == renditions.count else { throw HorizonError.message(ViewingMessage.invalid) }
        _ = try policy.resolve(sessionURL, expected: policy.sessionsURL)
    }
}

public struct ViewerConfiguration: Equatable, Sendable {
    public let grid: Bool
    public let maximumHeight: Int?
    public let exactHeight: Int?
    public let audio: Bool
    public let dataSaver: Bool
    public let forceRelay: Bool
    public init(grid: Bool, maximumHeight: Int? = nil, exactHeight: Int? = nil,
                audio: Bool = true, dataSaver: Bool = false, forceRelay: Bool = false) {
        self.grid = grid; self.maximumHeight = grid ? nil : maximumHeight
        self.exactHeight = grid ? nil : exactHeight; self.audio = grid ? false : audio
        self.dataSaver = dataSaver; self.forceRelay = forceRelay
    }
    public func creation(status: LiveWebRTCStatus) throws -> ViewerCreateBody {
        guard !forceRelay || status.relayAvailable else { throw HorizonError.message(ViewingMessage.unavailable) }
        if grid {
            return ViewerCreateBody(view: "grid", height: status.gridHeight, maxHeight: nil, audio: false, forceRelay: forceRelay)
        }
        let detail = Set(status.renditions.map(\.height).filter { $0 >= 720 })
        guard !detail.isEmpty else { throw HorizonError.message(ViewingMessage.unavailable) }
        let cap = dataSaver ? 720 : (maximumHeight ?? detail.max()!)
        guard [720,1080,2160].contains(cap), detail.contains(where: { $0 <= cap }),
              maximumHeight.map({ [720,1080,2160].contains($0) }) ?? true else {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        let height = dataSaver ? 720 : exactHeight
        guard height.map({ detail.contains($0) && $0 <= cap }) ?? true else {
            throw HorizonError.message(String(localized: "viewer.quality", defaultValue: "Choose an advertised detail quality within the current cap. Data Saver requires 720p, not a grid-only rung."))
        }
        return ViewerCreateBody(view: "detail", height: height, maxHeight: cap, audio: audio, forceRelay: forceRelay)
    }
}

public struct ViewerCreateBody: Encodable, Sendable {
    public let view: String
    public let height: Int?
    public let maxHeight: Int?
    public let audio: Bool
    public let forceRelay: Bool
    enum CodingKeys: String, CodingKey { case view, height, audio; case maxHeight = "max_height"; case forceRelay = "force_relay" }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(view, forKey: .view); try values.encode(height, forKey: .height)
        try values.encode(maxHeight, forKey: .maxHeight); try values.encode(audio, forKey: .audio)
        try values.encode(forceRelay, forKey: .forceRelay)
    }
}

public struct ViewerResourcePolicy: Sendable {
    public let address: ServerAddress
    public let camera: String
    public let apiBase: URL
    public let statusURL: URL
    public let sessionsURL: URL
    public init(address: ServerAddress, camera: String) throws {
        guard address.url.scheme == "https", !camera.isEmpty, camera.utf8.count <= 256,
              camera != ".", camera != "..", camera.rangeOfCharacter(from: .controlCharacters) == nil,
              let encoded = camera.addingPercentEncoding(withAllowedCharacters:
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        self.address = address; self.camera = camera
        apiBase = address.endpoint(["api"]).appendingPathComponent("")
        var parts = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += encoded + "/live/webrtc/status"
        guard let status = parts.url else { throw HorizonError.message(ViewingMessage.invalid) }
        statusURL = status
        sessionsURL = status.deletingLastPathComponent().appendingPathComponent("sessions")
    }
    public func owned(_ id: UUID, operation: String? = nil) -> URL {
        let base = sessionsURL.appendingPathComponent(id.uuidString.lowercased())
        return operation.map { base.appendingPathComponent($0) } ?? base
    }
    public func resolve(_ reference: String, expected: URL) throws -> URL {
        guard !reference.isEmpty, reference.utf8.count <= 4096,
              !reference.contains("\\"), reference.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts = URLComponents(string: reference), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let result = URL(string: reference, relativeTo: apiBase)?.absoluteURL,
              address.hasSameOrigin(as: result),
              URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedPath
                == URLComponents(url: expected, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        return result
    }
}

public struct ViewerSDP: Codable, Sendable {
    public let type: String
    public let sdp: String
    public init(type: String, sdp: String) { self.type = type; self.sdp = sdp }
    public func validate(expected: String, receiveOnly: Bool = false) throws {
        guard type == expected, sdp.utf8.count <= 524_288, sdp.hasPrefix("v=0"),
              sdp.contains("m=video "), !sdp.contains("m=application ") else { throw HorizonError.message(ViewingMessage.invalid) }
        if receiveOnly {
            var direction = "sendrecv"
            for line in sdp.components(separatedBy: .newlines) {
                if line.hasPrefix("a=sendrecv") || line.hasPrefix("a=sendonly") { throw HorizonError.message(ViewingMessage.invalid) }
                if line == "a=recvonly" || line == "a=inactive" { direction = "recvonly" }
            }
            guard direction == "recvonly" else { throw HorizonError.message(ViewingMessage.invalid) }
        }
    }
}

public struct ViewerCandidate: Codable, Sendable {
    public let candidate: String
    public let sdpMLineIndex: Int32
    public let sdpMid: String?
    public let usernameFragment: String?
    public init(candidate: String, sdpMLineIndex: Int32, sdpMid: String?, usernameFragment: String? = nil) throws {
        guard candidate.hasPrefix("candidate:"), candidate.utf8.count <= 16_384, sdpMLineIndex >= 0,
              (sdpMid?.utf8.count ?? 0) <= 256, (usernameFragment?.utf8.count ?? 0) <= 256 else {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        self.candidate = candidate; self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid; self.usernameFragment = usernameFragment
    }
}

public struct ViewerCandidateQueue: Sendable {
    private var answered = false
    private var pending: [ViewerCandidate] = []
    public init() {}
    public var hasReadyBatch: Bool { answered && !pending.isEmpty }
    public mutating func append(_ value: ViewerCandidate) throws {
        guard pending.count < 256 else { throw HorizonError.message(ViewingMessage.failed) }
        pending.append(value)
    }
    public mutating func acceptAnswer() { answered = true }
    public mutating func takeBatch() -> [ViewerCandidate] {
        guard answered else { return [] }
        let batch = Array(pending.prefix(32))
        pending.removeFirst(batch.count)
        return batch
    }
}

public struct ViewerSessionIdentity: Decodable, Sendable {
    public let sessionID: UUID
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

public struct ViewerSessionDescription: Decodable, Sendable {
    public let version: Int
    public let protocolName: String
    public let sessionID: UUID
    public let expiresAt: Double
    public let heartbeatSeconds: Int
    public let answerURL: String
    public let candidatesURL: String
    public let heartbeatURL: String
    public let closeURL: String
    public let qualityURL: String
    public let iceServers: [ICEServer]
    public let offer: ViewerSDP
    public let iceCandidates: [ViewerCandidate]
    public let iceTransportPolicy: String
    public let renditions: [ViewingRendition]
    public let initialHeight: Int
    enum CodingKeys: String, CodingKey {
        case version, offer, renditions
        case protocolName = "protocol"; case sessionID = "session_id"; case expiresAt = "expires_at"
        case heartbeatSeconds = "heartbeat_seconds"; case answerURL = "answer_url"; case candidatesURL = "candidates_url"
        case heartbeatURL = "heartbeat_url"; case closeURL = "close_url"; case qualityURL = "quality_url"
        case iceServers = "ice_servers"; case iceCandidates = "ice_candidates"
        case iceTransportPolicy = "ice_transport_policy"; case initialHeight = "initial_height"
    }
    public func validate(policy: ViewerResourcePolicy, configuration: ViewerConfiguration, now: Double) throws {
        guard version == 1, protocolName == "webrtc", expiresAt.isFinite, expiresAt > now,
              (1...60).contains(heartbeatSeconds), ["all", "relay"].contains(iceTransportPolicy),
              !configuration.forceRelay || iceTransportPolicy == "relay",
              !renditions.isEmpty, renditions.count <= 16,
              Set(renditions.map(\.height)).count == renditions.count,
              renditions.contains(where: { $0.height == initialHeight }),
              configuration.grid || renditions.allSatisfy({ $0.height >= 720 }),
              configuration.maximumHeight.map({ cap in renditions.allSatisfy { $0.height <= cap } }) ?? true,
              !configuration.dataSaver || configuration.grid || (initialHeight == 720 && renditions.allSatisfy { $0.height <= 720 }),
              iceCandidates.count <= 256 else { throw HorizonError.message(ViewingMessage.invalid) }
        if let requested = configuration.exactHeight, !configuration.grid, !configuration.dataSaver,
           initialHeight != requested { throw HorizonError.message(ViewingMessage.invalid) }
        for rendition in renditions { try rendition.validate() }
        try offer.validate(expected: "offer")
        for server in iceServers { try Self.validateICE(server) }
        if iceTransportPolicy == "relay",
           !iceServers.contains(where: { $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }) {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        for candidate in iceCandidates {
            _ = try ViewerCandidate(candidate: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid, usernameFragment: candidate.usernameFragment)
        }
        for (reference, expected) in [(answerURL, policy.owned(sessionID, operation: "answer")),
            (candidatesURL, policy.owned(sessionID, operation: "candidates")),
            (heartbeatURL, policy.owned(sessionID)), (closeURL, policy.owned(sessionID)),
            (qualityURL, policy.owned(sessionID, operation: "quality"))] { _ = try policy.resolve(reference, expected: expected) }
    }
    public static func validateICE(_ server: ICEServer) throws {
        guard !server.urls.isEmpty, server.urls.count <= 16 else { throw HorizonError.message(ViewingMessage.invalid) }
        for url in server.urls {
            let scheme = url.split(separator: ":", maxSplits: 1).first.map(String.init)
            guard ["stun", "stuns", "turn", "turns"].contains(scheme ?? ""),
                  url.utf8.count <= 2048, !url.contains("@"), !url.contains("#"),
                  url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw HorizonError.message(ViewingMessage.invalid) }
            if scheme == "turn" || scheme == "turns" {
                guard server.username?.isEmpty == false, server.credential?.isEmpty == false else {
                    throw HorizonError.message(ViewingMessage.invalid)
                }
            }
        }
    }
}

public struct ViewerHeartbeat: Decodable, Sendable {
    public let sessionID: UUID?
    public let expiresAt: Double
    public let heartbeatSeconds: Int?
    public let iceServers: [ICEServer]?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"; case expiresAt = "expires_at"
        case heartbeatSeconds = "heartbeat_seconds"; case iceServers = "ice_servers"
    }
}

public struct ViewerLeaseState: Sendable {
    public private(set) var id: UUID?
    public private(set) var expiresAt = 0.0
    public private(set) var interval = 10
    public init() {}
    public mutating func accept(id: UUID, expiresAt: Double, interval: Int, now: Double) throws {
        guard now.isFinite, expiresAt.isFinite, expiresAt > now, (1...60).contains(interval) else {
            throw HorizonError.message(ViewingMessage.expired)
        }

        self.id = id; self.expiresAt = expiresAt; self.interval = interval
    }
    public mutating func renew(_ value: ViewerHeartbeat, now: Double) throws {
        guard let id, value.sessionID == nil || value.sessionID == id, now < expiresAt else {
            throw HorizonError.message(ViewingMessage.expired)
        }
        try accept(id: id, expiresAt: value.expiresAt, interval: value.heartbeatSeconds ?? interval, now: now)
    }
    public func isValid(now: Double) -> Bool { id != nil && now.isFinite && now < expiresAt }
}

public struct ViewerOwnershipState: Sendable {
    public private(set) var generation = UUID()
    public private(set) var activeID: UUID?
    public init() {}
    public mutating func invalidate() { generation = UUID(); activeID = nil }
    public mutating func acceptCreated(_ id: UUID, generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        activeID = id
        return true
    }
}

public func viewingFailureMessage(_ error: Error) -> String {
    switch (error as? HorizonError)?.httpStatusCode {
    case 401: return String(localized: "viewer.auth", defaultValue: "Sign in again to renew this account's viewing session.")
    case 403: return String(localized: "viewer.denied", defaultValue: "Camera access was denied. Refresh permissions or choose another camera.")
    case 404: return String(localized: "viewer.missing", defaultValue: "The owned viewer or requested quality is no longer available. Refresh and retry.")
    case 409: return String(localized: "viewer.conflict", defaultValue: "The viewing session is in a conflicting negotiation state. Reconnect.")
    case 410: return ViewingMessage.expired
    case 422: return String(localized: "viewer.payload", defaultValue: "The server rejected the viewing request. Update the app/server contract.")
    case 429: return String(localized: "viewer.capacity", defaultValue: "The server's shared viewing/encoder capacity is in use. Close another viewer before retrying.")
    case 503: return ViewingMessage.unavailable
    default:
        if let failure = error as? HorizonError, case .message(let message) = failure { return message }
        return ViewingMessage.failed
    }
}
