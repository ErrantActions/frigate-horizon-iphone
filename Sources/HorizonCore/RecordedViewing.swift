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
