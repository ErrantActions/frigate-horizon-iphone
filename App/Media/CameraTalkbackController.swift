import AVFoundation
import Combine
import HorizonCore
@preconcurrency import WebRTC

@MainActor
final class CameraTalkbackController: NSObject, ObservableObject {
    @Published private(set) var phase: CameraPushToTalkState.Phase = .idle
    @Published private(set) var error: String?

    private static var microphone = CameraMicrophoneOwnership()
    private static let holdLimitMessage = "Talkback stopped at the 30-second safety limit. Release and hold again to continue."
    static var microphoneInUse: Bool { microphone.owner != nil }
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private struct AudioSnapshot {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let manualAudio: Bool
        let audioEnabled: Bool
    }

    private struct RemoteLease {
        let api: HorizonAPI
        let cameraID: String
        let id: UUID
        let generation: UUID
    }

    private var state = CameraPushToTalkState()
    private var leaseState = CameraTalkbackLeaseState()
    private var remoteLease: RemoteLease?
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var holdLimit: Task<Void, Never>?
    private var leaseMonitor: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var peer: RTCPeerConnection?
    private var microphoneTrack: RTCAudioTrack?
    private var audioSnapshot: AudioSnapshot?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase != .idle else { return }
                    self.fail("Talkback stopped because the audio session was interrupted. Hold again to reconnect.")
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in
                guard let self, self.phase != .idle else { return }
                self.fail("Talkback stopped because the audio device disconnected. Hold again to reconnect.")
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(
        api: HorizonAPI, cameraID: String, capabilities: CameraControlCapabilities?,
        iceServers: [ICEServer]
    ) {
        guard phase == .idle else { return }
        error = nil
        do {
            guard let capabilities else { throw HorizonError.message("Reload camera controls before using talkback.") }
            try capabilities.validate(cameraID: cameraID)
            guard capabilities.talkback.supported else {
                throw HorizonError.message("Talkback is not available for this camera or account.")
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let token = state.begin(now: started)
        guard Self.microphone.acquire(token) else {
            state.end()
            error = "Another camera is using the microphone. Release its talk button first."
            return
        }
        leaseState.begin(generation: token, now: started)
        phase = state.phase
        holdLimit = Task { [weak self] in
            let remaining = max(0, CameraPushToTalkState.maximumHoldDuration -
                (ProcessInfo.processInfo.systemUptime - started))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.state.generation == token else { return }
            self.fail(Self.holdLimitMessage)
        }
        LivePictureInPictureController.shared.stop()
        LiveGroupPictureInPictureController.shared.stop()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkHeld(token)
                let granted = await self.requestPermission()
                try self.checkHeld(token)
                guard granted else {
                    throw HorizonError.message("Microphone access is denied. Enable Horizon's microphone permission in Settings, then hold again.")
                }
                guard self.state.permissionGranted(token) else { throw CancellationError() }
                self.phase = self.state.phase
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.state.owns(token), self.phase != .transmitting else { return }
                    self.fail("Talkback could not connect. Check the camera backchannel and the server's ICE/TURN configuration.")
                }
                try await self.negotiate(api: api, cameraID: cameraID, token: token, iceServers: iceServers)
            } catch {
                CameraTalkbackCleanupStore.shared.offerFailed(token, reason: error.localizedDescription)
                guard self.state.owns(token), !Task.isCancelled else { return }
                self.fail("Talkback unavailable: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        let token = state.generation
        let endedLease = remoteLease
        remoteLease = nil
        state.end()
        leaseState.end()
        phase = .idle
        task?.cancel()
        task = nil
        timeout?.cancel()
        timeout = nil
        holdLimit?.cancel()
        holdLimit = nil
        leaseMonitor?.cancel()
        leaseMonitor = nil
        renewal?.cancel()
        renewal = nil
        microphoneTrack?.isEnabled = false
        peer?.transceivers.forEach { ($0.receiver.track as? RTCAudioTrack)?.isEnabled = false }
        if audioSnapshot != nil { RTCAudioSession.sharedInstance().isAudioEnabled = false }
        if let peer {
            for sender in peer.senders { _ = peer.removeTrack(sender) }
        }
        peer?.delegate = nil
        peer?.close()
        peer = nil
        microphoneTrack = nil
        restoreAudioSession()
        if let token { Self.microphone.release(token) }
        if let token { CameraTalkbackCleanupStore.shared.offerEnded(token) }
        if let endedLease {
            CameraTalkbackCleanupStore.shared.close(
                api: endedLease.api, cameraID: endedLease.cameraID, leaseID: endedLease.id)
        }
    }

    func clearError() { error = nil }

    private func checkHeld(_ token: UUID) throws {
        try Task.checkCancellation()
        if state.generation == token && state.hasExpired() {
            fail(Self.holdLimitMessage)
            throw CancellationError()
        }
        if state.generation == token, leaseState.lease != nil,
           !leaseState.canUse(token, now: ProcessInfo.processInfo.systemUptime) {
            fail("The talkback lease expired. The microphone is stopped; remote closure must still be confirmed.")
            throw CancellationError()
        }
        guard state.owns(token), Self.microphone.owner == token else { throw CancellationError() }
    }

    private func requestPermission() async -> Bool {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private func negotiate(
        api: HorizonAPI, cameraID: String, token: UUID, iceServers: [ICEServer]
    ) async throws {
        try checkHeld(token)
        try prepareAudioSession()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        guard let peer = Self.factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        ) else { throw HorizonError.message("The audio connection could not be created.") }
        self.peer = peer
        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true", "googAutoGainControl": "true",
            "googNoiseSuppression": "true", "googHighpassFilter": "true",
        ], optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: source, trackId: "horizon-push-to-talk")
        track.isEnabled = false
        microphoneTrack = track
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .sendRecv
        guard peer.addTransceiver(with: track, init: transceiver) != nil else {
            throw HorizonError.message("The microphone sender could not be created.")
        }
        let offer = try await createOffer(peer)
        try checkHeld(token)
        try await setDescription(offer, on: peer, remote: false)
        try checkHeld(token)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while peer.iceGatheringState != .complete {
            try checkHeld(token)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HorizonError.message("Talkback ICE gathering timed out. Check the server's ICE/TURN settings.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try checkHeld(token)
        guard let local = peer.localDescription else { throw HorizonError.unexpectedResponse }
        let body = try CameraTalkbackDescription(offer: local.sdp)
        // Do not cancel an already-dispatched offer on release: its lease headers are
        // needed to DELETE the exact remote peer even if the answer arrives late.
        let result = try await Task { [self] in
            try checkHeld(token)
            CameraTalkbackCleanupStore.shared.offerStarted(token)
            return try await api.sendWithHTTPResponse(
                CameraControlRoute.talkback(cameraID: cameraID), body: body)
        }.value
        var headers: [String: String] = [:]
        for (key, value) in result.response.allHeaderFields {
            guard let name = key as? String,
                  CameraTalkbackLease.headerNames.contains(where: {
                      $0.caseInsensitiveCompare(name) == .orderedSame
                  }) else { continue }
            headers[name] = String(describing: value)
        }
        guard let leaseID = CameraTalkbackLease.id(in: headers) else {
            throw HorizonError.message("The server returned no valid talkback lease UUID. The microphone remains off; remote cleanup cannot be confirmed.")
        }
        CameraTalkbackCleanupStore.shared.offerIdentified(token)
        let scope = RemoteLease(api: api, cameraID: cameraID, id: leaseID, generation: token)
        guard state.owns(token), !Task.isCancelled else {
            CameraTalkbackCleanupStore.shared.close(api: api, cameraID: cameraID, leaseID: leaseID)
            try checkHeld(token)
            throw CancellationError()
        }
        remoteLease = scope
        let lease = try CameraTalkbackLease(headers: headers)
        guard try leaseState.acceptInitial(lease, generation: token,
            now: ProcessInfo.processInfo.systemUptime, wallNow: Date().timeIntervalSince1970)
        else { throw HorizonError.message("The talkback lease no longer belongs to the held camera.") }
        monitorLease(scope)
        let answer = try JSONDecoder().decode(CameraTalkbackDescription.self, from: result.data)
        let sdp = try answer.validatedAnswer()
        try await setDescription(RTCSessionDescription(type: .answer, sdp: sdp), on: peer, remote: true)
        try checkHeld(token)
        // Capture stays disabled until ICE is connected, not merely until an answer arrives.
        if peer.iceConnectionState == .connected || peer.iceConnectionState == .completed {
            enableMicrophone(token)
        }
    }

    private func enableMicrophone(_ token: UUID) {
        if state.generation == token && state.hasExpired() {
            fail(Self.holdLimitMessage)
            return
        }
        guard leaseState.canUse(token, now: ProcessInfo.processInfo.systemUptime) else {
            if state.generation == token { fail("The talkback lease is not valid. The microphone remains off.") }
            return
        }
        guard Self.microphone.owner == token, microphoneTrack != nil, state.connected(token) else { return }
        microphoneTrack?.isEnabled = true
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        peer?.transceivers.forEach { ($0.receiver.track as? RTCAudioTrack)?.isEnabled = true }
        phase = state.phase
        timeout?.cancel()
        timeout = nil
    }

    private func monitorLease(_ scope: RemoteLease) {
        leaseMonitor?.cancel()
        leaseMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.state.generation == scope.generation else { return }
                if self.state.hasExpired() {
                    self.fail(Self.holdLimitMessage)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.leaseState.canUse(scope.generation, now: now) else {
                    self.fail("Talkback stopped because its server lease expired. Remote closure is not yet confirmed.")
                    return
                }
                if self.renewal == nil && self.leaseState.needsRenewal(scope.generation, now: now) {
                    self.renewLease(scope)
                }
            }
        }
    }

    private func renewLease(_ scope: RemoteLease) {
        renewal = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkHeld(scope.generation)
                let response: CameraTalkbackLeaseRenewal = try await scope.api.send(
                    CameraControlRoute.talkback(cameraID: scope.cameraID, leaseID: scope.id) + ["renew"],
                    body: CameraTalkbackEmptyBody())
                guard self.state.owns(scope.generation), !Task.isCancelled else {
                    CameraTalkbackCleanupStore.shared.close(
                        api: scope.api, cameraID: scope.cameraID, leaseID: scope.id)
                    if self.state.generation == scope.generation {
                        self.fail(Self.holdLimitMessage)
                    }
                    return
                }
                try self.checkHeld(scope.generation)
                guard try self.leaseState.acceptRenewal(response, generation: scope.generation,
                    now: ProcessInfo.processInfo.systemUptime, wallNow: Date().timeIntervalSince1970)
                else { throw HorizonError.message("The renewed talkback lease is no longer active.") }
                self.renewal = nil
            } catch {
                guard self.state.generation == scope.generation, !Task.isCancelled else {
                    CameraTalkbackCleanupStore.shared.close(
                        api: scope.api, cameraID: scope.cameraID, leaseID: scope.id)
                    return
                }
                self.fail("Talkback stopped because lease renewal failed: \(error.localizedDescription)")
            }
        }
    }

    private func prepareAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        let rtc = RTCAudioSession.sharedInstance()
        audioSnapshot = AudioSnapshot(category: audio.category, mode: audio.mode,
            options: audio.categoryOptions, manualAudio: rtc.useManualAudio, audioEnabled: rtc.isAudioEnabled)
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
    }

    private func restoreAudioSession() {
        guard let snapshot = audioSnapshot else { return }
        audioSnapshot = nil
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = snapshot.manualAudio
        rtc.isAudioEnabled = snapshot.audioEnabled
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                snapshot.category, mode: snapshot.mode, options: snapshot.options)
        } catch {
            self.error = "Talkback stopped, but the previous audio mode could not be restored: \(error.localizedDescription)"
        }
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    private func createOffer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let error { continuation.resume(throwing: error) }
                else if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: HorizonError.unexpectedResponse) }
            }
        }
    }

    private func setDescription(
        _ description: RTCSessionDescription, on peer: RTCPeerConnection, remote: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if remote { peer.setRemoteDescription(description, completionHandler: completion) }
            else { peer.setLocalDescription(description, completionHandler: completion) }
        }
    }
}

extension CameraTalkbackController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection, let token = self.state.generation else { return }
            switch state {
            case .connected, .completed: self.enableMicrophone(token)
            case .failed, .disconnected, .closed:
                self.fail("Talkback disconnected. Release and hold again to reconnect.")
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen channel: RTCDataChannel) {}
}

@MainActor
final class CameraTalkbackCleanupStore: ObservableObject {
    static let shared = CameraTalkbackCleanupStore()
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var isPending = false

    private struct Key: Hashable {
        let client: ObjectIdentifier
        let cameraID: String
        let leaseID: UUID
    }

    private var offers = Set<UUID>()
    private var waitingOffers = Set<UUID>()
    private var unidentifiedFailures: [UUID: String] = [:]
    private var failures: [Key: String] = [:]
    private var cleanups: [Key: Task<Void, Never>] = [:]
    private var confirmedClosures = Set<Key>()

    private init() {}

    func offerStarted(_ token: UUID) { offers.insert(token) }

    func offerEnded(_ token: UUID) {
        if offers.contains(token) {
            waitingOffers.insert(token)
            updateStatus()
        }
    }

    func offerIdentified(_ token: UUID) {
        offers.remove(token)
        waitingOffers.remove(token)
        unidentifiedFailures.removeValue(forKey: token)
        updateStatus()
    }

    func offerFailed(_ token: UUID, reason: String) {
        guard offers.remove(token) != nil else { return }
        waitingOffers.remove(token)
        unidentifiedFailures[token] = "The offer's lease could not be identified: \(reason)"
        updateStatus()
    }

    func close(api: HorizonAPI, cameraID: String, leaseID: UUID) {
        let key = Key(client: ObjectIdentifier(api), cameraID: cameraID, leaseID: leaseID)
        guard cleanups[key] == nil, !confirmedClosures.contains(key) else { return }
        cleanups[key] = Task {
            do {
                let result: APIActionResult = try await api.send(
                    CameraControlRoute.talkback(cameraID: cameraID, leaseID: leaseID),
                    method: "DELETE", body: CameraTalkbackEmptyBody())
                try result.requireSuccess()
                failures.removeValue(forKey: key)
                confirmedClosures.insert(key)
            } catch {
                failures[key] = error.localizedDescription
            }
            cleanups.removeValue(forKey: key)
            updateStatus()
        }
        updateStatus()
    }

    private func updateStatus() {
        isPending = !cleanups.isEmpty || !waitingOffers.isEmpty
        if let failure = unidentifiedFailures.values.first ?? failures.values.first {
            error = "Local capture for the ended hold is off, but remote talkback cleanup is unconfirmed. \(failure)"
        } else {
            error = nil
        }
        if isPending {
            status = "Local capture for the ended hold is stopped. Waiting for the server to confirm remote talkback closure."
        } else if !confirmedClosures.isEmpty && error == nil {
            status = "The server confirmed closure of the ended talkback lease."
        } else {
            status = nil
        }
    }
}
