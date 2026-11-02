import Foundation
import HorizonCore

final class SameOriginDelegate: NSObject, URLSessionTaskDelegate {
    let address: ServerAddress

    init(address: ServerAddress) { self.address = address }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map { address.hasSameOrigin(as: $0) } == true ? request : nil)
    }
}

final class ViewerTaskDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class HorizonAPI {
    let address: ServerAddress
    let session: URLSession
    private(set) var viewingAccountKey: String?
    func bindViewingAccount(username: String) throws {
        let key = HorizonAccountScope.key(server: address.url.absoluteString, username: username)
        if let existing = viewingAccountKey, existing != key { throw HorizonError.unauthorized }
        viewingAccountKey = key
    }

    init(
        address: ServerAddress, cookies: [HTTPCookie] = [],
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.address = address
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = ["X-CSRF-TOKEN": "1"]
        configuration.urlCache = nil
        for cookie in cookies {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        session = URLSession(
            configuration: configuration,
            delegate: SameOriginDelegate(address: address), delegateQueue: nil
        )
    }

    var cookies: [HTTPCookie] {
        SavedSession.cookiesForMedia(session.configuration.httpCookieStorage?.cookies ?? [], address: address)
    }

    func close() { session.invalidateAndCancel() }

    deinit { session.invalidateAndCancel() }

    func login(user: String, password: String) async throws {
        struct Login: Encodable { let user: String; let password: String }
        var request = URLRequest(url: address.endpoint(["api", "login"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Login(user: user, password: password))
        _ = try await data(request)
    }

    func get<T: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> T {
        let bytes = try await data(URLRequest(url: address.endpoint(["api"] + path, query: query)))
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    func viewerRequest(_ url: URL, method: String = "GET", body: Data? = nil,
                       success: Set<Int> = [200]) async throws -> Data {
        try await viewerResponse(url, method: method, body: body, success: success).data
    }

    func viewerResponse(_ url: URL, method: String = "GET", body: Data? = nil,
                        success: Set<Int> = [200]) async throws -> (data: Data, response: HTTPURLResponse) {
        guard address.url.scheme == "https", address.hasSameOrigin(as: url),
              url.path.hasPrefix(address.endpoint(["api"]).path + "/"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw HorizonError.message(ViewingMessage.invalid)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let result = try await dataWithHTTPResponse(request, viewerRequest: true)
        guard success.contains(result.response.statusCode) else { throw HorizonError.unexpectedResponse }
        return result
    }

    func image(_ url: URL) async throws -> Data {
        guard address.hasSameOrigin(as: url) else { throw HorizonError.invalidMediaPath }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await data(request)
    }

    func send<T: Decodable, Body: Encodable>(
        _ path: [String], method: String = "POST", body: Body, query: [URLQueryItem] = []
    ) async throws -> T {
        let result = try await sendWithHTTPResponse(path, method: method, body: body, query: query)
        return try JSONDecoder().decode(T.self, from: result.data)
    }

    func sendWithHTTPResponse<Body: Encodable>(
        _ path: [String], method: String = "POST", body: Body, query: [URLQueryItem] = []
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: address.endpoint(["api"] + path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await dataWithHTTPResponse(request)
    }

    func action<Body: Encodable>(_ path: [String], method: String = "POST", body: Body) async throws {
        let result: APIActionResult = try await send(path, method: method, body: body)
        try result.requireSuccess()
    }

    func deleteBookmark(camera: String, id: String, revision: Int) async throws {
        guard revision >= 1 else { throw HorizonError.message("Reload the bookmark before deleting it.") }
        var request = URLRequest(url: address.endpoint(["api", camera, "recordings", "bookmarks", id], query: [
            URLQueryItem(name: "revision", value: String(revision)),
        ]))
        request.httpMethod = "DELETE"
        let result = try await data(request)
        guard result.isEmpty else { throw HorizonError.unexpectedResponse }
    }

    func text(_ path: [String]) async throws -> String {
        let bytes = try await data(URLRequest(url: address.endpoint(["api"] + path)))
        if bytes.first == 34 { return try JSONDecoder().decode(String.self, from: bytes) }
        guard let value = String(data: bytes, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
        return value
    }

    func saveConfiguration(_ yaml: String, restart: Bool) async throws -> APIActionResult {
        var request = URLRequest(url: address.endpoint(["api", "config", "save"], query: [
            URLQueryItem(name: "save_option", value: restart ? "restart" : "saveonly"),
        ]))
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(yaml.utf8)
        let result = try JSONDecoder().decode(APIActionResult.self, from: await data(request))
        try result.requireSuccess()
        return result
    }

    func streamLogs(service: String, onLine: @MainActor (String) -> Void) async throws {
        guard ["frigate", "nginx", "go2rtc"].contains(service) else {
            throw HorizonError.message("Choose a supported log service.")
        }
        let configuration = session.configuration
        configuration.timeoutIntervalForResource = 86400
        let streaming = URLSession(configuration: configuration,
            delegate: SameOriginDelegate(address: address), delegateQueue: nil)
        defer { streaming.invalidateAndCancel() }
        let request = URLRequest(url: address.endpoint(["api", "logs", service], query: [
            URLQueryItem(name: "stream", value: "true"),
        ]))
        let (bytes, response) = try await streaming.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw HorizonError.unexpectedResponse }
        if response.statusCode == 403 { throw HorizonError.forbidden }
        if response.statusCode == 401 { throw HorizonError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw HorizonError.http(response.statusCode) }
        guard response.mimeType == "text/plain" else { throw HorizonError.unexpectedResponse }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            await onLine(line)
        }
        throw HorizonError.message("The live log stream ended. Refresh or reconnect to continue following logs.")
    }

    func download(_ url: URL, fileExtension: String) async throws -> URL {
        guard address.hasSameOrigin(as: url), ["mp4", "jpg", "zip"].contains(fileExtension) else {
            throw HorizonError.invalidMediaPath
        }
        let configuration = session.configuration
        configuration.timeoutIntervalForResource = 600
        configuration.timeoutIntervalForRequest = 60
        let downloader = URLSession(configuration: configuration,
            delegate: SameOriginDelegate(address: address), delegateQueue: nil)
        defer { downloader.invalidateAndCancel() }
        let (temporary, response) = try await downloader.download(from: url)
        guard let response = response as? HTTPURLResponse else { throw HorizonError.unexpectedResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw HorizonError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw HorizonError.http(response.statusCode) }
        let expectedTypes: [String: Set<String>] = [
            "mp4": ["video/mp4", "application/octet-stream"],
            "jpg": ["image/jpeg", "image/jpg", "application/octet-stream"],
            "zip": ["application/zip", "application/octet-stream"],
        ]
        guard let mime = response.mimeType, expectedTypes[fileExtension]?.contains(mime) == true else {
            throw HorizonError.unexpectedResponse
        }
        try Task.checkCancellation()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Horizon-\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func markReviewed(_ id: String, reviewed: Bool) async throws {
        struct Body: Encodable { let ids: [String]; let reviewed: Bool }
        try await action(["reviews", "viewed"], body: Body(ids: [id], reviewed: reviewed))
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let result = try await dataWithHTTPResponse(request)
        return result.data
    }

    private func dataWithHTTPResponse(_ request: URLRequest,
                                      distinguishCameraDenial: Bool = false, viewerRequest: Bool = false) async throws -> (data: Data, response: HTTPURLResponse) {
        let (bytes, response) = try await session.data(for: request, delegate: viewerRequest ? ViewerTaskDelegate() : nil)
        guard let response = response as? HTTPURLResponse else { throw HorizonError.unexpectedResponse }
        if response.statusCode == 403 {
            if viewerRequest {
                let detail = ViewerValidationResponse.detail(data: bytes, mimeType: response.mimeType)
                if detail.lowercased().contains("csrf") {
                    throw HorizonError.server(status: 403, message: detail)
                }
            }
            throw HorizonError.forbidden
        }
        if response.statusCode == 401 { throw HorizonError.unauthorized }
        if viewerRequest && response.statusCode == 422 {
            throw HorizonError.server(status: 422,
                message: ViewerValidationResponse.detail(data: bytes, mimeType: response.mimeType))
        }
        guard (200..<300).contains(response.statusCode) else {
            struct ServerFailure: Decodable { let message: String?; let detail: String? }
            if response.mimeType == "application/json" {
                do {
                    let failure = try JSONDecoder().decode(ServerFailure.self, from: bytes)
                    if let message = failure.message ?? failure.detail {
                        throw HorizonError.server(status: response.statusCode,
                            message: String(message.prefix(4000)))
                    }
                } catch is DecodingError {
                    throw HorizonError.http(response.statusCode)
                }
            }
            throw HorizonError.http(response.statusCode)
        }
        if response.mimeType == "text/html" { throw HorizonError.unexpectedResponse }
        return (bytes, response)
    }
}
