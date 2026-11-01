import SwiftUI
import HorizonCore

@main
struct HorizonApp: App {
    @UIApplicationDelegateAdaptor(HorizonApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var push = NativePushController.shared
    @State private var mediaAccount: String?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            Group {
                if let api = model.api {
                    HorizonRoot(api: api)
                        .id(ObjectIdentifier(api))
                } else {
                    ConnectionView()
                }
            }
            .environmentObject(model)
            .environmentObject(push)
            .tint(HorizonPalette.accent)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .task { await model.restore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .horizonMediaAuthenticationExpired)) { notification in
                if let api = notification.object as? HorizonAPI { model.reportSessionExpiry(from: api) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .horizonMediaCleanupFailure)) { notification in
                if let message = notification.object as? String { model.error = message }
            }
            .task(id: "\(model.api.map { String(describing: ObjectIdentifier($0)) } ?? "")-\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-\(model.cameras.map { "\($0.id):\($0.settings.enabled)" }.joined(separator: ","))") {
                let account = model.api.flatMap { api in
                    model.profile.map { HorizonAccountScope.key(server: api.address.url.absoluteString, username: $0.username) }
                }
                if mediaAccount != account {
                    LivePictureInPictureController.shared.stop()
                    RecordedViewingRegistry.stopAll()
                    mediaAccount = account
                }
                if let api = model.api {
                    for camera in model.cameras {
                        if let retained = LivePictureInPictureController.shared.retainedSelection(api: api, cameraID: camera.id) {
                            if !camera.settings.enabled {
                                LivePictureInPictureController.shared.stop()
                            }
                        }
                    }
                }
                LivePictureInPictureController.shared.updateScope(api: model.api,
                    allowedCameraIDs: Set(model.cameras.filter { $0.settings.enabled }.map(\.id)))
                await push.attach(api: model.api, username: model.profile?.username,
                    allowedCameraIDs: model.cameras.map(\.id))
            }
        }
    }
}
