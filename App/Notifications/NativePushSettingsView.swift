import SwiftUI
import UserNotifications
import HorizonCore

struct NativePushSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.scenePhase) private var scenePhase
    @State private var allCameras = true
    @State private var selectedCameras: Set<String> = []
    @State private var confirmImages = false
    @State private var confirmTest = false
    @State private var camerasEdited = false

    var body: some View {
        Form {
            Section {
                Text("Server rules decide which alerts exist. This iPhone's registration decides which ones it receives.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                HorizonStatusPill(title: push.registered ? "Installation registered" : "Installation not registered",
                    systemImage: push.registered ? "checkmark.shield" : "bell.slash",
                    tint: push.registered ? HorizonPalette.accent : HorizonPalette.warm)
                LabeledContent("Server provider", value: push.capabilities?.enabled == true ? "Enabled" : "Not configured / unavailable")
                LabeledContent("iOS permission", value: permissionText)
                Text(push.status).font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Technical details") {
                    LabeledContent("Build support", value: push.supportedBuild ? "Enabled" : "Not enabled in this build")
                }
                if push.checkingSupport { ProgressView("Checking server notification support") }
                if push.busy { ProgressView("Updating notification registration") }
                if let error = push.error { ErrorNotice(message: error) }
                Button("Refresh notification support", systemImage: "arrow.clockwise") {
                    Task { await push.refreshServerSupport() }
                }
                .disabled(push.busy || push.checkingSupport || !push.supportedBuild)
                if push.cleanupPending {
                    HorizonStatusPill(title: "Server registration cleanup is pending",
                        systemImage: "exclamationmark.triangle", tint: HorizonPalette.warm)
                }
            } header: {
                HorizonSectionHeader(title: "Native Apple notifications", systemImage: "antenna.radiowaves.left.and.right")
            }
            .listRowBackground(HorizonPalette.surface)
            Section {
                NavigationLink { NativeNotificationSetupView() } label: {
                    Label("Provider, camera rules and cooldowns", systemImage: "checklist")
                        .frame(minHeight: 44)
                }
                Text("Configure server-side rules here. Register this iPhone below; neither action replaces the other.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HorizonSectionHeader(title: "Server rules", systemImage: "server.rack")
            }
            .listRowBackground(HorizonPalette.surface)
            Section {
                Toggle("All cameras allowed by my account", isOn: Binding(
                    get: { allCameras }, set: { allCameras = $0; camerasEdited = true }))
                if !allCameras {
                    ForEach(model.cameras) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { selectedCameras.contains(camera.id) },
                            set: {
                                camerasEdited = true
                                if $0 { selectedCameras.insert(camera.id) } else { selectedCameras.remove(camera.id) }
                            }
                        ))
                    }
                    Text(push.actualSelection.known
                        ? (push.actualSelection.cameraIDs == nil ? "Server selection: all permitted cameras." :
                            (push.actualSelection.cameraIDs!.isEmpty ? "Server selection: no cameras (explicit opt-out)." :
                                "Server selection: " + push.actualSelection.cameraIDs!.joined(separator: ", ")))
                        : "This installation's server camera selection has not been confirmed. Select cameras explicitly before enabling.")
                        .font(.caption).foregroundStyle(.secondary)
                    if selectedCameras.isEmpty {
                        Text("No cameras selected: this installation will not receive camera alerts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(push.registered ? "Save camera choices / renew registration" : "Enable on this iPhone") {
                    Task {
                        await push.enable(cameraIDs: allCameras ? nil : selectedCameras.sorted())
                        camerasEdited = false
                    }
                }
                .buttonStyle(HorizonButtonStyle(.primary))
                .disabled(push.busy || push.checkingSupport || !push.supportedBuild || push.capabilities?.enabled != true)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        Label("iOS notification permissions", systemImage: "arrow.up.forward.app")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            } header: {
                HorizonSectionHeader(title: "This iPhone", systemImage: "iphone")
            }
            .listRowBackground(HorizonPalette.surface)
            .disabled(push.busy)
            Section {
                Toggle("Include camera images on the lock screen", isOn: Binding(
                    get: { push.imageNotifications },
                    set: { if $0 { confirmImages = true } else { push.setImageNotifications(false) } }
                ))
                .disabled(!push.imageNotifications && (push.busy || push.checkingSupport
                    || !push.registered || !push.supportedImageBuild
                    || push.capabilities?.imageNotifications != true))
                LabeledContent("Protected server image service",
                    value: push.capabilities?.imageNotifications == true ? "Available" : "Not enabled / unavailable")
                if push.imageNotifications {
                    LabeledContent("Secure image session", value: push.imageSessionReady ? "Ready" : "Needs attention")
                }
            } header: {
                HorizonSectionHeader(title: "Private notification images", systemImage: "photo")
            } footer: {
                Text("Off by default. Images can expose private camera footage on the lock screen. Thumbnails are fetched over authenticated HTTPS from your saved server, not sent through APNs. Unavailable authentication, connectivity, or time falls back to text. Turning images off removes delivered notifications from this device.")
            }
            .listRowBackground(HorizonPalette.surface)
            Section {
                NavigationLink { NativeNotificationPreferencesView() } label: {
                    Label("Quiet hours, camera snooze and health alerts", systemImage: "bell.slash")
                        .frame(minHeight: 44)
                }
                .disabled(!push.registered || push.checkingSupport || push.capabilities?.devicePreferences != true)
                if push.capabilities?.devicePreferences != true {
                    Text("Device alert controls require the matching Horizon backend update.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Send a test to this installation") { confirmTest = true }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(push.busy || !push.registered)
                if push.wantsPush || push.cleanupPending || push.registered {
                    Button("Disable and unregister", role: .destructive) { Task { _ = await push.disable() } }
                        .buttonStyle(HorizonButtonStyle(.secondary))
                        .disabled(push.busy)
                }
            } header: {
                HorizonSectionHeader(title: "Delivery controls", systemImage: "paperplane")
            } footer: {
                Text("Camera alert rules, suspension, cooldowns, and server permissions still apply. Registering this device does not enable server camera alerts. APNs uses Apple's service; generic text is the server default, but routing identifiers are sent. Apple acceptance does not guarantee delivery.")
            }
            .listRowBackground(HorizonPalette.surface)
        }
        .horizonScreen()
        .navigationTitle("Notifications")
        .confirmationDialog("Allow camera images on your lock screen?", isPresented: $confirmImages,
            titleVisibility: .visible) {
            Button("Enable private camera images") { push.setImageNotifications(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who can see your lock screen may see these images. A limited session copy is shared securely with the notification extension and revoked on logout or account changes.")
        }
        .confirmationDialog("Send a real Apple push notification?", isPresented: $confirmTest,
            titleVisibility: .visible) {
            Button("Send test") { Task { await push.sendTest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This contacts the server and Apple for this installation only. A test without an event or review reference is text-only; it does not verify image delivery.")
        }
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await push.refreshServerSupport() }
        }
        .refreshable { await push.refreshServerSupport() }
        .onAppear {
            if let cameras = push.savedCameraIDs {
                allCameras = false
                selectedCameras = Set(cameras)
            }
        }
        .onChange(of: push.actualSelection) { _, selection in
            guard !camerasEdited, selection.known else { return }
            allCameras = selection.cameraIDs == nil
            selectedCameras = Set(selection.cameraIDs ?? [])
            camerasEdited = false
        }
    }

    private var permissionText: String {
        switch push.permission {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .ephemeral: return "Temporary"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

struct NativeNotificationDestinationView: View {
    let api: HorizonAPI
    let route: NativeNotificationRoute
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @State private var review: ReviewSegment?
    @State private var event: SearchEvent?
    @State private var camera: HorizonCamera?
    @State private var error: String?
    @State private var retry = 0
    @State private var recordedCamera: HorizonCamera?
    @State private var recordedTime: Double?
    @State private var loadedScope: String?
    @State private var actionMessage: String?
    @State private var completedActionID: UUID?
    @State private var authorizedCamera: HorizonCamera?

    private var scope: String {
        "\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-\(model.cameras.map(\.id).joined(separator: ","))"
    }

    var body: some View {
        Group {
            if loadedScope != scope {
                ProgressView("Verifying notification access")
            } else if let error {
                VStack {
                    HorizonCard { ErrorNotice(message: error) { retry += 1 } }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .horizonScreen()
            } else if route.kind == .health {
                RecordingHealthView(api: api, focusedIssueID: route.identifier)
            } else if let actionMessage {
                VStack(spacing: 18) {
                    HorizonHero(title: "Camera alerts snoozed", subtitle: actionMessage,
                        systemImage: "bell.slash", eyebrow: "This installation")
                    NavigationLink { NativeNotificationPreferencesView() } label: {
                        Label("Device alert controls", systemImage: "slider.horizontal.3")
                    }
                    if let camera {
                        NavigationLink { CameraDetailView(api: api, camera: camera) } label: {
                            Label("Open \(camera.name)", systemImage: "video")
                        }
                    }
                }
                .padding(20).horizonScreen()
            } else if route.kind == .test {
                ContentUnavailableView("Test notification received", systemImage: "checkmark.bubble",
                    description: Text("This device received an Apple push notification."))
                    .horizonScreen()
            } else if let recordedCamera, let recordedTime {
                ReviewWorkspaceView(api: api, camera: recordedCamera.id, timestamp: recordedTime,
                    cameras: [recordedCamera], day: Date(timeIntervalSince1970: recordedTime))
            } else if let review {
                ReviewWorkspaceView(api: api, initialReview: review,
                    cameras: authorizedCamera.map { [$0] } ?? model.cameras,
                    day: Date(timeIntervalSince1970: review.startTime))
            } else if let event {
                EventDetailView(api: api, initialEvent: event) {}
            } else if let camera {
                CameraDetailView(api: api, camera: camera)
            } else {
                ProgressView("Opening notification")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .horizonScreen()
            }
        }
        .task(id: "\(route.id)-\(retry)-\(push.registered)-\(scope)") {
            let accountScope = scope
            review = nil; event = nil; camera = nil; recordedCamera = nil; recordedTime = nil
            authorizedCamera = nil
            error = nil; actionMessage = nil; loadedScope = accountScope
            guard push.capabilities?.serverID == route.serverID else {
                error = "This notification belongs to a different server."
                return
            }
            guard ![.test, .health].contains(route.kind), let identifier = route.identifier else { return }
            if route.intent == .snooze, completedActionID == route.id {
                actionMessage = "This notification's snooze request was already completed. Open device alert controls to see its current state."
                return
            }
            do {
                var resolvedCamera: HorizonCamera?
                var resolution: NativeNotificationResolution?
                if push.capabilities?.actionNotifications == true {
                    let value: NativeNotificationResolution = try await api.get([
                        "notifications", "apns", "resolve", route.kind.rawValue, identifier,
                    ])
                    try Task.checkCancellation()
                    guard accountScope == scope else { return }
                    try value.requireMatch(route, allowedCameras: Set(model.cameras.map(\.id)))
                    resolution = value
                    authorizedCamera = model.cameras.first { $0.id == value.camera }
                } else if route.intent != .open {
                    throw HorizonError.message("Update the server before using notification actions.")
                }
                switch route.kind {
                case .review:
                    let rows: [ReviewSegment] = try await api.get(["review_ids"], query: [
                        URLQueryItem(name: "ids", value: identifier),
                    ])
                    try Task.checkCancellation()
                    guard accountScope == scope, let row = rows.first(where: { $0.id == identifier }),
                          let allowedCamera = model.cameras.first(where: { $0.id == row.camera }),
                          resolution == nil || resolution?.camera == row.camera else {
                        throw HorizonError.message("The review item is unavailable or access was removed.")
                    }
                    resolvedCamera = allowedCamera
                    if [.live, .snooze].contains(route.intent) { camera = allowedCamera }
                    else { review = row }
                case .event:
                    let value: SearchEvent = try await api.get(["events", identifier])
                    try Task.checkCancellation()
                    guard accountScope == scope,
                          let allowedCamera = model.cameras.first(where: { $0.id == value.camera }),
                          resolution == nil || resolution?.camera == value.camera else {
                        throw HorizonError.message("This event is no longer available to your account.")
                    }
                    resolvedCamera = allowedCamera
                    if route.intent == .review {
                        recordedCamera = allowedCamera
                        recordedTime = value.startTime
                    } else if [.live, .snooze].contains(route.intent) { camera = allowedCamera }
                    else { event = value }
                case .camera:
                    guard let value = model.cameras.first(where: { $0.id == identifier }) else {
                        throw HorizonError.message("This camera is no longer available to your account.")
                    }
                    resolvedCamera = value
                    if route.intent == .review {
                        recordedCamera = value
                        recordedTime = route.receivedAt.timeIntervalSince1970
                    } else { camera = value }
                case .test, .health: break
                }
                if route.intent == .snooze {
                    guard let username = model.profile?.username, let resolvedCamera,
                          route.registrationAccount == HorizonAccountScope.key(
                            server: api.address.url.absoluteString, username: username) else {
                        throw HorizonError.message("This snooze action belongs to a different or expired account registration.")
                    }
                    let value = try await push.snoozeCamera(resolvedCamera.id, seconds: 900)
                    try Task.checkCancellation()
                    guard accountScope == scope else { return }
                    guard let until = value.cameraSnoozeUntil[resolvedCamera.id] else {
                        throw HorizonError.message("The server did not confirm the requested camera snooze.")
                    }
                    completedActionID = route.id
                    actionMessage = "\(resolvedCamera.name) is snoozed until \(Date(timeIntervalSince1970: until).formatted(date: .abbreviated, time: .shortened)). Other installations and server camera rules are unchanged."
                }
            } catch { if !Task.isCancelled && accountScope == scope { self.error = error.localizedDescription } }
        }
    }
}
