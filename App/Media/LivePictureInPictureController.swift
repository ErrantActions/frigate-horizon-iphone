import AVKit
import Combine
import HorizonCore

@MainActor
final class LivePictureInPictureController: NSObject, ObservableObject {
    static let shared = LivePictureInPictureController()
    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var scopeRevision: UInt64 = 0
    // Surface this at the app root so a failure while the camera view is gone is not lost.
    @Published var error: String?

    // Present the selected camera/stream when the system's "return to app" button is used.
    // Completion is acknowledged only after that live view actually attaches in the foreground.
    var restoreUserInterface: ((LivePictureInPictureSelection) -> Void)? {
        didSet {
            if let pendingRestoration { restoreUserInterface?(pendingRestoration) }
        }
    }
    private var pendingRestoration: LivePictureInPictureSelection?

    private weak var scopedAPI: HorizonAPI?
    private var scopedIdentity: ObjectIdentifier?
    private var allowedCameraIDs: Set<String> = []
    private var hasScope = false
    private var session: LivePlaybackSession?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var startup: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private var trackObservation: AnyCancellable?
    private var returningToInline = false
    private var startRequested = false
    private var systemStarting = false

    private override init() { super.init() }

    // Call on API/account changes and authoritative permission changes; pass nil on logout.
    func updateScope(api: HorizonAPI?, allowedCameraIDs: Set<String>) {
        let identity = api.map(ObjectIdentifier.init)
        guard !hasScope || identity != scopedIdentity || allowedCameraIDs != self.allowedCameraIDs else { return }
        if identity != scopedIdentity { error = nil }
        hasScope = true
        scopedAPI = api
        scopedIdentity = identity
        self.allowedCameraIDs = allowedCameraIDs
        if let session, api.map({ session.belongs(to: $0, allowedCameraIDs: allowedCameraIDs) }) != true {
            stop()
        }
        scopeRevision &+= 1
    }

    // Synchronous cancellation is intentional: talkback/incident playback can take media ownership
    // immediately, without waiting for AVKit's asynchronous window dismissal.
    func stop() { end(keepInlinePlayback: false) }

    func owns(_ value: LivePlaybackSession) -> Bool { session === value }
    func isPlaying(_ value: LivePlaybackSession) -> Bool {
        owns(value) && (isActive || (isStarting && systemStarting))
    }

    func permitsInlinePlayback(api: HorizonAPI, cameraID: String) -> Bool {
        !hasScope || (scopedAPI === api && allowedCameraIDs.contains(cameraID))
    }

    func retainedSession(
        api: HorizonAPI, cameraID: String, stream: String?, transport: String
    ) -> LivePlaybackSession? {
        guard let session, session.matches(api: api, cameraID: cameraID, stream: stream, transport: transport) else {
            return nil
        }
        return session
    }

    // Seed a recreated camera detail's stream, transport, and mute state before choosing defaults.
    func retainedSelection(api: HorizonAPI, cameraID: String) -> LivePictureInPictureSelection? {
        guard scopedAPI === api, session?.selection?.cameraID == cameraID else { return nil }
        return session?.selection
    }

    func retainedViewerConfiguration(api: HorizonAPI, cameraID: String) -> ViewerConfiguration? {
        guard scopedAPI === api, session?.selection?.cameraID == cameraID,
              session?.viewerConfiguration != nil else { return nil }
        return session?.viewerConfiguration
    }

    func start(_ value: LivePlaybackSession) {
        error = nil
        value.pictureInPictureError = nil
        guard !CameraTalkbackController.microphoneInUse else {
            value.pictureInPictureError = "Release camera talkback before starting live Picture in Picture."
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            value.pictureInPictureError = "Live Picture in Picture is not supported on this device or is unavailable in the current system configuration."
            return
        }
        guard let selection = value.selection, let api = scopedAPI,
              value.belongs(to: api, allowedCameraIDs: allowedCameraIDs) else {
            value.pictureInPictureError = "Live Picture in Picture is not authorized for this account and camera. Refresh cameras and try again."
            return
        }
        guard value.hasInlineViewer, value.isRunning, value.resolution != nil, value.error == nil else {
            value.pictureInPictureError = "Wait for live video to appear before starting Picture in Picture."
            return
        }
        if owns(value), isActive || isStarting { return }
        stop()
        session = value
        returningToInline = false
        startRequested = false
        systemStarting = false
        isStarting = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            fail("Live Picture in Picture could not activate audio playback: \(error.localizedDescription)")
            return
        }
        let controller: AVPictureInPictureController
        guard let track = value.rtcViewer.videoTrack else { fail(ViewingMessage.failed); return }
        value.rtcViewer.pipRenderer.onFailure = { [weak self] in self?.fail(ViewingMessage.failed) }
        value.rtcViewer.pipRenderer.follow(track)
        trackObservation = value.rtcViewer.$videoTrack.sink { [weak self, weak value] track in
            Task { @MainActor in
                guard let self, let value, self.owns(value), let track else { return }
                value.rtcViewer.pipRenderer.follow(track)
            }
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: value.rtcViewer.pipRenderer.displayLayer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.controller === observed else { return }
                self.startIfPossible()
            }
        }
        startup = Task { [weak self, weak value] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, let value, self.owns(value), !self.isActive else { return }
            self.fail("Live Picture in Picture could not start. Keep the camera visible, check that Picture in Picture is allowed in iOS settings, and try again.")
        }
        startIfPossible()
    }

    func returnToInline(_ value: LivePlaybackSession) {
        guard owns(value), let controller, isActive, value.hasInlineViewer else { return }
        returningToInline = true
        controller.stopPictureInPicture()
    }

    private func startIfPossible() {
        guard let controller, isStarting, !startRequested, controller.isPictureInPicturePossible else { return }
        startRequested = true
        controller.startPictureInPicture()
    }

    private func began(_ observed: AVPictureInPictureController) {
        guard controller === observed, let session else { return }
        startup?.cancel()
        startup = nil
        isActive = true
        isStarting = false
        observed.invalidatePlaybackState()
        watchdog = Task { [weak self, weak session] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    guard let self, let session, self.isPlaying(session) else { return }
                    let lastFrame = session.rtcViewer.lastVideoReceivedAt
                    guard session.isRunning, let lastFrame, Date().timeIntervalSince(lastFrame) < 10 else {
                        session.sourceFailed("No live video is arriving. Check camera availability and reconnect.")
                        return
                    }
                }
            } catch { return }
        }
    }

    private func fail(_ message: String) {
        if session?.hasInlineViewer != true { error = message }
        session?.pictureInPictureError = message
        // A failed PiP launch must not unnecessarily restart healthy, visible inline playback.
        end(keepInlinePlayback: session?.hasInlineViewer == true)
    }

    func sourceFailed(_ value: LivePlaybackSession, message: String) {
        guard owns(value) else { return }
        let message = "Live Picture in Picture stopped: \(message)"
        value.pictureInPictureError = message
        if !value.hasInlineViewer { error = message }
        stop()
    }

    private func end(keepInlinePlayback: Bool) {
        let previous = session
        let previousController = controller
        session = nil
        controller = nil
        startup?.cancel()
        startup = nil
        watchdog?.cancel()
        watchdog = nil
        restoration?.cancel()
        restoration = nil
        possibleObservation = nil
        trackObservation = nil
        previous?.rtcViewer.pipRenderer.onFailure = nil
        previous?.rtcViewer.pipRenderer.stop()
        previousController?.delegate = nil
        previousController?.stopPictureInPicture()
        previousController?.contentSource = nil
        isActive = false
        isStarting = false
        returningToInline = false
        startRequested = false
        systemStarting = false
        pendingRestoration = nil
        previous?.pictureInPictureEnded(keepInlinePlayback: keepInlinePlayback)
    }
}

extension LivePictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            // AVKit accepted the explicit request. Preserve frames during its bounded activation
            // animation, including a scene transition that precedes the didStart callback.
            self.systemStarting = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.began(controller) }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.fail("Live Picture in Picture could not start: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.end(keepInlinePlayback: self.returningToInline)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        Task { @MainActor in
            guard self.controller === controller, let session = self.session, let selection = session.selection else {
                completionHandler(false)
                return
            }
            self.restoration?.cancel()
            self.pendingRestoration = selection
            self.restoreUserInterface?(selection)
            self.restoration = Task { @MainActor [weak self, weak session] in
                var restored = false
                defer { completionHandler(restored) }
                for _ in 0..<60 {
                    guard let self, let session, self.controller === controller, !Task.isCancelled else { return }
                    if session.hasInlineViewer {
                        self.returningToInline = true
                        self.pendingRestoration = nil
                        restored = true
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                let message = "The live camera could not be restored. Open its camera view in Horizon and try again."
                self?.pendingRestoration = nil
                self?.error = message
                session?.pictureInPictureError = message
            }
        }
    }
}

extension LivePictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        guard !playing else { return }
        Task { @MainActor in
            guard self.controller === pictureInPictureController, !self.returningToInline else { return }
            self.stop()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) { completionHandler() }
}
