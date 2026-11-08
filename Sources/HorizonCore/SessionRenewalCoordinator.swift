import Foundation

public struct SessionAuthenticationReceipt: Equatable, Sendable {
    public let username: String
    public let role: String
}

private final class SessionAuthRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor SessionRenewalCoordinator {
    private let session: URLSession
    private let address: ServerAddress
    private var pending: Task<SessionAuthenticationReceipt, Error>?
    private var lastResult: Result<SessionAuthenticationReceipt, Error>?
    private var checkedAt = -Double.infinity
    public init(session: URLSession, address: ServerAddress) {
        self.session = session; self.address = address
    }
    public func check(force: Bool = false) async throws -> SessionAuthenticationReceipt {
        if let pending {
            let value = try await pending.value
            try Task.checkCancellation()
            return value
        }
        let age = ProcessInfo.processInfo.systemUptime - checkedAt
        if let lastResult {
            let interval: Double
            switch lastResult {
            case .success: interval = force ? 1 : 20
            case .failure: interval = 1
            }
            if age < interval {
                try Task.checkCancellation()
                return try lastResult.get()
            }
        }
        let session = self.session, address = self.address
        // Shared authentication work isn't cancelled by one disappearing tile.
        let work = Task {
            let url = address.endpoint(["api","auth"])
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 25
            request.httpShouldHandleCookies = false
            let cookies = SavedSession.cookiesForRequest(session.configuration.httpCookieStorage?.cookies ?? [],
                address: address, url: url)
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await session.data(for: request, delegate: SessionAuthRedirectDelegate())
            guard let response = response as? HTTPURLResponse else { throw HorizonError.unexpectedResponse }
            if response.statusCode == 401 { throw HorizonError.unauthorized }
            if response.statusCode == 403 { throw HorizonError.forbidden }
            guard response.statusCode == 202, data.isEmpty,
                  let username = response.value(forHTTPHeaderField: "remote-user"), !username.isEmpty,
                  let role = response.value(forHTTPHeaderField: "remote-role"), !role.isEmpty else {
                throw HorizonError.unexpectedResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String:String]()) { fields, item in
                if let key = item.key as? String, let value = item.value as? String { fields[key] = value }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                session.configuration.httpCookieStorage?.setCookie(cookie)
            }
            return SessionAuthenticationReceipt(username: username, role: role)
        }
        pending = work
        let result = await work.result
        pending = nil; lastResult = result; checkedAt = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        return try result.get()
    }
}
