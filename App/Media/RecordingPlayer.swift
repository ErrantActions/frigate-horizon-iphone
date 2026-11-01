import SwiftUI
import AVKit
import HorizonCore

@MainActor
final class RecordingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var error: String? = ViewingMessage.recorded
    @Published private(set) var loading = false
    @Published private(set) var position = 0.0
    @Published private(set) var isSeeking = false
    @Published private(set) var capabilities: RecordedHTTPCapability?
    @Published private(set) var quality: RecordedHTTPQuality = .auto
    @Published private(set) var wantsToPlay = true
    @Published private(set) var metrics = RecordedPlaybackMetrics()
    private let injectedTransport: (any RecordedHTTPTransport)?
    private var transport: (any RecordedHTTPTransport)?
    private var manager: RecordedHTTPWindowManager?
    private var prepared: PreparedRecordedHTTPWindow?
    private var media: RecordedMP4Asset?
    private var api: HorizonAPI?
    private var selection: RecordedViewingSelection?
    private var sourceRange: ClosedRange<Double>?
    private var task: Task<Void, Never>?
    private var lease: Task<Void, Never>?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var output: AVPlayerItemVideoOutput?
    private var transition = false
    private var attemptStart = ProcessInfo.processInfo.systemUptime
    private var seekStart: Double?
    private var pendingSeek: (timestamp: Double, playing: Bool)?
    var inlineAttached = false
    var restoreInline: (() -> Bool)?
    private var requestedRate: Float = 1

    init(transport: (any RecordedHTTPTransport)? = nil) {
        injectedTransport = transport
        RecordedViewingRegistry.add(self)
    }

    func open(selection: RecordedViewingSelection, api: HorizonAPI, sourceRange: ClosedRange<Double>? = nil,
              startTimestamp: Double? = nil, autoplay: Bool = true) {
        stop()
        let intentStart = ProcessInfo.processInfo.systemUptime
        self.api = api; self.selection = selection
        let transport = injectedTransport ?? UnavailableRecordedHTTPTransport(address: api.address)
        guard transport.address == api.address, transport.qualification.usable,
              api.viewingAccountKey != nil else { error = ViewingMessage.recorded; return }
        self.transport = transport
        manager = RecordedHTTPWindowManager(transport: transport)
        wantsToPlay = autoplay; loading = true; error = nil
        let token = generation
        task = Task {
            do {
                try await RecordedViewingRegistry.awaitCleanup()
                try Task.checkCancellation()
                let caps = try await transport.discover(camera: selection.camera)
                try caps.validate()
                let bounds: ClosedRange<Double>
                if let sourceRange { bounds = sourceRange }
                else if case .timeRange(let start, let end) = selection.identity, start.isFinite, end.isFinite, end > start {
                    bounds = start...end
                } else { bounds = try await transport.sourceRange(selection: selection) }
                guard generation == token, !Task.isCancelled else { return }
                capabilities = caps; self.sourceRange = bounds
                let pending = pendingSeek; pendingSeek = nil
                replace(at: pending?.timestamp ?? startTimestamp ?? bounds.lowerBound,
                    autoplay: pending?.playing ?? wantsToPlay, startedAt: intentStart)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func seekToCatalog(_ timestamp: Double, autoplay: Bool? = nil) {
        let playing = autoplay ?? wantsToPlay
        guard let prepared else {
            if capabilities != nil { replace(at: timestamp, autoplay: playing) }
            else if transport?.qualification.usable == true { pendingSeek = (timestamp, playing) }
            else { error = ViewingMessage.recorded }
            return
        }
        switch prepared.seekDecision(at: timestamp) {
        case .native(let mediaTime):
            seekMedia(mediaTime, autoplay: playing)
        case .gap:
            setPlaying(false); error = RecordedHTTPError.gap.localizedDescription
        case .replacement: replace(at: timestamp, autoplay: playing)
        }
    }

    func setQuality(_ value: RecordedHTTPQuality, dataSaver: Bool = false) {
        do {
            guard let capabilities else { throw RecordedHTTPError.unavailable }
            let resolved = try capabilities.quality(value, dataSaver: dataSaver)
            guard resolved != quality else { return }
            let source = position
            quality = resolved
            replace(at: source, autoplay: wantsToPlay)
        } catch { self.error = error.localizedDescription }
    }

    private func replace(at timestamp: Double, autoplay: Bool, startedAt: Double? = nil) {
        guard let manager, let selection, let sourceRange, let capabilities else { error = ViewingMessage.recorded; return }
        let request: RecordedHTTPWindowRequest
        do {
            request = try .bounded(sourceRange: sourceRange, at: timestamp,
                maximum: capabilities.maxWindowSeconds, quality: capabilities.quality(quality, dataSaver: false))
        } catch { setPlaying(false); self.error = error.localizedDescription; return }
        task?.cancel()
        generation = UUID(); let token = generation
        wantsToPlay = autoplay; transition = true
        clearMedia(keepingPiPItem: RecordedViewingRegistry.ownsPiP(self))
        loading = true; error = nil; position = timestamp
        attemptStart = startedAt ?? ProcessInfo.processInfo.systemUptime; metrics = RecordedPlaybackMetrics()
        task = Task {
            do {
                // Coalesce scrub/quality intents; the manager serializes dispatched creation and late cleanup.
                try await Task.sleep(for: .milliseconds(150))
                let ready = try await manager.prepare(selection: selection, request: request, playing: autoplay)
                guard generation == token, !Task.isCancelled, let api else { return }
                prepared = ready
                guard let url = ready.window.mediaURL else { throw RecordedHTTPError.invalidWindow }
                let reader = try AuthenticatedRecordedMP4Reader(mediaURL: url, info: ready.info,
                    policy: RecordedHTTPResourcePolicy(address: api.address), cookies: api.cookies)
                let asset = try RecordedMP4Asset(reader: reader) { [weak self] failure in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.fail(failure)
                    }
                }
                media = asset
                let item = AVPlayerItem(asset: asset.asset)
                item.preferredForwardBufferDuration = 3
                let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(videoOutput); output = videoOutput
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                player.replaceCurrentItem(with: item)
                observe(item, token: token)
                lease = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) }
                        catch { return }
                        guard !Task.isCancelled, generation == token else { return }
                        if loading && ProcessInfo.processInfo.systemUptime - attemptStart > 30 {
                            fail(RecordedHTTPError.preparationFailed); return
                        }
                        if Date().timeIntervalSince1970 >= ready.window.hardExpiresAt {
                            fail(RecordedHTTPError.expired); return
                        }
                    }
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func observe(_ item: AVPlayerItem, token: UUID) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.loading = false
                    self.metrics.readySeconds = ProcessInfo.processInfo.systemUptime - self.attemptStart
                    guard let prepared = self.prepared, let time = prepared.mapping.mediaTime(for: prepared.request.startTimestamp) else {
                        self.fail(RecordedHTTPError.gap); return
                    }
                    self.seekMedia(time, autoplay: self.wantsToPlay)
                } else if item.status == .failed { self.fail(item.error ?? RecordedHTTPError.preparationFailed) }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.generation == token, !self.transition else { return }
                self.wantsToPlay = player.timeControlStatus != .paused
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == token, !self.isSeeking else { return }
                if let source = self.prepared?.mapping.sourceTime(for: time.seconds) { self.position = source }
                if let output = self.output, output.hasNewPixelBuffer(forItemTime: time),
                   output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.metrics.firstDecodedSeconds == nil { self.metrics.firstDecodedSeconds = now - self.attemptStart }
                    if let start = self.seekStart { self.metrics.seekDecodedSeconds = now - start; self.seekStart = nil }
                }
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.metrics.stalls += 1 }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.metrics.droppedFrames = item.accessLog()?.events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames }
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.metrics.errorCodes = item.errorLog()?.events.map(\.errorStatusCode) ?? []
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, let ready = self.prepared else { return }
                let runEnd = item.forwardPlaybackEndTime.seconds
                if ready.mapping.spans.last.map({ runEnd < $0.mediaEnd - 0.001 || $0.sourceEnd < ready.request.before - 0.001 }) == true {
                    self.setPlaying(false); self.error = RecordedHTTPError.gap.localizedDescription
                } else if self.wantsToPlay, let range = self.sourceRange, ready.request.before < range.upperBound {
                    self.replace(at: ready.request.before, autoplay: true)
                } else { self.setPlaying(false) }
            }
        })
    }

    private func seekMedia(_ time: Double, autoplay: Bool) {
        guard let item = player.currentItem, let end = prepared?.mapping.runEnd(at: time) else {
            error = RecordedHTTPError.gap.localizedDescription; return
        }
        seekGeneration = UUID(); let token = seekGeneration; let owner = generation
        wantsToPlay = autoplay; transition = true; isSeeking = true; error = nil
        seekStart = ProcessInfo.processInfo.systemUptime
        item.cancelPendingSeeks()
        player.pause()
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == owner, self.seekGeneration == token else { return }
                self.isSeeking = false; self.transition = false
                guard finished else { self.error = RecordedHTTPError.preparationFailed.localizedDescription; return }
                if autoplay { self.player.playImmediately(atRate: self.requestedRate) }
            }
        }
    }

    func setPlaying(_ value: Bool) {
        wantsToPlay = value
        if value { player.playImmediately(atRate: requestedRate) } else { player.pause() }
    }
    func setRate(_ value: Float) {
        guard [0.5,1,1.5,2].contains(value), let item = player.currentItem,
              value == 1 || (value < 1 ? item.canPlaySlowForward : item.canPlayFastForward) else {
            error = String(localized: "review.rateUnavailable", defaultValue: "This MP4 item does not support the selected native playback rate."); return
        }
        requestedRate = value
        if wantsToPlay { player.rate = value }
    }
    private func clearMedia(keepingPiPItem: Bool = false) {
        lease?.cancel(); lease = nil
        statusObservation = nil; rateObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        notifications.removeAll()
        player.pause(); player.currentItem?.cancelPendingSeeks()
        if !keepingPiPItem { player.replaceCurrentItem(with: nil) }
        output = nil; media?.cancel(); media = nil; prepared = nil
    }
    private func fail(_ failure: Error) {
        if let horizon = failure as? HorizonError {
            switch horizon.httpStatusCode {
            case 401,403,422,429: error = viewingFailureMessage(horizon)
            case 404,410: error = RecordedHTTPError.expired.localizedDescription
            default: error = String(localized: "review.networkFailure", defaultValue: "Recorded HTTPS playback failed. Check server/range readiness and retry.")
            }
        } else { error = failure.localizedDescription }
        if (failure as? HorizonError)?.httpStatusCode == 401, let api {
            NotificationCenter.default.post(name: .horizonMediaAuthenticationExpired, object: api)
        }
        stop()
    }
    func stop() {
        RecordedViewingRegistry.releasePiP(self)
        generation = UUID(); seekGeneration = UUID(); task?.cancel(); task = nil
        clearMedia(); transition = false; loading = false; isSeeking = false
        if let manager { RecordedViewingRegistry.clean(manager) }
        manager = nil; capabilities = nil; pendingSeek = nil
    }
    func releaseInline() { inlineAttached = false; if !RecordedViewingRegistry.ownsPiP(self) { stop() } }
    func pictureInPictureFailed() {
        error = String(localized: "review.pipFailed", defaultValue: "Recorded Picture in Picture could not start. Wait for decoded video and try again.")
    }
    func belongs(to api: HorizonAPI?, cameras: Set<String>) -> Bool {
        self.api === api && selection.map({ cameras.contains($0.camera) }) == true
    }
}

struct RecordedPlaybackMetrics {
    var readySeconds: Double?
    var firstDecodedSeconds: Double?
    var seekDecodedSeconds: Double?
    var stalls = 0
    var droppedFrames: Int?
    var errorCodes: [Int] = []
    var report: String {
        let absent = String(localized: "review.notObserved", defaultValue: "not observed")
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? absent }
        return "playerReady: \(seconds(readySeconds))\nfirstDecodedFrame: \(seconds(firstDecodedSeconds))\nseekDecodedFrame: \(seconds(seekDecodedSeconds))\nstalls: \(stalls)\ndroppedFrames: \(droppedFrames.map(String.init) ?? absent)\nAVPlayer error codes: \(errorCodes)\n" + String(localized: "review.metricBasis", defaultValue: "Startup times begin at the recorded window intent; seeks begin at native seek dispatch. Decoded video-output frames are measured, not display or device certification.")
    }
}

extension Notification.Name {
    static let horizonMediaAuthenticationExpired = Notification.Name("Horizon.mediaAuthenticationExpired")
    static let horizonMediaCleanupFailure = Notification.Name("Horizon.mediaCleanupFailure")
}

@MainActor
final class RecordedViewingRegistry: ObservableObject {
    static let shared = RecordedViewingRegistry()
    private static let players = NSHashTable<RecordingPlayer>.weakObjects()
    private static var pip: RecordingPlayer?
    private static var pipToken: UUID?
    private static var cleanups: [ObjectIdentifier: RecordedHTTPWindowManager] = [:]
    private static var cleanupJobs: [ObjectIdentifier: Task<Void, Error>] = [:]
    private static weak var scopedAPI: HorizonAPI?
    private static var scopedCameras: Set<String> = []
    @Published private(set) var error: String?
    static func add(_ player: RecordingPlayer) { players.add(player) }
    static func ownsPiP(_ player: RecordingPlayer) -> Bool { pip === player }
    static func ownsPiP(_ player: RecordingPlayer, token: UUID) -> Bool { pip === player && pipToken == token }
    static func retainPiP(_ player: RecordingPlayer, token: UUID) {
        guard player.belongs(to: scopedAPI, cameras: scopedCameras), player.player.currentItem?.status == .readyToPlay else {
            player.pictureInPictureFailed(); player.stop(); return
        }
        if pip !== player { pip?.stop() }
        LivePictureInPictureController.shared.stop()
        pip = player; pipToken = token
    }
    static func releasePiP(_ player: RecordingPlayer) { if pip === player { pip = nil; pipToken = nil } }
    static func stopPiP() { let old = pip; pip = nil; pipToken = nil; old?.stop() }
    static func stopAll() { for player in players.allObjects { player.stop() } }
    static func background() { for player in players.allObjects where !ownsPiP(player) { player.stop() } }
    static func updateScope(api: HorizonAPI?, cameras: Set<String>) {
        scopedAPI = api; scopedCameras = cameras
        for player in players.allObjects where !player.belongs(to: api, cameras: cameras) { player.stop() }
    }
    static func clean(_ manager: RecordedHTTPWindowManager) {
        let id = ObjectIdentifier(manager); cleanups[id] = manager
        let job = Task {
            await manager.cancel()
            try await manager.finishCleanup()
        }
        cleanupJobs[id] = job
        Task {
            do {
                try await job.value
                cleanups.removeValue(forKey: id)
                cleanupJobs.removeValue(forKey: id)
            } catch {
                shared.error = error.localizedDescription
                NotificationCenter.default.post(name: .horizonMediaCleanupFailure, object: error.localizedDescription)
            }
        }
    }
    static func awaitCleanup() async throws {
        for job in Array(cleanupJobs.values) { try await job.value }
    }
    static func retryCleanup() async {
        for (id, manager) in Array(cleanups) {
            do {
                _ = await cleanupJobs[id]?.result
                try await manager.retryCleanup()
                cleanups.removeValue(forKey: id); cleanupJobs.removeValue(forKey: id)
            }
            catch { shared.error = error.localizedDescription; return }
        }
        shared.error = nil
    }
}

struct NativeRecordingSurface: View {
    @ObservedObject var owner: RecordingPlayer
    var body: some View {
        Group {
            if owner.player.currentItem != nil {
                NativeRecordedController(owner: owner)
            } else {
                ContentUnavailableView(String(localized: "viewer.recordedTitle", defaultValue: "Recorded HTTP review unavailable"),
                    systemImage: "play.slash", description: Text(owner.error ?? ViewingMessage.recorded))
            }
        }
        .onAppear { owner.inlineAttached = true }
        .onDisappear { owner.releaseInline() }
    }
}

private struct NativeRecordedController: UIViewControllerRepresentable {
    let owner: RecordingPlayer
    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = owner.player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = owner.player }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        if !RecordedViewingRegistry.ownsPiP(coordinator.owner) { controller.player = nil }
    }
    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let owner: RecordingPlayer
        let token = UUID()
        init(owner: RecordingPlayer) { self.owner = owner }
        nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in RecordedViewingRegistry.retainPiP(self.owner, token: self.token) }
        }
        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in
                guard RecordedViewingRegistry.ownsPiP(self.owner, token: self.token) else { return }
                RecordedViewingRegistry.releasePiP(self.owner)
                if !self.owner.inlineAttached { self.owner.stop() }
            }
        }
        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
            Task { @MainActor in
                guard RecordedViewingRegistry.ownsPiP(self.owner, token: self.token) else { return }
                RecordedViewingRegistry.releasePiP(self.owner)
                self.owner.pictureInPictureFailed()
                if !self.owner.inlineAttached { self.owner.stop() }
            }
        }
        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in
                completionHandler(RecordedViewingRegistry.ownsPiP(self.owner, token: self.token)
                    && (self.owner.inlineAttached || self.owner.restoreInline?() == true))
            }
        }
    }
}

struct RecordedPlaybackControls: View {
    @ObservedObject var owner: RecordingPlayer
    var body: some View {
        if let caps = owner.capabilities {
            HStack {
                Menu(String(localized: "review.quality", defaultValue: "Viewing quality")) {
                    ForEach(caps.qualities, id: \.self) { value in
                        Button(value.label) { owner.setQuality(value) }
                    }
                    Button(String(localized: "review.dataSaver", defaultValue: "Data Saver")) { owner.setQuality(.auto, dataSaver: true) }
                }
                Menu(String(localized: "review.rate", defaultValue: "Playback rate")) {
                    ForEach([0.5,1,1.5,2], id: \.self) { value in
                        Button("\(value.formatted())x") { owner.setRate(Float(value)) }
                    }
                }
                ShareLink(item: owner.metrics.report) {
                    Label(String(localized: "review.diagnostics", defaultValue: "Playback diagnostics"), systemImage: "waveform.path.ecg")
                }
            }.disabled(owner.loading)
        }
    }
}

private extension RecordedHTTPQuality {
    var label: String {
        switch self {
        case .auto: return String(localized: "review.auto", defaultValue: "Auto (bounded windows)")
        case .original: return String(localized: "review.original", defaultValue: "Original-quality window")
        case .h2160: return "4K"
        default: return "\(height ?? 0)p"
        }
    }
}

struct RecordingPlaybackView: View {
    let api: HorizonAPI
    let camera: String
    let start: Double
    let end: Double
    var initialTimestamp: Double? = nil
    var identity: RecordedViewingSelection.Identity? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var playback = RecordingPlayer()
    private var allowed: Bool { model.api === api && model.cameras.contains(where: { $0.id == camera }) }
    var body: some View {
        VStack {
            NativeRecordingSurface(owner: playback)
            if playback.loading { ProgressView(String(localized: "review.preparing", defaultValue: "Preparing recorded window")) }
            RecordedPlaybackControls(owner: playback)
            if let error = playback.error { ErrorNotice(message: error) }
        }
        .task(id: "\(allowed)-\(phase == .active)-\(camera)-\(start)-\(end)") {
            guard allowed, phase == .active, end > start else { playback.stop(); return }
            playback.open(selection: .init(camera: camera, identity: identity ?? .timeRange(start: start, end: end)),
                api: api, sourceRange: start...end, startTimestamp: initialTimestamp, autoplay: true)
        }
        .onDisappear { playback.releaseInline() }
    }
}
