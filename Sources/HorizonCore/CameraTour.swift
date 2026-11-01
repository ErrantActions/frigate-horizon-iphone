import Foundation

public extension HorizonCamera {
    var isTourCandidate: Bool {
        isLiveDashboardCamera
    }
}

public enum CameraTourInterval: Int, CaseIterable, Identifiable, Sendable {
    case five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60
    public var id: Int { rawValue }
    public var label: String { "\(rawValue) sec" }
}

public enum CameraTourMode: String, CaseIterable, Identifiable, Sendable {
    case timed, motion
    public var id: String { rawValue }
    public var label: String { self == .timed ? "Timed cycle" : "Follow motion" }
}

public enum CameraTourTiming {
    public static let allowedSeconds = 1...3600
    public static let motionHoldSeconds: TimeInterval = 8

    public static func seconds(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(trimmed), allowedSeconds.contains(value) else { return nil }
        return value
    }
}

public struct CameraTourState: Equatable, Sendable {
    public private(set) var cameraIDs: [String] = []
    public private(set) var currentID: String?

    public init(cameraIDs: [String] = []) { update(cameraIDs: cameraIDs) }
    public var position: Int? { currentID.flatMap { cameraIDs.firstIndex(of: $0).map { $0 + 1 } } }

    public mutating func update(cameraIDs: [String]) {
        var seen: Set<String> = []
        self.cameraIDs = cameraIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        if currentID.map({ self.cameraIDs.contains($0) }) != true { currentID = self.cameraIDs.first }
    }

    public mutating func next() { move(by: 1) }
    public mutating func previous() { move(by: -1) }

    private mutating func move(by offset: Int) {
        guard let currentID, let index = cameraIDs.firstIndex(of: currentID), !cameraIDs.isEmpty else { return }
        self.currentID = cameraIDs[(index + offset + cameraIDs.count) % cameraIDs.count]
    }
}

public struct CameraTourSchedule: Equatable, Sendable {
    public let cameraID: String?
    public let cameraCount: Int
    public let interval: CameraTourInterval
    public let cycling: Bool
    public let foreground: Bool
    public let ready: Bool
    public let failed: Bool

    public init(cameraID: String?, cameraCount: Int, interval: CameraTourInterval,
                cycling: Bool, foreground: Bool, ready: Bool, failed: Bool) {
        self.cameraID = cameraID
        self.cameraCount = cameraCount
        self.interval = interval
        self.cycling = cycling
        self.foreground = foreground
        self.ready = ready
        self.failed = failed
    }

    public var advanceAfterSeconds: Int? {
        guard cameraID != nil, cameraCount > 1, cycling, foreground else { return nil }
        return ready && !failed ? interval.rawValue : nil
    }

    public static func keepAwake(active: Bool, visible: Bool, foreground: Bool, hasCamera: Bool) -> Bool {
        active && visible && foreground && hasCamera
    }
}

public struct CameraTourSlot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: String
    public fileprivate(set) var ready = false
    public fileprivate(set) var failed = false

    fileprivate init(cameraID: String) {
        id = UUID()
        self.cameraID = cameraID
    }
}

/// Slot identity survives handoff, so promoting a decoded incoming stream never restarts it.
public struct CameraTourPlayback: Equatable, Sendable {
    public private(set) var cameraIDs: [String] = []
    public private(set) var current: CameraTourSlot?
    public private(set) var incoming: CameraTourSlot?
    public private(set) var handoffRequested = false

    public init(cameraIDs: [String] = []) { update(cameraIDs: cameraIDs) }
    public var slots: [CameraTourSlot] { [current, incoming].compactMap { $0 } }
    public var position: Int? { current.flatMap { cameraIDs.firstIndex(of: $0.cameraID).map { $0 + 1 } } }

    public mutating func update(cameraIDs: [String]) {
        let ids = CameraTourState(cameraIDs: cameraIDs).cameraIDs
        guard ids != self.cameraIDs else { return }
        self.cameraIDs = ids
        cancelIncoming()
        if current.map({ ids.contains($0.cameraID) }) != true {
            current = ids.first.map { CameraTourSlot(cameraID: $0) }
        }
    }

    public func neighbor(offset: Int, fromPending: Bool = false) -> String? {
        guard !cameraIDs.isEmpty,
              let id = (fromPending ? incoming?.cameraID : nil) ?? current?.cameraID,
              let index = cameraIDs.firstIndex(of: id) else { return nil }
        let step = offset % cameraIDs.count
        return cameraIDs[(index + step + cameraIDs.count) % cameraIDs.count]
    }

    public mutating func preload(_ cameraID: String) {
        guard cameraIDs.contains(cameraID), current?.cameraID != cameraID else { return }
        if incoming?.cameraID != cameraID { incoming = CameraTourSlot(cameraID: cameraID) }
        handoffRequested = false
    }

    public mutating func request(_ cameraID: String) {
        guard cameraIDs.contains(cameraID) else { return }
        if current?.cameraID == cameraID { cancelIncoming(); return }
        if incoming?.cameraID != cameraID { incoming = CameraTourSlot(cameraID: cameraID) }
        handoffRequested = true
        promoteIfReady()
    }

    public mutating func setReady(_ ready: Bool, slotID: UUID) {
        if current?.id == slotID { current?.ready = ready }
        else if incoming?.id == slotID { incoming?.ready = ready }
        else { return }
        promoteIfReady()
    }

    @discardableResult
    public mutating func fail(slotID: UUID) -> String? {
        if current?.id == slotID {
            current?.failed = true
            current?.ready = false
            cancelIncoming()
            return current?.cameraID
        }
        guard incoming?.id == slotID else { return nil }
        let cameraID = incoming?.cameraID
        cancelIncoming()
        return cameraID
    }

    public mutating func cancelIncoming() {
        incoming = nil
        handoffRequested = false
    }

    public mutating func retryCurrent() {
        cancelIncoming()
        current = current.map { CameraTourSlot(cameraID: $0.cameraID) }
    }

    private mutating func promoteIfReady() {
        guard handoffRequested, let incoming, incoming.ready, !incoming.failed,
              cameraIDs.contains(incoming.cameraID) else { return }
        current = incoming
        cancelIncoming()
    }
}

public struct CameraMotionEvent: Equatable, Sendable {
    public let cameraID: String
    public let active: Bool
    public init(cameraID: String, active: Bool) { self.cameraID = cameraID; self.active = active }
}

public enum CameraMotionMessage: Equatable, Sendable {
    case ignored
    case event(CameraMotionEvent)
    case snapshot([String: Bool])
    case malformed
}

public enum CameraMotionParser {
    public static let maximumMessageBytes = 256 * 1024

    public static func parse(_ data: Data, allowedCameraIDs: Set<String>) -> CameraMotionMessage {
        guard data.count <= maximumMessageBytes,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = envelope["topic"] as? String, topic.utf8.count <= 512 else { return .malformed }
        if topic == "camera_activity" {
            let payload: Data?
            if let text = envelope["payload"] as? String { payload = text.data(using: .utf8) }
            else if let object = envelope["payload"] as? [String: Any] {
                payload = try? JSONSerialization.data(withJSONObject: object)
            } else { payload = nil }
            struct Activity: Decodable { let motion: Bool }
            guard let payload, let cameras = try? JSONDecoder().decode([String: Activity].self, from: payload) else {
                return .malformed
            }
            return .snapshot(cameras.filter { allowedCameraIDs.contains($0.key) }.mapValues(\.motion))
        }
        let components = topic.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == "motion",
              allowedCameraIDs.contains(String(components[0])) else { return .ignored }
        guard let value = envelope["payload"] as? String, value == "ON" || value == "OFF" else {
            return .malformed
        }
        return .event(CameraMotionEvent(cameraID: String(components[0]), active: value == "ON"))
    }
}

public struct CameraTourMotionSelection: Equatable, Sendable {
    public private(set) var allowedCameraIDs: Set<String> = []
    public private(set) var queuedCameraID: String?
    public private(set) var holdUntil: Date?
    private var activity: [String: Bool] = [:]

    public init() {}

    public mutating func update(allowedCameraIDs: Set<String>) {
        self.allowedCameraIDs = allowedCameraIDs
        activity = activity.filter { allowedCameraIDs.contains($0.key) }
        if let queuedCameraID, !allowedCameraIDs.contains(queuedCameraID) { self.queuedCameraID = nil }
    }

    public mutating func resetFeed() {
        activity = [:]
        queuedCameraID = nil
    }

    public mutating func discardQueued() { queuedCameraID = nil }

    public mutating func seed(_ snapshot: [String: Bool]) {
        // A reconnect snapshot describes existing activity, not new motion.
        for (cameraID, active) in snapshot where allowedCameraIDs.contains(cameraID) {
            activity[cameraID] = active
        }
    }

    public mutating func receive(_ event: CameraMotionEvent, currentID: String?) {
        guard allowedCameraIDs.contains(event.cameraID) else { return }
        let wasActive = activity[event.cameraID] == true
        activity[event.cameraID] = event.active
        guard event.active, !wasActive, event.cameraID != currentID else { return }
        queuedCameraID = event.cameraID
    }

    public mutating func displayed(at date: Date) {
        holdUntil = date.addingTimeInterval(CameraTourTiming.motionHoldSeconds)
    }

    public mutating func takeTarget(currentID: String?, at date: Date) -> String? {
        guard holdUntil.map({ date >= $0 }) ?? true, let queuedCameraID else { return nil }
        self.queuedCameraID = nil
        guard allowedCameraIDs.contains(queuedCameraID), queuedCameraID != currentID else { return nil }
        return queuedCameraID
    }
}
