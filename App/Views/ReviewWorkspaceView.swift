import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class ReviewPlaybackStore: ObservableObject {
    let playback = RecordingPlayer()
    @Published private(set) var coverage: RecordingCoverage?
    @Published private(set) var range: ReviewTimeRange?
    @Published private(set) var motion: [MotionSample] = []
    @Published private(set) var events: [ReviewSegment] = []
    @Published private(set) var loading = false
    @Published private(set) var missingRecording = false
    @Published private(set) var intendsToPlay = true
    @Published var error: String?
    @Published private(set) var metadataErrors: [String] = []
    var metadataError: String? { metadataErrors.isEmpty ? nil : metadataErrors.joined(separator: "\n") }
    private var generation = UUID()
    private var clipGeneration = UUID()
    private var loadedCamera: String?

    func prepare(api: HorizonAPI, camera: String, day: Date, timestamp: Double, autoplay: Bool = true) async {
        let token = UUID()
        generation = token
        intendsToPlay = autoplay
        clipGeneration = UUID()
        playback.stop()
        loading = true
        error = nil
        missingRecording = false
        loadedCamera = nil
        coverage = nil
        motion = []
        events = []
        metadataErrors = []
        let range: ReviewTimeRange
        do {
            if let existing = self.range { range = existing }
            else { range = try ReviewTimeRange(day: day) }
            self.range = range
        } catch {
            self.error = error.localizedDescription
            loading = false
            return
        }
        let query = [
            URLQueryItem(name: "after", value: String(range.start)),
            URLQueryItem(name: "before", value: String(range.end)),
        ]
        do {
            let result: RecordingCoverage = try await api.get([camera, "recordings", "coverage"], query: query)
            guard !Task.isCancelled, generation == token else { return }
            coverage = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Recording coverage: \(error.localizedDescription)")
        }
        await seek(api: api, camera: camera, timestamp: timestamp, autoplay: autoplay)
        guard !Task.isCancelled, generation == token else { return }
        async let motionRequest: [MotionSample] = api.get(["review", "activity", "motion"], query: query + [
            URLQueryItem(name: "cameras", value: camera), URLQueryItem(name: "scale", value: "15"),
        ])
        async let eventRequest: [ReviewSegment] = api.get(["review"], query: query + [
            URLQueryItem(name: "cameras", value: camera), URLQueryItem(name: "limit", value: "1000"),
        ])
        do {
            let result = try await motionRequest
            guard !Task.isCancelled, generation == token else { return }
            motion = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Motion timeline: \(error.localizedDescription)")
        }
        do {
            let result = try await eventRequest
            guard !Task.isCancelled, generation == token else { return }
            events = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Activity timeline: \(error.localizedDescription)")
        }
    }

    func seek(api: HorizonAPI, camera: String, timestamp: Double, autoplay: Bool = true) async {
        guard timestamp.isFinite, let range else {
            error = "The review timeline is not ready for this recording time."
            return
        }
        let token = UUID()
        clipGeneration = token
        intendsToPlay = autoplay
        error = nil
        missingRecording = false
        if loadedCamera == camera, playback.loading || playback.player.currentItem != nil {
            playback.seekToCatalog(timestamp, autoplay: autoplay)
            return
        }
        loading = true
        defer { if clipGeneration == token { loading = false } }
        guard timestamp >= range.start, timestamp < range.end else { missingRecording = true; return }
        if let coverage, !coverage.contains(timestamp) {
            missingRecording = true
            playback.setPlaying(false)
            return
        }
        loadedCamera = camera
        playback.open(selection: .init(camera: camera, identity: .timeRange(start: range.start, end: range.end)),
            api: api, sourceRange: range.start...range.end, startTimestamp: timestamp, autoplay: autoplay)
    }

    func stop() {
        generation = UUID()
        clipGeneration = UUID()
        playback.stop()
    }

    func leave() {
        generation = UUID()
        clipGeneration = UUID()
        playback.releaseInline()
    }
}

struct ReviewWorkspaceView: View {
    let api: HorizonAPI
    let cameras: [HorizonCamera]
    let day: Date
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ReviewPlaybackStore()
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    @State private var camera: String
    @State private var timestamp: Double
    @State private var previewTimestamp: Double
    @State private var scrubbing = false
    @State private var seekRequest: ReviewSeekRequest?
    @State private var timelineScale = ReviewTimelineScale.thirtySeconds
    @State private var playing = true
    @State private var resumeAfterScrub: Bool?
    @State private var resumeAfterCameraChange = true
    @State private var showExport = false
    @State private var showBookmarks = false
    @State private var showQuickEvidence = false
    @State private var showIncidentReplay = false
    @State private var resumeAfterTool = false

    private var allowedCameras: [HorizonCamera] {
        let allowed = Set(model.cameras.map(\.id))
        return cameras.filter { allowed.contains($0.id) }
    }

    private var accessKey: String {
        "\(model.api.map { String(describing: ObjectIdentifier($0)) } ?? "")-\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-\(model.cameras.map(\.id).joined(separator: ","))"
    }

    init(api: HorizonAPI, initialReview: ReviewSegment,
         cameras: [HorizonCamera], day: Date) {
        self.init(api: api, camera: initialReview.camera, timestamp: initialReview.startTime, cameras: cameras, day: day)
    }

    init(api: HorizonAPI, camera: String, timestamp: Double,
         cameras: [HorizonCamera], day: Date) {
        self.api = api
        self.cameras = cameras
        self.day = Calendar.current.startOfDay(for: day)
        _camera = State(initialValue: camera)
        let initialTime = max(Calendar.current.startOfDay(for: day).timeIntervalSince1970, timestamp)
        _timestamp = State(initialValue: initialTime)
        _previewTimestamp = State(initialValue: initialTime)
    }

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                ReviewPlayerPane(playback: store.playback, loading: store.loading,
                    missing: store.missingRecording, error: store.error) {
                    requestSeek(timestamp)
                }
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
                controlPlane
                .tabletopReflection(reflection, foldMode: foldMode, player: store.playback.player)
            }
            .horizonScreen()
            .navigationTitle(cameras.first { $0.id == camera }?.name ?? camera)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export selected time", systemImage: "film.stack") { showExport = true }
                        .disabled(store.range == nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Bookmarks", systemImage: "bookmark") { showBookmarks = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("Evidence and incident tools", systemImage: "square.stack.3d.up") {
                        Button("Save evidence around this time", systemImage: "square.and.arrow.down") {
                            pauseForTool()
                            showQuickEvidence = true
                        }
                        .disabled(!allowedCameras.contains(where: { $0.id == camera }))
                        Button("Synchronized incident replay", systemImage: "square.split.2x2") {
                            pauseForTool()
                            LivePictureInPictureController.shared.stop()
                            showIncidentReplay = true
                        }
                        .disabled(allowedCameras.count < 2)
                    }
                }
            }
            .task(id: "\(camera)-\(accessKey)-\(scenePhase == .active)") {
                guard scenePhase == .active else { store.leave(); return }
                guard model.api === api, allowedCameras.contains(where: { $0.id == camera }) else {
                    store.stop()
                    store.error = "This camera is no longer available to the current account."
                    return
                }
                if let range = store.range, store.playback.reattachPiP(
                    selection: .init(camera: camera, identity: .timeRange(start: range.start, end: range.end)), api: api) {
                    return
                }
                await store.prepare(api: api, camera: camera, day: day, timestamp: timestamp,
                    autoplay: resumeAfterCameraChange)
            }
            .task(id: seekRequest) {
                guard let seekRequest else { return }
                await store.seek(api: api, camera: camera, timestamp: seekRequest.timestamp,
                    autoplay: seekRequest.autoplay)
            }
            .onReceive(store.playback.$position) { position in
                guard !scrubbing, !store.loading, !store.playback.isSeeking,
                      store.playback.player.currentItem != nil else { return }
                timestamp = position
            }
            .onReceive(store.playback.player.publisher(for: \.timeControlStatus)) { playing = $0 != .paused }
            .onDisappear { store.leave() }
            .sheet(isPresented: $showExport) {
                CreateExportView(api: api, initialCamera: camera,
                    initialStart: Date(timeIntervalSince1970: max(day.timeIntervalSince1970, timestamp - 30)),
                    initialEnd: Date(timeIntervalSince1970: min(timestamp + 30, store.range?.end ?? timestamp))) {}
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksView(api: api, camera: camera, initialTimestamp: timestamp)
            }
            .sheet(isPresented: $showQuickEvidence, onDismiss: resumeAfterTools) {
                if let value = allowedCameras.first(where: { $0.id == camera }) {
                    QuickEvidenceView(api: api, camera: value, anchorDate: Date(timeIntervalSince1970: timestamp))
                }
            }
            .fullScreenCover(isPresented: $showIncidentReplay, onDismiss: resumeAfterTools) {
                IncidentCameraPickerView(api: api, cameras: allowedCameras,
                    initialDate: Date(timeIntervalSince1970: timestamp))
            }
        }
    }

    private func pauseForTool() {
        resumeAfterTool = playbackRequested
        resumeAfterCameraChange = resumeAfterTool
        store.playback.player.pause()
    }

    private func resumeAfterTools() {
        guard scenePhase == .active, model.api === api,
              allowedCameras.contains(where: { $0.id == camera }) else { return }
        guard let range = store.range else {
            store.error = "The recording timeline must finish loading before playback can resume."
            return
        }
        do {
            seekRequest = try ReviewSeekRequest(timestamp: timestamp, autoplay: resumeAfterTool, range: range)
        } catch { store.error = error.localizedDescription }
    }

    private var controlPlane: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    playbackControls(compact: true)
                    RecordedPlaybackControls(owner: store.playback)
                    timelinePane
                        .frame(height: dynamicTypeSize.isAccessibilitySize
                            ? 176 : max(112, min(140, geometry.size.height * 0.42)))
                    if let metadataError = store.metadataError {
                        Label(metadataError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(HorizonPalette.warm)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    cameraPreviews(availableWidth: max(0, geometry.size.width - 24))
                    if store.events.count == 1000 {
                        Text("Showing the latest 1,000 activity markers for this camera and day.")
                            .font(.caption2).foregroundStyle(HorizonPalette.warm)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var timelinePane: some View {
        Group {
            if let range = store.range {
                NativeReviewTimeline(
                    range: range, time: $timestamp, scrubbing: $scrubbing, scale: timelineScale,
                    coverage: store.coverage?.spans,
                    events: store.events, motion: store.motion,
                    beginScrub: {
                        resumeAfterScrub = playbackRequested
                        store.playback.player.pause()
                    },
                    commit: { requestSeek($0) }
                )
                .overlay(alignment: .bottomLeading) {
                    timelineZoomButton(inward: false).padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    timelineZoomButton(inward: true).padding(4)
                }
                .overlay(alignment: .bottom) {
                    timelineScaleMenu.padding(.bottom, 4)
                }
            } else if store.error != nil {
                Label("Timeline unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(HorizonPalette.warm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Preparing timeline")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HorizonPalette.raised, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                .stroke(HorizonPalette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
    }

    private func playbackControls(compact: Bool) -> some View {
        HorizonPlaybackDock(time: Date(timeIntervalSince1970: timestamp),
            status: playbackStatus, playing: playing,
            playEnabled: !(store.loading || store.missingRecording || store.error != nil || store.playback.player.currentItem == nil),
            compact: compact,
            back: { requestSeek(timestamp - 15) },
            togglePlayback: {
                if playbackRequested { store.playback.player.pause() }
                else { store.playback.player.play() }
            },
            forward: { requestSeek(timestamp + 15) })
    }

    private var playbackStatus: String {
        if store.error != nil || store.playback.error != nil { return "Playback error" }
        if store.loading || store.playback.loading { return "Opening" }
        if store.missingRecording { return "No recording" }
        if scrubbing { return "Scrubbing" }
        if store.playback.isSeeking { return "Seeking" }
        return playing ? "Playing" : "Paused"
    }

    private func timelineZoomButton(inward: Bool) -> some View {
        let next = inward ? timelineScale.finer : timelineScale.coarser
        return Button {
            if let next { timelineScale = next }
        } label: {
            Image(systemName: inward ? "plus.magnifyingglass" : "minus.magnifyingglass")
                .font(.headline)
                .frame(width: 44, height: 44)
                .foregroundStyle(HorizonPalette.accent)
                .background(HorizonPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(scrubbing || next == nil)
        .opacity(next == nil ? 0.4 : 1)
        .accessibilityLabel(inward ? "Zoom timeline in" : "Zoom timeline out")
    }

    private var timelineScaleMenu: some View {
        Menu {
            Picker("Time per tick", selection: $timelineScale) {
                ForEach(ReviewTimelineScale.allCases) { scale in
                    Text("\(scale.label) per tick").tag(scale)
                }
            }
        } label: {
            Label("\(timelineScale.label) per tick", systemImage: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(HorizonPalette.surface, in: Capsule())
        }
        .disabled(scrubbing)
        .accessibilityLabel("Timeline time per tick")
        .accessibilityValue(timelineScale.label)
    }

    private func cameraPreviews(availableWidth: CGFloat) -> some View {
        let minimumWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 156 : 100
        let count = min(max(1, cameras.count), max(1, Int((availableWidth + 8) / (minimumWidth + 8))))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: count), spacing: 8) {
                ForEach(cameras) { candidate in
                    Button {
                        guard candidate.id != camera else { return }
                        resumeAfterCameraChange = resumeAfterScrub ?? playbackRequested
                        resumeAfterScrub = nil
                        previewTimestamp = timestamp
                        seekRequest = nil
                        camera = candidate.id
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            RecordedCameraPreview(api: api, camera: candidate.id, timestamp: previewTimestamp)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            Label(candidate.name, systemImage: candidate.id == camera ? "checkmark.circle.fill" : "video")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                                .stroke(candidate.id == camera ? HorizonPalette.accent : HorizonPalette.border,
                                    lineWidth: candidate.id == camera ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(candidate.name) at the selected recording time")
                    .accessibilityHint("Recorded preview. Switching cameras keeps the selected time.")
                    .accessibilityAddTraits(candidate.id == camera ? [.isSelected] : [])
                }
        }
    }

    private var playbackRequested: Bool {
        if store.loading || store.missingRecording || store.error != nil || store.playback.error != nil {
            return store.intendsToPlay
        }
        return store.playback.player.timeControlStatus != .paused
    }

    private func requestSeek(_ time: Double) {
        guard let range = store.range else {
            store.error = "The review timeline is not ready yet."
            return
        }
        do {
            let request = try ReviewSeekRequest(timestamp: time,
                autoplay: resumeAfterScrub ?? playbackRequested, range: range)
            resumeAfterScrub = nil
            timestamp = request.timestamp
            previewTimestamp = request.timestamp
            seekRequest = request
        } catch {
            store.error = error.localizedDescription
        }
    }
}

private struct ReviewPlayerPane: View {
    @ObservedObject var playback: RecordingPlayer
    let loading: Bool
    let missing: Bool
    let error: String?
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if missing {
                ContentUnavailableView("No recording at this time", systemImage: "video.slash",
                    description: Text("Scrub to a recorded section or choose another camera."))
                    .foregroundStyle(.white)
            } else {
                NativeRecordingSurface(owner: playback)
                if loading || playback.loading {
                    ProgressView("Opening recording").tint(.white).foregroundStyle(.white)
                }
            }
            if let message = error ?? playback.error {
                VStack { Spacer(); ErrorNotice(message: message, retry: retry).background(.black.opacity(0.85)) }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct RecordedCameraPreview: View {
    let api: HorizonAPI
    let camera: String
    let timestamp: Double
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let error {
                VStack(spacing: 4) {
                    Image(systemName: "video.slash")
                    Text(error).font(.caption2).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.white).padding(5)
            } else { ProgressView().tint(.white) }
        }
        .task(id: "\(camera)-\(timestamp)") {
            image = nil
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(350))
                let url = api.address.endpoint(
                    ["api", camera, "recordings", String(timestamp), "snapshot.jpg"],
                    query: [URLQueryItem(name: "height", value: "180")]
                )
                let data = try await api.image(url)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw HorizonError.unexpectedResponse }
                image = decoded
            } catch HorizonError.http(404) {
                if !Task.isCancelled { error = "No recording" }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
