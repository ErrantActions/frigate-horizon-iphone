import AVFoundation
import SwiftUI
import HorizonCore

@MainActor
final class VideoReflection: ObservableObject {
    @Published private(set) var image: CGImage?
    private(set) var generation = UUID()
    private var enabled = false
    private let renderer = VideoReflectionRenderer()
    private var source: Source?
    private var sampling: Task<Void, Never>?
    private var transformLoading: Task<Void, Never>?
    private var playerObservation: NSKeyValueObservation?
    private var tracksObservation: NSKeyValueObservation?
    private var jumpObservation: NSObjectProtocol?
    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var transform: CGAffineTransform?
    private var lastPlayerFrame: Double?
    private var gate = ReflectionSamplingGate()

    private enum Source {
        case player(AVPlayer)

        func matches(_ other: Source) -> Bool {
            switch (self, other) {
            case (.player(let lhs), .player(let rhs)): return lhs === rhs
            }
        }
    }

    private enum Sample {
        case frame(ReflectionFrame)
        case unchanged
        case clear
    }

    func follow(player: AVPlayer) { setSource(.player(player)) }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { startSampling() }
        else { stopSampling() }
    }

    func clearSource() {
        stopSampling()
        source = nil
    }

    private func setSource(_ value: Source) {
        guard source?.matches(value) != true else { return }
        stopSampling()
        source = value
        startSampling()
    }

    private func startSampling() {
        guard enabled, let source else { return }
        switch source {
        case .player(let player):
            attachItem(player.currentItem)
            playerObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, self.enabled, self.source?.matches(.player(player)) == true else { return }
                    self.attachItem(player.currentItem)
                }
            }
        }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await self.sample() }
                else { return }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
    }

    private func stopSampling() {
        sampling?.cancel()
        sampling = nil
        playerObservation = nil
        detachItem()
        clearFrame()
    }

    private func attachItem(_ value: AVPlayerItem?) {
        guard item !== value else { return }
        detachItem()
        clearFrame()
        guard let value else { return }
        item = value
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        self.output = output
        value.add(output)
        jumpObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: value, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.item === value else { return }
                self.clearFrame()
                self.lastPlayerFrame = nil
            }
        }
        tracksObservation = value.observe(\.tracks, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.item === item, self.output === output else { return }
                self.loadTransform(for: item, output: output)
            }
        }
    }

    private func loadTransform(for item: AVPlayerItem, output: AVPlayerItemVideoOutput) {
        transformLoading?.cancel()
        transform = nil
        clearFrame()
        transformLoading = Task { [weak self] in
            do {
                let activeTrack = item.tracks.first {
                    $0.isEnabled && $0.assetTrack?.mediaType == .video
                }?.assetTrack
                let track: AVAssetTrack?
                if let activeTrack { track = activeTrack }
                else { track = try await item.asset.loadTracks(withMediaType: .video).first }
                guard let track else { return }
                let transform = try await track.load(.preferredTransform)
                guard !Task.isCancelled, let self, self.item === item, self.output === output else { return }
                self.transform = transform
            } catch {
                // A missing/unreadable video transform disables only the decorative reflection.
            }
        }
    }

    private func detachItem() {
        tracksObservation = nil
        transformLoading?.cancel()
        transformLoading = nil
        if let jumpObservation { NotificationCenter.default.removeObserver(jumpObservation) }
        jumpObservation = nil
        if let item, let output { item.remove(output) }
        item = nil
        output = nil
        transform = nil
        lastPlayerFrame = nil
    }

    private func sample() async {
        guard enabled, !Task.isCancelled, gate.take(at: CACurrentMediaTime()) else { return }
        let token = generation
        switch capture() {
        case .frame(let frame):
            let result = await renderer.render(frame)
            guard !Task.isCancelled else { return }
            publish(result, generation: token)
        case .clear:
            if image != nil { clearFrame() }
        case .unchanged:
            break
        }
    }

    private func capture() -> Sample {
        switch source {
        case .player(let player):
            // Check identity synchronously as well as via KVO, so no old-camera image can escape.
            if item !== player.currentItem { attachItem(player.currentItem) }
            guard let item, item.status == .readyToPlay, let output, let transform else { return .clear }
            let time = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time) else {
                if player.rate == 0 { return .unchanged }
                return lastPlayerFrame.map {
                    CACurrentMediaTime() - $0 < VideoReflectionPolicy.staleInterval ? .unchanged : .clear
                } ?? .clear
            }
            guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return .clear }
            lastPlayerFrame = CACurrentMediaTime()
            return .frame(ReflectionFrame(content: .pixelBuffer(buffer, transform)))
        case nil:
            return .clear
        }
    }

    private func clearFrame() {
        generation = UUID()
        image = nil
    }

    func publish(_ value: CGImage?, generation token: UUID) {
        guard enabled, generation == token else { return }
        if case .player(let player) = source, item !== player.currentItem {
            attachItem(player.currentItem)
            return
        }
        image = value
    }
}
