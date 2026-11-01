import SwiftUI
import HorizonCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var api: HorizonAPI?
    @Published private(set) var configuration: HorizonConfiguration?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionIssue: ConnectionIssue?
    @Published private(set) var lastConnectionCheck: Date?
    @Published private(set) var savedServerAddress: String?
    @Published var error: String?
    @Published var serverText = ""
    @Published private(set) var pendingExportIDs: [String] = []
    @Published private(set) var serverProfiles = ServerProfileLibrary()
    @Published private(set) var profilesError: String?
    @Published private(set) var profileNotice: String?
    private var profilesLoaded = false
    private let profilesStorageKey = "serverProfiles.v1"
    private var connectionGeneration = UUID()

    var canRetrySavedConnection: Bool {
        api == nil && savedServerAddress != nil
            && savedServerAddress == (try? ServerAddress(serverText))?.url.absoluteString
            && connectionIssue?.allowsSavedSessionRetry == true
    }

    var cameras: [HorizonCamera] {
        guard let configuration, let profile else { return [] }
        let allowed = Set(profile.allowedCameras)
        return configuration.orderedCameras.filter { allowed.contains($0.id) }
    }

    var iceServers: [ICEServer] { configuration?.go2rtc?.webrtc?.iceServers ?? [] }
    var isAdmin: Bool { profile?.isAdmin == true }
    var semanticSearchEnabled: Bool { configuration?.semanticSearch?.enabled == true }
    var roles: [String] { configuration?.auth?.roles.keys.sorted() ?? [] }
    var profileSwitchCleanupPending: Bool { NativePushController.shared.cleanupPending }
    var profileSwitchNeedsConfirmation: Bool {
        let push = NativePushController.shared
        return api != nil || push.wantsPush || push.registered || push.cleanupPending
    }

    func trackExport(_ id: String) {
        if !pendingExportIDs.contains(id) { pendingExportIDs.append(id) }
    }

    func finishExport(_ id: String) {
        if pendingExportIDs.contains(id) { pendingExportIDs.removeAll { $0 == id } }
    }

    func restore() async {
        guard !isConnecting, api == nil else { return }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        do {
            try loadProfiles()
            let saved: SavedSession
            let expectedUsername: String?
            if let selection = serverProfiles.selection {
                let address = try serverProfiles.address(for: selection)
                serverText = address.url.absoluteString
                guard let record = try SessionVault.profileSession(selection.profileID, address: address) else {
                    profileNotice = "This address has no saved login. Enter your current Frigate credentials."
                    return
                }
                saved = record.session
                expectedUsername = record.username
            } else {
                guard let legacy = try SessionVault.read() else { return }
                saved = legacy
                expectedUsername = nil
                let address = try ServerAddress(legacy.server)
                if address.url.scheme == "https" {
                    var library = serverProfiles
                    let selection = try library.adopt(address)
                    try SessionVault.saveProfile(selection.profileID, username: nil, session: legacy)
                    try persistProfiles(library)
                }
            }
            serverText = saved.server
            let address = try ServerAddress(saved.server)
            savedServerAddress = address.url.absoluteString
            let client = HorizonAPI(
                address: address, cookies: saved.cookies.compactMap { $0.restore(for: address) }
            )
            do {
                try await activate(client, generation: generation, expectedUsername: expectedUsername)
            } catch {
                client.close()
                throw error
            }
        } catch {
            recordConnectionFailure(error, generation: generation)
        }
    }

    func connect(username: String, password: String, authenticate: Bool) async {
        guard !isConnecting, api == nil else { return }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        var candidate: HorizonAPI?
        do {
            try loadProfiles()
            let client = HorizonAPI(address: try ServerAddress(serverText))
            candidate = client
            if authenticate { try await client.login(user: username, password: password) }
            try await activate(client, generation: generation)
        } catch {
            candidate?.close()
            recordConnectionFailure(error, generation: generation)
        }
    }

    func refresh() async {
        guard let api, !isRefreshing, !isConnecting else { return }
        let generation = connectionGeneration
        isRefreshing = true
        defer { if connectionGeneration == generation { isRefreshing = false } }
        do {
            try await activate(api, generation: generation)
        } catch {
            recordConnectionFailure(error, generation: generation)
        }
    }

    func reauthenticate(password: String) async -> Bool {
        guard !isConnecting, let api, let username = profile?.username else { return false }
        guard !password.isEmpty else {
            error = "Enter your current Frigate password."
            return false
        }

        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        let client = HorizonAPI(address: api.address)
        do {
            try await client.login(user: username, password: password)
            try await activate(client, generation: generation, expectedUsername: username)
            return true
        } catch {
            client.close()
            recordConnectionFailure(error, generation: generation)
            return false
        }
    }

    func reportSessionExpiry(from client: HorizonAPI) {
        guard api === client, !isConnecting, connectionIssue?.kind != .authentication else { return }
        recordConnectionFailure(HorizonError.unauthorized, generation: connectionGeneration)
    }

    func disconnect(skippingPushCleanup: Bool = false) async -> Bool {
        guard !isConnecting else { return false }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        do {
            return try await releaseConnection(skippingPushCleanup: skippingPushCleanup, forgetSession: true)
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func releaseConnection(skippingPushCleanup: Bool, forgetSession: Bool) async throws -> Bool {
        let push = NativePushController.shared
        if !skippingPushCleanup, api != nil || push.wantsPush || push.registered || push.cleanupPending {
            guard await push.disable(using: api) else {
                error = push.error ?? "Could not remove the server's push registration. Retry or explicitly disconnect without cleanup."
                return false
            }
        }
        if let selection = serverProfiles.selection {
            let address = try serverProfiles.address(for: selection)
            if forgetSession {
                try SessionVault.clearProfileEndpoint(selection.profileID, address: address)
            } else if let api, api.address == address, let username = profile?.username {
                try SessionVault.saveProfile(selection.profileID, username: username,
                    session: SavedSession(server: address.url.absoluteString, cookies: api.cookies.map(SavedSession.SavedCookie.init)))
            }
        }
        try push.abandonForLogout()
        try SessionVault.clear()
        LivePictureInPictureController.shared.stop()
        // Owned lease-cleanup tasks retain their old client until authenticated cleanup finishes.
        api = nil
        configuration = nil
        profile = nil
        pendingExportIDs = []
        error = nil
        connectionIssue = nil
        lastConnectionCheck = nil
        savedServerAddress = nil
        return true
    }

    func prepareServerProfiles() {
        do { try loadProfiles() }
        catch { profilesError = error.localizedDescription }
    }

    private func loadProfiles() throws {
        guard !profilesLoaded else { return }
        do {
            if let stored = UserDefaults.standard.object(forKey: profilesStorageKey) {
                guard let data = stored as? Data else {
                    throw HorizonError.message("Saved server profiles could not be read. Reset them explicitly in Server profiles.")
                }
                serverProfiles = try JSONDecoder().decode(ServerProfileLibrary.self, from: data)
            }
            profilesLoaded = true
            profilesError = nil
        } catch {
            profilesError = "Saved profiles could not be loaded: \(error.localizedDescription)"
            throw error
        }
    }

    private func persistProfiles(_ library: ServerProfileLibrary) throws {
        let data = try JSONEncoder().encode(library)
        UserDefaults.standard.set(data, forKey: profilesStorageKey)
        serverProfiles = library
        profilesLoaded = true
        profilesError = nil
    }

    func saveServerProfile(_ value: ServerProfile) throws {
        guard !isConnecting else { throw HorizonError.message("Wait for the connection attempt to finish.") }
        try loadProfiles()
        var library = serverProfiles
        let previous = library.profiles.first { $0.id == value.id }
        let endpointsChanged = previous.map {
            $0.primaryAddress != value.primaryAddress || $0.localAddress != value.localAddress
        } ?? false
        guard !(api != nil && library.selection?.profileID == value.id && endpointsChanged) else {
            throw HorizonError.message("Disconnect before changing the active profile's addresses.")
        }
        try library.save(value)
        if endpointsChanged {
            try SessionVault.clearProfile(value.id)
            if library.selection?.profileID == value.id {
                try NativePushController.shared.abandonForLogout()
                try SessionVault.clear()
            }
        }
        try persistProfiles(library)
        if api == nil, let selection = library.selection, selection.profileID == value.id {
            serverText = try library.address(for: selection).url.absoluteString
            savedServerAddress = nil
            connectionIssue = nil
            error = nil
        }
    }

    func deleteServerProfile(_ id: UUID) throws {
        guard !isConnecting else { throw HorizonError.message("Wait for the connection attempt to finish.") }
        try loadProfiles()
        guard api == nil || serverProfiles.selection?.profileID != id else {
            throw HorizonError.message("Disconnect or switch servers before deleting the active profile.")
        }
        var library = serverProfiles
        let selected = library.selection?.profileID == id
        try library.remove(id)
        try SessionVault.clearProfile(id)
        if selected {
            try NativePushController.shared.abandonForLogout()
            try SessionVault.clear()
        }
        try persistProfiles(library)
        if selected { serverText = ""; savedServerAddress = nil; connectionIssue = nil; error = nil }
    }

    func resetServerProfiles() throws {
        guard api == nil, !isConnecting else {
            throw HorizonError.message("Disconnect before resetting saved profiles and logins.")
        }
        try NativePushController.shared.abandonForLogout()
        try SessionVault.clearAllProfiles()
        try SessionVault.clear()
        UserDefaults.standard.removeObject(forKey: profilesStorageKey)
        serverProfiles = ServerProfileLibrary()
        profilesLoaded = true
        profilesError = nil
        profileNotice = nil
        serverText = ""
        savedServerAddress = nil
        error = nil
        connectionIssue = nil
    }

    func selectServerProfile(_ selection: ServerProfileSelection, skippingPushCleanup: Bool = false) async -> Bool {
        guard !isConnecting else { return false }
        let generation = beginConnectionAttempt()
        defer { if connectionGeneration == generation { isConnecting = false } }
        var candidate: HorizonAPI?
        do {
            try loadProfiles()
            var library = serverProfiles
            let address = try library.address(for: selection)
            try library.select(selection)
            if api?.address == address, serverProfiles.selection?.profileID == selection.profileID {
                try persistProfiles(library)
                return true
            }
            guard try await releaseConnection(skippingPushCleanup: skippingPushCleanup, forgetSession: false) else { return false }
            try Task.checkCancellation()
            guard generation == connectionGeneration else { throw CancellationError() }
            try persistProfiles(library)
            serverText = address.url.absoluteString
            profileNotice = "Profile selected. Sign in if this address has no valid saved session."
            guard let record = try SessionVault.profileSession(selection.profileID, address: address) else { return true }
            savedServerAddress = address.url.absoluteString
            let client = HorizonAPI(address: address, cookies: record.session.cookies.compactMap { $0.restore(for: address) })
            candidate = client
            try await activate(client, generation: generation, expectedUsername: record.username)
            return true
        } catch {
            candidate?.close()
            recordConnectionFailure(error, generation: generation)
            return false
        }
    }

    private func beginConnectionAttempt() -> UUID {
        connectionGeneration = UUID()
        isConnecting = true
        isRefreshing = false
        error = nil
        connectionIssue = nil
        return connectionGeneration
    }

    private func recordConnectionFailure(_ failure: Error, generation: UUID) {
        guard generation == connectionGeneration else { return }
        let issue = ConnectionIssue(error: failure)
        guard issue.kind != .cancelled else { return }
        error = failure.localizedDescription
        connectionIssue = issue
    }

    private func activate(_ client: HorizonAPI, generation: UUID,
                          expectedUsername: String? = nil) async throws {
        async let config: HorizonConfiguration = client.get(["config"])
        async let profile: UserProfile = client.get(["profile"])
        let (newConfig, newProfile) = try await (config, profile)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        if let expectedUsername, newProfile.username != expectedUsername {
            throw HorizonError.message("The server returned a different account. Disconnect before switching accounts.")
        }
        try client.bindViewingAccount(username: newProfile.username)
        if api?.address != client.address || self.profile?.username != newProfile.username {
            try NativePushController.shared.prepareForAccountChange(api: client, username: newProfile.username)
        }
        try loadProfiles()
        var library = serverProfiles
        if client.address.url.scheme == "https" {
            let selection = try library.adopt(client.address)
            try SessionVault.saveProfile(selection.profileID, username: newProfile.username,
                session: SavedSession(server: client.address.url.absoluteString, cookies: client.cookies.map(SavedSession.SavedCookie.init)))
        } else {
            try library.select(nil)
            profileNotice = "This existing HTTP connection was not added to profiles. Saved profiles require trusted HTTPS."
        }
        try SessionVault.save(client)
        try persistProfiles(library)
        configuration = newConfig
        self.profile = newProfile
        api = client
        serverText = client.address.url.absoluteString
        savedServerAddress = serverText
        lastConnectionCheck = Date()
        error = nil
        connectionIssue = nil
        if client.address.url.scheme == "https" { profileNotice = nil }
        NativePushController.shared.refreshImageSession(api: client, username: newProfile.username,
            allowedCameraIDs: newProfile.allowedCameras)
    }
}
