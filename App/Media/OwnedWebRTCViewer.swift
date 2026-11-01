import AVFoundation
import Combine
import HorizonCore
@preconcurrency import WebRTC

@MainActor
final class ViewerCleanupStore: ObservableObject {
    static let shared = ViewerCleanupStore()
    @Published private(set) var error: String?
    private var jobs: [String: Task<Bool, Never>] = [:]
    private var confirmed: [String] = []
    private var failed: [String: (api: HorizonAPI, policy: ViewerResourcePolicy, id: UUID)] = [:]
    private var unidentified = false
    @discardableResult
    func close(api: HorizonAPI, policy: ViewerResourcePolicy, id: UUID) -> Task<Bool, Never> {
        let key = "\(ObjectIdentifier(api))-\(id)"
        if let job = jobs[key] { return job }
        if confirmed.contains(key) { return Task { true } }
        let job = Task { [self] in
            defer { jobs.removeValue(forKey: key) }
            do {
                _ = try await api.viewerRequest(policy.owned(id), method: "DELETE", success: [200,204,410])
                confirmed.append(key)
                failed.removeValue(forKey: key)
                if failed.isEmpty && !unidentified { self.error = nil }
                if confirmed.count > 256 { confirmed.removeFirst() }
                return true
            } catch let failure as HorizonError where [404,410].contains(failure.httpStatusCode ?? 0) {
                confirmed.append(key)
                failed.removeValue(forKey: key)
                if failed.isEmpty && !unidentified { self.error = nil }
                return !unidentified
            } catch {
                failed[key] = (api, policy, id)
                self.error = String(localized: "viewer.cleanup", defaultValue: "Local playback stopped, but owned viewer deletion is unconfirmed. Its lease is only a safeguard; retry cleanup before assuming server work ended.")
                return false
            }
        }
        jobs[key] = job
        return job
    }
    func drain() async -> Bool {
        let pending = Array(jobs.values)
        for job in pending { _ = await job.value }
        let failures = Array(failed.values)
        for owner in failures {
            let closed = await close(api: owner.api, policy: owner.policy, id: owner.id).value
            if !closed { return false }
        }
        return true
    }
    func unidentifiedCreation() {
        unidentified = true
        error = String(localized: "viewer.unknownCreation", defaultValue: "The server accepted viewer creation without a usable session identity. Cleanup cannot be confirmed; no creation replay was attempted.")
    }
}

@MainActor
final class OwnedWebRTCViewer: NSObject, ObservableObject {
    @Published private(set) var resolution: CGSize?
    @Published private(set) var error: String?
    @Published private(set) var needsReauthentication = false
    @Published private(set) var status = String(localized: "viewer.waiting", defaultValue: "WebRTC viewer stopped")
    @Published private(set) var advertisedHeights: [Int] = []
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var metrics = ""
    @Published private(set) var qualityUpdating = false
    private(set) var lastFailure: Error?
    private(set) var frameObserver = RTCViewerFrameObserver()
    let pipRenderer = RTCViewerPiPRenderer()
    var muted = true { didSet { audioTrack?.isEnabled = !muted && configuration?.audio == true } }
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private var peer: RTCPeerConnection?
    private var rtcConfiguration: RTCConfiguration?
    private var audioTrack: RTCAudioTrack?
    private var worker: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var leaseMonitor: Task<Void, Never>?
    private var candidatesTask: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var ownership = ViewerOwnershipState()
    private var generation: UUID { ownership.generation }
    private var candidateQueue = ViewerCandidateQueue()
    private var owner: (api: HorizonAPI, policy: ViewerResourcePolicy, id: UUID)?
    private var lease = ViewerLeaseState()
    private var configuration: ViewerConfiguration?
    private var startUptime = 0.0
    private var firstFrame: TimeInterval?
    private var lastFrameUptime: TimeInterval?
    var lastVideoReceivedAt: Date? {
        lastFrameUptime.map { Date().addingTimeInterval($0 - ProcessInfo.processInfo.systemUptime) }
    }
    var isRunning: Bool { worker != nil || owner != nil }
    private var pendingHeights: [Int] = []
    private var lastCleanup: Task<Bool, Never>?

    private func observeFrames(token: UUID) {
        frameObserver = RTCViewerFrameObserver()
        frameObserver.onDecoded = { [weak self] size, uptime in
            Task { @MainActor in
                guard let self, self.generation == token, self.peer != nil else { return }
                self.lastFrameUptime = uptime
                if self.firstFrame == nil {
                    self.firstFrame = max(0, uptime - self.startUptime)
                    self.startup?.cancel()
                }
                if self.resolution != size { self.resolution = size }
                let text = String(localized: "viewer.live", defaultValue: "Live WebRTC")
                if self.status != text { self.status = text }
            }
        }
    }

    func start(api: HorizonAPI, camera: String, configuration: ViewerConfiguration) {
        let previousWorker = worker
        stop()
        let previousCleanup = lastCleanup
        self.configuration = configuration
        error = nil
        needsReauthentication = false
        lastFailure = nil
        startUptime = ProcessInfo.processInfo.systemUptime
        firstFrame = nil
        let token = generation
        observeFrames(token: token)
        status = String(localized: "viewer.discovering", defaultValue: "Checking WebRTC viewing support")
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                await previousWorker?.value
                _ = await previousCleanup?.value
                let cleaned = await ViewerCleanupStore.shared.drain()
                guard cleaned else { throw HorizonError.message(ViewingMessage.failed) }
                try self.check(token)
                let features: ViewingFeatures
                do { features = try await api.get(["native", "features"]) }
                catch {
                    if error is DecodingError { throw HorizonError.message(ViewingMessage.upgrade) }
                    if let code = (error as? HorizonError)?.httpStatusCode, [404,405,501].contains(code) {
                        throw HorizonError.message(ViewingMessage.upgrade)
                    }
                    throw error
                }
                _ = try features.requireLive()
                try self.check(token)
                let policy = try ViewerResourcePolicy(address: api.address, camera: camera)
                let data = try await api.viewerRequest(policy.statusURL)
                let status = try JSONDecoder().decode(LiveWebRTCStatus.self, from: data)
                try status.validate(policy: policy)
                let body = try configuration.creation(status: status)
                let url = try policy.resolve(status.sessionURL, expected: policy.sessionsURL)
                try self.check(token)
                // Creation is not canceled in flight: a late 201 still needs its exact DELETE.
                let creation = Task { try await api.viewerRequest(url, method: "POST",
                    body: JSONEncoder().encode(body), success: [201]) }
                let created = try await creation.value
                let identity: ViewerSessionIdentity
                do { identity = try JSONDecoder().decode(ViewerSessionIdentity.self, from: created) }
                catch { ViewerCleanupStore.shared.unidentifiedCreation(); throw HorizonError.message(ViewingMessage.invalid) }
                do {
                    let description = try JSONDecoder().decode(ViewerSessionDescription.self, from: created)
                    try description.validate(policy: policy, configuration: configuration, now: Date().timeIntervalSince1970)
                    guard !Task.isCancelled, self.ownership.acceptCreated(identity.sessionID, generation: token) else {
                        _ = await ViewerCleanupStore.shared.close(api: api, policy: policy, id: identity.sessionID).value
                        return
                    }
                    self.owner = (api, policy, identity.sessionID)
                    self.advertisedHeights = description.renditions.map(\.height).sorted()
                    try self.lease.accept(id: identity.sessionID, expiresAt: description.expiresAt,
                        interval: description.heartbeatSeconds, now: Date().timeIntervalSince1970)
                    self.beginMaintenance(token: token)
                    try await self.negotiate(description, token: token)
                    try self.check(token)
                } catch {
                    _ = await ViewerCleanupStore.shared.close(api: api, policy: policy, id: identity.sessionID).value
                    throw error
                }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func negotiate(_ description: ViewerSessionDescription, token: UUID) async throws {
        guard let owner else { throw HorizonError.message(ViewingMessage.invalid) }
        status = String(localized: "viewer.connecting", defaultValue: "Connecting WebRTC")
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.iceTransportPolicy = description.iceTransportPolicy == "relay" ? .relay : .all
        config.iceServers = description.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        guard let peer = Self.factory.peerConnection(with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw HorizonError.message(ViewingMessage.failed)
        }
        self.peer = peer
        rtcConfiguration = config
        startup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.generation == token, self.resolution == nil else { return }
            self.fail(HorizonError.message(ViewingMessage.failed))
        }
        if configuration?.audio == true {
            RTCAudioSession.sharedInstance().useManualAudio = true
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            RTCAudioSession.sharedInstance().isAudioEnabled = true
        }
        try await setRemote(RTCSessionDescription(type: .offer, sdp: description.offer.sdp), peer: peer)
        try check(token)
        guard peer.senders.allSatisfy({ $0.track == nil }) else { throw HorizonError.message(ViewingMessage.invalid) }
        for candidate in description.iceCandidates { try await add(candidate, peer: peer); try check(token) }
        let answer = try await answer(peer)
        try ViewerSDP(type: "answer", sdp: answer.sdp).validate(expected: "answer", receiveOnly: true)
        try check(token)
        try await setLocal(answer, peer: peer)
        try check(token)
        _ = try await owner.api.viewerRequest(owner.policy.owned(owner.id, operation: "answer"), method: "POST",
            body: JSONEncoder().encode(ViewerSDP(type: "answer", sdp: answer.sdp)), success: [204])
        try check(token)
        candidateQueue.acceptAnswer()
        flushCandidates(token: token)
        attachTracks(peer)
    }

    private func attachTracks(_ peer: RTCPeerConnection) {
        guard self.peer === peer else { return }
        if let track = peer.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first, videoTrack !== track {
            videoTrack?.remove(frameObserver)
            videoTrack = track
            track.add(frameObserver)
        }
        audioTrack = peer.transceivers.compactMap { $0.receiver.track as? RTCAudioTrack }.first
        audioTrack?.isEnabled = !muted && configuration?.audio == true
    }

    private func flushCandidates(token: UUID) {
        guard candidateQueue.hasReadyBatch, candidatesTask == nil else { return }
        candidatesTask = Task { [weak self] in
            guard let self else { return }
            defer { self.candidatesTask = nil }
            while self.generation == token, !Task.isCancelled, self.candidateQueue.hasReadyBatch {
                guard let owner = self.owner else { return }
                let batch = self.candidateQueue.takeBatch()
                struct Batch: Encodable { let candidates: [ViewerCandidate] }
                do {
                    _ = try await owner.api.viewerRequest(owner.policy.owned(owner.id, operation: "candidates"), method: "POST",
                        body: JSONEncoder().encode(Batch(candidates: batch)), success: [204])
                } catch {
                    if self.generation == token, !Task.isCancelled { self.fail(error) }
                    return
                }
            }
        }
    }

    private func beginMaintenance(token: UUID) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                do { try await Task.sleep(for: .seconds(self.lease.interval)) } catch { return }
                guard self.generation == token, let owner = self.owner else { return }
                do {
                    let data = try await owner.api.viewerRequest(owner.policy.owned(owner.id), method: "PATCH",
                        body: Data("{}".utf8))
                    let update = try JSONDecoder().decode(ViewerHeartbeat.self, from: data)
                    try self.check(token)
                    try self.lease.renew(update, now: Date().timeIntervalSince1970)
                    if let servers = update.iceServers, let config = self.rtcConfiguration {
                        for server in servers { try ViewerSessionDescription.validateICE(server) }
                        config.iceServers = servers.map {
                            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
                        }
                        guard self.peer?.setConfiguration(config) == true else { throw HorizonError.message(ViewingMessage.failed) }
                    }
                } catch {
                    if self.generation == token, !Task.isCancelled { self.fail(error) }
                    return
                }
            }
        }
        leaseMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.generation == token else { return }
                if !self.lease.isValid(now: Date().timeIntervalSince1970) {
                    self.fail(HorizonError.http(410)); return
                }
            }
        }
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == token, let peer = self.peer else { return }
                peer.statistics { [weak self] report in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.reportStats(report)
                    }
                }
            }
        }
    }

    func setQuality(_ height: Int?) {
        guard qualityTask == nil, let owner else { return }
        guard height.map({ advertisedHeights.contains($0) }) ?? true else {
            error = viewingFailureMessage(HorizonError.http(404)); return
        }
        let token = generation
        qualityUpdating = true
        qualityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.qualityUpdating = false; self.qualityTask = nil }
            struct Body: Encodable {
                let height: Int?
                func encode(to encoder: Encoder) throws {
                    var value = encoder.container(keyedBy: Key.self); try value.encode(height, forKey: .height)
                }
                enum Key: String, CodingKey { case height }
            }
            do {
                _ = try await owner.api.viewerRequest(owner.policy.owned(owner.id, operation: "quality"), method: "PATCH",
                    body: JSONEncoder().encode(Body(height: height)), success: [200,204])
                try self.check(token)
                self.error = nil
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                if (error as? HorizonError)?.httpStatusCode == 404 || (error as? HorizonError)?.httpStatusCode == 422 {
                    self.error = viewingFailureMessage(error)
                } else { self.fail(error) }
            }
        }
    }

    private func reportStats(_ report: RTCStatisticsReport) {
        let values = Array(report.statistics.values)
        let transport = values.first { $0.type == "transport" }
        let pairID = transport?.values["selectedCandidatePairId"] as? String
        let pair = pairID.flatMap { report.statistics[$0] }
        let candidateID = pair?.values["localCandidateId"] as? String
        let candidate = candidateID.flatMap { report.statistics[$0] }
        func safe(_ key: String, allowed: Set<String>) -> String {
            guard let value = candidate?.values[key] as? String, allowed.contains(value) else { return "not observed" }
            return value
        }
        let inbound = values.first { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" }
        let decoded = inbound?.values["framesDecoded"] as? NSNumber
        let dropped = inbound?.values["framesDropped"] as? NSNumber
        let first = firstFrame.map { String(format: "%.3f s", $0) } ?? "not observed"
        metrics = "Protocol: WebRTC\nFirst decoded frame: \(first)\nDecoded: \(decoded?.stringValue ?? "not observed")\nDropped: \(dropped?.stringValue ?? "not observed")\n" +
            "Decoded size: \(resolution.map { "\(Int($0.width))x\(Int($0.height))" } ?? "not observed")\n" +
            "Candidate: \(safe("candidateType", allowed: ["host","srflx","prflx","relay"]))\n" +
            "Protocol: \(safe("protocol", allowed: ["udp","tcp"]))\nRelay protocol: \(safe("relayProtocol", allowed: ["udp","tcp","tls"]))"
    }

    private func fail(_ failure: Error) {
        let message = viewingFailureMessage(failure)
        let auth = (failure as? HorizonError)?.httpStatusCode == 401
        stop()
        error = message; needsReauthentication = auth
        lastFailure = failure
        status = message
    }

    func stop() {
        ownership.invalidate()
        worker?.cancel(); worker = nil
        heartbeat?.cancel(); heartbeat = nil
        leaseMonitor?.cancel(); leaseMonitor = nil
        candidatesTask?.cancel(); candidatesTask = nil
        startup?.cancel(); startup = nil
        statisticsTask?.cancel(); statisticsTask = nil
        qualityTask?.cancel(); qualityTask = nil
        qualityUpdating = false
        videoTrack?.remove(frameObserver); videoTrack = nil
        frameObserver.reset()
        pipRenderer.stop()
        audioTrack?.isEnabled = false; audioTrack = nil
        peer?.delegate = nil; peer?.close(); peer = nil
        rtcConfiguration = nil
        candidateQueue = ViewerCandidateQueue()
        resolution = nil; lastFrameUptime = nil
        advertisedHeights = []
        if let owner { lastCleanup = ViewerCleanupStore.shared.close(api: owner.api, policy: owner.policy, id: owner.id) }
        owner = nil
        lease = ViewerLeaseState()
    }

    private func answer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                if let answer, error == nil { continuation.resume(returning: answer) }
                else { continuation.resume(throwing: HorizonError.message(ViewingMessage.failed)) }
            }
        }
    }
    private func setRemote(_ description: RTCSessionDescription, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: HorizonError.message(ViewingMessage.failed)) }
            }
        }
    }
    private func setLocal(_ description: RTCSessionDescription, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: HorizonError.message(ViewingMessage.failed)) }
            }
        }
    }
    private func add(_ candidate: ViewerCandidate, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)) { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: HorizonError.message(ViewingMessage.failed)) }
            }
        }
    }
}

extension OwnedWebRTCViewer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            do {
                let value = try ViewerCandidate(candidate: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
                try self.candidateQueue.append(value)
                self.flushCandidates(token: self.generation)
            } catch { self.fail(error) }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard self.peer === peerConnection else { return }
            if newState == .failed { self.fail(HorizonError.message(ViewingMessage.failed)) }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor in self.attachTracks(peerConnection) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
