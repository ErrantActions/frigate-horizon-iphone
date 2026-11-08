import Foundation

public struct RecordedMP4Range: Equatable, Sendable {
    public static let maximumRead = 1_048_576
    public let offset: Int64
    public let count: Int
    public var header: String { "bytes=\(offset)-\(offset + Int64(count) - 1)" }
    public init(offset: Int64, count: Int) throws {
        guard offset >= 0, count > 0, count <= Self.maximumRead,
              offset <= Int64.max - Int64(count) else { throw RecordedHTTPError.invalidRange }
        self.offset = offset; self.count = count
    }
    public func validate(status: Int, contentRange: String?, length: Int64, bodyCount: Int) throws {
        if status == 401 { throw HorizonError.unauthorized }
        if status == 403 { throw HorizonError.forbidden }
        if status == 416 {
            guard contentRange == "bytes */\(length)", offset >= length, bodyCount == 0 else {
                throw RecordedHTTPError.invalidRange
            }
            return
        }
        guard status == 206 else {
            if status == 200 { throw RecordedHTTPError.rangeUnsupported }
            throw HorizonError.http(status)
        }
        let end = min(length - 1, offset + Int64(count) - 1)
        guard offset < length, contentRange == "bytes \(offset)-\(end)/\(length)",
              Int64(bodyCount) == end - offset + 1 else { throw RecordedHTTPError.invalidRange }
    }
}

private final class MP4Cookies: @unchecked Sendable {
    private struct Key: Hashable {
        let name: String
        let domain: String
        let path: String
        init(_ cookie: HTTPCookie) {
            name = cookie.name; domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); path = cookie.path
        }
    }
    private let lock = NSLock()
    private let address: ServerAddress
    private var cookies: [Key: HTTPCookie] = [:]
    init(_ initial: [HTTPCookie], address: ServerAddress) {
        self.address = address
        for cookie in initial { cookies[Key(cookie)] = cookie }
    }
    func replace(with current: [HTTPCookie]) {
        lock.lock(); defer { lock.unlock() }
        cookies.removeAll()
        for cookie in current { cookies[Key(cookie)] = cookie }
    }
    func headers(for url: URL) -> [String: String] {
        lock.lock(); let values = Array(cookies.values); lock.unlock()
        let scoped = SavedSession.cookiesForRequest(values, address: address, url: url)
        return HTTPCookie.requestHeaderFields(with: scoped)
    }
    func receive(_ response: HTTPURLResponse) {
        guard let url = response.url, address.hasSameOrigin(as: url) else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        let updates = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        lock.lock(); defer { lock.unlock() }
        for cookie in updates {
            if SavedSession.SavedCookie(cookie).restore(for: address) != nil { cookies[Key(cookie)] = cookie }
            else { cookies.removeValue(forKey: Key(cookie)) }
        }
    }
}

private final class MP4ReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let cookies: MP4Cookies
    init(cookies: MP4Cookies) { self.cookies = cookies; super.init() }
    struct Read {
        let range: RecordedMP4Range
        let length: Int64
        let continuation: CheckedContinuation<Data, Error>
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
    }
    private let lock = NSLock()
    private var reads: [Int: Read] = [:]
    func register(_ task: URLSessionDataTask, range: RecordedMP4Range, length: Int64, continuation: CheckedContinuation<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        reads[task.taskIdentifier] = Read(range: range, length: length, continuation: continuation)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var read = reads[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        do {
            guard let http = response as? HTTPURLResponse else { throw HorizonError.unexpectedResponse }
            cookies.receive(http)
            let size = Int(min(Int64(read.range.count), read.length - read.range.offset))
            try read.range.validate(status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                length: read.length, bodyCount: http.statusCode == 416 ? 0 : size)
            guard http.statusCode == 206,
                  http.mimeType == "video/mp4" || http.mimeType == "application/mp4",
                  http.expectedContentLength < 0 || http.expectedContentLength == Int64(size) else {
                throw RecordedHTTPError.invalidRange
            }
            read.response = http
            reads[dataTask.taskIdentifier] = read
            lock.unlock(); completionHandler(.allow)
        } catch {
            read.error = error; reads[dataTask.taskIdentifier] = read
            lock.unlock(); completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var read = reads[dataTask.taskIdentifier] else { lock.unlock(); return }
        if data.count > read.range.count - read.data.count {
            read.error = RecordedHTTPError.invalidRange
            reads[dataTask.taskIdentifier] = read
            lock.unlock(); dataTask.cancel(); return
        }
        read.data.append(data); reads[dataTask.taskIdentifier] = read
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let read = reads.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let read else { return }
        do {
            if let error = read.error ?? error { throw error }
            guard let response = read.response else { throw HorizonError.unexpectedResponse }
            try read.range.validate(status: response.statusCode, contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                length: read.length, bodyCount: read.data.count)
            read.continuation.resume(returning: read.data)
        } catch { read.continuation.resume(throwing: error) }
    }
}

private final class MP4ReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ value: URLSessionTask) {
        lock.lock(); task = value; let cancel = cancelled; lock.unlock()
        if cancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
}

public final class AuthenticatedRecordedMP4Reader: @unchecked Sendable {
    public let mediaURL: URL
    public let length: Int64
    private let session: URLSession
    private let delegate: MP4ReadDelegate
    private let cookieStore: MP4Cookies
    private let cookieProvider: (@Sendable () async throws -> [HTTPCookie])?
    public convenience init(mediaURL: URL, info: RecordedHTTPMediaInfo, policy: RecordedHTTPResourcePolicy,
                cookies: [HTTPCookie], configuration: URLSessionConfiguration = .ephemeral,
                cookieProvider: (@Sendable () async throws -> [HTTPCookie])? = nil) throws {
        try info.validate()
        try self.init(mediaURL: mediaURL, verificationLength: info.length, policy: policy, cookies: cookies,
            configuration: configuration, cookieProvider: cookieProvider)
    }
    public init(mediaURL: URL, verificationLength: Int64, policy: RecordedHTTPResourcePolicy,
                cookies: [HTTPCookie], configuration: URLSessionConfiguration = .ephemeral,
                cookieProvider: (@Sendable () async throws -> [HTTPCookie])? = nil) throws {
        self.mediaURL = try policy.validate(mediaURL)
        guard verificationLength > 0 else { throw RecordedHTTPError.rangeUnsupported }
        length = verificationLength
        self.cookieProvider = cookieProvider
        let cookieStore = MP4Cookies(cookies, address: policy.address)
        self.cookieStore = cookieStore
        delegate = MP4ReadDelegate(cookies: cookieStore)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    public func read(_ range: RecordedMP4Range) async throws -> Data {
        if range.offset >= length { return Data() }
        try Task.checkCancellation()
        if let cookieProvider { cookieStore.replace(with: try await cookieProvider()) }
        try Task.checkCancellation()
        var request = URLRequest(url: mediaURL, cachePolicy: .reloadIgnoringLocalCacheData)
        // URLSession protocol/custom-loader requests must carry observable auth themselves.
        request.httpShouldHandleCookies = false
        for (name, value) in cookieStore.headers(for: mediaURL) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(range.header, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let cancellation = MP4ReadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, range: range, length: length, continuation: continuation)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
    public func close() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}
