import SwiftUI
import HorizonCore

struct LiveView: View {
    let api: HorizonAPI
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var selected: HorizonCamera?
    @State private var selectedHandoff: LiveCameraHandoff?
    @State private var showCameraTour = false
    @State private var preferences = CameraDashboardPreferences()
    @State private var loadedPreferenceScope: String?
    @State private var preferencesReady = false
    @State private var preferenceError: String?
    @State private var showCameraGroups = false
    @State private var cameraGroupScope: String?
    @State private var showIncidentReplay = false
    @State private var showCameraOrder = false
    @State private var cameraOrderScope: String?
    @State private var cameraOrderSnapshot: CameraDashboardPreferences?
    @State private var gridSessions: [String: LivePlaybackSession] = [:]
    @ObservedObject private var groupPiP = LiveGroupPictureInPictureController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HorizonHero(title: "Eyes on everything.",
                        subtitle: "Tap to view. Touch and hold a camera to manage favorites.",
                        systemImage: "video.fill", eyebrow: "Live")
                    HStack {
                        HorizonStatusPill(title: "\(dashboardCameras.count) cameras", systemImage: "square.grid.2x2")
                        Spacer(minLength: 8)
                        Button("Reorder", systemImage: "arrow.up.arrow.down") { openCameraOrder() }
                            .frame(minHeight: 44)
                            .disabled(!canEditPreferences || dashboardCameras.count < 2)
                    }
                    Button {
                        if groupPiP.hasOwner { groupPiP.stop() }
                        else { startGroupPiP() }
                    } label: {
                        Label(groupPiP.hasOwner
                            ? String(localized: "groupPip.stop", defaultValue: "Stop Group PiP")
                            : String(localized: "groupPip.start", defaultValue: "Group PiP"),
                            systemImage: groupPiP.hasOwner ? "pip.exit" : "pip.enter")
                    }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(!active || dashboardCameras.isEmpty)
                    if groupPiP.hasOwner {
                        LiveGroupPiPPreview(controller: groupPiP)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 360)
                            .accessibilityLabel(String(localized: "groupPip.preview", defaultValue: "Live camera group Picture in Picture preview"))
                    }
                    if let group = currentPreferences.selectedGroup {
                        Text(group.name).font(.headline).lineLimit(2)
                    }
                    if let preferenceError {
                        ErrorNotice(message: preferenceError)
                        Button("Reset camera view preferences") { resetPreferences() }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    }
                    if dynamicTypeSize.isAccessibilitySize && currentPreferences.effectiveDensity != .oneColumn {
                        Text("Larger accessibility text uses a single camera column.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LiveCameraGridLayout(density: currentPreferences.effectiveDensity,
                        accessibility: dynamicTypeSize.isAccessibilitySize, layoutDirection: layoutDirection) {
                        ForEach(dashboardCameras) { camera in
                            Button { selectCamera(camera) } label: {
                                LiveVideoView(
                                    api: api, camera: camera,
                                    stream: camera.preferredStream(expanded: false),
                                    active: active && selected == nil && !showCameraTour
                                        && !showCameraGroups && !showIncidentReplay && !showCameraOrder, muted: true,
                                    isFavorite: currentPreferences.favoriteIDs.contains(camera.id),
                                    favoriteAction: canEditPreferences ? {
                                        updatePreferences { try $0.toggleFavorite(camera.id) }
                                    } : nil,
                                    adaptiveQuality: true, participatesInGroupPiP: true,
                                    onSessionAttached: { gridSessions[camera.id] = $0 },
                                    onSessionDetached: { session in
                                        if gridSessions[camera.id] === session { gridSessions.removeValue(forKey: camera.id) }
                                    }
                                )
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .overlay(alignment: .bottomLeading) {
                                    cameraLabel(camera)
                                }
                                .background(HorizonPalette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: HorizonPalette.cardRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: HorizonPalette.cardRadius)
                                        .stroke(HorizonPalette.border, lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.1), radius: 16, x: 0, y: 7)
                                .contentShape(RoundedRectangle(cornerRadius: HorizonPalette.cardRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(camera.name)")
                            .accessibilityValue(currentPreferences.favoriteIDs.contains(camera.id) ? "Favorite" : "")
                            .accessibilityHint("Opens live video. Touch and hold for favorites and reconnect.")
                        }
                    }
                    if dashboardCameras.isEmpty {
                        ContentUnavailableView(currentPreferences.favoritesOnly ? "No available favorites" :
                            (currentPreferences.selectedGroup != nil ? "No available group cameras" :
                                (model.cameras.isEmpty ? "No cameras" : "No dashboard cameras")),
                            systemImage: currentPreferences.favoritesOnly ? "star" : "video.slash",
                            description: Text(model.cameras.isEmpty
                                ? "No cameras are available for this account."
                                : (currentPreferences.favoritesOnly
                                    ? "Show all cameras, then touch and hold a video to add a favorite."
                                    : (currentPreferences.selectedGroup != nil
                                        ? "Choose another group or all dashboard cameras. Camera access is always checked for this account."
                                        : "No enabled cameras are configured to appear on this dashboard. Disabled cameras can still be browsed in Recordings."))))
                        if currentPreferences.favoritesOnly {
                            Button("Show all cameras") { updatePreferences { $0.favoritesOnly = false } }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                        if currentPreferences.selectedGroup != nil {
                            Button("Show all dashboard cameras") {
                                updatePreferences { value in
                                    try value.selectGroup(nil)
                                    value.favoritesOnly = false
                                }
                            }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                    }
                }
                .padding(18)
            }
            .horizonScreen()
            .navigationTitle("Live")
            .task(id: preferenceScope) { loadPreferences() }
            .onChange(of: groupPiP.restorationRevision, initial: true) { _, revision in
                guard revision > 0 else { return }
                selected = nil; showCameraTour = false; showCameraGroups = false
                showIncidentReplay = false; showCameraOrder = false
            }
            .onChange(of: dashboardCameras.map(\.id)) { _, ids in
                if groupPiP.hasOwner, ids != groupPiP.cameraIDs { groupPiP.stop() }
            }
            .onChange(of: model.cameras.filter(\.isLiveDashboardCamera).map(\.id)) { _, ids in
                if let selected, !ids.contains(selected.id) { self.selected = nil }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { dashboardOptions }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Camera tools", systemImage: "ellipsis.circle") {
                        Button("Incident replay", systemImage: "square.split.2x2") { showIncidentReplay = true }
                            .disabled(dashboardCameras.count < 2)
                        Button("Camera tour", systemImage: "play.rectangle.on.rectangle") { showCameraTour = true }
                            .disabled(!dashboardCameras.contains(where: \.isTourCandidate))
                        Button("Refresh cameras", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) {
                if let error = model.error {
                    ErrorNotice(message: error) { Task { await model.refresh() } }.padding()
                }
            }
            .sheet(item: $selected, onDismiss: {
                selectedHandoff?.release(); selectedHandoff = nil
            }) { camera in
                CameraDetailView(api: api, camera: camera, handoff: selectedHandoff)
            }
            .sheet(isPresented: $showCameraOrder, onDismiss: {
                cameraOrderScope = nil
                cameraOrderSnapshot = nil
            }) {
                if let snapshot = cameraOrderSnapshot {
                    LiveCameraOrderView(cameras: model.cameras, preferences: snapshot) { value in
                        guard cameraOrderScope != nil, cameraOrderScope == preferenceScope,
                              currentPreferences == snapshot else {
                            throw HorizonError.message("The account or camera layout changed. Reopen Reorder cameras before saving.")
                        }
                        try persistPreferences(value)
                    }
                    .id(cameraOrderScope)
                }
            }
            .fullScreenCover(isPresented: $showCameraTour) {
                CameraTourView(api: api, active: active, preferredCameraIDs: dashboardCameras.map(\.id))
            }
            .sheet(isPresented: $showCameraGroups, onDismiss: { cameraGroupScope = nil }) {
                SavedCameraGroupsView(cameras: model.cameras, preferences: currentPreferences) { value in
                    guard cameraGroupScope != nil, cameraGroupScope == preferenceScope else {
                        throw HorizonError.message("The account changed while these camera groups were being edited.")
                    }
                    try persistPreferences(value)
                }
                .id(cameraGroupScope)
            }
            .fullScreenCover(isPresented: $showIncidentReplay) {
                IncidentCameraPickerView(api: api, cameras: dashboardCameras)
            }
        }
    }

    private var dashboardCameras: [HorizonCamera] {
        currentPreferences.cameras(from: model.cameras)
    }

    private func selectCamera(_ camera: HorizonCamera) {
        selectedHandoff?.release()
        selectedHandoff = gridSessions[camera.id].flatMap { LiveCameraHandoff(api: api, camera: camera.id, session: $0) }
        selected = camera
    }

    private func startGroupPiP() {
        let cameras = dashboardCameras
        guard cameras.allSatisfy({ gridSessions[$0.id] != nil }) else {
            groupPiP.error = String(localized: "groupPip.waitForVideo", defaultValue: "Wait for every camera in this grid to show live video, resolve any camera errors, then try Group PiP again.")
            return
        }
        groupPiP.start(api: api, cameras: cameras.compactMap { camera in
            gridSessions[camera.id].map { LiveGroupPiPCamera(id: camera.id, name: camera.name, session: $0) }
        })
    }

    private var preferenceScope: String? {
        guard let username = model.profile?.username else { return nil }
        return "liveDashboard.v2." + HorizonAccountScope.key(server: api.address.url.absoluteString, username: username)
    }

    private var legacyPreferenceScope: String? {
        guard let username = model.profile?.username else { return nil }
        return "liveDashboard.v1." + HorizonAccountScope.key(server: api.address.url.absoluteString, username: username)
    }

    private var canEditPreferences: Bool {
        preferencesReady && preferenceScope != nil && loadedPreferenceScope == preferenceScope
    }

    private var currentPreferences: CameraDashboardPreferences {
        canEditPreferences ? preferences : CameraDashboardPreferences()
    }

    private var dashboardOptions: some View {
        Menu {
            Button("Reorder cameras", systemImage: "arrow.up.arrow.down") { openCameraOrder() }
                .disabled(dashboardCameras.count < 2)
            Picker("Camera group", selection: Binding(
                get: { currentPreferences.selectedGroupID },
                set: { value in updatePreferences { try $0.selectGroup(value) } }
            )) {
                Text("All cameras").tag(Optional<UUID>.none)
                ForEach(currentPreferences.groups) { group in Text(group.name).tag(Optional(group.id)) }
            }
            Button("Manage camera groups", systemImage: "square.grid.3x2") {
                cameraGroupScope = preferenceScope
                showCameraGroups = true
            }
            Picker("Camera layout", selection: Binding(
                get: { currentPreferences.effectiveDensity },
                set: { value in updatePreferences { try $0.setCurrentDensity(value) } }
            )) {
                ForEach(CameraDashboardPreferences.Density.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            Toggle("Favorites only", isOn: Binding(
                get: { currentPreferences.favoritesOnly },
                set: { value in updatePreferences { $0.favoritesOnly = value } }
            ))
        } label: {
            Label("Camera view options", systemImage: "square.grid.2x2")
        }
        .disabled(!canEditPreferences)
    }

    private func cameraLabel(_ camera: HorizonCamera) -> some View {
        HStack(spacing: 6) {
            if currentPreferences.favoriteIDs.contains(camera.id) {
                Image(systemName: "star.fill").foregroundStyle(HorizonPalette.accent).accessibilityHidden(true)
            }
            Text(camera.name).lineLimit(1)
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.7), in: Capsule())
        .foregroundStyle(.white).padding(12)
        .allowsHitTesting(false)
    }

    private func loadPreferences() {
        selected = nil
        showCameraTour = false
        showCameraGroups = false
        cameraGroupScope = nil
        showIncidentReplay = false
        showCameraOrder = false
        cameraOrderScope = nil
        cameraOrderSnapshot = nil
        preferencesReady = false
        preferenceError = nil
        preferences = CameraDashboardPreferences()
        loadedPreferenceScope = preferenceScope
        guard let scope = preferenceScope else { return }
        do {
            let stored = UserDefaults.standard.object(forKey: scope)
                ?? legacyPreferenceScope.flatMap { UserDefaults.standard.object(forKey: $0) }
            if let stored {
                guard let data = stored as? Data else {
                    throw HorizonError.message("The saved camera view preferences have an invalid format.")
                }
                preferences = try JSONDecoder().decode(CameraDashboardPreferences.self, from: data)
            }
            preferencesReady = true
        } catch {
            preferenceError = "Camera view preferences could not be loaded: \(error.localizedDescription)"
        }
    }

    private func updatePreferences(_ update: (inout CameraDashboardPreferences) throws -> Void) {
        guard canEditPreferences else {
            preferenceError = "Wait for this account's camera view preferences to load before changing them."
            return
        }
        do {
            var next = preferences
            try update(&next)
            try persistPreferences(next)
            preferenceError = nil
        } catch {
            preferenceError = "Camera view preferences could not be saved: \(error.localizedDescription)"
        }
    }

    private func openCameraOrder() {
        guard canEditPreferences else {
            preferenceError = "Wait for this account's camera layout to load before reordering."
            return
        }
        cameraOrderScope = preferenceScope
        cameraOrderSnapshot = currentPreferences
        showCameraOrder = true
    }

    private func persistPreferences(_ value: CameraDashboardPreferences) throws {
        guard canEditPreferences, let scope = preferenceScope else {
            throw HorizonError.message("The account changed before these camera preferences could be saved.")
        }
        let data = try JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: scope)
        preferences = value
        preferenceError = nil
    }

    private func resetPreferences() {
        guard let scope = preferenceScope else {
            preferenceError = "Sign into an account before resetting its camera view preferences."
            return
        }
        UserDefaults.standard.removeObject(forKey: scope)
        if let legacyPreferenceScope { UserDefaults.standard.removeObject(forKey: legacyPreferenceScope) }
        loadPreferences()
    }
}

@MainActor
struct LiveVideoView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let stream: String?
    let active: Bool
    let muted: Bool
    var reflection: VideoReflection? = nil
    var onVideoReady: ((Bool) -> Void)? = nil
    var onPlaybackFailure: ((String?) -> Void)? = nil
    var fillVideo = false
    var showsVideoHUD = true
    var isFavorite = false
    var favoriteAction: (() -> Void)? = nil
    var showsPiPControl = false
    var adaptiveQuality = false
    var expandedQuality = false
    var maximumQualityHeight: Int? = nil
    var onViewerHeightsChanged: (([Int]) -> Void)? = nil
    var exactViewerHeight: Int? = nil
    var forceRelay = false
    var handoff: LiveCameraHandoff? = nil
    var participatesInGroupPiP = false
    var onSessionAttached: ((LivePlaybackSession) -> Void)? = nil
    var onSessionDetached: ((LivePlaybackSession) -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var attachment = LivePlaybackAttachment()
    @ObservedObject private var pictureInPicture = LivePictureInPictureController.shared
    @ObservedObject private var groupPictureInPicture = LiveGroupPictureInPictureController.shared
    @ObservedObject private var network = LiveNetworkConditions.shared
    private let transport = "webrtc"
    @State private var retry = 0
    @State private var visible = false
    @State private var viewer = UUID()
    @State private var showReauthentication = false

    private var playback: LivePlaybackSession { attachment.session }
    private var rtc: OwnedWebRTCViewer { playback.rtcViewer }
    private var allowedCamera: HorizonCamera? { model.cameras.first { $0.id == camera.id } }
    private var playbackEnabled: Bool { allowedCamera?.settings.enabled == true }
    private var needsReauthentication: Bool { playback.needsReauthentication || rtc.needsReauthentication }
    private var playbackQuality: LivePlaybackQuality? {
        nil
    }
    private var effectiveStream: String? { playbackQuality?.requestedStream }
    private var qualityPlan: LiveAdaptiveQualityPlan? { playbackQuality?.adaptivePlan }
    private var viewingConfiguration: ViewerConfiguration? {
        guard playbackEnabled else { return nil }
        let fullCap = network.restricted ? min(maximumQualityHeight ?? 720, 720) : maximumQualityHeight
        let cap = expandedQuality ? fullCap : (network.restricted ? 720 : nil)
        return ViewerConfiguration(grid: !expandedQuality, maximumHeight: cap,
            exactHeight: expandedQuality ? exactViewerHeight : nil, audio: expandedQuality,
            dataSaver: network.restricted, forceRelay: expandedQuality && forceRelay)
    }

    var body: some View {
        ZStack {
            Color.black
            if playbackEnabled {
                NativeRTCViewerSurface(track: rtc.videoTrack, fillVideo: fillVideo,
                    pipLayer: showsPiPControl ? rtc.pipRenderer.displayLayer : nil).id(ObjectIdentifier(playback))
                if resolution == nil, let handoff {
                    LiveCameraHandoffSurface(handoff: handoff, fillVideo: fillVideo)
                }
            }
            if !playbackEnabled {
                Label("Camera disabled", systemImage: "video.slash")
                    .foregroundStyle(.white)
            } else if effectiveStream == nil && viewingConfiguration == nil {
                Text("Choose a live stream in the camera view.")
                    .font(.callout).foregroundStyle(.white).padding()
            } else if let error = playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(5)
                }
                .foregroundStyle(.white).padding()
                .accessibilityLabel(error)
            } else if resolution == nil {
                if playback.paused {
                    Text("Paused — reconnect to resume").font(.callout).foregroundStyle(.white).padding()
                } else {
                    ProgressView(active && scenePhase == .active
                        ? playback.status : "Paused")
                        .tint(.white).foregroundStyle(.white)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsPiPControl, resolution != nil || playbackError != nil {
                ShareLink(item: rtc.metrics) {
                    Label("Playback metrics", systemImage: "waveform.path.ecg")
                        .font(.caption).padding(8).background(.black.opacity(0.75), in: Capsule())
                }
                .foregroundStyle(.white).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsPiPControl, playbackEnabled, effectiveStream != nil || viewingConfiguration != nil {
                Button {
                    if pictureInPicture.owns(playback), pictureInPicture.isStarting {
                        pictureInPicture.stop()
                    } else if pictureInPicture.isPlaying(playback) {
                        pictureInPicture.returnToInline(playback)
                    } else {
                        pictureInPicture.start(playback)
                    }
                } label: {
                    Image(systemName: pictureInPicture.isPlaying(playback) ? "pip.exit" : "pip.enter")
                        .font(.title3).frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(reduceTransparency ? Color.black : Color.black.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pictureInPicture.owns(playback) && pictureInPicture.isStarting
                    ? "Cancel Picture in Picture"
                    : (pictureInPicture.isPlaying(playback) ? "Return live video to app" : "Start live Picture in Picture"))
                .padding(8)
            }
        }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
            ShareLink(item: rtc.metrics) {
                Label("Share playback metrics", systemImage: "waveform.path.ecg")
            }
            if let favoriteAction {
                Button(isFavorite ? "Remove from favorites" : "Add to favorites",
                    systemImage: isFavorite ? "star.slash" : "star") { favoriteAction() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if needsReauthentication, model.profile != nil {
                Button("Sign in again", systemImage: "person.crop.circle.badge.checkmark") {
                    showReauthentication = true
                }
                .buttonStyle(HorizonButtonStyle(.secondary)).padding(8)
            } else if playbackError != nil || playback.paused {
                Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
                    .buttonStyle(HorizonButtonStyle(.secondary)).padding(8)
            } else if let notice = playback.compatibilityNotice {
                Text(notice).font(.caption2).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.75), in: Capsule()).padding(8)
            }
        }
        .alert("Live Picture in Picture", isPresented: Binding(
            get: { playback.pictureInPictureError != nil },
            set: { if !$0 { playback.pictureInPictureError = nil } }
        )) {
            Button("OK", role: .cancel) { playback.pictureInPictureError = nil }
        } message: {
            Text(playback.pictureInPictureError ?? "")
        }
        .onAppear { visible = true; playback.attach(viewer); onSessionAttached?(playback) }
        .onDisappear {
            visible = false
            playback.detach(viewer)
            onSessionDetached?(playback)
            if !playback.hasInlineViewer { reflection?.clearSource() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.deactivateInlineViewer(viewer) }
        }
        .onChange(of: active) { _, value in
            if !value { playback.deactivateInlineViewer(viewer) }
        }
        .onChange(of: muted, initial: true) { _, value in rtc.muted = value }
        .onChange(of: resolution != nil, initial: true) { _, value in
            if value { handoff?.release() }
            onVideoReady?(value)
        }
        .onChange(of: playbackError, initial: true) { _, value in onPlaybackFailure?(value) }
        .onChange(of: needsReauthentication, initial: true) { _, needed in
            if needed { model.reportSessionExpiry(from: api) }
        }
        .sheet(isPresented: $showReauthentication) {
            if let username = model.profile?.username { ReauthenticateView(username: username) }
        }
        .onReceive(rtc.$resolution) { resolution in
            if resolution != nil { reflection?.follow(realtime: rtc.frameObserver) }
            else { reflection?.clearSource() }
        }
        .onReceive(rtc.$advertisedHeights) { heights in onViewerHeightsChanged?(heights) }
        .task(id: "\(ObjectIdentifier(api))-\(camera.id)-\(playbackEnabled)-\(maximumQualityHeight ?? 0)-\(exactViewerHeight ?? 0)-\(forceRelay)-\(network.restricted)-\(expandedQuality)-\(active)-\(visible)-\(scenePhase == .active)-\(retry)-\(muted)-\(pictureInPicture.scopeRevision)-\(groupPictureInPicture.scopeRevision)") {
            if participatesInGroupPiP { attachment.adoptGroupSession(api: api, cameraID: camera.id, viewer: viewer) }
            attachment.adoptRetainedSession(
                api: api, cameraID: camera.id, stream: effectiveStream, transport: transport,
                enabled: showsPiPControl, viewer: viewer
            )
            playback.configure(
                api: api, cameraID: camera.id, stream: effectiveStream, transport: transport,
                muted: muted, cameraEnabled: playbackEnabled,
                active: active, visible: visible, foreground: scenePhase == .active,
                viewer: viewer, iceServers: model.iceServers, adaptiveQuality: qualityPlan,
                viewerConfiguration: viewingConfiguration
            )
            onSessionAttached?(playback)
            if active, visible, scenePhase == .active {
                reflection?.follow(realtime: rtc.frameObserver)
            } else {
                reflection?.clearSource()
            }
        }
    }

    private var resolution: CGSize? { playback.resolution }
    private var playbackError: String? { playback.error }

    private func reconnect() {
        reflection?.clearSource()
        playback.reconnect()
        retry += 1
    }
}

struct CameraDetailView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let handoff: LiveCameraHandoff?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stream = ""
    @State private var muted = true
    @State private var retry = UUID()
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    private let transport = "webrtc"
    @State private var showQuickEvidence = false
    @State private var automaticMaximumHeight = 0
    @State private var history: CameraHistoryContext?
    @State private var showHistory = false
    @State private var historyError: String?
    @State private var viewerHeights: [Int] = []
    @State private var pinnedHeight = 0
    @State private var forceRelay = false

    init(api: HorizonAPI, camera: HorizonCamera, handoff: LiveCameraHandoff? = nil) {
        self.api = api
        self.camera = camera
        self.handoff = handoff
        let retained = LivePictureInPictureController.shared.retainedSelection(api: api, cameraID: camera.id)
        let configuration = LivePictureInPictureController.shared.retainedViewerConfiguration(api: api, cameraID: camera.id)
        _stream = State(initialValue: "")
        _automaticMaximumHeight = State(initialValue: configuration?.maximumHeight ?? 0)
        _pinnedHeight = State(initialValue: configuration?.exactHeight ?? 0)
        _forceRelay = State(initialValue: configuration?.forceRelay ?? false)
        _muted = State(initialValue: retained?.muted ?? true)
    }

    private var allowed: Bool {
        model.api === api && model.cameras.contains { $0.id == camera.id && $0.settings.enabled }
    }
    private var currentCamera: HorizonCamera { model.cameras.first { $0.id == camera.id } ?? camera }
    private var maximumHeight: Int? { automaticMaximumHeight == 0 ? nil : automaticMaximumHeight }

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                LiveVideoView(
                    api: api, camera: currentCamera, stream: stream.isEmpty
                        ? currentCamera.preferredStream(expanded: true, maximumHeight: maximumHeight) : stream,
                    active: allowed && !showQuickEvidence && !showHistory, muted: muted, reflection: reflection,
                    showsPiPControl: true, adaptiveQuality: stream.isEmpty, expandedQuality: true,
                    maximumQualityHeight: maximumHeight,
                    onViewerHeightsChanged: { if !$0.isEmpty { viewerHeights = $0 } },
                    exactViewerHeight: pinnedHeight == 0 ? nil : pinnedHeight, forceRelay: forceRelay,
                    handoff: handoff
                )
                .id(retry)
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
                        HStack {
                            Toggle("Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2", isOn: $muted)
                                .toggleStyle(.button).frame(minHeight: 44)
                            Spacer()
                            Button("Recordings", systemImage: "clock.arrow.circlepath") { openHistory() }
                                .frame(minHeight: 44).disabled(!allowed)
                        }
                        if let historyError { ErrorNotice(message: historyError) }
                        CameraControlsView(api: api, camera: camera,
                            active: allowed && scenePhase == .active && !showQuickEvidence && !showHistory)
                        HorizonCard {
                            DisclosureGroup("Quality and connection") {
                            LabeledContent("Transport", value: "Native WebRTC")
                            Picker("Quality", selection: $pinnedHeight) {
                                Text("Auto").tag(0)
                                ForEach(viewerHeights, id: \.self) { height in
                                    Text(height == 2160 ? "4K (2160p)" : "\(height)p").tag(height)
                                }
                                if pinnedHeight != 0, !viewerHeights.contains(pinnedHeight) {
                                    Text("\(pinnedHeight)p (unavailable)").tag(pinnedHeight)
                                }
                            }
                            let heights = viewerHeights
                            if pinnedHeight == 0 {
                                Menu {
                                    Picker("Automatic maximum", selection: $automaticMaximumHeight) {
                                        Text("No display cap").tag(0)
                                        ForEach(heights.filter { [720,1080,2160].contains($0) }, id: \.self) { height in
                                            Text("\(height)p").tag(height)
                                        }
                                        if automaticMaximumHeight != 0,
                                           !heights.contains(automaticMaximumHeight) {
                                            Text("\(automaticMaximumHeight)p (unavailable)").tag(automaticMaximumHeight)
                                        }
                                    }
                                } label: {
                                    controlLabel("Automatic maximum", value: automaticMaximumHeight == 0
                                        ? "Default" : "\(automaticMaximumHeight)p")
                                }
                            }
                            Text("Auto uses the server's WebRTC bandwidth adaptation. Pins use this session's offered ladder. Data Saver detail uses 720p, never a grid-only rung. Original recordings and downloads do not change.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Force relay (diagnostic test)", isOn: $forceRelay)
                            Divider()
                            Button("Reconnect", systemImage: "arrow.clockwise") {
                                LivePictureInPictureController.shared.stop()
                                retry = UUID()
                            }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                            }
                        }
                        HorizonCard {
                            DisclosureGroup("Camera information") {
                            LabeledContent("Camera", value: camera.name)
                            LabeledContent("Transport", value: "Native WebRTC")
                            HorizonStatusPill(title: camera.settings.enabled ? "Camera enabled" : "Camera disabled",
                                systemImage: camera.settings.enabled ? "checkmark.circle" : "video.slash",
                                tint: camera.settings.enabled ? HorizonPalette.accent : HorizonPalette.warm)
                            Text("Discovery and signaling use your authenticated HTTPS server. Media uses direct ICE or session-scoped authenticated TURN. Missing backend support shows an upgrade state; no alternate viewing transport is opened.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(18)
                }
                .tabletopReflection(reflection, foldMode: foldMode)
            }
            .horizonScreen()
            .navigationTitle(camera.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save quick evidence", systemImage: "square.and.arrow.down") {
                        showQuickEvidence = true
                    }
                    .disabled(!model.cameras.contains(where: { $0.id == camera.id }))
                }
            }
            .onAppear {
                if let retained = LivePictureInPictureController.shared.retainedSelection(api: api, cameraID: camera.id) {
                    if let configuration = LivePictureInPictureController.shared.retainedViewerConfiguration(api: api, cameraID: camera.id) {
                        stream = ""
                        automaticMaximumHeight = configuration.maximumHeight ?? 0
                    } else { stream = retained.stream }
                    muted = retained.muted
                }
            }
            .sheet(isPresented: $showQuickEvidence) { QuickEvidenceView(api: api, camera: camera) }
            .onDisappear { handoff?.release() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { handoff?.release() } }
            .onChange(of: allowed) { _, allowed in if !allowed { handoff?.release() } }
            .onChange(of: showHistory) { _, showing in if showing { handoff?.release() } }
            .onChange(of: showQuickEvidence) { _, showing in if showing { handoff?.release() } }
            .fullScreenCover(isPresented: $showHistory) {
                if let history {
                    RecordingsView(api: api, context: history, standalone: true)
                }
            }
        }
    }

    private func openHistory() {
        do {
            let now = Date()
            history = try CameraHistoryContext(camera: camera.id, at: now,
                allowedCameraIDs: Set(model.cameras.map(\.id)), now: now)
            historyError = nil
            showHistory = true
        } catch { historyError = error.localizedDescription }
    }

    private func controlLabel(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
