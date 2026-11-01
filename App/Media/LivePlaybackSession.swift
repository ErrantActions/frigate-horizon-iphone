import Combine
import AVFoundation
import HorizonCore

struct LivePictureInPictureSelection: Equatable {
    let cameraID: String
    let stream: String
    let transport: String
    let muted: Bool
}

@MainActor
final class LivePlaybackAttachment: ObservableObject {
    @Published private(set) var session = LivePlaybackSession()
    private var observation: AnyCancellable?
    init() { observeSession() }
    func adoptRetainedSession(api: HorizonAPI, cameraID: String, stream: String?, transport: String,
                              enabled: Bool, viewer: UUID) {
        guard enabled, let retained = LivePictureInPictureController.shared.retainedSession(
            api: api, cameraID: cameraID, stream: stream, transport: transport), retained !== session else { return }
        session.detach(viewer)
        session = retained
        observeSession()
        retained.attach(viewer)
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

@MainActor
final class LivePlaybackSession: ObservableObject {
    let hlsLive = HLSLiveStream()
    @Published var pictureInPictureError: String?
    @Published private(set) var failure: String?
    @Published private(set) var paused = false
    @Published private(set) var selection: LivePictureInPictureSelection?
    @Published private(set) var needsReauthentication = false
    private(set) var liveHLSConfiguration: LiveHLSConfiguration?
    private var apiIdentity: ObjectIdentifier?
    private var playback: Task<Void, Never>?
    private var generation = UUID()
    private var viewers: [UUID: Bool] = [:]
    private var observation: AnyCancellable?
    var usesLiveHLS: Bool { true }
    var resolution: CGSize? { hlsLive.resolution }
    var error: String? { failure ?? hlsLive.error }
    var status: String { hlsLive.status }
    var compatibilityNotice: String? { nil }
    var hasInlineViewer: Bool { viewers.values.contains(true) }
    var isRunning: Bool { playback != nil }

    init() {
        observation = hlsLive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func matches(api: HorizonAPI, cameraID: String, stream: String?, transport: String) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection?.cameraID == cameraID
    }
    func belongs(to api: HorizonAPI, allowedCameraIDs: Set<String>) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection.map { allowedCameraIDs.contains($0.cameraID) } == true
    }
    func attach(_ viewer: UUID) { if viewers[viewer] == nil { viewers[viewer] = false } }
    func detach(_ viewer: UUID) { viewers.removeValue(forKey: viewer); stopIfNoOwner() }
    func deactivateInlineViewer(_ viewer: UUID) { viewers[viewer] = false; stopIfNoOwner() }
    private func stopIfNoOwner() {
        if !hasInlineViewer && !LivePictureInPictureController.shared.isPlaying(self) { suspend() }
    }
    func configure(api: HorizonAPI, cameraID: String, stream: String?, transport: String,
                   muted: Bool, cameraEnabled: Bool, active: Bool, visible: Bool, foreground: Bool,
                   viewer: UUID, iceServers: [ICEServer], adaptiveQuality: LiveAdaptiveQualityPlan? = nil,
                   liveHLS: LiveHLSConfiguration? = nil) {
        let pip = LivePictureInPictureController.shared
        let authorized = pip.permitsInlinePlayback(api: api, cameraID: cameraID)
        viewers[viewer] = active && visible && foreground && authorized && cameraEnabled
        guard authorized, cameraEnabled, let configuration = liveHLS else {
            if pip.owns(self) { pip.stop() }
            suspend()
            return
        }
        let retained = pip.owns(self) && apiIdentity == ObjectIdentifier(api) && selection?.cameraID == cameraID
        if apiIdentity != ObjectIdentifier(api) || selection?.cameraID != cameraID ||
            (!retained && liveHLSConfiguration != configuration) {
            if pip.owns(self) { pip.stop() }
            suspend()
            apiIdentity = ObjectIdentifier(api)
            failure = nil
            needsReauthentication = false
            paused = false
        }
        if !retained { liveHLSConfiguration = configuration }
        selection = .init(cameraID: cameraID, stream: "", transport: "hls", muted: muted)
        hlsLive.muted = muted
        guard hasInlineViewer || pip.isPlaying(self) else { suspend(); return }
        guard playback == nil, !paused, failure == nil else { return }
        let token = UUID()
        generation = token
        playback = Task { [weak self] in
            guard let self else { return }
            // A rotated child is recovered by rebuilding status and master once, not retrying its URL.
            for attempt in 0...1 {
                do {
                    guard try await self.hlsLive.prepare(api: api, camera: cameraID, configuration: configuration) else {
                        self.sourceFailed("Live HLS is disabled or unavailable for this camera. Refresh cameras or check its server status.")
                        return
                    }
                    guard self.generation == token, !Task.isCancelled else { self.hlsLive.stop(); return }
                    await self.hlsLive.run()
                    guard self.generation == token, !Task.isCancelled else { return }
                    if self.hlsLive.lastHTTPStatus == 404 && attempt == 0 { continue }
                    self.sourceFailed(self.hlsLive.error ?? "Live HLS ended. Reconnect to retry.",
                        authenticationRequired: self.hlsLive.needsReauthentication)
                    return
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    if (error as? HorizonError)?.httpStatusCode == 404 && attempt == 0 { continue }
                    self.sourceFailed(error.localizedDescription,
                        authenticationRequired: LiveHLSGate.requiresReauthentication(error))
                    return
                }
            }
        }
    }
    func reconnect() {
        if LivePictureInPictureController.shared.owns(self) { LivePictureInPictureController.shared.stop() }
        suspend()
        failure = nil
        needsReauthentication = false
        paused = false
        pictureInPictureError = nil
    }
    func sourceFailed(_ message: String, authenticationRequired: Bool = false) {
        failure = message
        needsReauthentication = authenticationRequired
        if LivePictureInPictureController.shared.owns(self) {
            LivePictureInPictureController.shared.sourceFailed(self, message: message)
        } else { suspend() }
    }
    func pictureInPictureEnded(keepInlinePlayback: Bool) {
        if !keepInlinePlayback || !hasInlineViewer { paused = true; suspend() }
    }
    private func suspend() {
        generation = UUID()
        playback?.cancel()
        playback = nil
        hlsLive.stop()
    }
}
