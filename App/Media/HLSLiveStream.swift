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
    private var openedAt = ProcessInfo.processInfo.systemUptime
    private var firstFrame: Double?
    private var transitions: [String] = []
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
        lastHTTPStatus = nil
        let token = generation
        status = "Checking live HLS support"
        let policy = try LiveHLSResourcePolicy(address: api.address, camera: camera)
        startup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.resolution == nil else { return }
            self.fail("Live HLS did not produce video in time. Reconnect to retry.")
        }
        do {
            let capability: LiveHLSStatus
            do { capability = try await api.liveHLSStatus(camera: camera) }
            catch {
                if let failure = error as? HorizonError, let code = failure.httpStatusCode,
                   LiveHLSGate.isUnsupportedHTTP(code) {
                    startup?.cancel(); startup = nil
                    status = "Live HLS is unsupported; using compatibility HTTPS"
                    return false
                }
                throw error
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard capability.isAvailable else {
                startup?.cancel(); startup = nil
                status = "Live HLS is unavailable; using compatibility HTTPS"
                return false
            }
            advertisedHeights = Array(Set(capability.renditions.map(\.height).filter { $0 >= 720 })).sorted()
            _ = try policy.masterURL(capability.playlist)
            status = "Opening authenticated live HLS"
            let masterURL = try configuration.masterURL(status: capability, policy: policy)
            let client = AuthenticatedLiveHLSClient(policy: policy, cookies: api.cookies,
                maximumHeight: configuration.maximumHeight, masterURL: masterURL)
            self.client = client
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
                    httpStatus: (failure as? HorizonError)?.httpStatusCode)
            }
            return true
        } catch {
            client?.invalidate()
            client = nil
            startup?.cancel()
            startup = nil
            throw error
        }
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
                    startupPolicy = LiveHLSStartupPolicy(lowestBandwidth: master.lowestBandwidth)
                    item.preferredPeakBitRate = Double(master.lowestBandwidth)
                    item.preferredForwardBufferDuration = 1
                    player.isMuted = muted
                    observations = [
                        item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                            Task { @MainActor in
                                guard let self, self.generation == token, self.player.currentItem === item else { return }
                                if item.status == .readyToPlay { self.player.play() }
                                else if item.status == .failed {
                                    let code = item.error.map { ($0 as NSError).code } ?? 0
                                    self.fail("AVPlayer HLS failed (code \(code)); errors \(item.errorLog()?.events.count ?? 0). If LL-HLS part durations changed, retain the server playlists for packager qualification.")
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
                            self.fail(message)
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
                                self.status = self.recoveringEdge ? "Recovering live edge" :
                                    (playing ? "Live HLS / native adaptive bitrate" : "Buffering live HLS")
                                let stalledFor = ProcessInfo.processInfo.systemUptime - self.lastProgressUptime
                                if !self.recoveringEdge, let window = item.seekableTimeRanges.last?.timeRangeValue,
                                   let target = self.edgePolicy.target(current: time.seconds,
                                    seekableStart: window.start.seconds, seekableEnd: CMTimeRangeGetEnd(window).seconds,
                                    recommendedOffset: item.recommendedTimeOffsetFromLive.seconds, stalledFor: stalledFor,
                                    waiting: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate) {
                                    self.recoverLiveEdge(target: target, item: item, token: token)
                                }
                                if !self.recoveringEdge, stalledFor > 20 {
                                    self.fail("Live HLS has stalled. Reconnect to retry; playback was not restarted automatically.")
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
        if firstFrame == nil { firstFrame = ProcessInfo.processInfo.systemUptime - openedAt }
        if resolution != size {
            resolution = size
            transitions.append("\(Int(size.width))x\(Int(size.height))")
            if transitions.count > 16 { transitions.removeFirst() }
        }
        let access = player.currentItem?.accessLog()?.events.last
        metrics = "First decoded frame: \((firstFrame ?? 0).formatted(.number.precision(.fractionLength(2)))) s; " +
            "resolutions: \(transitions.joined(separator: " > ")); " +
            "observed bps: \((access?.observedBitrate ?? 0).formatted()); indicated bps: \((access?.indicatedBitrate ?? 0).formatted()); " +
            "stalls: \(access?.numberOfStalls ?? 0)"
        startup?.cancel()
        startup = nil
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

    private func fail(_ message: String, authenticationRequired: Bool = false, httpStatus: Int? = nil) {
        stop()
        lastHTTPStatus = httpStatus
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
