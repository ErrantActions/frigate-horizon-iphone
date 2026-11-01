import SwiftUI
import HorizonCore

@MainActor
struct CameraTourView: View {
    let api: HorizonAPI
    let active: Bool
    var preferredCameraIDs: [String]? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("cameraTourInterval") private var intervalSeconds = 15
    @AppStorage("cameraTourMode") private var mode = CameraTourMode.timed
    @AppStorage("cameraTourFill") private var fillVideo = true
    @StateObject private var motionStream = FrigateMotionStream()
    @State private var playback = CameraTourPlayback()
    @State private var motion = CameraTourMotionSelection()
    @State private var cycling = true
    @State private var failedCameraID: String?
    @State private var visible = false
    @State private var showSettings = false
    @State private var showHUD = true
    @State private var hudRevision = UUID()
    @State private var motionRetry = 0
    @State private var previousIdleTimerSetting: Bool?

    private var cameras: [HorizonCamera] {
        let available = model.cameras.filter(\.isTourCandidate)
        guard let preferredCameraIDs else { return available }
        return CameraTourState(cameraIDs: preferredCameraIDs).cameraIDs.compactMap { id in
            available.first { $0.id == id }
        }
    }
    private var camera: HorizonCamera? { cameras.first { $0.id == playback.current?.cameraID } }
    private var foreground: Bool { active && visible && scenePhase == .active }
    private var seconds: Int { CameraTourTiming.allowedSeconds.contains(intervalSeconds) ? intervalSeconds : 15 }
    private var automationEnabled: Bool { foreground && cycling && !showSettings }
    private var feedEnabled: Bool { automationEnabled && mode == .motion && !cameras.isEmpty }
    private var keepAwake: Bool {
        CameraTourSchedule.keepAwake(active: active, visible: visible,
            foreground: scenePhase == .active, hasCamera: camera != nil)
    }
    private var hudPinned: Bool {
        voiceOver || showSettings || failedCameraID != nil || playback.current?.ready != true
            || playback.handoffRequested || (mode == .motion && cycling && !motionStream.available)
    }
    private var hudVisible: Bool { showHUD || hudPinned }
    private var timedPlan: TimedPlan? {
        guard automationEnabled, mode == .timed, failedCameraID == nil, !playback.handoffRequested,
              cameras.count > 1, let current = playback.current, current.ready, !current.failed else { return nil }
        return TimedPlan(slotID: current.id, seconds: seconds, cameraIDs: cameras.map(\.id))
    }
    private var motionPlan: MotionPlan? {
        guard feedEnabled, motionStream.available, failedCameraID == nil,
              let target = motion.queuedCameraID, let current = playback.current else { return nil }
        return MotionPlan(slotID: current.id, target: target, notBefore: motion.holdUntil)
    }
    private var feedKey: FeedKey {
        FeedKey(account: ObjectIdentifier(api), cameraIDs: cameras.map(\.id),
            enabled: feedEnabled, retry: motionRetry)
    }

    var body: some View {
        ZStack {
            video
            if hudVisible {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .background(.black)
        .statusBarHidden(!hudVisible)
        .persistentSystemOverlays(hudVisible ? .visible : .hidden)
        .sheet(isPresented: $showSettings) {
            CameraTourSettingsView(mode: $mode, intervalSeconds: $intervalSeconds, fillVideo: $fillVideo)
        }
        .onAppear {
            visible = true
            if !CameraTourTiming.allowedSeconds.contains(intervalSeconds) { intervalSeconds = 15 }
            revealHUD()
        }
        .onDisappear {
            visible = false
            cancelPendingWork()
            restoreIdleTimer()
        }
        .onChange(of: cameras.map(\.id), initial: true) { _, ids in
            playback.update(cameraIDs: ids)
            motion.update(allowedCameraIDs: Set(ids))
            motion.discardQueued()
            if let failedCameraID, !ids.contains(failedCameraID) { self.failedCameraID = nil }
            revealHUD()
        }
        .onChange(of: ObjectIdentifier(api)) { _, _ in
            cancelPendingWork()
            playback = CameraTourPlayback(cameraIDs: cameras.map(\.id))
            motion.resetFeed()
            failedCameraID = nil
        }
        .onChange(of: foreground) { _, value in
            if !value { cancelPendingWork() }
            else { revealHUD() }
        }
        .onChange(of: cycling) { _, value in
            if !value { cancelPendingWork() }
            revealHUD()
        }
        .onChange(of: mode) { _, _ in
            cancelPendingWork()
            revealHUD()
        }
        .onChange(of: intervalSeconds) { _, _ in
            playback.cancelIncoming()
            revealHUD()
        }
        .onChange(of: showSettings) { _, value in
            if value { cancelPendingWork() }
            revealHUD()
        }
        .onChange(of: motionStream.available) { _, available in
            if !available {
                motion.discardQueued()
                if mode == .motion { playback.cancelIncoming() }
            }
            revealHUD()
        }
        .onChange(of: keepAwake, initial: true) { _, value in
            if value {
                if previousIdleTimerSetting == nil {
                    previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
                }
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer() }
        }
        .onChange(of: active) { _, value in if !value { closeTour() } }
        .task(id: "\(hudRevision)-\(hudPinned)-\(foreground)") {
            guard foreground, !hudPinned else { return }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled, !hudPinned else { return }
            showHUD = false
        }
        .task(id: timedPlan) {
            guard let plan = timedPlan else { return }
            // Only one incoming stream is attached, at full size behind the outgoing video.
            let lead = min(3, plan.seconds)
            do { try await Task.sleep(for: .seconds(plan.seconds - lead)) }
            catch { return }
            guard !Task.isCancelled, timedPlan == plan, let next = playback.neighbor(offset: 1) else { return }
            playback.preload(next)
            do { try await Task.sleep(for: .seconds(lead)) }
            catch { return }
            guard !Task.isCancelled, timedPlan == plan else { return }
            requestSwitch(to: next)
        }
        .task(id: motionPlan) {
            guard let plan = motionPlan else { return }
            let delay = max(0, plan.notBefore?.timeIntervalSinceNow ?? 0)
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, motionPlan == plan,
                  let target = motion.takeTarget(currentID: playback.current?.cameraID, at: Date()) else { return }
            requestSwitch(to: target)
        }
        .task(id: feedKey) {
            let key = feedKey
            guard !Task.isCancelled else { return }
            guard key.enabled else { motionStream.stop(); return }
            await motionStream.run(api: api, allowedCameraIDs: Set(key.cameraIDs)) { message in
                guard feedKey == key, feedEnabled else { return }
                switch message {
                case .event(let event): motion.receive(event, currentID: playback.current?.cameraID)
                case .snapshot(let snapshot): motion.seed(snapshot)
                case .ignored, .malformed: break
                }
            }
        }
    }

    private var video: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                ForEach(playback.slots) { slot in
                    if let candidate = cameras.first(where: { $0.id == slot.cameraID }) {
                        LiveVideoView(api: api, camera: candidate, stream: candidate.preferredStream(expanded: true),
                            active: foreground, muted: true,
                            onVideoReady: { ready in receivedReadiness(ready, slotID: slot.id) },
                            onPlaybackFailure: { error in receivedFailure(error, slotID: slot.id) },
                            fillVideo: fillVideo, showsVideoHUD: false, expandedQuality: true)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .zIndex(slot.id == playback.current?.id ? 1 : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                if cameras.isEmpty {
                    ContentUnavailableView("No tour cameras", systemImage: "video.slash",
                        description: Text("Enable a dashboard camera with a configured live stream. Only cameras allowed by your account can appear."))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture { revealHUD() }
            .accessibilityAction(named: "Show camera tour controls") { revealHUD() }
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CAMERA TOUR").font(.caption2.weight(.bold)).tracking(1.5)
                    .foregroundStyle(HorizonPalette.accent)
                Text(camera?.name ?? "Horizon").font(.headline).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let position = playback.position {
                Text("\(position) / \(playback.cameraIDs.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            tourButton("Camera tour settings", symbol: "gearshape") { showSettings = true }
            Button("Done", action: closeTour).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Close camera tour")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(HorizonPalette.surface)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tourButton("Previous camera", symbol: "backward.end.fill") { move(by: -1) }
                    .disabled(cameras.count < 2)
                tourButton(cycling ? "Pause camera switching" : "Resume camera switching",
                    symbol: cycling ? "pause.fill" : "play.fill", primary: true) { cycling.toggle() }
                    .disabled(cameras.isEmpty)
                tourButton("Next camera", symbol: "forward.end.fill") { move(by: 1) }
                    .disabled(cameras.count < 2)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(mode == .timed ? "\(seconds) sec cycle" : "Follow motion")
                    Text(fillVideo ? "Fill · may crop" : "Fit · entire frame")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if failedCameraID != nil {
                Button("Retry camera", systemImage: "arrow.clockwise", action: retryCamera)
                    .frame(minHeight: 44).buttonStyle(HorizonButtonStyle(.secondary))
            }
            if mode == .motion, cycling, !motionStream.available {
                Button("Retry motion feed", systemImage: "arrow.clockwise") {
                    cancelPendingWork()
                    motionRetry += 1
                }
                .frame(minHeight: 44).buttonStyle(HorizonButtonStyle(.secondary))
            }
            Text(status).font(.caption).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Label("Muted", systemImage: "speaker.slash")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(HorizonPalette.surface)
    }

    private var status: String {
        if cameras.isEmpty { return "No available live cameras" }
        if let failedCameraID {
            return failedCameraID == playback.current?.cameraID
                ? "Camera unavailable. Retry or choose another camera."
                : "Next camera unavailable; keeping the current camera. Retry or choose another."
        }
        if playback.incoming != nil {
            return playback.handoffRequested
                ? "Waiting for decoded video; keeping the current camera."
                : "Preloading the next camera; keeping the current camera."
        }
        if !cycling { return "Switching paused; this camera stays live." }
        if mode == .motion { return motionStream.status.notice }
        if playback.current?.ready != true { return "Waiting for video before starting the interval." }
        if cameras.count == 1 { return "One camera; live view continues." }
        return "Next camera after \(seconds) seconds of live video."
    }

    private func receivedReadiness(_ ready: Bool, slotID: UUID) {
        let previous = playback.current
        playback.setReady(ready, slotID: slotID)
        if let current = playback.current, current.ready,
           previous?.id != current.id || previous?.ready != true {
            motion.displayed(at: Date())
        }
    }

    private func receivedFailure(_ error: String?, slotID: UUID) {
        guard error != nil, let failed = playback.fail(slotID: slotID) else { return }
        failedCameraID = failed
        revealHUD()
    }

    private func move(by offset: Int) {
        guard let target = playback.neighbor(offset: offset, fromPending: playback.handoffRequested) else { return }
        // A manual choice discards queued activity; the new camera gets its own stable hold.
        motion.discardQueued()
        requestSwitch(to: target)
        revealHUD()
    }

    private func requestSwitch(to cameraID: String) {
        failedCameraID = nil
        playback.request(cameraID)
        if playback.incoming == nil, playback.current?.failed == true {
            failedCameraID = playback.current?.cameraID
        }
        if playback.current?.cameraID == cameraID, playback.current?.ready == true {
            motion.displayed(at: Date())
        }
    }

    private func retryCamera() {
        guard let target = failedCameraID else { return }
        failedCameraID = nil
        if target == playback.current?.cameraID { playback.retryCurrent() }
        else { playback.request(target) }
        revealHUD()
    }

    private func cancelPendingWork() {
        playback.cancelIncoming()
        if failedCameraID == nil, playback.current?.failed == true { failedCameraID = playback.current?.cameraID }
        motion.discardQueued()
        motionStream.stop()
    }

    private func revealHUD() { showHUD = true; hudRevision = UUID() }

    private func tourButton(_ title: String, symbol: String, primary: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.headline)
                .frame(width: 44, height: 44)
                .foregroundStyle(primary ? HorizonPalette.onAccent : HorizonPalette.accent)
                .background(primary ? HorizonPalette.accent : HorizonPalette.raised,
                    in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func restoreIdleTimer() {
        if let previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            self.previousIdleTimerSetting = nil
        }
    }

    private func closeTour() {
        visible = false
        cancelPendingWork()
        restoreIdleTimer()
        dismiss()
    }

    private struct TimedPlan: Hashable { let slotID: UUID; let seconds: Int; let cameraIDs: [String] }
    private struct MotionPlan: Hashable { let slotID: UUID; let target: String; let notBefore: Date? }
    private struct FeedKey: Hashable {
        let account: ObjectIdentifier
        let cameraIDs: [String]
        let enabled: Bool
        let retry: Int
    }
}

@MainActor
private struct CameraTourSettingsView: View {
    @Binding var mode: CameraTourMode
    @Binding var intervalSeconds: Int
    @Binding var fillVideo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var customSeconds = ""
    private var validatedSeconds: Int? { CameraTourTiming.seconds(from: customSeconds) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Switching mode", selection: $mode) {
                        ForEach(CameraTourMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Switching") } footer: {
                    Text(mode == .timed
                        ? "The cycle time starts only after video is ready. The current video stays on screen until the next camera has decoded video."
                        : "Only new detected motion switches cameras, with an 8-second minimum hold. The latest new motion waits its turn. Without a working motion feed, this camera stays live; there is no timed fallback.")
                }
                Section {
                    Text("Saved cycle time: \(intervalSeconds) seconds")
                    TextField("Custom seconds (1–3600)", text: $customSeconds)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Custom camera cycle time in seconds, 1 to 3600")
                    Text("Enter a whole number from 1 to 3600 seconds.")
                        .font(.caption)
                        .foregroundStyle(validatedSeconds == nil ? Color.red : Color.secondary)
                    Button("Save custom cycle time") {
                        if let value = validatedSeconds { intervalSeconds = value }
                    }
                    .disabled(validatedSeconds == nil)
                    .frame(minHeight: 44)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                        ForEach(CameraTourInterval.allCases) { preset in
                            Button(preset.label) {
                                intervalSeconds = preset.rawValue
                                customSeconds = String(preset.rawValue)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Set cycle time to \(preset.rawValue) seconds")
                        }
                    }
                } header: { Text("Adjustable cycle time") } footer: {
                    Text("Saved on this device. Applies to Timed cycle only.")
                }
                Section {
                    Picker("Video sizing", selection: $fillVideo) {
                        Text("Fill screen (may crop)").tag(true)
                        Text("Fit entire frame (may letterbox)").tag(false)
                    }
                } header: { Text("Full-screen video") } footer: {
                    Text("Video extends edge to edge. Controls hide automatically; tap the video to show them. VoiceOver keeps controls visible. Audio is always muted.")
                }
            }
            .navigationTitle("Camera tour settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { customSeconds = String(intervalSeconds) }
        }
    }
}
