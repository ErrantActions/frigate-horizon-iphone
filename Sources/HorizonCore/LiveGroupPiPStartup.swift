import Foundation

public struct LiveGroupPiPStartup: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, preparing, requested, starting, active }
    public private(set) var phase: Phase = .idle
    private var deadline: Double?
    public init() {}
    public mutating func begin(now: Double) {
        precondition(now.isFinite)
        phase = .preparing; deadline = now + 10
    }
    public func retainsPlayers(now: Double) -> Bool {
        guard now.isFinite else { return false }
        return phase == .active || (phase != .idle && deadline.map { now < $0 } == true)
    }
    public mutating func requestIfReady(now: Double, previewReady: Bool, firstFrame: Bool, possible: Bool) -> Bool {
        guard phase == .preparing, retainsPlayers(now: now), previewReady, firstFrame, possible else { return false }
        phase = .requested
        return true
    }
    public mutating func willStart() {
        guard phase != .idle, phase != .active else { return }
        phase = .starting
    }
    public mutating func didStart() {
        guard phase != .idle else { return }
        phase = .active; deadline = nil
    }
    public mutating func expire(now: Double) -> Bool {
        guard phase != .idle, phase != .active, !retainsPlayers(now: now) else { return false }
        cancel()
        return true
    }
    public mutating func cancel() { phase = .idle; deadline = nil }
    public func shouldCancelDetachedPreview(foreground: Bool) -> Bool {
        foreground && phase == .preparing
    }
}
