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
    @Published private(set) var intendsToPlay = true
    @Published private(set) var synchronizing = false
    @Published private(set) var masterCamera: String?
    @Published private(set) var audibleCamera: String?
    @Published private(set) var error: String?
    private var channels: [String: IncidentReplayChannel] = [:]
    private var cameraIDs: [String] = []
    private var api: HorizonAPI?
    private var generation = UUID()
    private var loadingTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var chunk: ClosedRange<Double>?
    private var metadataReady = false
    private var running = false
    private var anchorTimestamp = 0.0
    private var anchorHost = CMTime.zero
    private var barrierStarted = 0.0
    private var lastSeekHost = 0.0
    private var changingGroup = false
    private var audioInitialized = false
    private let hostClock = CMClockGetHostTimeClock()

    func prepare(api: HorizonAPI, cameraIDs: [String], allowed: Set<String>, day: Date, at time: Double) {
        stop()
        error = nil
        do {
            let ids = try IncidentReplayPolicy.cameras(cameraIDs, allowed: allowed)
            let reviewRange = try ReviewTimeRange(day: day)
            range = reviewRange
            timestamp = try reviewRange.clamped(time)
            self.api = api
            self.cameraIDs = ids
            if !audioInitialized {
                audibleCamera = ids.first
                audioInitialized = true
            } else if let audibleCamera, !ids.contains(audibleCamera) { self.audibleCamera = ids.first }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            for id in ids {
                let channel = IncidentReplayChannel(id: id, clock: hostClock)
                channel.changed = { [weak self] in self?.channelChanged() }
                channels[id] = channel
                players[id] = channel.player
            }
            updateAudio()
            seek(to: timestamp)
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self else { return }
                    self.tick()
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func seek(to requested: Double) {
        guard let range, let api else { return }
        let request: IncidentReplaySeek
        do { request = try IncidentReplaySeek(timestamp: requested, autoplay: intendsToPlay, range: range) }
        catch { self.error = error.localizedDescription; return }
        freezeClock()
        timestamp = request.timestamp
        generation = request.id
        loadingTask?.cancel()
        let token = request.id
        do {
            let nextChunk = try IncidentReplayPolicy.chunk(at: timestamp, range: range)
            barrierStarted = hostSeconds
            lastSeekHost = hostSeconds
            synchronizing = true
            if chunk == nextChunk, metadataReady, channels.values.allSatisfy({ $0.coverage != nil }) {
                changingGroup = true
                for channel in channels.values { channel.seek(timestamp: timestamp, resetCorrections: true) }
                changingGroup = false
                channelChanged()
                return
            }
            chunk = nextChunk
            metadataReady = false
            for channel in channels.values { channel.clear() }
            publishStates()
            loadingTask = Task { [weak self] in
                guard let self else { return }
                for id in self.cameraIDs {
                    guard !Task.isCancelled, self.generation == token, let channel = self.channels[id] else { return }
                    do {
                        let coverage: RecordingCoverage = try await api.get([id, "recordings", "coverage"], query: [
                            URLQueryItem(name: "after", value: String(nextChunk.lowerBound)),
                            URLQueryItem(name: "before", value: String(nextChunk.upperBound)),
                            URLQueryItem(name: "timelines", value: "true"),
                        ])
                        guard !Task.isCancelled, self.generation == token else { return }
                        guard let spans = coverage.timelines?.auto else {
                            throw HorizonError.message("The server did not provide the realized recording timeline.")
                        }
                        channel.configure(coverage: coverage, timeline: PlaybackTimeline(spans: spans),
                            url: try api.address.playback(camera: id, start: nextChunk.lowerBound, end: nextChunk.upperBound),
                            api: api, timestamp: request.timestamp)
                    } catch {
                        guard !Task.isCancelled, self.generation == token else { return }
                        channel.fail(error.localizedDescription)
                    }
                }
                guard !Task.isCancelled, self.generation == token else { return }
                self.metadataReady = true
                self.barrierStarted = self.hostSeconds
                self.channelChanged()
            }
        } catch { self.error = error.localizedDescription; synchronizing = false }
    }

    func setPlaying(_ playing: Bool) {
        freezeClock()
        intendsToPlay = playing
        channelChanged()
    }

    func selectAudio(_ id: String) {
        guard cameraIDs.contains(id) else { return }
        audibleCamera = audibleCamera == id ? nil : id
        updateAudio()
    }

    func stop() {
        freezeClock()
        generation = UUID()
        loadingTask?.cancel()
        clockTask?.cancel()
        loadingTask = nil
        clockTask = nil
        for channel in channels.values { channel.stop() }
        channels = [:]
        players = [:]
        states = [:]
        cameraErrors = [:]
        cameraIDs = []
        api = nil
        chunk = nil
        metadataReady = false
        range = nil
        synchronizing = false
        masterCamera = nil
    }

    private var hostSeconds: Double { CMClockGetTime(hostClock).seconds }

    private func freezeClock() {
        if running, let range {
            timestamp = (try? IncidentReplayPolicy.timestamp(anchor: anchorTimestamp,
                hostElapsed: hostSeconds - anchorHost.seconds, range: range)) ?? timestamp
        }
        running = false
        for channel in channels.values { channel.player.pause() }
    }

    private func publishStates() {
        states = channels.mapValues(\.state)
        cameraErrors = channels.compactMapValues(\.error)
        masterCamera = IncidentReplayPolicy.master(orderedCameras: cameraIDs, states: states, previous: masterCamera)
    }

    private func channelChanged() {
        guard !changingGroup else { return }
        publishStates()
        guard metadataReady else { return }
        let open = IncidentReplayPolicy.barrierOpen(states)
        synchronizing = !open && states.values.contains(.loading)
        if running && !open { freezeClock() }
        guard intendsToPlay, open, !running else { return }
        // All players share one host-clock start; none can start while another is seeking.
        anchorTimestamp = timestamp
        anchorHost = CMTimeAdd(CMClockGetTime(hostClock), CMTime(seconds: 0.15, preferredTimescale: 90000))
        for channel in channels.values where channel.state == .ready {
            guard let position = channel.timeline.position(for: timestamp) else { continue }
            channel.player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 90000), atHostTime: anchorHost)
        }
        lastSeekHost = hostSeconds
        running = true
    }

    private func tick() {
        guard let range else { return }
        if !running {
            if metadataReady, synchronizing, hostSeconds - barrierStarted > IncidentReplayPolicy.readinessTimeout {
                for channel in channels.values where channel.state == .loading {
                    channel.fail("This camera did not become ready in time. Seek or retry to reload its recording.")
                }
                channelChanged()
            }
            return
        }
        let elapsed = max(0, hostSeconds - anchorHost.seconds)
        let actual = anchorTimestamp + elapsed
        if actual >= range.end {
            freezeClock()
            timestamp = range.end.nextDown
            intendsToPlay = false
            return
        }
        timestamp = actual
        if let chunk, actual >= chunk.upperBound {
            seek(to: actual)
            return
        }
        var transition = false
        for channel in channels.values {
            let available = channel.coverage?.contains(actual) == true
                && channel.timeline.position(for: actual) != nil
            if channel.state == .ready && !available {
                channel.markGap()
                transition = true
            } else if channel.state == .gap && available {
                transition = true
            }
        }
        if transition {
            freezeClock()
            barrierStarted = hostSeconds
            changingGroup = true
            for channel in channels.values { channel.seek(timestamp: timestamp, resetCorrections: false) }
            changingGroup = false
            channelChanged()
            return
        }
        for channel in channels.values where channel.state == .ready {
            let settling = hostSeconds - lastSeekHost
            if settling > IncidentReplayPolicy.correctionCooldown,
               channel.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                resynchronize(channel: channel, message: "Recording playback stalled repeatedly.")
                return
            }
            guard let recordedTime = channel.timeline.timestamp(for: channel.player.currentTime().seconds) else {
                if settling > IncidentReplayPolicy.correctionCooldown {
                    resynchronize(channel: channel, message: "The recording ended before the synchronized timeline.")
                }
                return
            }
            switch IncidentReplayPolicy.correction(drift: recordedTime - actual, secondsSinceSeek: settling) {
            case .none:
                if settling >= IncidentReplayPolicy.correctionCooldown, channel.player.rate != 1 {
                    channel.player.rate = 1
                }
            case .rate(let rate): channel.player.rate = Float(rate)
            case .seek:
                resynchronize(channel: channel, message: "This recording could not stay synchronized.")
                return
            }
        }
        publishStates()
    }

    private func resynchronize(channel: IncidentReplayChannel, message: String) {
        freezeClock()
        barrierStarted = hostSeconds
        channel.hardCorrections += 1
        if channel.hardCorrections > IncidentReplayPolicy.maximumHardCorrections { channel.fail(message) }
        changingGroup = true
        for value in channels.values { value.seek(timestamp: timestamp, resetCorrections: false) }
        changingGroup = false
        channelChanged()
    }

    private func updateAudio() {
        for (id, channel) in channels { channel.player.isMuted = id != audibleCamera }
    }
}

@MainActor
private final class IncidentReplayChannel {
    let id: String
    let player = AVPlayer()
    var changed: (() -> Void)?
    var coverage: RecordingCoverage?
    var timeline = PlaybackTimeline(spans: [])
    var state = IncidentReplayReadiness.loading
    var error: String?
    var hardCorrections = 0
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var url: URL?
    private var api: HorizonAPI?
    private var seekToken = UUID()
    private var pendingPosition: Double?
    private var source: AuthenticatedLiveHLSAsset?
    private var opening: Task<Void, Never>?

    init(id: String, clock: CMClock) {
        self.id = id
        player.masterClock = clock
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func configure(coverage: RecordingCoverage, timeline: PlaybackTimeline, url: URL, api: HorizonAPI, timestamp: Double) {
        self.coverage = coverage
        self.timeline = timeline
        self.url = url
        self.api = api
        seek(timestamp: timestamp, resetCorrections: true)
    }

    func clear() {
        stop()
        coverage = nil
        timeline = PlaybackTimeline(spans: [])
        state = .loading
        error = nil
        hardCorrections = 0
    }

    func seek(timestamp: Double, resetCorrections: Bool) {
        if resetCorrections { hardCorrections = 0 }
        guard state != .failed || resetCorrections else { return }
        if state == .failed { discardItem() }
        error = nil
        guard coverage?.contains(timestamp) == true, let position = timeline.position(for: timestamp) else {
            markGap()
            return
        }
        seekToken = UUID()
        pendingPosition = position
        state = .loading
        player.pause()
        if player.currentItem == nil {
            guard let url, let api else { fail("The recording source is not available."); return }
            let token = seekToken
            opening?.cancel()
            opening = Task { [weak self] in
            guard let self else { return }
            do {
            let policy = try LiveHLSResourcePolicy(address: api.address, mediaURL: url)
            let client = AuthenticatedLiveHLSClient(policy: policy, cookies: api.cookies)
            let source = try await AuthenticatedLiveHLSAsset(client: client)
            guard self.seekToken == token, !Task.isCancelled else { source.close(); return }
            self.source = source
            source.onFailure = { [weak self] error in
                self?.fail(error.localizedDescription)
                self?.discardItem()
                self?.changed?()
                if LiveHLSGate.requiresReauthentication(error) {
                    NotificationCenter.default.post(name: .horizonMediaAuthenticationExpired, object: api)
                }
            }
            let item = AVPlayerItem(asset: source.asset)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    if item.status == .readyToPlay { self.performSeek() }
                    else if item.status == .failed {
                        self.fail(item.error?.localizedDescription ?? "Recording playback failed.")
                        self.changed?()
                    }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "Recording playback failed."
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.fail(message)
                    self.changed?()
                }
            }
            player.replaceCurrentItem(with: item)
            } catch {
                if self.seekToken == token, !Task.isCancelled {
                    self.fail(error.localizedDescription); self.changed?()
                }
            }
            }
        } else if player.currentItem?.status == .readyToPlay { performSeek() }
        changed?()
    }

    private func performSeek() {
        guard let pendingPosition, let item = player.currentItem else { return }
        self.pendingPosition = nil
        let token = seekToken
        item.forwardPlaybackEndTime = .invalid
        player.seek(to: CMTime(seconds: pendingPosition, preferredTimescale: 90000),
            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.seekToken == token, self.player.currentItem === item else { return }
                if completed {
                    if let coverage = self.coverage, let timestamp = self.timeline.timestamp(for: pendingPosition),
                       let end = IncidentReplayPolicy.recordedRunEnd(at: timestamp, coverage: coverage, timeline: self.timeline),
                       let endPosition = self.timeline.position(for: end.nextDown) {
                        // Concatenated HLS must not decode the next recorded span across a known wall-clock gap.
                        item.forwardPlaybackEndTime = CMTime(seconds: endPosition, preferredTimescale: 90000)
                        self.state = .ready
                    } else {
                        self.fail("An accurate continuous recording range could not be established for this time.")
                    }
                }
                else { self.fail("The recording seek did not complete. Retry the selected time.") }
                self.changed?()
            }
        }
    }

    func markGap() {
        seekToken = UUID()
        pendingPosition = nil
        player.pause()
        state = .gap
    }

    func fail(_ message: String) {
        seekToken = UUID()
        pendingPosition = nil
        player.pause()
        error = message
        state = .failed
    }

    func stop() {
        discardItem()
        url = nil
        api = nil
    }

    private func discardItem() {
        opening?.cancel()
        opening = nil
        player.currentItem?.asset.cancelLoading()
        source?.close()
        source = nil
        seekToken = UUID()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        observation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.replaceCurrentItem(with: nil)
        pendingPosition = nil
    }
}
