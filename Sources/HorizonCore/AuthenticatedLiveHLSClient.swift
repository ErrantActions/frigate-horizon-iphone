import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HLSByteRange: Sendable {
    public let offset: Int64
    public let length: Int?
    public init(offset: Int64, length: Int?) throws {
        guard offset >= 0, length.map({ $0 > 0 && $0 <= 16_777_216 }) ?? true,
              !offset.addingReportingOverflow(Int64(length ?? 1) - 1).overflow else {
            throw HorizonError.invalidMediaPath
        }
        self.offset = offset
        self.length = length
    }
}

public struct LiveHLSResource: Sendable {
    public let data: Data
    public let offset: Int64
    public let totalLength: Int64
    public let pathExtension: String

    public func bytes(at requestedOffset: Int64, length: Int?, toEnd: Bool) throws -> Data {
        guard requestedOffset >= offset, requestedOffset - offset <= Int64(data.count) else {
            throw HorizonError.unexpectedResponse
        }
        let start = Int(requestedOffset - offset)
        let count = toEnd ? data.count - start : min(length ?? 0, data.count - start)
        guard count >= 0 else { throw HorizonError.unexpectedResponse }
        return data.subdata(in: start..<(start + count))
    }
}

public enum LiveHLSNetworkEvent: Sendable {
    case response(status: Int, length: Int64?, contentRange: String?)
    case data(Data)
}

private final class HLSRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func bind(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

// Delegate state is locked; the session uses an ephemeral, camera-scoped cookie jar.
public final class AuthenticatedLiveHLSClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let policy: LiveHLSResourcePolicy
    public let masterURL: URL
    private let maximumHeight: Int?
    private let lock = NSLock()
    private var session: URLSession!
    private var closed = false
    private var measurementHandler: (@Sendable (HLSMeasurement) -> Void)?
    private var initializationURLs: Set<URL> = []
    private struct Pending {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var stream: AsyncThrowingStream<LiveHLSNetworkEvent, Error>.Continuation?
        var response: HTTPURLResponse?
        var data = Data()
        var received = 0
        let startedAt: TimeInterval
        var firstByte: TimeInterval?
        let kind: HLSRequestMeasurement.Kind
        let limit: Int
    }
    private var pending: [Int: Pending] = [:]

    public func setMeasurementHandler(_ handler: @escaping @Sendable (HLSMeasurement) -> Void) {
        lock.lock()
        measurementHandler = handler
        lock.unlock()
    }

    public init(policy: LiveHLSResourcePolicy, cookies: [HTTPCookie], maximumHeight: Int? = nil,
                configuration: URLSessionConfiguration = .ephemeral, masterURL: URL? = nil) {
        self.policy = policy
        self.masterURL = masterURL ?? policy.canonicalMaster
        self.maximumHeight = maximumHeight
        super.init()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func prepareMaster() async throws -> LiveHLSMaster {
        let (data, _) = try await request(masterURL)
        guard let text = String(data: data, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
        let master = try LiveHLSMaster(text: text, policy: policy, url: masterURL,
            maximumHeight: maximumHeight)
        return master
    }

    public func load(_ url: URL) async throws -> LiveHLSResource {
        let url = try policy.validate(url)
        let playlist = url.pathExtension.lowercased() == "m3u8"
        let (data, _) = try await request(url)
        if playlist {
            guard let text = String(data: data, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
            let selected: String
            if policy.isLive && url.path == policy.canonicalMaster.path {
                selected = try LiveHLSMaster(text: text, policy: policy, url: url, maximumHeight: maximumHeight).playlist
            } else { selected = text }
            try recordPlaylist(selected, url: url)
            let rewritten = Data(try policy.rewritePlaylist(selected, url: url).utf8)
            return LiveHLSResource(data: rewritten, offset: 0, totalLength: Int64(rewritten.count), pathExtension: "m3u8")
        }
        return LiveHLSResource(data: data, offset: 0, totalLength: Int64(data.count),
            pathExtension: url.pathExtension.lowercased())
    }

    public func streamMedia(_ url: URL) throws -> AsyncThrowingStream<LiveHLSNetworkEvent, Error> {
        let url = try policy.validate(url)
        guard url.pathExtension.lowercased() != "m3u8" else { throw HorizonError.invalidMediaPath }
        let cancellation = HLSRequestCancellation()
        return AsyncThrowingStream { stream in
            stream.onTermination = { _ in cancellation.cancel() }
            let request = makeRequest(url)
            lock.lock()
            guard !closed, pending.count < 16 else {
                lock.unlock()
                stream.finish(throwing: HorizonError.message("Live HLS loading is closed or at its request limit."))
                return
            }
            let task = session.dataTask(with: request)
            pending[task.taskIdentifier] = Pending(stream: stream,
                startedAt: ProcessInfo.processInfo.systemUptime, kind: resourceKind(url), limit: 67_108_864)
            lock.unlock()
            cancellation.bind(task)
            task.resume()
        }
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        _ = try policy.validate(url)
        try Task.checkCancellation()
        let cancellation = HLSRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = makeRequest(url)
                lock.lock()
                guard !closed, pending.count < 16 else {
                    lock.unlock()
                    continuation.resume(throwing: HorizonError.message("Live HLS loading is closed or at its request limit."))
                    return
                }
                let task = session.dataTask(with: request)
                pending[task.taskIdentifier] = Pending(continuation: continuation,
                    startedAt: ProcessInfo.processInfo.systemUptime, kind: resourceKind(url),
                    limit: url.pathExtension.lowercased() == "m3u8" ? 1_048_576 : 67_108_864)
                lock.unlock()
                cancellation.bind(task)
                task.resume()
            }

        } onCancel: { cancellation.cancel() }
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: url) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    // Called with the delegate-state lock held.
    private func resourceKind(_ url: URL) -> HLSRequestMeasurement.Kind {
        if url.path == policy.canonicalMaster.path { return .master }
        if url.pathExtension.lowercased() == "m3u8" { return .childPlaylist }
        return initializationURLs.contains(url) ? .initialization : .media
    }

    private func recordPlaylist(_ text: String, url: URL) throws {
        var maps: [URL] = []
        var targets: [Double] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try HLSAttributes.parse(line)
                guard let uri = attributes["URI"] else { throw HorizonError.unexpectedResponse }
                maps.append(try policy.resolve(uri, relativeTo: url))
            }
            if line.hasPrefix("#EXT-X-PART-INF:") {
                let attributes = try HLSAttributes.parse(line)
                guard let value = attributes["PART-TARGET"].flatMap(Double.init), value.isFinite, value > 0 else {
                    throw HorizonError.message("The HLS packager returned an invalid PART-TARGET, not an authentication failure.")
                }
                targets.append(value)
            }
        }
        lock.lock()
        if initializationURLs.count > 128 { initializationURLs.removeAll(keepingCapacity: true) }
        for map in maps { initializationURLs.insert(map) }
        let handler = measurementHandler
        lock.unlock()
        for target in targets { handler?(.partTarget(target)) }
    }

    public func invalidate() {
        lock.lock()
        closed = true
        let cancelled = Array(pending.values)
        pending.removeAll()
        initializationURLs.removeAll()
        measurementHandler = nil
        lock.unlock()
        session.invalidateAndCancel()
        for record in cancelled {
            record.continuation?.resume(throwing: CancellationError())
            record.stream?.finish(throwing: CancellationError())
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? policy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse, let url = response.url else {
                throw HorizonError.unexpectedResponse
            }
            lock.lock()
            pending[dataTask.taskIdentifier]?.response = response
            lock.unlock()
            _ = try policy.validate(url)
            if response.statusCode == 401 { throw HorizonError.unauthorized }
            if response.statusCode == 403 { throw HorizonError.forbidden }
            guard response.statusCode == 200 else { throw HorizonError.http(response.statusCode) }
            let playlist = url.pathExtension.lowercased() == "m3u8"
            let validMime = playlist ? ["application/vnd.apple.mpegurl", "application/x-mpegurl"] :
                (policy.isLive ? ["video/mp4"] : ["video/mp4", "audio/mp4", "video/mp2t", "audio/aac", "application/octet-stream"])
            guard response.mimeType.map({ validMime.contains($0.lowercased()) }) == true else {
                throw HorizonError.unexpectedResponse
            }
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding != "identity",
               url.pathExtension.lowercased() != "m3u8" { throw HorizonError.unexpectedResponse }
            lock.lock()
            let limit = pending[dataTask.taskIdentifier]?.limit
            let record = pending[dataTask.taskIdentifier]
            let allowed = limit.map { response.expectedContentLength < 0 || response.expectedContentLength <= Int64($0) } ?? false
            if allowed { pending[dataTask.taskIdentifier]?.response = response }
            lock.unlock()
            guard allowed else { throw HorizonError.message("The live HLS resource exceeds its size limit.") }
            if let stream = record?.stream {
                stream.yield(.response(status: response.statusCode,
                    length: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
                    contentRange: nil))
            }
            completionHandler(.allow)
        } catch {
            finish(dataTask, error: error)
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var record = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        guard data.count <= record.limit - record.received else {
            lock.unlock()
            finish(dataTask, error: HorizonError.message("The live HLS resource exceeds its size limit."))
            dataTask.cancel()
            return
        }
        record.received += data.count
        if record.firstByte == nil { record.firstByte = ProcessInfo.processInfo.systemUptime - record.startedAt }
        if record.stream == nil { record.data.append(data) }
        pending[dataTask.taskIdentifier] = record
        lock.unlock()
        record.stream?.yield(.data(data))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task, error: error)
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        lock.lock()
        let record = pending.removeValue(forKey: task.taskIdentifier)
        let handler = measurementHandler
        lock.unlock()
        guard let record else { return }
        handler?(.request(HLSRequestMeasurement(kind: record.kind,
            elapsed: ProcessInfo.processInfo.systemUptime - record.startedAt,
            firstByte: record.firstByte, status: (error as? HorizonError)?.httpStatusCode ?? record.response?.statusCode,
            bytes: record.received)))
        if let error {
            record.continuation?.resume(throwing: error)
            record.stream?.finish(throwing: error)
        } else if let response = record.response {
            record.continuation?.resume(returning: (record.data, response))
            if let stream = record.stream {
                if response.expectedContentLength >= 0 && response.expectedContentLength != Int64(record.received) {
                    stream.finish(throwing: HorizonError.unexpectedResponse)
                } else { stream.finish() }
            }
        } else {
            record.continuation?.resume(throwing: HorizonError.unexpectedResponse)
            record.stream?.finish(throwing: HorizonError.unexpectedResponse)
        }
    }

}
