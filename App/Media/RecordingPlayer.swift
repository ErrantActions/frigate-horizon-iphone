import SwiftUI
import AVKit
import HorizonCore

@MainActor
final class RecordingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var error: String?
    @Published private(set) var loading = true
    @Published private(set) var position = 0.0
    @Published private(set) var isSeeking = false
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var initialPosition = 0.0
    private var seekGeneration = UUID()
    private var opening: Task<Void, Never>?
    private var source: AuthenticatedLiveHLSAsset?
    private var loadGeneration = UUID()
    private var backgroundObserver: NSObjectProtocol?

    func open(url: URL, api: HorizonAPI, initialPosition: Double = 0, autoplay: Bool = true, recoveries: Int = 0) {
        stop()
        loading = true
        error = nil
        self.initialPosition = initialPosition
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let policy = try LiveHLSResourcePolicy(address: api.address, mediaURL: url)
            let token = loadGeneration
            opening = Task { [weak self] in
            guard let self else { return }
            do {
            let client = AuthenticatedLiveHLSClient(policy: policy, cookies: api.cookies)
            let source = try await AuthenticatedLiveHLSAsset(client: client)
            guard self.loadGeneration == token, !Task.isCancelled else { source.close(); return }
            self.source = source
            source.onFailure = { [weak self] error in
                guard let self, self.loadGeneration == token else { return }
                if (error as? HorizonError)?.httpStatusCode == 404, recoveries == 0 {
                    let position = self.position
                    self.open(url: url, api: api, initialPosition: position, autoplay: autoplay, recoveries: 1)
                    return
                }
                self.error = error.localizedDescription
                self.loading = false
                self.player.pause()
                self.player.replaceCurrentItem(with: nil)
                self.source?.close()
                self.source = nil
                if LiveHLSGate.requiresReauthentication(error) {
                    // The shared AppModel coalesces this into the existing sign-in flow.
                    NotificationCenter.default.post(name: .horizonMediaAuthenticationExpired, object: api)
                }
            }
            let item = AVPlayerItem(asset: source.asset)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.loading = false
                        self.seek(to: self.initialPosition, autoplay: autoplay)
                    case .failed:
                        self.loading = false
                        self.error = item.error?.localizedDescription ?? "Recording playback failed."
                    default: break
                    }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "The recording stopped unexpectedly."
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.error = message
                    self.loading = false
                }
            }
            player.replaceCurrentItem(with: item)
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !HLSBackgroundOwnership.players.contains(ObjectIdentifier(self.player)) else { return }
                        self.stop()
                    }
                }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.player.currentItem === item, time.seconds.isFinite else { return }
                    self.position = time.seconds
                }
            }
            } catch {
                guard self.loadGeneration == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.loading = false
            }
            }
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    func stop() {
        loadGeneration = UUID()
        opening?.cancel()
        opening = nil
        player.currentItem?.asset.cancelLoading()
        source?.close()
        source = nil
        seekGeneration = UUID()
        isSeeking = false
        loading = false
        error = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observation = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.replaceCurrentItem(with: nil)
        position = 0
    }

    func seek(to position: Double, autoplay: Bool? = nil) {
        guard position.isFinite, position >= 0 else {
            error = "The selected recording position is invalid."
            return
        }
        guard let item = player.currentItem else {
            error = "No recording is loaded for seeking."
            return
        }
        let token = UUID()
        seekGeneration = token
        isSeeking = true
        if autoplay == false { player.pause() }
        player.seek(to: CMTime(seconds: position, preferredTimescale: 90000),
            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                Task { @MainActor in
                    guard let self, self.seekGeneration == token, self.player.currentItem === item else { return }
                    self.isSeeking = false
                    if completed && autoplay == true { self.player.play() }
                }
            }
    }
}

extension Notification.Name {
    static let horizonMediaAuthenticationExpired = Notification.Name("Horizon.mediaAuthenticationExpired")
    static let horizonMediaCleanupFailure = Notification.Name("Horizon.mediaCleanupFailure")
}

struct NativeRecordingSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = context.coordinator
        context.coordinator.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var player: AVPlayer?
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            if let player { HLSBackgroundOwnership.players.insert(ObjectIdentifier(player)) }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            if let player { HLSBackgroundOwnership.players.remove(ObjectIdentifier(player)) }
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            if let player { HLSBackgroundOwnership.players.remove(ObjectIdentifier(player)) }
        }
    }
}

@MainActor
enum HLSBackgroundOwnership { static var players: Set<ObjectIdentifier> = [] }
struct RecordingPlaybackView: View {
    let api: HorizonAPI
    let camera: String
    let start: Double
    let end: Double
    var initialTimestamp: Double? = nil
    var mediaURL: URL? = nil
    @StateObject private var playback = RecordingPlayer()
    @State private var retry = 0
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if expanded { Color.black }
                else { NativeRecordingSurface(player: playback.player) }
            }
                .background(.black)
                .overlay {
                    if playback.loading { ProgressView("Opening recording").tint(.white).foregroundStyle(.white) }
                }
                .frame(minHeight: 180)
            if let error = playback.error {
                ErrorNotice(message: error) { retry += 1 }
            }
            HStack {
                Label("Recorded", systemImage: "clock")
                Spacer()
                Button("Expand player", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
        .task(id: "\(camera)-\(start)-\(end)-\(retry)") {
            addressError = nil
            do {
                let url = try mediaURL ?? api.address.playback(camera: camera, start: start, end: end)
                let position = initialTimestamp.flatMap { value in
                    value.isFinite && value >= start && value < end ? value - start : nil
                } ?? 0
                playback.open(url: url, api: api, initialPosition: position)
            } catch {
                playback.stop()
                addressError = error.localizedDescription
            }
        }
        .overlay(alignment: .bottom) {
            if let addressError { ErrorNotice(message: addressError) { retry += 1 } }
        }
        .fullScreenCover(isPresented: $expanded) {
            FoldedRecordingView(player: playback.player, start: start)
        }
        .onDisappear { if !expanded { playback.stop() } }
    }

    @State private var addressError: String?
}

private struct FoldedRecordingView: View {
    let player: AVPlayer
    let start: Double
    @Environment(\.dismiss) private var dismiss
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    @State private var playing = true

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                NativeRecordingSurface(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: foldMode == .flat ? 0 : HorizonPalette.controlRadius))
                    .overlay {
                        if foldMode != .flat {
                            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                                .stroke(HorizonPalette.accent.opacity(0.3), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(foldMode == .flat ? 0 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            } secondary: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HorizonPlaybackModeBadge(foldMode: foldMode)
                        HorizonHero(title: "The moment, replayed.",
                            subtitle: "Recorded \(Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)).",
                            systemImage: "play.rectangle", eyebrow: "Recording")
                        HorizonPlaybackDock(time: Date(timeIntervalSince1970: start),
                            timeTitle: "Recording start",
                            status: playing ? "Playing" : "Paused", playing: playing,
                            back: { skip(-15) },
                            togglePlayback: {
                                if player.rate == 0 { player.play() } else { player.pause() }
                                playing = player.rate != 0
                            },
                            forward: { skip(15) })
                        HorizonCard {
                            HorizonSectionHeader(title: "Native playback", systemImage: "airplay.video")
                            Text("Use the video controls to scrub, expand the player, or continue with AirPlay and Picture in Picture.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabletopReflection(reflection, foldMode: foldMode, player: player)
            }
            .horizonScreen()
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onReceive(player.publisher(for: \.rate)) { playing = $0 != 0 }
        }
    }

    private func skip(_ seconds: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .infinity
        let upper = duration.isFinite ? duration : .infinity
        player.seek(to: CMTime(seconds: min(upper, max(0, current + seconds)), preferredTimescale: 600))
    }
}
