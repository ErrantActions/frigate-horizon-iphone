import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class HLSLiveStream: ObservableObject {
    let player = AVPlayer()
    let playerLayer: AVPlayerLayer
    @Published private(set) var resolution: CGSize?
    @Published private(set) var error: String?
    @Published private(set) var needsReauthentication = false
    @Published private(set) var status = "Checking live HLS"
    @Published private(set) var advertisedHeights: [Int] = []
    @Published private(set) var metrics = "Awaiting decoded video"
    private(set) var lastHTTPStatus: Int?
    private(set) var lastFailure: Error?
    private var openedAt = ProcessInfo.processInfo.systemUptime
    private var firstFrame: Double?
    private var transitions: [String] = []
    private var measurements = HLSStartupMeasurements()
    private var preparedStatus: LiveHLSStatus?
    private var preparedPolicy: LiveHLSResourcePolicy?
    private var preparedMasterURL: URL?
    private var activeConfiguration: LiveHLSConfiguration?
    private var lastMetricsPublishedAt = -Double.infinity
    private(set) var lastVideoReceivedAt: Date?
    var muted = true {
        didSet { player.isMuted = muted }
    }
    private var generation = UUID()
    private var client: AuthenticatedLiveHLSClient?
    private var source: AuthenticatedLiveHLSAsset?
    private var master: LiveHLSMaster?
    private var observations: [NSKeyValueObservation] = []
    private var failureObserver: NSObjectProtocol?
    private var health: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var startupPolicy: LiveHLSStartupPolicy?
    private var lastPosition: Double?
    private var lastProgressUptime = ProcessInfo.processInfo.systemUptime
    private var edgePolicy = LiveHLSEdgeRecoveryPolicy()
    private var recoveringEdge = false
    private var edgeDeadline: Task<Void, Never>?

    init() {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
    }

    func prepare(api: HorizonAPI, camera: String, configuration: LiveHLSConfiguration) async throws -> Bool {
        stop()
        openedAt = ProcessInfo.processInfo.systemUptime
        firstFrame = nil
        transitions = []
        measurements = HLSStartupMeasurements()
        lastMetricsPublishedAt = -Double.infinity
        metrics = measurements.report
        lastHTTPStatus = nil
        lastFailure = nil
        let token = generation
        status = "Checking live HLS support"
        let policy = try LiveHLSResourcePolicy(address: api.address, camera: camera)
        startup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.resolution == nil else { return }
            self.fail(HLSPlaybackFailure.startupTimedOut.localizedDescription,
                cause: HLSPlaybackFailure.startupTimedOut)
        }
        do {
            let capability: LiveHLSStatus
            let statusStarted = ProcessInfo.processInfo.systemUptime
            do {
                capability = try await api.liveHLSStatus(camera: camera)
                measurements.record(.statusFetch, seconds: ProcessInfo.processInfo.systemUptime - statusStarted)
            }
            catch {
                measurements.record(.statusFetch, seconds: ProcessInfo.processInfo.systemUptime - statusStarted)
                metrics = measurements.report
                if let failure = error as? HorizonError, let code = failure.httpStatusCode,
                   LiveHLSGate.isUnsupportedHTTP(code) {
                    startup?.cancel(); startup = nil
                    status = "This server does not advertise live HLS for this camera"
                    return false
                }
                throw error
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard capability.isAvailable else {
                startup?.cancel(); startup = nil
                status = "Live HLS is disabled or unavailable for this camera"
                return false
            }
            advertisedHeights = Array(Set(capability.renditions.map(\.height).filter { (144...2160).contains($0) })).sorted()
            _ = try policy.masterURL(capability.playlist)
            status = "Opening authenticated live HLS"
            let masterURL = try configuration.masterURL(status: capability, policy: policy)
            preparedStatus = capability
            preparedPolicy = policy
            preparedMasterURL = masterURL
            activeConfiguration = configuration
            let client = AuthenticatedLiveHLSClient(policy: policy, cookies: api.cookies,
                maximumHeight: configuration.maximumHeight, masterURL: masterURL)
            self.client = client
            client.setMeasurementHandler { [weak self] measurement in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.measurements.record(measurement)
                    self.updateMetrics()
                }
            }
            let master = try await client.prepareMaster()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            self.master = master
            let source = try await AuthenticatedLiveHLSAsset(client: client)
            guard generation == token, !Task.isCancelled else {
                source.close()
                throw CancellationError()
            }
            self.source = source
            source.onFailure = { [weak self] failure in
                guard let self, self.generation == token else { return }
                self.fail(failure.localizedDescription,
                    authenticationRequired: LiveHLSGate.requiresReauthentication(failure),
                    httpStatus: (failure as? HorizonError)?.httpStatusCode, cause: failure)
            }
            return true
        } catch {
            client?.invalidate()
            client = nil
            startup?.cancel()
            startup = nil
            updateMetrics()
            throw error
        }
    }

    func canReuse(_ configuration: LiveHLSConfiguration) -> Bool {
        guard let preparedStatus, let preparedPolicy, let preparedMasterURL,
              configuration.grid == activeConfiguration?.grid,
              let requested = try? configuration.masterURL(status: preparedStatus, policy: preparedPolicy) else { return false }
        return requested == preparedMasterURL
    }

    func run() async {
        let token = generation
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let source, let master else {
                    error = "No authenticated live HLS source is prepared."
                    continuation.resume()
                    return
                }
                completion = continuation
                do {
                    if !CameraTalkbackController.microphoneInUse {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                        try AVAudioSession.sharedInstance().setActive(true)
                    }
                    let item = AVPlayerItem(asset: source.asset)
                    item.automaticallyPreservesTimeOffsetFromLive = true
                    item.configuredTimeOffsetFromLive = CMTime(seconds: HLSPlaybackTuning.liveDelay, preferredTimescale: 600)
                    item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                    startupPolicy = LiveHLSStartupPolicy(lowestBandwidth: master.lowestBandwidth)
                    item.preferredPeakBitRate = Double(master.lowestBandwidth)
                    item.preferredForwardBufferDuration = HLSPlaybackTuning.forwardBuffer(grid: activeConfiguration?.grid == true)
                    player.automaticallyWaitsToMinimizeStalling = false
                    player.isMuted = muted
                    observations = [
                        item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                            Task { @MainActor in
                                guard let self, self.generation == token, self.player.currentItem === item else { return }
                                if item.status == .readyToPlay {
                                    self.measurements.record(.playerReady,
                                        seconds: ProcessInfo.processInfo.systemUptime - self.openedAt)
                                    self.updateMetrics()
                                    self.player.play()
                                }
                                else if item.status == .failed {
                                    let code = item.error.map { ($0 as NSError).code } ?? 0
                                    self.fail("AVPlayer HLS failed (code \(code)). Share playback diagnostics; LL-HLS packaging errors are not an authentication failure.",
                                        cause: item.error)
                                }
                            }
                        },
                        playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                            Task { @MainActor in self?.updateVideo(token: token) }
                        },
                        item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                            Task { @MainActor in self?.updateVideo(token: token) }
                        },
                    ]
                    failureObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
                    ) { [weak self] notification in
                        let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                            .localizedDescription ?? "Live HLS stopped unexpectedly."
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.fail(message, cause: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                        }
                    }
                    player.replaceCurrentItem(with: item)
                    lastProgressUptime = ProcessInfo.processInfo.systemUptime
                    health = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                            guard let self, self.generation == token, self.player.currentItem === item else { return }
                            let time = self.player.currentTime()
                            self.updateVideo(token: token)
                            let playing = self.player.timeControlStatus == .playing
                            if time.seconds.isFinite, self.resolution != nil, playing,
                               self.lastPosition.map({ abs(time.seconds - $0) > 0.001 }) ?? true {
                                self.lastPosition = time.seconds
                                self.lastVideoReceivedAt = Date()
                                self.lastProgressUptime = ProcessInfo.processInfo.systemUptime
                            }
                            let ahead = item.loadedTimeRanges.compactMap { value -> Double? in
                                let range = value.timeRangeValue
                                guard CMTimeRangeContainsTime(range, time: time) else { return nil }
                                let remaining = CMTimeRangeGetEnd(range).seconds - time.seconds
                                return remaining.isFinite ? max(0, remaining) : nil
                            }.max() ?? 0
                            self.startupPolicy?.observe(now: ProcessInfo.processInfo.systemUptime,
                                decodedVideo: self.resolution != nil, bufferedAhead: ahead,
                                playing: playing && !item.isPlaybackBufferEmpty,
                                restrictedNetwork: LiveNetworkConditions.shared.restricted)
                            if LiveNetworkConditions.shared.restricted,
                               master.variants.allSatisfy({ $0.height > 720 }) {
                                self.fail("This pinned rendition exceeds Low Data Mode. Choose Auto or an advertised rung at or below 720p.")
                                return
                            }
                            if let cap = self.startupPolicy?.preferredPeakBitRate { item.preferredPeakBitRate = cap }
                            if self.resolution != nil {
                                let nextStatus = self.recoveringEdge ? "Recovering live edge" :
                                    (playing ? "Live HLS / native adaptive bitrate" : "Buffering live HLS")
                                if self.status != nextStatus { self.status = nextStatus }
                                let stalledFor = ProcessInfo.processInfo.systemUptime - self.lastProgressUptime
                                if !self.recoveringEdge, let window = item.seekableTimeRanges.last?.timeRangeValue,
                                   let target = self.edgePolicy.target(current: time.seconds,
                                    seekableStart: window.start.seconds, seekableEnd: CMTimeRangeGetEnd(window).seconds,
                                    recommendedOffset: max(HLSPlaybackTuning.liveDelay,
                                        item.recommendedTimeOffsetFromLive.seconds.isFinite
                                            ? item.recommendedTimeOffsetFromLive.seconds : HLSPlaybackTuning.liveDelay),
                                    stalledFor: stalledFor,
                                    waiting: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate) {
                                    self.recoverLiveEdge(target: target, item: item, token: token)
                                }
                                if !self.recoveringEdge, stalledFor > 20 {
                                    self.fail(HLSPlaybackFailure.stalled.localizedDescription, cause: HLSPlaybackFailure.stalled)
                                }
                            }
                        }
                    }
                } catch { fail(error.localizedDescription) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
            }
        }
    }

    private func updateVideo(token: UUID) {
        guard generation == token, playerLayer.isReadyForDisplay,
              let size = player.currentItem?.presentationSize,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let isFirstFrame = firstFrame == nil
        if isFirstFrame {
            firstFrame = ProcessInfo.processInfo.systemUptime - openedAt
            measurements.record(.firstDisplayedFrame, seconds: firstFrame ?? 0)
            player.automaticallyWaitsToMinimizeStalling = true
        }
        if resolution != size {
            resolution = size
            transitions.append("\(Int(size.width))x\(Int(size.height))")
            if transitions.count > 16 { transitions.removeFirst() }
        }
        updateMetrics(force: isFirstFrame)
        startup?.cancel()
        startup = nil
    }

    private func updateMetrics(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastMetricsPublishedAt >= 1 else { return }
        lastMetricsPublishedAt = now
        let access = player.currentItem?.accessLog()?.events.last
        let errors = player.currentItem?.errorLog()?.events.suffix(8).map(\.errorStatusCode)
        let observed = access.flatMap { event in
            event.observedBitrate.isFinite && event.observedBitrate >= 0 ? event.observedBitrate.formatted() : nil
        } ?? "not observed"
        let indicated = access.flatMap { event in
            event.indicatedBitrate.isFinite && event.indicatedBitrate >= 0 ? event.indicatedBitrate.formatted() : nil
        } ?? "not observed"
        let stalls = access.map { String($0.numberOfStalls) } ?? "not observed"
        let dropped = access.map { String($0.numberOfDroppedVideoFrames) } ?? "not observed"
        let errorCodes = errors.map { String(describing: $0) } ?? "not observed"
        metrics = measurements.report + "\nDecoded resolutions: \(transitions.joined(separator: " > "))" +
            "\nObserved bps: \(observed); indicated bps: \(indicated)" +
            "\nStalls: \(stalls); dropped video frames: \(dropped)" +
            "\nAVPlayer error codes: \(errorCodes)"
    }

    private func recoverLiveEdge(target: Double, item: AVPlayerItem, token: UUID) {
        recoveringEdge = true
        edgeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == token, self.recoveringEdge else { return }
            self.fail("Live-edge recovery timed out. Reconnect to retry.")
        }
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.generation == token, self.player.currentItem === item else { return }
                self.edgeDeadline?.cancel()
                self.edgeDeadline = nil
                self.recoveringEdge = false
                guard completed else {
                    self.fail("Live-edge recovery did not complete. Reconnect to retry.")
                    return
                }
                self.lastProgressUptime = ProcessInfo.processInfo.systemUptime
                self.lastPosition = nil
                self.player.play()
            }
        }
    }

    private func fail(_ message: String, authenticationRequired: Bool = false, httpStatus: Int? = nil, cause: Error? = nil) {
        updateMetrics(force: true)
        stop()
        lastHTTPStatus = httpStatus
        lastFailure = cause ?? httpStatus.map { HorizonError.http($0) } ?? HorizonError.message(message)
        error = message
        needsReauthentication = authenticationRequired
        status = "Live HLS failed"
    }

    func stop() {
        generation = UUID()
        startup?.cancel()
        startup = nil
        edgeDeadline?.cancel()
        edgeDeadline = nil
        recoveringEdge = false
        edgePolicy = LiveHLSEdgeRecoveryPolicy()
        player.pause()
        health?.cancel()
        health = nil
        observations.removeAll()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.currentItem?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
        source?.close()
        source = nil
        client?.invalidate()
        client = nil
        master = nil
        preparedStatus = nil
        preparedPolicy = nil
        preparedMasterURL = nil
        activeConfiguration = nil
        advertisedHeights = []
        startupPolicy = nil
        resolution = nil
        lastVideoReceivedAt = nil
        lastPosition = nil
        error = nil
        needsReauthentication = false
        let completion = completion
        self.completion = nil
        completion?.resume()
    }
}

struct NativeLiveHLSSurface: UIViewRepresentable {
    let stream: HLSLiveStream
    var fillVideo = false
    func makeUIView(context: Context) -> LiveHLSHost { LiveHLSHost(playerLayer: stream.playerLayer) }
    func updateUIView(_ view: LiveHLSHost, context: Context) {
        stream.playerLayer.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect
    }
}

final class LiveHLSHost: UIView {
    private let playerLayer: AVPlayerLayer
    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
