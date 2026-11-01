import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class IncidentPlaybackCoordinator: ObservableObject {
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var states: [String: IncidentReplayReadiness] = [:]
    @Published private(set) var cameraErrors: [String: String] = [:]
    @Published private(set) var range: ReviewTimeRange?
    @Published private(set) var timestamp = 0.0
    @Published private(set) var intendsToPlay = false
    @Published private(set) var synchronizing = false
    @Published private(set) var masterCamera: String?
    @Published private(set) var audibleCamera: String?
    @Published private(set) var error: String? = ViewingMessage.recorded
    func prepare(api: HorizonAPI, cameraIDs: [String], allowed: Set<String>, day: Date, at time: Double) {
        stop()
        do {
            _ = try IncidentReplayPolicy.cameras(cameraIDs, allowed: allowed)
            range = try ReviewTimeRange(day: day)
            error = ViewingMessage.recorded
        } catch { self.error = error.localizedDescription }
    }
    func seek(to requested: Double) { error = ViewingMessage.recorded }
    func setPlaying(_ playing: Bool) { error = ViewingMessage.recorded }
    func selectAudio(_ id: String) { error = ViewingMessage.recorded }
    func stop() { players = [:]; states = [:]; cameraErrors = [:]; synchronizing = false; intendsToPlay = false }
}
