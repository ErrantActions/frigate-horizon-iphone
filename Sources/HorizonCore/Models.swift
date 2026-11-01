import Foundation

public struct HorizonConfiguration: Decodable, Sendable {
    public let cameras: [String: CameraSettings]
    public let go2rtc: Go2RTCSettings?
    public let semanticSearch: SemanticSearchSettings?
    public let auth: AuthSettings?
    enum CodingKeys: String, CodingKey {
        case cameras, go2rtc, auth
        case semanticSearch = "semantic_search"
    }

    public struct AuthSettings: Decodable, Sendable {
        public let roles: [String: [String]]
    }

    public var orderedCameras: [HorizonCamera] {
        cameras.map { HorizonCamera(id: $0.key, settings: $0.value) }.sorted {
            let left = $0.settings.ui?.order ?? 0
            let right = $1.settings.ui?.order ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
    }
}

public struct SemanticSearchSettings: Decodable, Sendable {
    public let enabled: Bool
}

public struct CameraSettings: Decodable, Sendable {
    public let friendlyName: String?
    public let enabled: Bool
    public let live: LiveSettings
    public let ui: CameraUI?

    enum CodingKeys: String, CodingKey {
        case friendlyName = "friendly_name"
        case enabled, live, ui
    }
}

public struct CameraUI: Decodable, Sendable {
    public let order: Int?
    public let dashboard: Bool?
    public let liveHLS: Bool

    enum CodingKeys: String, CodingKey {
        case order, dashboard
        case liveHLS = "live_hls"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent(Int.self, forKey: .order)
        dashboard = try values.decodeIfPresent(Bool.self, forKey: .dashboard)
        liveHLS = try values.decodeIfPresent(Bool.self, forKey: .liveHLS) ?? false
    }
}

public struct LiveSettings: Decodable, Sendable {
    public let streams: [String: String]
    public let transcode: LiveTranscode?
}

public struct LiveTranscode: Decodable, Sendable {
    public let enabled: Bool
    public let source: String?
    public let qualities: [LiveQuality]
}

public struct LiveQuality: Decodable, Sendable {
    public let height: Int
}

public struct Go2RTCSettings: Decodable, Sendable {
    public let webrtc: WebRTCSettings?
}

public struct WebRTCSettings: Decodable, Sendable {
    public let iceServers: [ICEServer]?
    enum CodingKeys: String, CodingKey { case iceServers = "ice_servers" }
}

public struct ICEServer: Decodable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
    private enum CodingKeys: String, CodingKey { case urls, username, credential }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let url = try? values.decode(String.self, forKey: .urls) { urls = [url] }
        else { urls = try values.decode([String].self, forKey: .urls) }
        username = try values.decodeIfPresent(String.self, forKey: .username)
        credential = try values.decodeIfPresent(String.self, forKey: .credential)
    }
}

public struct HorizonCamera: Identifiable, Sendable {
    public let id: String
    public let settings: CameraSettings

    public var name: String {
        guard let name = settings.friendlyName, !name.isEmpty else {
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return name
    }

    public func preferredStream(expanded: Bool, maximumHeight: Int? = nil) -> String? {
        guard settings.enabled else { return nil }
        let belowMinimum = Set(advertisedLiveProfiles.filter { $0.height < 720 }.map(\.stream))
        let configured = Set(settings.live.streams.values).subtracting(belowMinimum)
        let renditions = advertisedLiveRenditions
        if let maximumHeight {
            return renditions.last(where: { $0.height <= maximumHeight })?.stream
        }
        let target = expanded ? 1080 : 720
        if let rendition = renditions.first(where: { $0.height >= target }) ?? renditions.last {
            return rendition.stream
        }
        if let source = settings.live.transcode?.source, configured.contains(source) {
            return source
        }
        if configured.contains(id) { return id }
        if let main = settings.live.streams.first(where: { $0.key.lowercased() == "main" }),
           configured.contains(main.value) {
            return main.value
        }
        return configured.count == 1 ? configured.first : nil
    }
}

public struct UserProfile: Decodable, Sendable {
    public let username: String
    public let role: String
    public let allowedCameras: [String]
    public var isAdmin: Bool { role == "admin" }
    enum CodingKeys: String, CodingKey {
        case username, role
        case allowedCameras = "allowed_cameras"
    }
}

public struct ReviewSegment: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let severity: String
    public let startTime: Double
    public let endTime: Double?
    public let thumbPath: String
    public var hasBeenReviewed: Bool
    public let data: ReviewData

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case startTime = "start_time"
        case endTime = "end_time"
        case thumbPath = "thumb_path"
        case hasBeenReviewed = "has_been_reviewed"
    }

    public var title: String {
        let labels = Array(Set(data.objects + data.audio)).sorted()
        return labels.isEmpty ? "Activity" : labels.joined(separator: ", ").capitalized
    }

    public func playbackRange(now: Double = Date().timeIntervalSince1970) -> ClosedRange<Double>? {
        // Open events remain open. A bounded playback request must not manufacture an end time.
        guard let endTime, endTime <= now, endTime > startTime else { return nil }
        return max(0, startTime - 4)...endTime
    }
}

public struct ReviewData: Decodable, Sendable {
    public let objects: [String]
    public let audio: [String]
    public let zones: [String]
}

public struct RecordingSegment: Decodable, Sendable {
    public let startTime: Double
    public let endTime: Double
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

public struct RecordingWindow: Identifiable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public var id: String { "\(start)-\(end)" }

    public static func available(
        _ segments: [RecordingSegment], after: Double, before: Double
    ) -> [RecordingWindow] {
        let valid = segments.filter {
            $0.startTime.isFinite && $0.endTime.isFinite
                && $0.endTime > $0.startTime && $0.endTime > after && $0.startTime < before
        }.sorted { $0.startTime < $1.startTime }
        var windows: [RecordingWindow] = []
        for segment in valid {
            let start = max(after, segment.startTime)
            let end = min(before, segment.endTime)
            if let last = windows.last, start <= last.end {
                windows[windows.count - 1] = RecordingWindow(start: last.start, end: max(last.end, end))
            } else {
                windows.append(RecordingWindow(start: start, end: end))
            }
        }
        return windows
    }
}
