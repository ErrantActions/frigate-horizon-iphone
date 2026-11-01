import Foundation

public struct LiveHLSStatus: Decodable, Sendable {
    public struct Rendition: Decodable, Sendable {
        public let height: Int
        public let bitrate: Int
    }

    public let version: Int
    public let protocolName: String
    public let enabled: Bool
    public let available: Bool
    public let playlist: String
    public let renditions: [Rendition]
    public var isAvailable: Bool { version == 1 && protocolName == "ll-hls" && enabled && available }

    enum CodingKeys: String, CodingKey {
        case version, enabled, available, playlist, renditions
        case protocolName = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        protocolName = try values.decode(String.self, forKey: .protocolName)
        if version != 1 || protocolName != "ll-hls" {
            enabled = false; available = false; playlist = ""; renditions = []
            return
        }
        enabled = try values.decode(Bool.self, forKey: .enabled)
        available = try values.decode(Bool.self, forKey: .available)
        playlist = try values.decodeIfPresent(String.self, forKey: .playlist) ?? ""
        renditions = try values.decodeIfPresent([Rendition].self, forKey: .renditions) ?? []
        if enabled && available && (playlist.isEmpty || renditions.isEmpty ||
            renditions.contains(where: { $0.height <= 0 || $0.bitrate <= 0 })) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Available live HLS requires a playlist and valid renditions."))
        }
    }
}

public enum LiveHLSGate {
    public static func shouldProbe(cameraEnabled: Bool, optedIn: Bool, automatic: Bool, transport: String) -> Bool {
        cameraEnabled
    }

    public static func permitsCompatibilityFallback(_ configuration: LiveHLSConfiguration?) -> Bool {
        false
    }

    public static func mayRetain(cameraEnabled: Bool, optedIn: Bool,
                                 configuration: LiveHLSConfiguration?) -> Bool {
        cameraEnabled && configuration != nil
    }

    public static func isUnsupportedHTTP(_ status: Int) -> Bool { [404, 405, 410, 501].contains(status) }

    public static func requiresReauthentication(_ error: Error) -> Bool {
        (error as? HorizonError)?.httpStatusCode == 401
    }
}

public struct LiveHLSEdgeRecoveryPolicy: Sendable {
    public private(set) var attempts = 0
    public init() {}

    public mutating func target(current: TimeInterval, seekableStart: TimeInterval, seekableEnd: TimeInterval,
                                recommendedOffset: TimeInterval?, stalledFor: TimeInterval,
                                waiting: Bool) -> TimeInterval? {
        guard attempts == 0, waiting, current.isFinite, seekableStart.isFinite, seekableEnd.isFinite,
              seekableStart >= 0, seekableEnd > seekableStart, stalledFor.isFinite, stalledFor >= 5 else { return nil }
        let offset = recommendedOffset.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 3
        let target = max(seekableStart, seekableEnd - offset)
        guard target < seekableEnd, target - current > 2 || current > seekableEnd else { return nil }
        attempts += 1
        return target
    }
}

public struct LiveHLSConfiguration: Equatable, Sendable {
    public let maximumHeight: Int?
    public let requiresHLS: Bool
    public let exactHeight: Int?
    public let grid: Bool
    public let audio: Bool
    public init(maximumHeight: Int? = nil, requiresHLS: Bool = true,
                exactHeight: Int? = nil, grid: Bool = false, audio: Bool = true) {
        self.maximumHeight = maximumHeight
        self.requiresHLS = true
        self.exactHeight = exactHeight
        self.grid = grid
        self.audio = audio
    }

    public func masterURL(status: LiveHLSStatus, policy: LiveHLSResourcePolicy) throws -> URL {
        let master = try policy.masterURL(status.playlist)
        let heights = Set(status.renditions.map(\.height).filter { (144...2160).contains($0) })
        guard !heights.isEmpty else { throw HorizonError.message("No advertised HLS video profiles are available.") }
        var query: [URLQueryItem] = []
        if !audio || grid { query.append(.init(name: "audio", value: "false")) }
        if let exactHeight {
            guard heights.contains(exactHeight), maximumHeight.map({ exactHeight <= $0 }) ?? true else {
                throw HorizonError.message("The pinned HLS height is unavailable or exceeds Data Saver. Choose an advertised height or Auto.")
            }
            query.append(.init(name: "height", value: String(exactHeight)))
        } else if grid {
            return try cappedGridURL(master: master, heights: heights)
        } else if let maximumHeight {
            guard (144...2160).contains(maximumHeight), heights.contains(where: { $0 <= maximumHeight }) else {
                throw HorizonError.message("No advertised HLS rung fits this display/Data Saver cap.")
            }
            query.append(.init(name: "max_height", value: String(maximumHeight)))
        }
        var parts = URLComponents(url: master, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        return try policy.validate(parts.url!)
    }

    private func cappedGridURL(master: URL, heights: Set<Int>) throws -> URL {
        guard let height = heights.filter({ height in maximumHeight.map { height <= $0 } ?? true }).min() else {
            throw HorizonError.message("No advertised HLS rung fits the tile's cap.")
        }
        var parts = URLComponents(url: master, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "audio", value: "false"), .init(name: "height", value: String(height))]
        return parts.url!
    }
}

public struct LiveHLSStartupPolicy: Sendable {
    private let lowestBandwidth: Double
    private var healthySince: TimeInterval?
    private var lastObservation: TimeInterval?
    public private(set) var released = false
    public var preferredPeakBitRate: Double { released ? 0 : lowestBandwidth }

    public init(lowestBandwidth: Int) { self.lowestBandwidth = Double(lowestBandwidth) }

    public mutating func observe(now: TimeInterval, decodedVideo: Bool, bufferedAhead: TimeInterval,
                                 playing: Bool, restrictedNetwork: Bool) {
        guard now.isFinite, lastObservation.map({ now >= $0 }) ?? true else {
            healthySince = nil
            return
        }
        lastObservation = now
        if restrictedNetwork {
            released = false
            healthySince = nil
            return
        }
        guard !released else { return }
        guard decodedVideo, playing, bufferedAhead.isFinite, bufferedAhead >= 1 else {
            healthySince = nil
            return
        }
        if healthySince == nil { healthySince = now }
        if let healthySince, now - healthySince >= 3 { released = true }
    }
}

public struct LiveHLSResourcePolicy: Sendable {
    public let address: ServerAddress
    public let camera: String
    public let root: URL
    public let canonicalMaster: URL
    public let isLive: Bool
    private static let assetScheme = "horizon-hls"

    public init(address: ServerAddress, camera: String) throws {
        guard address.url.scheme == "https", !camera.isEmpty, camera.utf8.count <= 256,
              camera != ".", camera != "..",
              !camera.contains(where: { "/\\?#%".contains($0) || $0.isWhitespace || $0.isNewline }),
              !camera.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw HorizonError.message("Live HLS requires a trusted HTTPS server and a valid camera.") }
        self.address = address
        self.camera = camera
        root = address.endpoint(["api", camera, "live", "hls"])
        canonicalMaster = root.appendingPathComponent("master.m3u8")
        isLive = true
    }

    public init(address: ServerAddress, mediaURL: URL) throws {
        guard address.url.scheme == "https", address.hasSameOrigin(as: mediaURL),
              mediaURL.pathExtension == "m3u8",
              mediaURL.user == nil, mediaURL.password == nil, mediaURL.query == nil, mediaURL.fragment == nil else {
            throw HorizonError.invalidMediaPath
        }
        let vod = address.endpoint(["vod"]).path + "/"
        let api = address.endpoint(["api", "onvif", "cameras"]).path + "/"
        guard mediaURL.path.hasPrefix(vod) || mediaURL.path.hasPrefix(api) else { throw HorizonError.invalidMediaPath }
        if mediaURL.path.hasPrefix(api) {
            let parts = mediaURL.path.dropFirst(api.count).split(separator: "/")
            guard parts.count == 6, parts[1] == "replay", parts[2] == "sessions",
                  parts[4] == "hls", parts[5] == "index.m3u8",
                  NativeNotificationRoute.isValidIdentifier(String(parts[0])),
                  NativeNotificationRoute.isValidIdentifier(String(parts[3])) else { throw HorizonError.invalidMediaPath }
        }
        self.address = address
        camera = ""
        root = mediaURL.deletingLastPathComponent()
        canonicalMaster = mediaURL
        isLive = false
        _ = try validate(mediaURL)
    }

    public func masterURL(_ reference: String) throws -> URL {
        let api = address.endpoint(["api"]).appendingPathComponent("")
        let url = try resolve(reference, relativeTo: api)
        guard url == canonicalMaster else { throw HorizonError.invalidMediaPath }
        return url
    }

    public func resolve(_ reference: String, relativeTo base: URL) throws -> URL {
        guard !reference.isEmpty, reference.utf8.count <= 4096,
              !reference.contains("\\"),
              !reference.contains("{$"),
              !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: reference),
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw HorizonError.invalidMediaPath
        }
        try validateSegments(components.percentEncodedPath)
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL else {
            throw HorizonError.invalidMediaPath
        }
        let safe = try validate(url)
        return safe
    }

    public func validate(_ url: URL) throws -> URL {
        guard address.hasSameOrigin(as: url), url.scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil
        else { throw HorizonError.invalidMediaPath }
        try validateSegments(components.percentEncodedPath)
        var segments: [Substring] = []
        for segment in components.percentEncodedPath.split(separator: "/") {
            if segment == "." { continue }
            if segment == ".." {
                guard !segments.isEmpty else { throw HorizonError.invalidMediaPath }
                segments.removeLast()
            } else { segments.append(segment) }
        }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let normalized = components.url, normalized.path.hasPrefix(root.path + "/"),
              (isLive ? ["m3u8", "mp4"] : ["m3u8", "mp4", "m4s", "ts", "aac"]).contains(normalized.pathExtension.lowercased())
        else { throw HorizonError.invalidMediaPath }
        let route = normalized.path.dropFirst(root.path.count + 1).split(separator: "/")
        if isLive && (route.count != 1 || route.first != "master.m3u8") {
            guard route.count == 2, Self.height(String(route[0])) != nil,
                  !route[1].isEmpty else { throw HorizonError.invalidMediaPath }
        }
        let query = components.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count,
              query.isEmpty || normalized.pathExtension.lowercased() == "m3u8" else { throw HorizonError.invalidMediaPath }
        for item in query {
            guard let value = item.value else { throw HorizonError.invalidMediaPath }
            switch item.name {
            case "_HLS_msn", "_HLS_part":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int64(value) else { throw HorizonError.invalidMediaPath }
                if item.name == "_HLS_part" {
                    guard query.contains(where: { $0.name == "_HLS_msn" }),
                          number <= 1_000_000 else { throw HorizonError.invalidMediaPath }
                }
            case "_HLS_skip":
                guard ["YES", "v2"].contains(value) else { throw HorizonError.invalidMediaPath }
            case "warm_max_height", "height", "max_height":
                guard isLive, let number = Int(value), (144...2160).contains(number),
                      value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw HorizonError.invalidMediaPath }
                if item.name != "warm_max_height" {
                    guard normalized.path == canonicalMaster.path else { throw HorizonError.invalidMediaPath }
                } else if route.count == 2, let active = Self.height(String(route[0])), number < active {
                    throw HorizonError.invalidMediaPath
                }
            case "audio":
                guard isLive, normalized.path == canonicalMaster.path, value == "false" else { throw HorizonError.invalidMediaPath }
            default: throw HorizonError.invalidMediaPath
            }
        }
        return normalized
    }

    public func renditionHeight(for url: URL) throws -> Int {
        let safe = try validate(url)
        let route = safe.path.dropFirst(root.path.count + 1).split(separator: "/")
        guard route.count == 2, let height = Self.height(String(route[0])) else { throw HorizonError.invalidMediaPath }
        return height
    }

    private static func height(_ component: String) -> Int? {
        guard component.hasSuffix("p") else { return nil }
        let digits = component.dropLast()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let height = Int(digits), (144...2160).contains(height) else { return nil }
        return height
    }

    public func assetURL(_ network: URL) throws -> URL {
        let safe = try validate(network)
        var parts = URLComponents(url: safe, resolvingAgainstBaseURL: false)!
        parts.scheme = Self.assetScheme
        guard let result = parts.url else { throw HorizonError.invalidMediaPath }
        return result
    }

    public func networkURL(_ asset: URL) throws -> URL {
        guard asset.scheme == Self.assetScheme,
              var parts = URLComponents(url: asset, resolvingAgainstBaseURL: false) else {
            throw HorizonError.invalidMediaPath
        }
        parts.scheme = "https"
        guard let result = parts.url else { throw HorizonError.invalidMediaPath }
        return try validate(result)
    }

    private func validateSegments(_ path: String) throws {
        for segment in path.split(separator: "/") {
            var value = String(segment)
            for _ in 0..<4 {
                guard !value.contains("/"), !value.contains("\\"),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let decoded = value.removingPercentEncoding else { throw HorizonError.invalidMediaPath }
                if decoded == value { break }
                guard decoded != ".", decoded != ".." else { throw HorizonError.invalidMediaPath }
                value = decoded
            }
            guard !value.contains("%"), !value.contains("/"), !value.contains("\\") else {
                throw HorizonError.invalidMediaPath
            }
        }
    }

    public func rewritePlaylist(_ text: String, url: URL) throws -> String {
        _ = try validate(url)
        return try transformPlaylist(text) { reference in
            try assetURL(resolve(reference, relativeTo: url))
        }
    }

    public func rewriteAssetPlaylist(_ text: String, resourceURL: (URL) throws -> URL) throws -> String {
        try transformPlaylist(text) { reference in
            guard let asset = URL(string: reference) else { throw HorizonError.invalidMediaPath }
            return try resourceURL(networkURL(asset))
        }
    }

    private func transformPlaylist(_ text: String, resourceURL: (String) throws -> URL) throws -> String {
        guard text.utf8.count <= 1_048_576, text.hasPrefix("#EXTM3U") else {
            throw HorizonError.unexpectedResponse
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return try lines.components(separatedBy: "\n").map { line in
            if line.isEmpty { return line }
            if !line.hasPrefix("#") { return try resourceURL(line).absoluteString }
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") ||
                line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") {
                throw HorizonError.message("The live HLS playlist uses an unsupported key or steering contract.")
            }
            guard line.contains("URI=") else { return line }
            let attributes = try HLSAttributes.parse(line)
            guard let uri = attributes["URI"] else { throw HorizonError.unexpectedResponse }
            let replacement = try resourceURL(uri).absoluteString
            guard let range = line.range(of: "URI=\"\(uri)\"") else { throw HorizonError.unexpectedResponse }
            return line.replacingCharacters(in: range, with: "URI=\"\(replacement)\"")
        }.joined(separator: "\n")
    }
}

enum HLSAttributes {
    static func parse(_ line: String) throws -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { throw HorizonError.unexpectedResponse }
        var quoted = false
        var token = ""
        var tokens: [String] = []
        for character in line[line.index(after: colon)...] {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { tokens.append(token); token = "" }
            else { token.append(character) }
        }
        guard !quoted else { throw HorizonError.unexpectedResponse }
        tokens.append(token)
        var result: [String: String] = [:]
        for token in tokens {
            guard let equals = token.firstIndex(of: "=") else { throw HorizonError.unexpectedResponse }
            let key = String(token[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(token[token.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst(); value.removeLast()
            }
            guard !key.isEmpty, !value.contains("\""), result[key] == nil else { throw HorizonError.unexpectedResponse }
            result[key] = value
        }
        return result
    }
}

public struct LiveHLSMaster: Sendable {
    public struct Variant: Equatable, Sendable {
        public let url: URL
        public let bandwidth: Int
        public let width: Int?
        public let height: Int
    }

    public let variants: [Variant]
    public let playlist: String
    public var lowestBandwidth: Int { variants.map(\.bandwidth).min()! }

    public init(text: String, policy: LiveHLSResourcePolicy, url: URL, maximumHeight: Int? = nil) throws {
        guard text.utf8.count <= 1_048_576, text.hasPrefix("#EXTM3U") else { throw HorizonError.unexpectedResponse }
        _ = try policy.rewritePlaylist(text, url: url)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        var variants: [Variant] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = try HLSAttributes.parse(line)
                guard let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init), bandwidth > 0,
                      index + 1 < lines.count, !lines[index + 1].isEmpty,
                      !lines[index + 1].hasPrefix("#") else { throw HorizonError.unexpectedResponse }
                let child = try policy.resolve(lines[index + 1], relativeTo: url)
                guard child.pathExtension.lowercased() == "m3u8" else { throw HorizonError.unexpectedResponse }
                var width: Int?
                var height = try policy.renditionHeight(for: child)
                if let value = attributes["RESOLUTION"] {
                    let resolution = value.split(separator: "x")
                    guard resolution.count == 2, let actualWidth = Int(resolution[0]),
                          let actualHeight = Int(resolution[1]), actualWidth > 0, actualHeight > 0 else {
                        throw HorizonError.unexpectedResponse
                    }
                    width = actualWidth
                    height = actualHeight
                }
                if height >= 144 && height <= 2160 && (maximumHeight.map({ height <= $0 }) ?? true) {
                    variants.append(Variant(url: child, bandwidth: bandwidth, width: width, height: height))
                    kept.append(line); kept.append(lines[index + 1])
                }
                index += 2
            } else {
                kept.append(line)
                index += 1
            }
        }
        guard !variants.isEmpty, variants.count <= 32 else {
            throw HorizonError.message("The live HLS master has no supported video profiles within the selected maximum.")
        }
        self.variants = variants
        playlist = kept.joined(separator: "\n")
    }
}
