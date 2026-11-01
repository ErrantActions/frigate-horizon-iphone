import Foundation

public struct RecordedViewingSelection: Equatable, Sendable {
    public enum Identity: Equatable, Sendable {
        case timeRange(start: Double, end: Double)
        case event(String)
        case export(String)
        case cameraSD(recordingID: String, start: Double, end: Double)
    }
    public let camera: String
    public let identity: Identity
    public init(camera: String, identity: Identity) { self.camera = camera; self.identity = identity }
}

public struct RecordedViewingPosition: Equatable, Sendable {
    public let sourceTimestamp: Double
    public let generation: UUID
    public let sequence: Int64
    public let playing: Bool
    public init(sourceTimestamp: Double, generation: UUID, sequence: Int64, playing: Bool) {
        self.sourceTimestamp = sourceTimestamp; self.generation = generation; self.sequence = sequence; self.playing = playing
    }
}

public protocol RecordedViewingSession: Sendable {
    func capabilities() async throws -> RecordedViewingCapabilities
    func positionEvents() async -> AsyncThrowingStream<RecordedViewingPosition, Error>
    func play() async throws
    func pause() async throws
    func seek(sourceTimestamp: Double, generation: UUID) async throws -> RecordedViewingPosition
    func setRate(_ rate: Double) async throws
    func setQuality(_ height: Int?) async throws
    func close() async throws
}

public struct RecordedViewingCapabilities: Equatable, Sendable {
    public let renditions: [ViewingRendition]
    public let playbackRates: [Double]
    public let pauseSupported: Bool
    public let seekSupported: Bool
    public init(renditions: [ViewingRendition], playbackRates: [Double],
                pauseSupported: Bool, seekSupported: Bool) {
        self.renditions = renditions; self.playbackRates = playbackRates
        self.pauseSupported = pauseSupported; self.seekSupported = seekSupported
    }
}

public struct RecordedViewingTimeline: Sendable {
    public private(set) var generation = UUID()
    public private(set) var position: RecordedViewingPosition?
    public init() {}
    public mutating func beginSeek() -> UUID { generation = UUID(); position = nil; return generation }
    public mutating func accept(_ value: RecordedViewingPosition) -> Bool {
        guard value.generation == generation, value.sourceTimestamp.isFinite, value.sourceTimestamp >= 0,
              value.sequence >= 0, position.map({ value.sequence > $0.sequence }) ?? true else { return false }
        position = value
        return true
    }
    public func acceptsFrame(generation: UUID) -> Bool { self.generation == generation && position != nil }
}
