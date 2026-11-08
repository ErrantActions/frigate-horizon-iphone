import Foundation

public struct ConnectionIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case invalidAddress, authentication, accessDenied, offline, dns, unreachable, timedOut
        case certificate, secureConnection, serverUnavailable, rateLimited
        case unexpectedResponse, cancelled, other
    }

    public let kind: Kind
    public let httpStatus: Int?
    public let networkCode: Int?

    public init(error: Error) {
        if error is CancellationError {
            self.init(kind: .cancelled)
            return
        }
        if let failure = error as? HorizonError {
            if let status = failure.httpStatusCode {
                let kind: Kind
                switch status {
                case 401: kind = .authentication
                case 403: kind = .accessDenied
                case 408, 504: kind = .timedOut
                case 429: kind = .rateLimited
                case 500...599: kind = .serverUnavailable
                case 404: kind = .unexpectedResponse
                default: kind = .other
                }
                self.init(kind: kind, httpStatus: status)
                return
            }
            switch failure {
            case .invalidAddress: self.init(kind: .invalidAddress); return
            case .unexpectedResponse: self.init(kind: .unexpectedResponse); return
            default: break
            }
        }
        if error is DecodingError {
            self.init(kind: .unexpectedResponse)
            return
        }
        var underlying = error as NSError
        for _ in 0..<6 {
            if underlying.domain == NSURLErrorDomain {
                let kind: Kind
                switch URLError.Code(rawValue: underlying.code) {
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                    kind = .offline
                case .cannotFindHost, .dnsLookupFailed: kind = .dns
                case .cannotConnectToHost, .networkConnectionLost: kind = .unreachable
                case .timedOut: kind = .timedOut
                case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                     .clientCertificateRejected, .clientCertificateRequired:
                    kind = .certificate
                case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection:
                    kind = .secureConnection
                case .cancelled: kind = .cancelled
                default: kind = .other
                }
                self.init(kind: kind, networkCode: underlying.code)
                return
            }
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            underlying = next
        }
        self.init(kind: .other)
    }

    private init(kind: Kind, httpStatus: Int? = nil, networkCode: Int? = nil) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.networkCode = networkCode
    }

    public var title: String {
        switch kind {
        case .invalidAddress: return "Check the server address"
        case .authentication: return "Sign in again"
        case .accessDenied: return String(localized: "auth.accessDenied", defaultValue: "Access denied")
        case .offline: return "No network connection"
        case .dns: return "Server name not found"
        case .unreachable: return "Connection interrupted"
        case .timedOut: return "The connection timed out"
        case .certificate: return "Certificate could not be verified"
        case .secureConnection: return "Secure connection unavailable"
        case .serverUnavailable: return "Server or proxy unavailable"
        case .rateLimited: return "The server needs a moment"
        case .unexpectedResponse: return "Unexpected server response"
        case .cancelled: return "Connection check cancelled"
        case .other: return "Connection needs attention"
        }
    }

    public var guidance: String {
        switch kind {
        case .invalidAddress:
            return "Use the server root, including its port or proxy base path, without /api, credentials or query parameters."
        case .authentication:
            return "Your session, credentials or account access may have changed. Sign in with your current Frigate account. Saved camera groups and layouts are kept."
        case .accessDenied:
            return String(localized: "auth.accessGuidance", defaultValue: "The server denied this request (HTTP 403). Check camera permissions or CSRF/proxy requirements; this is not proof that your login expired.")
        case .offline:
            return "Check Wi-Fi, cellular, VPN and local-network access, then retry. You do not need to forget your saved session."
        case .dns:
            return "Check the hostname and your network or VPN. After a DNS change, allow caches to update, then retry."
        case .unreachable:
            return "The connection was refused or interrupted. Check the server address, port and network route before retrying."
        case .timedOut:
            return "The server or its network path did not respond in time. Wait a moment and retry without resetting the app."
        case .certificate:
            return "Use a hostname with a valid certificate trusted by this iPhone. A browser exception does not establish app trust. Certificate validation has not been bypassed."
        case .secureConnection:
            return "Use HTTPS and check the server or reverse proxy's TLS configuration. Horizon will not bypass secure connection checks."
        case .serverUnavailable:
            return "The server or reverse proxy could not complete the request. This does not identify a Frigate fault or mean a restart is needed. Wait and retry."
        case .rateLimited:
            return "Wait before retrying. Repeated connection attempts can extend the server's request limit."
        case .unexpectedResponse:
            return "Check the server root, proxy base path and backend compatibility. A web login page is not a successful API response."
        case .cancelled:
            return "Retry when you are ready."
        case .other:
            return "Retry the connection. If it persists, check the server and secure session store. Saved camera groups and layouts have not been removed."
        }
    }

    public var allowsSavedSessionRetry: Bool {
        switch kind {
        case .authentication, .invalidAddress, .certificate, .secureConnection, .cancelled:
            return false
        default: return true
        }
    }

    public var diagnosticSummary: String {
        var lines = ["Horizon connection check", "Category: \(kind.rawValue)"]
        if let httpStatus { lines.append("HTTP status: \(httpStatus)") }
        if let networkCode { lines.append("Network code: \(networkCode)") }
        return lines.joined(separator: "\n")
    }
}
