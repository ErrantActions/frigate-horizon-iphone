import AVFoundation
import Foundation
import Network
import Security

private enum HLSLocalDeliveryError: Error { case requestClosed }

struct LiveHLSLocalRequest {
    let url: URL
    let range: HLSByteRange?
    let head: Bool
}

struct LiveHLSLocalRoute: Sendable {
    let policy: LiveHLSResourcePolicy
    let port: UInt16
    let credential: String
    let cookieName: String
    init(policy: LiveHLSResourcePolicy, port: UInt16, credential: String,
         cookieName: String = "HorizonLocalLive") {
        self.policy = policy
        self.port = port
        self.credential = credential
        self.cookieName = cookieName
    }
    private let mount = "/live-hls"

    func localURL(_ remote: URL) throws -> URL {
        let safe = try policy.validate(remote)
        var parts = URLComponents(url: safe, resolvingAgainstBaseURL: false)!
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = Int(port)
        parts.percentEncodedPath = mount + parts.percentEncodedPath
        guard let url = parts.url else { throw HorizonError.invalidMediaPath }
        return url
    }

    func parse(_ data: Data) throws -> LiveHLSLocalRequest {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { throw HorizonError.invalidMediaPath }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
              ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])),
              first[1].hasPrefix(mount + "/") else { throw HorizonError.invalidMediaPath }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HorizonError.invalidMediaPath }
            let key = line[..<colon].lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { throw HorizonError.invalidMediaPath }
            headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"].map({ $0 == "0" }) ?? true else { throw HorizonError.invalidMediaPath }
        let cookies = headers["cookie"]?.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? []
        guard cookies.contains("\(cookieName)=\(credential)") else { throw HorizonError.unauthorized }
        guard let local = URLComponents(string: "http://127.0.0.1:\(port)\(first[1])"),
              local.fragment == nil, local.user == nil, local.password == nil else { throw HorizonError.invalidMediaPath }
        var remote = URLComponents(url: policy.canonicalMaster, resolvingAgainstBaseURL: false)!
        remote.percentEncodedPath = String(local.percentEncodedPath.dropFirst(mount.count))
        remote.percentEncodedQuery = local.percentEncodedQuery
        guard let url = remote.url else { throw HorizonError.invalidMediaPath }
        let safe = try policy.validate(url)
        var range: HLSByteRange?
        if let header = headers["range"] {
            guard header.hasPrefix("bytes="), !header.contains(",") else { throw HorizonError.invalidMediaPath }
            let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), start >= 0 else { throw HorizonError.invalidMediaPath }
            if bounds[1].isEmpty { range = try HLSByteRange(offset: start, length: nil) }
            else {
                guard let end = Int64(bounds[1]), end >= start, end - start < 16_777_216 else {
                    throw HorizonError.invalidMediaPath
                }
                range = try HLSByteRange(offset: start, length: Int(end - start + 1))
            }
        }
        return LiveHLSLocalRequest(url: safe, range: range, head: first[0] == "HEAD")
    }
}

@MainActor
public final class AuthenticatedLiveHLSAsset {
    public let asset: AVURLAsset
    private let proxy: LiveHLSLoopbackProxy
    public var onFailure: ((Error) -> Void)? {
        get { proxy.onFailure }
        set { proxy.onFailure = newValue }
    }

    public init(client: AuthenticatedLiveHLSClient) async throws {
        let proxy = try LiveHLSLoopbackProxy(client: client)
        self.proxy = proxy
        do {
            let url = try await proxy.start()
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [try proxy.cookie()]])
        } catch {
            proxy.close()
            throw error
        }
    }

    public func close() { asset.cancelLoading(); proxy.close() }
}

// AVPlayer reads ordinary local HLS; only this adapter can fetch remote media, over scoped HTTPS.
@MainActor
private final class LiveHLSLoopbackProxy {
    private let client: AuthenticatedLiveHLSClient
    private let listener: NWListener
    private let credential: String
    private let cookieName = "HorizonLocalLive_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var route: LiveHLSLocalRoute?
    private var opening: CheckedContinuation<URL, Error>?
    private var openingTimeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    var onFailure: ((Error) -> Void)?

    init(client: AuthenticatedLiveHLSClient) throws {
        self.client = client
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HorizonError.message("The private live-player transport could not initialize.")
        }
        credential = bytes.map { String(format: "%02x", $0) }.joined()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else {
                            self.finishOpening(.failure(HorizonError.unexpectedResponse))
                            return
                        }
                        self.route = LiveHLSLocalRoute(policy: self.client.policy, port: port.rawValue,
                            credential: self.credential, cookieName: self.cookieName)
                        do { self.finishOpening(.success(try self.route!.localURL(self.client.masterURL))) }
                        catch { self.finishOpening(.failure(error)) }
                    case .failed(let error):
                        self.finishOpening(.failure(error))
                        self.onFailure?(error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
            openingTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finishOpening(.failure(HorizonError.message("The private live-player transport did not start.")))
            }
        }
    }

    private func finishOpening(_ result: Result<URL, Error>) {
        openingTimeout?.cancel()
        openingTimeout = nil
        let continuation = opening
        opening = nil
        continuation?.resume(with: result)
    }

    func cookie() throws -> HTTPCookie {
        guard let cookie = HTTPCookie(properties: [.name: cookieName,
            .value: credential, .domain: "127.0.0.1", .path: "/live-hls"]) else {
            throw HorizonError.unexpectedResponse
        }
        return cookie
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, route != nil, connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.remove(id) }
            default: break
            }
        }
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.remove(id)
        }
        readHeader(id, data: Data())
    }

    private func readHeader(_ id: UUID, data: Data) {
        guard let connection = connections[id], data.count < 16_384 else { remove(id); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - data.count) {
            [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var header = data
                if let chunk { header.append(chunk) }
                if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                    guard end.upperBound == header.count else { self.remove(id); return }
                    self.deadlines.removeValue(forKey: id)?.cancel()
                    self.serve(id, header: header)
                } else if error != nil || complete { self.remove(id) }
                else { self.readHeader(id, data: header) }
            }
        }
    }

    private func serve(_ id: UUID, header: Data) {
        guard let route, let connection = connections[id] else { remove(id); return }
        let request: LiveHLSLocalRequest
        do { request = try route.parse(header) }
        catch {
            connection.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.remove(id) }
            do {
                let playlist = request.url.pathExtension.lowercased() == "m3u8"
                let boundedRange = request.range.map { $0.offset != 0 || $0.length != nil } ?? false
                if playlist || boundedRange {
                    let resource = try await self.client.load(request.url)
                    var data = resource.data
                    if playlist {
                        guard let text = String(data: data, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
                        data = Data(try self.client.policy.rewriteAssetPlaylist(text) { try route.localURL($0) }.utf8)
                    }
                    let total = playlist ? Int64(data.count) : resource.totalLength
                    let full = LiveHLSResource(data: data, offset: playlist ? 0 : resource.offset,
                        totalLength: total, pathExtension: resource.pathExtension)
                    let start = request.range?.offset ?? 0
                    let body = try full.bytes(at: start, length: request.range?.length, toEnd: request.range?.length == nil)
                    let ranged = request.range != nil
                    let contentRange = ranged ? "bytes \(start)-\(start + Int64(body.count) - 1)/\(total)" : nil
                    try await self.send(connection, data: self.response(status: ranged ? 206 : 200,
                        path: request.url.pathExtension, length: Int64(body.count), contentRange: contentRange))
                    if !request.head { try await self.send(connection, data: body) }
                } else {
                    var chunked = false
                    for try await event in try self.client.streamMedia(request.url) {
                        try Task.checkCancellation()
                        switch event {
                        case .response(let status, let length, let contentRange):
                            chunked = length == nil
                            try await self.send(connection, data: self.response(status: status,
                                path: request.url.pathExtension, length: length, contentRange: contentRange))
                            if request.head { return }
                        case .data(let data):
                            if chunked {
                                try await self.send(connection, data: Data("\(String(data.count, radix: 16))\r\n".utf8))
                            }
                            try await self.send(connection, data: data)
                            if chunked { try await self.send(connection, data: Data("\r\n".utf8)) }
                        }
                    }
                    if chunked { try await self.send(connection, data: Data("0\r\n\r\n".utf8)) }
                }
                try await self.finishSending(connection)
            } catch HLSLocalDeliveryError.requestClosed {
                // AVPlayer can close an old request during ABR/seek without ending playback.
                return
            } catch {
                guard !self.closed, !Task.isCancelled else { return }
                self.onFailure?(error)
            }
        }
    }

    private func response(status: Int, path: String, length: Int64?, contentRange: String?) -> Data {
        let mime: String
        switch path.lowercased() {
        case "m3u8": mime = "application/vnd.apple.mpegurl"
        case "ts": mime = "video/mp2t"
        case "aac": mime = "audio/aac"
        default: mime = "video/mp4"
        }
        var lines = ["HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")",
            "Content-Type: \(mime)", "Cache-Control: private, no-store", "Connection: close", "Accept-Ranges: bytes"]
        if let length { lines.append("Content-Length: \(length)") }
        else { lines.append("Transfer-Encoding: chunked") }
        if let contentRange { lines.append("Content-Range: \(contentRange)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: HLSLocalDeliveryError.requestClosed) }
                else { continuation.resume() }
            })
        }

    }

    private func finishSending(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: HLSLocalDeliveryError.requestClosed) }
                    else { continuation.resume() }
                })
        }
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        jobs.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }

    func close() {
        guard !closed else { return }
        closed = true
        finishOpening(.failure(CancellationError()))
        listener.cancel()
        for id in Array(connections.keys) { remove(id) }
        client.invalidate()
        onFailure = nil
    }
}
