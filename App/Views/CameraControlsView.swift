import SwiftUI
import UIKit
import HorizonCore

struct CameraControlsView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controls = CameraControlsController()
    @StateObject private var talkback = CameraTalkbackController()
    @ObservedObject private var talkbackCleanup = CameraTalkbackCleanupStore.shared
    @State private var refresh = UUID()
    @State private var selectedPreset = ""
    @State private var loadedKey: LoadKey?

    private struct AccessContext: Equatable {
        let client: ObjectIdentifier?
        let username: String?
        let role: String?
        let permissions: [String]
        let allowed: [String]
        let enabled: Bool
        let active: Bool
    }

    private struct LoadKey: Equatable {
        let access: AccessContext
        let cameraID: String
        let refresh: UUID
    }

    private var access: AccessContext {
        AccessContext(client: model.api.map(ObjectIdentifier.init),
            username: model.profile?.username, role: model.profile?.role,
            permissions: model.profile.flatMap { model.configuration?.auth?.roles[$0.role] }?.sorted() ?? [],
            allowed: model.profile?.allowedCameras.sorted() ?? [],
            enabled: model.cameras.contains { $0.id == camera.id && $0.settings.enabled },
            active: active && scenePhase == .active)
    }

    private var available: Bool {
        access.active && access.enabled && access.client == ObjectIdentifier(api) &&
            access.username != nil && access.allowed.contains(camera.id)
    }

    private var loadKey: LoadKey { LoadKey(access: access, cameraID: camera.id, refresh: refresh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Camera controls", systemImage: "slider.horizontal.3")
                .font(.headline)
            if !available {
                Text("Camera controls are unavailable while this camera, account, or screen is inactive.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if controls.isLoading {
                ProgressView("Checking camera capabilities…")
            } else if let capabilities = controls.capabilities {
                ptz(capabilities)
                Divider()
                Text("Talkback is unsupported in this HLS-only release. Authorized PTZ remains available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controls.isStopping {
                ProgressView("Confirming PTZ stop…")
            }
            if let error = controls.error {
                ErrorNotice(message: error)
            }
            if let error = talkback.error {
                ErrorNotice(message: error)
            }
            if let error = talkbackCleanup.error {
                ErrorNotice(message: error)
            }
            if let status = talkbackCleanup.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if available {
                Button("Reload controls", systemImage: "arrow.clockwise") {
                    tearDown()
                    talkback.clearError()
                    refresh = UUID()
                }
                .disabled(controls.isLoading)
                .font(.callout)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .task(id: loadKey) {
            talkback.stop()
            talkback.clearError()
            guard available else { tearDown(); return }
            loadedKey = loadKey
            await controls.run(api: api, cameraID: camera.id)
        }
        .onChange(of: loadKey) { _, key in
            if loadedKey != key { tearDown() }
        }
        .onReceive(model.$api) { client in
            if client !== api { tearDown() }
        }
        .onReceive(model.$profile) { profile in
            if profile?.username != access.username || profile?.role != access.role ||
                (profile?.allowedCameras.sorted() ?? []) != access.allowed {
                tearDown()
            }
        }
        .onReceive(model.$configuration) { configuration in
            let permissions = model.profile.flatMap { configuration?.auth?.roles[$0.role] }?.sorted() ?? []
            if configuration?.cameras[camera.id]?.enabled != true || permissions != access.permissions {
                tearDown()
            }
        }
        .onReceive(controls.$capabilities) { capabilities in
            if capabilities?.talkback.supported != true { talkback.stop() }
            let presets = capabilities?.ptz.presets ?? []
            if !presets.contains(where: { $0.id == selectedPreset }) {
                selectedPreset = presets.first?.id ?? ""
            }
        }
        .onReceive(controls.$error) { error in
            if error != nil { talkback.stop() }
        }
        .onReceive(talkback.$error) { error in
            if error != nil { controls.stopMotion() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            tearDown()
        }
        .onDisappear { tearDown() }
    }

    @ViewBuilder
    private func ptz(_ capabilities: CameraControlCapabilities) -> some View {
        if capabilities.ptz.supported &&
            (capabilities.ptz.panTilt || capabilities.ptz.zoom || !capabilities.ptz.presets.isEmpty) {
            Text("Hold to move. Release or slide away to stop.")
                .font(.caption).foregroundStyle(.secondary)
            if capabilities.ptz.panTilt {
                VStack(spacing: 8) {
                    motionButton(.up, title: "Tilt up", image: "arrow.up")
                    HStack(spacing: 8) {
                        motionButton(.left, title: "Pan left", image: "arrow.left")
                        Button("Stop", systemImage: "stop.fill") { controls.stopMotion() }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .disabled(controls.holdingCommand == nil)
                        motionButton(.right, title: "Pan right", image: "arrow.right")
                    }
                    motionButton(.down, title: "Tilt down", image: "arrow.down")
                }
            }
            if capabilities.ptz.zoom {
                HStack(spacing: 8) {
                    motionButton(.zoomOut, title: "Zoom out", image: "minus.magnifyingglass")
                    motionButton(.zoomIn, title: "Zoom in", image: "plus.magnifyingglass")
                }
            }
            if !capabilities.ptz.presets.isEmpty {
                Picker("Camera preset", selection: $selectedPreset) {
                    ForEach(capabilities.ptz.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .onChange(of: selectedPreset) { _, _ in controls.stopMotion() }
                HoldCameraControl(title: "Hold to move to preset", image: "scope",
                    enabled: available && controls.canStart && !selectedPreset.isEmpty &&
                        (controls.holdingCommand == nil || controls.holdingCommand == .preset),
                    onPress: { controls.begin(.preset, preset: selectedPreset) },
                    onRelease: { controls.end(.preset) })
                    .frame(minHeight: 52)
            }
        } else {
            Label("PTZ is not available for this camera or account.", systemImage: "move.3d")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func motionButton(_ command: CameraPTZCommand, title: String, image: String) -> some View {
        HoldCameraControl(title: title, image: image,
            enabled: available && controls.canStart &&
                (controls.holdingCommand == nil || controls.holdingCommand == command),
            onPress: { controls.begin(command) },
            onRelease: { controls.end(command) })
            .frame(maxWidth: .infinity, minHeight: 52)
    }

    @ViewBuilder
    private func microphone(_ capabilities: CameraControlCapabilities) -> some View {
        if capabilities.talkback.supported {
            HoldCameraControl(title: talkbackTitle, image: talkback.phase == .transmitting ? "mic.fill" : "mic",
                enabled: available && controls.canStart,
                onPress: {
                    talkback.begin(api: api, cameraID: camera.id, capabilities: controls.capabilities,
                        iceServers: model.iceServers)
                },
                onRelease: { talkback.stop() })
                .frame(minHeight: 56)
            Text("Microphone audio is sent only while held and is never saved. Release or slide away to mute. After granting microphone access, hold again. Picture in Picture stops before microphone access.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Talkback is not available for this camera or account.", systemImage: "mic.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var talkbackTitle: String {
        switch talkback.phase {
        case .idle: return "Hold to talk"
        case .awaitingPermission: return "Waiting for microphone permission…"
        case .negotiating: return "Connecting — keep holding"
        case .transmitting: return "Talking — release to mute"
        }
    }

    private func tearDown() {
        loadedKey = nil
        talkback.stop()
        controls.invalidate()
    }
}

private struct HoldCameraControl: UIViewRepresentable {
    let title: String
    let image: String
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> CameraHoldButton {
        let button = CameraHoldButton(type: .system)
        button.addTarget(button, action: #selector(CameraHoldButton.press), for: .touchDown)
        button.addTarget(button, action: #selector(CameraHoldButton.releaseHold),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return button
    }

    func updateUIView(_ button: CameraHoldButton, context: Context) {
        button.onPress = onPress
        button.onRelease = onRelease
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 8
        configuration.cornerStyle = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .callout)
            return outgoing
        }
        button.configuration = configuration
        button.isEnabled = enabled
        button.accessibilityLabel = title
        button.accessibilityHint = "Keep holding to activate. Release or slide outside to stop."
    }

    static func dismantleUIView(_ button: CameraHoldButton, coordinator: ()) {
        button.releaseHold()
        button.onPress = nil
        button.onRelease = nil
    }
}

private final class CameraHoldButton: UIButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var trackingHoldActive = false

    override var isEnabled: Bool {
        didSet { if !isEnabled { releaseHold() } }
    }

    @objc func press() {
        guard isEnabled, !trackingHoldActive else { return }
        trackingHoldActive = true
        onPress?()
    }

    @objc func releaseHold() {
        guard trackingHoldActive else { return }
        trackingHoldActive = false
        onRelease?()
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if !bounds.contains(touch.location(in: self)) { releaseHold() }
        return super.continueTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        releaseHold()
        super.cancelTracking(with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        releaseHold()
        super.endTracking(touch, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseHold() }
    }
}
