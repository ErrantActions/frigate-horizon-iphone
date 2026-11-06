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
        session.detach(viewer); session = retained; observeSession(); retained.attach(viewer)
    }
    func adoptGroupSession(api: HorizonAPI, cameraID: String, viewer: UUID) {
        guard let retained = LiveGroupPictureInPictureController.shared.retainedSession(api: api, cameraID: cameraID),
              retained !== session else { return }
        session.detach(viewer); session = retained; observeSession(); retained.attach(viewer)
    }
    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

@MainActor
final class LivePlaybackSession: ObservableObject {
    let rtcViewer = OwnedWebRTCViewer()
    @Published var pictureInPictureError: String?
    @Published private(set) var failure: String?
    @Published private(set) var paused = false
    @Published private(set) var selection: LivePictureInPictureSelection?
    @Published private(set) var needsReauthentication = false
    @Published private var recovering = false
    private(set) var viewerConfiguration: ViewerConfiguration?
    private var apiIdentity: ObjectIdentifier?
    private var playback: Task<Void, Never>?
    private var generation = UUID()
    private var viewers: [UUID: Bool] = [:]
    private var observation: AnyCancellable?
    var resolution: CGSize? { rtcViewer.resolution }
    var error: String? { failure ?? rtcViewer.error }
    var status: String { recovering ? String(localized: "viewer.recovering", defaultValue: "Recreating owned WebRTC viewer") : rtcViewer.status }
    var compatibilityNotice: String? { nil }
    var hasInlineViewer: Bool { viewers.values.contains(true) }
    var isRunning: Bool { rtcViewer.isRunning }

    init() {
        observation = rtcViewer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func matches(api: HorizonAPI, cameraID: String, stream: String?, transport: String) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection?.cameraID == cameraID
    }
    func belongs(to api: HorizonAPI, allowedCameraIDs: Set<String>) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection.map { allowedCameraIDs.contains($0.cameraID) } == true
    }
    func attach(_ viewer: UUID) { if viewers[viewer] == nil { viewers[viewer] = false } }
    func retainGridHandoff(_ viewer: UUID, api: HorizonAPI, cameraID: String) -> Bool {
        guard belongs(to: api, allowedCameraIDs: [cameraID]), selection?.cameraID == cameraID,
              viewerConfiguration?.grid == true, hasInlineViewer, isRunning,
              resolution != nil, rtcViewer.videoTrack != nil, error == nil else { return false }
        viewers[viewer] = true
        return true
    }
    func detach(_ viewer: UUID) { viewers.removeValue(forKey: viewer); stopIfNoOwner() }
    func deactivateInlineViewer(_ viewer: UUID) { viewers[viewer] = false; stopIfNoOwner() }
    private func stopIfNoOwner() {
        if !hasInlineViewer && !LivePictureInPictureController.shared.isPlaying(self) &&
            !LiveGroupPictureInPictureController.shared.isPlaying(self) { suspend() }
    }
    func configure(api: HorizonAPI, cameraID: String, stream: String?, transport: String,
                   muted: Bool, cameraEnabled: Bool, active: Bool, visible: Bool, foreground: Bool,
                   viewer: UUID, iceServers: [ICEServer], adaptiveQuality: LiveAdaptiveQualityPlan? = nil,
                   viewerConfiguration configuration: ViewerConfiguration?) {
        let pip = LivePictureInPictureController.shared
        let authorized = pip.permitsInlinePlayback(api: api, cameraID: cameraID)
        viewers[viewer] = active && visible && foreground && authorized && cameraEnabled
        guard authorized, cameraEnabled, let configuration else {
            if pip.owns(self) { pip.stop() }
            if LiveGroupPictureInPictureController.shared.owns(self) { LiveGroupPictureInPictureController.shared.stop() }
            suspend(); return
        }
        let sameEnvelope = viewerConfiguration.map {
            $0.grid == configuration.grid && $0.maximumHeight == configuration.maximumHeight &&
            $0.audio == configuration.audio && $0.dataSaver == configuration.dataSaver &&
            $0.forceRelay == configuration.forceRelay
        } ?? false
        let sourceChanged = apiIdentity != ObjectIdentifier(api) || selection?.cameraID != cameraID || !sameEnvelope
        if sourceChanged {
            if pip.owns(self) { pip.stop() }
            if LiveGroupPictureInPictureController.shared.owns(self) { LiveGroupPictureInPictureController.shared.stop() }
            suspend(); apiIdentity = ObjectIdentifier(api)
            failure = nil; paused = false; needsReauthentication = false
        }
        if !sourceChanged, viewerConfiguration?.exactHeight != configuration.exactHeight {
            rtcViewer.setQuality(configuration.dataSaver && !configuration.grid ? 720 : configuration.exactHeight)
        }
        viewerConfiguration = configuration
        selection = .init(cameraID: cameraID, stream: "", transport: "webrtc", muted: muted)
        rtcViewer.muted = muted
        guard hasInlineViewer || pip.isPlaying(self) || LiveGroupPictureInPictureController.shared.isPlaying(self) else { suspend(); return }
        guard playback == nil, failure == nil, !paused else { return }
        let token = UUID(); generation = token
        playback = Task { [weak self] in
            guard let self else { return }
            for attempt in 0...2 {
                guard self.generation == token, !Task.isCancelled else { return }
                self.recovering = false
                self.rtcViewer.start(api: api, camera: cameraID, configuration: configuration)
                while self.generation == token, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard self.rtcViewer.error != nil, !self.rtcViewer.isRunning else { continue }
                    let problem = self.rtcViewer.lastFailure
                    let code = (problem as? HorizonError)?.httpStatusCode
                    if attempt < 2 && (problem is ViewerTransportFailure || [404,409,410,503,502,504].contains(code ?? 0)) { break }
                    self.sourceFailed(self.rtcViewer.error ?? ViewingMessage.failed,
                        authenticationRequired: code == 401)
                    return
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.recovering = true
                do { try await Task.sleep(for: .seconds(Double(attempt + 1) + Double.random(in: 0...1))) }
                catch { return }
            }
            self.sourceFailed(ViewingMessage.failed)
        }
    }
    func reconnect() {
        if LivePictureInPictureController.shared.owns(self) { LivePictureInPictureController.shared.stop() }
        suspend(); failure = nil; needsReauthentication = false; paused = false; pictureInPictureError = nil
    }
    func sourceFailed(_ message: String, authenticationRequired: Bool = false) {
        failure = message; needsReauthentication = authenticationRequired
        if LivePictureInPictureController.shared.owns(self) {
            LivePictureInPictureController.shared.sourceFailed(self, message: message)
        } else {
            LiveGroupPictureInPictureController.shared.sourceFailed(self)
            suspend()
        }
    }
    func groupPictureInPictureEnded() { stopIfNoOwner() }
    func pictureInPictureEnded(keepInlinePlayback: Bool) {
        if !keepInlinePlayback || !hasInlineViewer { paused = true; suspend() }
    }
    private func suspend() {
        generation = UUID(); playback?.cancel(); playback = nil
        recovering = false; rtcViewer.stop()
    }
}
