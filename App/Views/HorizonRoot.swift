import SwiftUI
import HorizonCore

struct HorizonRoot: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: HorizonDestination = .live
    @StateObject private var activity = ActivityNavigationState()
    @State private var librarySection: LibrarySection = .exports
    @State private var libraryCamera = "all"
    @State private var restoredCamera: HorizonCamera?
    @ObservedObject private var pictureInPicture = LivePictureInPictureController.shared
    @ObservedObject private var talkbackCleanup = CameraTalkbackCleanupStore.shared
    @ObservedObject private var viewerCleanup = ViewerCleanupStore.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab("Live", systemImage: "video", value: HorizonDestination.live) {
                LiveView(api: api, active: selection == .live && restoredCamera == nil)
            }
            Tab("Activity", systemImage: "rectangle.stack", value: HorizonDestination.activity) {
                ActivityView(api: api, state: activity)
            }
            Tab("Recordings", systemImage: "clock.arrow.circlepath", value: HorizonDestination.recordings) {
                RecordingsView(api: api)
            }
            Tab("Library", systemImage: "folder", value: HorizonDestination.library) {
                LibraryView(api: api, active: selection == .library, section: $librarySection, camera: $libraryCamera)
            }
            Tab("Settings", systemImage: "gearshape", value: HorizonDestination.settings) {
                SettingsView(api: api)
            }
            if horizontalSizeClass == .regular {
                TabSection("Shortcuts") {
                    Tab("Search", systemImage: "magnifyingglass", value: HorizonDestination.search) {
                        ActivityView(api: api, state: activity, forcedMode: .search)
                    }
                    Tab("Exports", systemImage: "film.stack", value: HorizonDestination.exports) {
                        ExportsView(api: api, active: selection == .exports, camera: $libraryCamera)
                    }
                    Tab("Protected", systemImage: "lock.shield", value: HorizonDestination.protectedMedia) {
                        ProtectedMediaView(api: api, camera: $libraryCamera)
                    }
                    if model.isAdmin {
                        Tab("Admin", systemImage: "server.rack", value: HorizonDestination.administration) {
                            AdministrationView(api: api)
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(HorizonPalette.accent)
        .toolbarBackground(HorizonPalette.surface, for: .tabBar)
        .background { HorizonBackdrop() }
        .safeAreaInset(edge: .bottom) {
            if let error = pictureInPicture.error {
                VStack {
                    ErrorNotice(message: error)
                    Button("Dismiss message") { pictureInPicture.error = nil }
                }
                .padding().background(HorizonPalette.surface)
            } else if let error = viewerCleanup.error {
                VStack {
                    ErrorNotice(message: error)
                    Button("Retry viewer cleanup") { Task { _ = await viewerCleanup.drain() } }
                }
                .padding().background(HorizonPalette.surface)
            } else if let error = talkbackCleanup.error {
                ErrorNotice(message: error).padding().background(HorizonPalette.surface)
            } else if talkbackCleanup.isPending, let status = talkbackCleanup.status {
                Text(status).font(.footnote).padding().background(HorizonPalette.surface)
            } else if let issue = model.connectionIssue {
                HStack(spacing: 12) {
                    Label(issue.title, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                    Spacer()
                    Button("Review connection") { selection = .settings }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .padding(.horizontal)
                .background(HorizonPalette.surface)
            }
        }
        .sheet(item: $restoredCamera) { camera in
            if let current = model.cameras.first(where: { $0.id == camera.id && $0.settings.enabled }) {
                CameraDetailView(api: api, camera: current)
            }
        }
        .onAppear {
            pictureInPicture.restoreUserInterface = { requested in
                guard model.api === api,
                      let camera = model.cameras.first(where: { $0.id == requested.cameraID && $0.settings.enabled }) else {
                    pictureInPicture.error = "The Picture in Picture camera is no longer available to this account."
                    pictureInPicture.stop()
                    return
                }
                UserDefaults.standard.set(requested.transport, forKey: "liveTransport")
                selection = .live
                restoredCamera = camera
            }
        }
        .onDisappear { pictureInPicture.restoreUserInterface = nil }
        .onChange(of: model.cameras.filter { $0.settings.enabled }.map(\.id)) { _, ids in
            if let restoredCamera, !ids.contains(restoredCamera.id) { self.restoredCamera = nil }
        }
        .onChange(of: model.isAdmin) { _, isAdmin in
            if !isAdmin && selection == .administration { selection = .settings }
        }
        .onChange(of: horizontalSizeClass) { _, size in
            guard size != .regular else { return }
            if selection == .search { activity.mode = .search }
            if selection == .exports { librarySection = .exports }
            if selection == .protectedMedia { librarySection = .protectedMedia }
            selection = selection.compactDestination
        }
        .onChange(of: push.route) { _, route in
            if route != nil { restoredCamera = nil; selection = .settings }
        }
    }
}
