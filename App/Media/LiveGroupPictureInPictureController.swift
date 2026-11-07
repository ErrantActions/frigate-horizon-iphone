import AVKit
import Combine
import HorizonCore

struct LiveGroupPiPCamera {
    let id: String
    let name: String
    let session: LivePlaybackSession
}

@MainActor
final class LiveGroupPictureInPictureController: NSObject, ObservableObject {
    static let shared = LiveGroupPictureInPictureController()
    let renderer = RTCGroupPiPRenderer()
    @Published private(set) var isStarting = false
    @Published private(set) var isActive = false
    @Published private(set) var scopeRevision: UInt64 = 0
    @Published private(set) var restorationRevision: UInt64 = 0
    @Published var error: String?
    @Published private(set) var diagnostics = ""
    var restoreUserInterface: (() -> Void)?
    private weak var scopedAPI: HorizonAPI?
    private var allowed: Set<String> = []
    private var members: [LiveGroupPiPCamera] = []
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private var trackObservations: [AnyCancellable] = []
    private var startup: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private var generation = UUID()
    private var startupState = LiveGroupPiPStartup()
    private var previewAttached = false
    private var foreground = true
    var cameraIDs: [String] { members.map(\.id) }
    var hasOwner: Bool { isStarting || isActive }

    func updateScope(api: HorizonAPI?, allowedCameraIDs: Set<String>) {
        let changed = scopedAPI !== api || allowed != allowedCameraIDs
        if scopedAPI !== api { stop(); error = nil }
        scopedAPI = api; allowed = allowedCameraIDs
        if !members.isEmpty, !LiveGroupPiPGeometry.accepts(cameraIDs: cameraIDs, allowed: allowedCameraIDs) {
            fail(String(localized: "groupPip.accessChanged", defaultValue: "Group Picture in Picture stopped because camera access changed."))
        }
        if changed { scopeRevision &+= 1 }
    }
    func owns(_ session: LivePlaybackSession) -> Bool { members.contains { $0.session === session } }
    func isPlaying(_ session: LivePlaybackSession) -> Bool {
        owns(session) && startupState.retainsPlayers(now: ProcessInfo.processInfo.systemUptime)
    }
    func retainedSession(api: HorizonAPI, cameraID: String) -> LivePlaybackSession? {
        guard scopedAPI === api else { return nil }
        return members.first { $0.id == cameraID }?.session
    }
    func start(api: HorizonAPI, cameras: [LiveGroupPiPCamera]) {
        error = nil
        guard scopedAPI === api, LiveGroupPiPGeometry.accepts(cameraIDs: cameras.map(\.id), allowed: allowed) else {
            fail(String(localized: "groupPip.notAuthorized", defaultValue: "Group Picture in Picture requires authorized cameras from the current server.")); return
        }
        guard !CameraTalkbackController.microphoneInUse, AVPictureInPictureController.isPictureInPictureSupported() else {
            error = String(localized: "groupPip.notSupported", defaultValue: "Group Picture in Picture is unavailable. Release talkback and check this device's Picture in Picture settings."); return
        }
        guard cameras.allSatisfy({ $0.session.belongs(to: api, allowedCameraIDs: allowed) &&
            $0.session.hasInlineViewer && $0.session.viewerConfiguration?.grid == true &&
            $0.session.viewerConfiguration?.audio == false && $0.session.isRunning &&
            $0.session.resolution != nil && $0.session.rtcViewer.videoTrack != nil && $0.session.error == nil }) else {
            error = String(localized: "groupPip.waitForVideo", defaultValue: "Wait for every camera in this grid to show live video, resolve any camera errors, then try Group PiP again."); return
        }
        stop()
        LivePictureInPictureController.shared.stop()
        RecordedViewingRegistry.stopPiP()
        members = cameras
        isStarting = true
        startupState.begin(now: ProcessInfo.processInfo.systemUptime)
        let token = generation
        updateDiagnostics("armed")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { fail(error.localizedDescription); return }
        renderer.onFailure = { [weak self] error in
            guard let self else { return }
            self.updateDiagnostics("render-failed")
            self.diagnostics += "\nrender error domain: \((error as NSError).domain)\nrender error code: \((error as NSError).code)"
            self.error = Self.renderFailure
            self.stop()
        }
        renderer.onFirstFrame = { [weak self] in
            self?.updateDiagnostics("first-mosaic-frame")
            self?.startIfPossible()
        }
        renderer.start(names: cameras.map(\.name))
        guard isStarting else { return }
        for (index, camera) in cameras.enumerated() {
            renderer.follow(camera.session.rtcViewer.videoTrack, at: index)
            trackObservations.append(camera.session.rtcViewer.$videoTrack.sink { [weak self] track in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.renderer.follow(track, at: index)
                }
            })
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: renderer.displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        // This controller exists only after the user explicitly chooses Group PiP.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.controller === observed else { return }
                self.startIfPossible()
            }
        }
        startup = Task {
            while generation == token, !isActive {
                if startupState.expire(now: ProcessInfo.processInfo.systemUptime) {
                    fail(String(localized: "groupPip.startFailed", defaultValue: "Group Picture in Picture could not start. Keep its preview visible and check iOS Picture in Picture settings."))
                    return
                }
                startIfPossible()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    func attachPreview(size: CGSize) {
        previewAttached = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        updateDiagnostics("preview-layout")
        startIfPossible()
    }
    func detachPreview() {
        previewAttached = false
        if startupState.shouldCancelDetachedPreview(foreground: foreground && UIApplication.shared.applicationState == .active) { stop() }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { startIfPossible() }
        updateDiagnostics(value ? "foreground" : "leaving-app")
    }
    private func startIfPossible() {
        guard isStarting, foreground, let controller, startupState.requestIfReady(now: ProcessInfo.processInfo.systemUptime,
            previewReady: previewAttached, firstFrame: renderer.hasRenderedFrame,
            possible: controller.isPictureInPicturePossible) else { return }
        updateDiagnostics("request-start")
        controller.startPictureInPicture()
    }
    private func began(_ value: AVPictureInPictureController) {
        guard controller === value else { return }
        startup?.cancel(); startup = nil
        isStarting = false; isActive = true
        startupState.didStart()
        updateDiagnostics("did-start")
        scopeRevision &+= 1
        let token = generation
        watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard generation == token else { return }
                guard let api = scopedAPI, members.allSatisfy({ $0.session.belongs(to: api, allowedCameraIDs: allowed) }) else {
                    fail(String(localized: "groupPip.accessChanged", defaultValue: "Group Picture in Picture stopped because camera access changed.")); return
                }
                for (index, member) in members.enumerated() where member.session.error != nil || !member.session.isRunning {
                    renderer.blank(at: index)
                }
            }
        }
    }
    func sourceFailed(_ session: LivePlaybackSession) {
        guard let index = members.firstIndex(where: { $0.session === session }) else { return }
        renderer.follow(nil, at: index)
        error = String(localized: "groupPip.cameraFailed", defaultValue: "A Group PiP camera stopped. Its tile is unavailable; return to Live to reconnect.")
    }
    func returnToInline() { requestRestoration(); controller?.stopPictureInPicture() }
    private func requestRestoration() {
        restorationRevision &+= 1
        restoreUserInterface?()
    }
    func stop() {
        let previous = members
        members = []
        generation = UUID()
        let previousController = controller; controller = nil
        startup?.cancel(); startup = nil; watchdog?.cancel(); watchdog = nil
        restoration?.cancel(); restoration = nil
        possible = nil; trackObservations = []
        renderer.onFailure = nil; renderer.stop()
        renderer.onFirstFrame = nil
        previousController?.delegate = nil; previousController?.stopPictureInPicture(); previousController?.contentSource = nil
        startupState.cancel()
        isStarting = false; isActive = false
        previewAttached = false
        scopeRevision &+= 1
        for member in previous { member.session.groupPictureInPictureEnded() }
    }
    private func fail(_ message: String) {
        error = message
        updateDiagnostics("failed")
        stop()
    }
    private func updateDiagnostics(_ event: String) {
        let value = "event: \(event)\nphase: \(startupState.phase.rawValue)\npreview ready: \(previewAttached)\nfirst mosaic frame: \(renderer.hasRenderedFrame)\nPiP possible: \(controller?.isPictureInPicturePossible == true)\nPiP active: \(isActive)\ncamera count: \(members.count)\nforeground: \(foreground)"
        if diagnostics != value { diagnostics = value }
    }
    private static var renderFailure: String {
        String(localized: "groupPip.renderFailed", defaultValue: "Group Picture in Picture rendering failed. Return to Live and try again.")
    }
}

extension LiveGroupPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ value: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === value else { return }
            self.startupState.willStart()
            self.updateDiagnostics("will-start")
            self.scopeRevision &+= 1
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ value: AVPictureInPictureController) {
        Task { @MainActor in self.began(value) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ value: AVPictureInPictureController) {
        Task { @MainActor in guard self.controller === value else { return }; self.stop() }
    }
    nonisolated func pictureInPictureController(_ value: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            guard self.controller === value else { return }
            self.updateDiagnostics("AVKit-start-failed")
            self.diagnostics += "\nAVKit error domain: \((error as NSError).domain)\nAVKit error code: \((error as NSError).code)"
            self.error = Self.renderFailure
            self.stop()
        }
    }
    nonisolated func pictureInPictureController(_ value: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in
            guard self.controller === value else { completionHandler(false); return }
            self.requestRestoration()
            self.restoration?.cancel()
            self.restoration = Task {
                var restored = false
                defer { completionHandler(restored) }
                for _ in 0..<60 {
                    guard !Task.isCancelled, self.controller === value else { return }
                    if !self.members.isEmpty, self.members.allSatisfy({ $0.session.hasInlineViewer }) { restored = true; return }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                self.error = String(localized: "groupPip.restoreFailed", defaultValue: "Open the Live screen to restore the Group PiP cameras.")
            }
        }
    }
}

extension LiveGroupPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ value: AVPictureInPictureController, setPlaying playing: Bool) {
        guard !playing else { return }
        Task { @MainActor in
            guard self.controller === value, self.isActive else { return }
            self.stop()
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ value: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ value: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ value: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ value: AVPictureInPictureController, skipByInterval interval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}
