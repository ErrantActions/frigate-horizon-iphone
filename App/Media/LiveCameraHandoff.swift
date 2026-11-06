import SwiftUI
import HorizonCore

@MainActor
final class LiveCameraHandoff: ObservableObject {
    let session: LivePlaybackSession
    @Published private(set) var isActive = true
    private let viewer = UUID()
    private var timeout: Task<Void, Never>?
    init?(api: HorizonAPI, camera: String, session: LivePlaybackSession) {
        self.session = session
        guard session.retainGridHandoff(viewer, api: api, cameraID: camera) else { return nil }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.release()
        }
    }
    func release() {
        guard isActive else { return }
        isActive = false
        timeout?.cancel(); timeout = nil
        session.detach(viewer)
    }
}

@MainActor
struct LiveCameraHandoffSurface: View {
    @ObservedObject var handoff: LiveCameraHandoff
    @ObservedObject private var source: LivePlaybackSession
    let fillVideo: Bool
    init(handoff: LiveCameraHandoff, fillVideo: Bool) {
        self.handoff = handoff; self.fillVideo = fillVideo
        _source = ObservedObject(wrappedValue: handoff.session)
    }
    var body: some View {
        Group {
            if handoff.isActive, source.error == nil {
                NativeRTCViewerSurface(track: source.rtcViewer.videoTrack, fillVideo: fillVideo)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: source.error) { _, error in if error != nil { handoff.release() } }
    }
}
