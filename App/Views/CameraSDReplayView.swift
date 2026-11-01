import SwiftUI
import HorizonCore

private struct SDReplayCapabilities: Decodable {
    let state: String
    let max_duration_seconds: Int
}
private struct SDRecordingPage: Decodable {
    struct Recording: Decodable, Identifiable {
        let token: String
        let start: String
        let end: String
        var id: String { token + start }
    }
    let recordings: [Recording]
}
private struct SDReplaySession: Decodable {
    let id: String
    let state: String
    let `protocol`: String
}

@MainActor
final class SDReplayOwner: ObservableObject {
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var mediaURL: URL?
    private var path: [String]?
    private var client: HorizonAPI?
    private var closing: Task<Void, Never>?
    private var generation = UUID()

    func open(api: HorizonAPI, camera: String, token: String, start: Date, end: Date) async {
        guard !busy, path == nil else { error = "Close the previous camera-SD session before opening another."; return }
        guard start < end, end <= Date(), end.timeIntervalSince(start) <= 300 else {
            error = "Choose a completed camera-SD interval of at most five minutes."; return
        }
        busy = true
        defer { busy = false }
        error = nil
        let generation = self.generation
        struct Body: Encodable { let recording_token: String; let start: String; let end: String; let audio: Bool }
        do {
            let base = ["onvif", "cameras", camera, "replay", "sessions"]
            let result: SDReplaySession = try await api.send(base, body: Body(recording_token: token,
                start: start.ISO8601Format(), end: end.ISO8601Format(), audio: true))
            guard NativeNotificationRoute.isValidIdentifier(result.id) else {
                throw HorizonError.message("The camera-SD server returned an invalid session identifier.")
            }
            path = base + [result.id]
            client = api
            guard self.generation == generation, !Task.isCancelled else { close(); return }
            guard result.protocol == "hls", result.state != "failed" else {
                close()
                throw HorizonError.message("The camera-SD server did not provide an HLS session.")
            }
            mediaURL = api.address.endpoint(["api"] + base + [result.id, "hls", "index.m3u8"])
        } catch { self.error = error.localizedDescription }
    }
    func close() {
        generation = UUID()
        mediaURL = nil
        guard let path, let api = client else { return }
        self.path = nil
        client = nil
        // Retain the authenticated old client until its one cleanup request finishes.
        closing = Task { [self] in
            do {
                struct Closed: Decodable { let state: String }
                let result: Closed = try await api.send(path, method: "DELETE", body: [String: String]())
                guard result.state == "closed" else { throw HorizonError.message("The camera-SD server did not confirm closure.") }
            }
            catch {
                self.error = "Camera-SD session closure is unconfirmed: \(error.localizedDescription)"
                NotificationCenter.default.post(name: .horizonMediaCleanupFailure, object: self.error)
            }
        }
    }
}

struct CameraSDReplayView: View {
    let api: HorizonAPI
    let camera: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var owner = SDReplayOwner()
    @StateObject private var player = RecordingPlayer()
    @State private var recordings: SDRecordingPage?
    @State private var supported = false
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date().addingTimeInterval(-3540)
    @State private var error: String?
    @State private var loading = false
    private var allowed: Bool { model.api === api && model.cameras.contains { $0.id == camera } }

    var body: some View {
        Form {
            if let url = owner.mediaURL {
                NativeRecordingSurface(player: player.player).frame(minHeight: 220)
                    .task(id: url) { player.open(url: url, api: api) }
                Button("Close replay") { player.stop(); owner.close() }
            } else {
                DatePicker("Start", selection: $start, in: ...Date())
                DatePicker("End (up to five minutes)", selection: $end, in: ...Date())
                Button("Find camera-SD recordings") { Task { await search() } }
                    .disabled(!supported || loading || !allowed || end <= start || end.timeIntervalSince(start) > 300)
                if let recordings {
                    ForEach(recordings.recordings) { record in
                        Button("Play \(record.start) - \(record.end)") {
                            Task { await owner.open(api: api, camera: camera, token: record.token, start: start, end: end) }
                        }
                        .disabled(owner.busy || !allowed)
                    }
                    if recordings.recordings.isEmpty { Text("No camera-SD footage was reported for this interval.") }
                }
            }
            if loading || owner.busy { ProgressView("Checking camera-SD replay") }
            if let error { ErrorNotice(message: error) }
            if let error = owner.error ?? player.error { ErrorNotice(message: error) }
            Text("Replay stays on your authenticated server origin. Leaving closes its replay session. No camera address or retired MP4 transport is opened.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Camera-SD replay")
        .horizonScreen()
        .task {
            do {
                let result: SDReplayCapabilities = try await api.get(["onvif", "cameras", camera, "replay"])
                guard allowed, !Task.isCancelled else { return }
                supported = result.state == "browser_sessions" && result.max_duration_seconds > 0
                if !supported { error = "This server did not advertise camera-SD replay support." }
            } catch { self.error = "Camera-SD replay is unavailable: \(error.localizedDescription)" }
        }
        .onDisappear { player.stop(); owner.close() }
        .onChange(of: allowed) { _, value in if !value { player.stop(); owner.close() } }
        .onChange(of: scenePhase) { _, value in if value != .active { player.stop(); owner.close() } }
    }

    private func search() async {
        guard allowed else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result: SDRecordingPage = try await api.get(["onvif", "cameras", camera, "recordings"], query: [
                .init(name: "start", value: start.ISO8601Format()), .init(name: "end", value: end.ISO8601Format()),
            ])
            guard allowed, !Task.isCancelled else { return }
            recordings = result
        } catch { self.error = error.localizedDescription }
    }
}
