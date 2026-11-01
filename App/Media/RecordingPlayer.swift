import SwiftUI
import AVFoundation
import HorizonCore

// Observable control compatibility only: no URL asset, media loading or local seek is implemented.
@MainActor
final class RecordingPlayer: ObservableObject {
    lazy var player = AVPlayer()
    @Published private(set) var error: String? = ViewingMessage.recorded
    @Published private(set) var loading = false
    @Published private(set) var position = 0.0
    @Published private(set) var isSeeking = false
    func open(selection: RecordedViewingSelection, api: HorizonAPI, initialPosition: Double = 0,
              autoplay: Bool = true) {
        error = ViewingMessage.recorded
    }
    func stop() { player.pause(); player.replaceCurrentItem(with: nil) }
    func releaseInline() { stop() }
    func seek(to position: Double, autoplay: Bool? = nil) { error = ViewingMessage.recorded }
}

extension Notification.Name {
    static let horizonMediaAuthenticationExpired = Notification.Name("Horizon.mediaAuthenticationExpired")
    static let horizonMediaCleanupFailure = Notification.Name("Horizon.mediaCleanupFailure")
}

@MainActor
enum RecordedViewingRegistry { static func stopAll() {} }

struct NativeRecordingSurface: View {
    let player: AVPlayer
    var allowsPiP = false
    var body: some View {
        ContentUnavailableView(String(localized: "viewer.recordedTitle", defaultValue: "Recorded viewing requires a server upgrade"),
            systemImage: "play.slash", description: Text(ViewingMessage.recorded))
    }
}

struct RecordingPlaybackView: View {
    let api: HorizonAPI
    let camera: String
    let start: Double
    let end: Double
    var initialTimestamp: Double? = nil
    var identity: RecordedViewingSelection.Identity? = nil
    var body: some View {
        ContentUnavailableView(String(localized: "viewer.recordedTitle", defaultValue: "Recorded viewing requires a server upgrade"),
            systemImage: "play.slash", description: Text(ViewingMessage.recorded))
    }
}
