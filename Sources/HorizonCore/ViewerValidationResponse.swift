import Foundation

public enum ViewerValidationResponse {
    private struct Failure: Decodable {
        let detail: Detail?
        let message: String?
    }
    private enum Detail: Decodable {
        case text(String), issues([Issue])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) { self = .text(text) }
            else { self = .issues(try value.decode([Issue].self)) }
        }
    }
    private enum Location: Decodable {
        case key(String), index(Int)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let key = try? value.decode(String.self) { self = .key(key) }
            else { self = .index(try value.decode(Int.self)) }
        }
    }
    private struct Issue: Decodable {
        let loc: [Location]
        let msg: String
        let type: String
        var summary: String {
            let keys = loc.prefix(8).map { location -> String in
                switch location {
                case .index(let value): return String(value)
                case .key(let value): return safeKey(value)
                }
            }
            let sensitive = keys.contains { key in
                let value = key.lowercased()
                return ["authorization","cookie","password","token","credential","sdp","candidate"].contains { value.contains($0) }
            }
            let message = sensitive ? redacted : safeText(msg)
            return "\(keys.joined(separator: ".")): \(message) (\(safeKey(type)))"
        }
    }
    private static var unavailable: String {
        String(localized: "viewer.validationUnavailable", defaultValue: "The server returned HTTP 422, but its validation detail could not be read. Check the app/server request contract.")
    }
    private static var redacted: String {
        String(localized: "viewer.validationRedacted", defaultValue: "Sensitive validation content was redacted.")
    }
    private static func safeKey(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !value.isEmpty, value.count <= 64, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "[field]" }
        return value
    }
    private static func safeText(_ value: String) -> String {
        if value.contains("candidate:") || value.contains("v=0") || value.contains("\nm=") { return redacted }
        var text = value
        for pattern in [
            #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, #"<[^>]+>"#,
            #"(?i)\bBearer\s+\S+"#, #"https?://[^\s"'<>]+"#,
            #"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"#,
            #"(?i)\b(token|password|credential|cookie|authorization)\s*[:=]\s*("[^"]*"|'[^']*'|\S+)"#,
            #"(?i)(?:[A-Z]:\\|/(?:media|config|mnt|home|Users)/)[^\s"'<>]+"#,
        ] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(text.prefix(600))
    }
    public static func detail(data: Data, mimeType: String?) -> String {
        guard !data.isEmpty, data.count <= 65_536 else { return unavailable }
        if mimeType?.lowercased().contains("json") == true {
            do {
                let failure = try JSONDecoder().decode(Failure.self, from: data)
                switch failure.detail {
                case .issues(let issues)?:
                    guard !issues.isEmpty else { return unavailable }
                    return String(issues.prefix(12).map(\.summary).joined(separator: "\n").prefix(4000))
                case .text(let message)?: return safeText(message).isEmpty ? unavailable : safeText(message)
                case nil:
                    if let message = failure.message, !message.isEmpty { return safeText(message) }
                    return unavailable
                }
            } catch {
                return unavailable
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return unavailable }
        let safe = safeText(text)
        return safe.isEmpty ? unavailable : safe
    }
}
