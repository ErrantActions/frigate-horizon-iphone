import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SavedSession: Codable, Equatable, Sendable {
    public let server: String
    public let cookies: [SavedCookie]

    public init(server: String, cookies: [SavedCookie]) {
        self.server = server
        self.cookies = cookies
    }

    public static func cookiesForMedia(_ cookies: [HTTPCookie], address: ServerAddress) -> [HTTPCookie] {
        // Retain original cookie paths; the receiving private jar selects them for each child URL.
        cookies.filter { SavedCookie($0).restore(for: address) != nil }
    }

    public struct SavedCookie: Codable, Equatable, Sendable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let secure: Bool
        public let expires: Date?

        public init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            secure = cookie.isSecure
            expires = cookie.expiresDate
        }

        public func restore(for address: ServerAddress) -> HTTPCookie? {
            let host = address.url.host?.lowercased() ?? ""
            let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == cookieDomain || host.hasSuffix("." + cookieDomain),
                  expires.map({ $0 > Date() }) ?? true else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
}
