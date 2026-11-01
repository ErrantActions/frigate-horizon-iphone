import SwiftUI
import UIKit
import UserNotifications
import HorizonCore

@MainActor
final class NativePushController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NativePushController()
    @Published private(set) var capabilities: NativePushCapabilities?
    @Published private(set) var wantsPush = UserDefaults.standard.bool(forKey: "nativePushWanted")
    @Published private(set) var cleanupPending = UserDefaults.standard.bool(forKey: "nativePushCleanupPending")
    @Published private(set) var registered = false
    @Published private(set) var busy = false
    @Published private(set) var checkingSupport = false
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private(set) var imageNotifications = UserDefaults.standard.bool(forKey: "nativePushImagesWanted")
    @Published private(set) var imageSessionReady = false
    @Published private(set) var devicePreferences: NativeDevicePreferences?
    @Published private(set) var preferencesBusy = false
    @Published var error: String?
    @Published var route: NativeNotificationRoute?
    @Published private(set) var status = "Native push has not been configured."
    @Published private(set) var actualSelection = NativePushSelection()
    private var api: HorizonAPI?
    private var accountFingerprint: String?
    private var deviceToken: String?
    private var registeredFeatures: Set<String> = []
    private var username: String?
    private var allowedCameraIDs: [String] = []
    private var requestTask: Task<Void, Never>?
    private var disablingTask: Task<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    private var registrationRequest = UUID()
    private var queuedRoute: NativeNotificationRoute?
    private var navigationBlocks: Set<UUID> = []
    private var explicitCameraSave = false

    var supportedBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HorizonNativePushEnabled") as? String == "YES"
    }

    var supportedImageBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HorizonNotificationImagesEnabled") as? Bool == true
    }

    func refreshAuthorization() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        configureNotificationCategories()
    }

    func attach(api: HorizonAPI?, username: String?, allowedCameraIDs: [String]) async {
        let token = UUID()
        generation = token
        self.api = api
        self.username = username
        self.allowedCameraIDs = allowedCameraIDs
        checkingSupport = true
        defer { if generation == token { checkingSupport = false } }
        error = nil
        capabilities = nil
        registered = false
        registeredFeatures = []
        actualSelection = NativePushSelection()
        explicitCameraSave = false
        devicePreferences = nil
        preferencesBusy = false
        imageSessionReady = false
        do { try NotificationImageVault.clear() }
        catch { self.error = error.localizedDescription; return }
        guard let api, let username else { accountFingerprint = nil; route = nil; return }
        accountFingerprint = fingerprint(api: api, username: username)
        if imageNotifications && accountFingerprint != UserDefaults.standard.string(forKey: "nativePushImagesAccount") {
            imageNotifications = false
            UserDefaults.standard.set(false, forKey: "nativePushImagesWanted")
        }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard generation == token else { return }
        guard supportedBuild else {
            status = "Native push is disabled in this build. A push-enabled App ID, profile, and build are required."
            return
        }
        do {
            let result = try await fetchCapabilities(api: api)
            guard !Task.isCancelled, generation == token else { return }
            capabilities = result
            configureNotificationCategories()
            try await loadInstallationSelection(api: api, token: token)
            guard result.enabled else { status = "The server's APNs provider is disabled."; return }
            status = "Native push is available. Enable it to request permission."
            publishQueuedRoute()
            if wantsPush && bindingMatches {
                await enable(cameraIDs: savedCameraIDs, requestPermission: false)
            } else if wantsPush {
                stopLocalDelivery()
                setWanted(false)
                status = "This is a different account/server. Enable notifications to register this installation here."
            }
        } catch {
            if !Task.isCancelled && generation == token { self.error = error.localizedDescription }
        }
    }

    func refreshServerSupport() async {
        await refreshAuthorization()
        guard !busy, !checkingSupport, supportedBuild, let api, let username else { return }
        let token = generation
        checkingSupport = true
        defer { if generation == token { checkingSupport = false } }
        do {
            let result = try await fetchCapabilities(api: api)
            guard !Task.isCancelled, generation == token else { return }
            let serverChanged = capabilities?.serverID != result.serverID
            if !result.enabled || result.imageNotifications != true || serverChanged {
                try NotificationImageVault.clear()
                imageSessionReady = false
            }
            capabilities = result
            configureNotificationCategories()
            try await loadInstallationSelection(api: api, token: token)
            self.error = nil
            guard result.enabled else {
                status = "The server's APNs provider is disabled."
                return
            }
            publishQueuedRoute()
            let needsFeatureUpgrade = result.supportsDeviceFeatures == true
                && registeredFeatures != Set(["actions-v1", "health-v1"])
            if wantsPush && bindingMatches && (!registered || serverChanged || needsFeatureUpgrade) {
                registered = false
                await enable(cameraIDs: savedCameraIDs, requestPermission: false)
            } else {
                status = registered
                    ? "Server notification support refreshed. This installation is registered."
                    : "Native push is available. Enable it to request permission."
                refreshImageSession(api: api, username: username, allowedCameraIDs: allowedCameraIDs)
            }
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            let message = error.localizedDescription
            capabilities = nil
            imageSessionReady = false
            status = "Server notification support is unavailable. Try refreshing again."
            self.error = "Notification support could not be refreshed: \(message)"
            do { try NotificationImageVault.clear() }
            catch let revokeError {
                self.error = "Notification support could not be refreshed: \(message). Image-session revocation also failed: \(revokeError.localizedDescription)"
            }
        }
    }

    private func fetchCapabilities(api: HorizonAPI) async throws -> NativePushCapabilities {
        let result: NativePushCapabilities = try await api.get(["notifications", "apns"])
        guard !result.enabled || (result.topic == Bundle.main.bundleIdentifier && result.serverID?.isEmpty == false) else {
            throw HorizonError.message("The server's APNs topic or server identifier is invalid for this app.")
        }
        return result
    }

    var savedCameraIDs: [String]? {
        if actualSelection.known { return actualSelection.cameraIDs }
        if UserDefaults.standard.bool(forKey: "nativePushSelectedCameras") {
            return UserDefaults.standard.stringArray(forKey: "nativePushCameraIDs") ?? []
        }

        private func loadInstallationSelection(api: HorizonAPI, token: UUID) async throws {
            let devices: [NativePushDeviceMetadata] = try await api.get(["notifications", "apns", "devices"])
            guard generation == token, self.api === api else { throw CancellationError() }
            let id = try UUID(uuidString: installationID())
            let matches = devices.filter { $0.installationID == id }
            guard matches.count <= 1 else { throw HorizonError.message("Duplicate installation metadata. Notification renewal was stopped.") }
            actualSelection = NativePushSelection()
            if let device = matches.first {
                actualSelection.confirm(device.cameraIDs)
                registered = true
                // This is a read of server state, not an opt-in or a registration write.
                UserDefaults.standard.set(device.cameraIDs != nil, forKey: "nativePushSelectedCameras")
                UserDefaults.standard.set(device.cameraIDs ?? [], forKey: "nativePushCameraIDs")
            }
        }
        return nil
    }

    private var bindingMatches: Bool {
        accountFingerprint != nil
            && accountFingerprint == UserDefaults.standard.string(forKey: "nativePushAccount")
    }

    private func installationID() throws -> String {
        if let stored = UserDefaults.standard.string(forKey: "nativePushInstallationID") {
            guard let value = UUID(uuidString: stored) else {
                throw HorizonError.message("The saved notification installation ID is invalid.")
            }
            return value.uuidString.lowercased()
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "nativePushInstallationID")
        return value
    }

    func enable(cameraIDs: [String]?, requestPermission: Bool = true) async {
        guard !busy else { return }
        guard supportedBuild, capabilities?.enabled == true, api != nil else {
            error = "A push-enabled build and configured server are required."
            return
        }
        guard !cleanupPending || bindingMatches
                || UserDefaults.standard.string(forKey: "nativePushAccount") == nil else {
            error = "Sign back into the previous account/server and finish notification cleanup before enabling notifications here."
            return
        }
        busy = true; error = nil
        let session = generation
        do {
            _ = try installationID()
            let center = UNUserNotificationCenter.current()
            let granted: Bool
            if requestPermission {
                granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                let existing = await center.notificationSettings().authorizationStatus
                granted = [.authorized, .provisional, .ephemeral].contains(existing)
            }
            permission = await center.notificationSettings().authorizationStatus
            guard generation == session else { busy = false; return }
            guard granted else {
                throw HorizonError.message("Notifications were not allowed. Enable them in iOS Settings.")
            }
            if requestPermission {
                actualSelection.confirm(cameraIDs)
                explicitCameraSave = true
            } else {
                _ = try actualSelection.renewalCameras()
            }
            let confirmed = try actualSelection.renewalCameras()
            UserDefaults.standard.set(confirmed != nil, forKey: "nativePushSelectedCameras")
            UserDefaults.standard.set(confirmed ?? [], forKey: "nativePushCameraIDs")
            setWanted(true)
            status = "Registering this device with Apple..."
            let token = generation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.generation == token, self.busy, self.deviceToken == nil else { return }
                self.busy = false
                self.error = "Apple device registration timed out. Check connectivity and the app's push entitlement."
            }
            if let deviceToken { scheduleRegistration(deviceToken) }
            else { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }

    func receivedToken(_ data: Data) {
        guard wantsPush else { return }
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        timeoutTask?.cancel()
        scheduleRegistration(token)
    }

    func registrationFailed(_ error: Error) {
        timeoutTask?.cancel()
        busy = false
        self.error = "Apple registration failed: \(error.localizedDescription)"
    }

    private func scheduleRegistration(_ token: String) {
        timeoutTask?.cancel()
        let previous = requestTask
        let requestID = UUID()
        registrationRequest = requestID
        let session = generation
        busy = true
        requestTask = Task {
            await previous?.value
            defer { if registrationRequest == requestID { busy = false } }
            guard generation == session, wantsPush, let api, let capabilities,
                  let fingerprint = accountFingerprint else { return }
            do {
                if !explicitCameraSave {
                    try await loadInstallationSelection(api: api, token: session)
                }
                guard generation == session, registrationRequest == requestID else { return }
                let environment: String
                switch Bundle.main.object(forInfoDictionaryKey: "HorizonAPNsEnvironment") as? String {
                case "development": environment = "sandbox"
                case "production": environment = "production"
                default: throw HorizonError.message("The app's APNs environment build setting is invalid.")
                }
                let features = capabilities.supportsDeviceFeatures == true ? ["actions-v1", "health-v1"] : nil
                guard registrationRequest == requestID else { return }
                let cameras = try actualSelection.renewalCameras()
                let body = try NativePushRegistrationBody(installationID: installationID(),
                    token: token, environment: environment, cameraIDs: cameras, features: features)
                UserDefaults.standard.set(fingerprint, forKey: "nativePushAccount")
                UserDefaults.standard.set(capabilities.serverID, forKey: "nativePushServerID")
                let result: NativePushRegistrationResult = try await api.send(
                    ["notifications", "apns", "register"], body: body
                )
                guard result.success, result.serverID == capabilities.serverID else {
                    throw HorizonError.message("The server did not confirm this notification registration.")
                }
                guard generation == session, registrationRequest == requestID, wantsPush else { return }
                explicitCameraSave = false
                registered = true
                registeredFeatures = Set(body.features ?? [])
                status = result.message
                cleanupPending = false
                UserDefaults.standard.set(false, forKey: "nativePushCleanupPending")
                UserDefaults.standard.set(fingerprint, forKey: "nativePushAccount")
                UserDefaults.standard.set(result.serverID, forKey: "nativePushServerID")
                refreshImageSession(api: api, username: username, allowedCameraIDs: allowedCameraIDs)
                publishQueuedRoute()
            } catch {
                guard generation == session, registrationRequest == requestID else { return }
                cleanupPending = true
                UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
                self.error = error.localizedDescription
            }
        }
    }

    func disable(using explicitAPI: HorizonAPI? = nil) async -> Bool {
        if let disablingTask { return await disablingTask.value }
        busy = true
        let task = Task { await performDisable(using: explicitAPI) }
        disablingTask = task
        let result = await task.value
        disablingTask = nil
        return result
    }

    private func performDisable(using explicitAPI: HorizonAPI?) async -> Bool {
        let needsCleanup = wantsPush || cleanupPending || registered
        do { try revokeImageAccess() }
        catch {
            self.error = "Could not revoke notification-image access: \(error.localizedDescription)"
            busy = false
            return false
        }
        setWanted(false)
        stopLocalDelivery()
        registered = false
        timeoutTask?.cancel()
        await requestTask?.value
        guard needsCleanup else { busy = false; return true }
        guard bindingMatches || UserDefaults.standard.string(forKey: "nativePushAccount") == nil,
              let api = explicitAPI ?? api else {
            error = "Server cleanup requires the account that registered this installation."
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
            busy = false
            return false
        }
        busy = true
        defer { busy = false }
        do {
            try await api.action(["notifications", "apns", "register", try installationID()],
                method: "DELETE", body: [String: String]())
            cleanupPending = false
            UserDefaults.standard.set(false, forKey: "nativePushCleanupPending")
            UserDefaults.standard.removeObject(forKey: "nativePushAccount")
            UserDefaults.standard.removeObject(forKey: "nativePushServerID")
            error = nil
            status = "Native notifications are disabled and the server registration was removed."
            return true
        } catch {
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
            self.error = "Notifications are off locally, but server cleanup failed: \(error.localizedDescription)"
            return false
        }
    }

    func stopLocalDelivery() {
        devicePreferences = nil
        registeredFeatures = []
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func abandonForLogout() throws {
        try revokeImageAccess()
        if wantsPush || registered {
            cleanupPending = true
            UserDefaults.standard.set(true, forKey: "nativePushCleanupPending")
        }
        setWanted(false)
        stopLocalDelivery()
        registered = false
        deviceToken = nil
        route = nil; queuedRoute = nil
    }

    func setImageNotifications(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                guard supportedBuild, supportedImageBuild, capabilities?.imageNotifications == true,
                      registered, bindingMatches,
                      let api, let username, let serverID = capabilities?.serverID,
                      let topic = capabilities?.topic, let accountFingerprint else {
                    throw HorizonError.message("Register this installation in an image-enabled build with the protected server image service before enabling lock-screen images.")
                }
                let record = try imageSession(api: api, username: username, serverID: serverID, topic: topic)
                try NotificationImageVault.save(record)
                UserDefaults.standard.set(accountFingerprint, forKey: "nativePushImagesAccount")
                UserDefaults.standard.set(true, forKey: "nativePushImagesWanted")
                imageNotifications = true
                imageSessionReady = true
            } else {
                try revokeImageAccess()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        } catch { self.error = error.localizedDescription }
    }

    func prepareForAccountChange(api: HorizonAPI, username: String) throws {
        try NotificationImageVault.clear()
        imageSessionReady = false
        let previous = UserDefaults.standard.string(forKey: "nativePushImagesAccount")
            ?? UserDefaults.standard.string(forKey: "nativePushAccount")
        if let previous, previous != fingerprint(api: api, username: username) {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }

    private func fingerprint(api: HorizonAPI, username: String) -> String {
        HorizonAccountScope.key(server: api.address.url.absoluteString, username: username)
    }

    func refreshImageSession(api: HorizonAPI, username: String?, allowedCameraIDs: [String]) {
        self.allowedCameraIDs = allowedCameraIDs
        imageSessionReady = false
        guard imageNotifications, capabilities?.imageNotifications == true, registered, bindingMatches,
              let username, username == self.username,
              let serverID = capabilities?.serverID, let topic = capabilities?.topic else { return }
        do {
            try NotificationImageVault.save(imageSession(api: api, username: username, serverID: serverID, topic: topic))
            imageSessionReady = true
        } catch {
            self.error = "Notification-image session refresh failed: \(error.localizedDescription)"
        }
    }

    private func imageSession(api: HorizonAPI, username: String, serverID: String,
                              topic: String) throws -> NotificationImageSession {
        let selected = savedCameraIDs.map { Set($0) }
        let cameras = allowedCameraIDs.filter { selected?.contains($0) ?? true }
        return try NotificationImageSession(installationID: installationID(), serverID: serverID, topic: topic, username: username,
            allowedCameraIDs: cameras,
            session: SavedSession(server: api.address.url.absoluteString,
                cookies: api.cookies.map(SavedSession.SavedCookie.init)))
    }

    private func revokeImageAccess() throws {
        try NotificationImageVault.clear()
        UserDefaults.standard.set(false, forKey: "nativePushImagesWanted")
        UserDefaults.standard.removeObject(forKey: "nativePushImagesAccount")
        imageNotifications = false
        imageSessionReady = false
    }

    func sendTest() async {
        guard registered, let api else { error = "Register this installation first."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result: APIActionResult = try await api.send(["notifications", "apns", "test"],
                body: ["installation_id": try installationID()])
            try result.requireSuccess()
            status = result.message ?? "Apple accepted the test request. Display is best-effort."
        } catch { self.error = error.localizedDescription }
    }

    private func setWanted(_ value: Bool) {
        wantsPush = value
        UserDefaults.standard.set(value, forKey: "nativePushWanted")
    }

    func loadAlertPreferences() async throws -> NativeDevicePreferences {
        let context = try beginPreferenceOperation()
        defer { finishPreferenceOperation(context) }
        let value: NativeDevicePreferences = try await context.api.get([
            "notifications", "apns", "devices", context.installationID, "preferences",
        ])
        try requirePreferenceContext(context)
        devicePreferences = value
        return value
    }

    func saveAlertPreferences(_ value: NativeDevicePreferences) async throws -> NativeDevicePreferences {
        let context = try beginPreferenceOperation()
        defer { finishPreferenceOperation(context) }
        let result: NativeDevicePreferences
        do {
            result = try await context.api.send([
                "notifications", "apns", "devices", context.installationID, "preferences",
            ], body: value)
        } catch HorizonError.http(409) {
            throw HorizonError.message("Notification preferences changed elsewhere. Reload before saving.")
        }
        try requirePreferenceContext(context)
        guard result.revision >= value.revision, result.quietHours == value.quietHours,
              result.healthAlerts == value.healthAlerts else {
            throw HorizonError.message("The server did not confirm these notification preferences.")
        }
        devicePreferences = result
        return result
    }

    func snoozeCamera(_ cameraID: String, seconds: Int) async throws -> NativeDevicePreferences {
        guard allowedCameraIDs.contains(cameraID) else {
            throw HorizonError.message("This camera is no longer available to your account.")
        }
        let body = try NativeCameraSnoozeBody(cameraID: cameraID, seconds: seconds)
        let context = try beginPreferenceOperation()
        defer { finishPreferenceOperation(context) }
        let value: NativeDevicePreferences = try await context.api.send([
            "notifications", "apns", "devices", context.installationID, "snooze",
        ], body: body)
        try requirePreferenceContext(context)
        let until = value.cameraSnoozeUntil[cameraID] ?? 0
        if seconds > 0 {
            guard until > Date().timeIntervalSince1970 else {
                throw HorizonError.message("The server did not confirm this camera's snooze.")
            }
        } else if until > Date().timeIntervalSince1970 {
            throw HorizonError.message("The server did not confirm that camera alerts resumed.")
        }
        devicePreferences = value
        return value
    }

    private struct PreferenceContext {
        let api: HorizonAPI
        let generation: UUID
        let installationID: String
    }

    private func beginPreferenceOperation() throws -> PreferenceContext {
        guard !preferencesBusy, !busy, registered, wantsPush, bindingMatches,
              capabilities?.devicePreferences == true, let api else {
            throw HorizonError.message("Finish registering this installation with a server supporting device alert preferences.")
        }
        let context = PreferenceContext(api: api, generation: generation, installationID: try installationID())
        preferencesBusy = true
        return context
    }

    private func finishPreferenceOperation(_ context: PreferenceContext) {
        if generation == context.generation { preferencesBusy = false }
    }

    private func requirePreferenceContext(_ context: PreferenceContext) throws {
        guard !Task.isCancelled, generation == context.generation, api === context.api,
              registered, wantsPush, bindingMatches else {
            throw HorizonError.message("The account or registration changed before confirmation. Refresh before continuing.")
        }
    }

    private func configureNotificationCategories() {
        let foreground: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        var actions = [
            UNNotificationAction(identifier: "HORIZON_LIVE", title: "Live", options: foreground),
            UNNotificationAction(identifier: "HORIZON_REVIEW", title: "Review", options: foreground),
        ]
        if capabilities?.actionNotifications == true && capabilities?.devicePreferences == true {
            actions.append(UNNotificationAction(identifier: "HORIZON_SNOOZE_15M",
                title: "Snooze camera 15 min", options: foreground))
        }
        let activity = UNNotificationCategory(identifier: "HORIZON_ACTIVITY", actions: actions,
            intentIdentifiers: [], options: [])
        let health = UNNotificationCategory(identifier: "HORIZON_HEALTH", actions: [
            UNNotificationAction(identifier: "HORIZON_HEALTH", title: "View health", options: foreground),
        ], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([activity, health])
    }

    func blockNavigation(_ id: UUID) { navigationBlocks.insert(id) }
    func unblockNavigation(_ id: UUID) { navigationBlocks.remove(id); publishQueuedRoute() }

    private func publishQueuedRoute() {
        guard navigationBlocks.isEmpty, let queuedRoute, api != nil,
              capabilities?.serverID == queuedRoute.serverID else { return }
        route = queuedRoute
        self.queuedRoute = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let candidate = NativeNotificationRoute(userInfo: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier, receivedAt: response.notification.date,
            registrationAccount: UserDefaults.standard.string(forKey: "nativePushAccount"))
        Task { @MainActor in
            guard let candidate else {
                self.error = "This notification could not be opened because its routing data is invalid."
                return
            }
            self.queuedRoute = candidate
            self.publishQueuedRoute()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let candidate = NativeNotificationRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            let allowed = self.wantsPush && self.api != nil && candidate?.serverID == self.capabilities?.serverID
            completionHandler(allowed && candidate != nil ? [.banner, .list, .sound] : [])
        }
    }
}

@MainActor
final class HorizonApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NativePushController.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NativePushController.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NativePushController.shared.registrationFailed(error)
    }
}

struct DeferNotificationNavigation: ViewModifier {
    @EnvironmentObject private var push: NativePushController
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { push.blockNavigation(id) }.onDisappear { push.unblockNavigation(id) }
    }
}
