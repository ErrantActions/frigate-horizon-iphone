import Foundation

public enum RecordedHTTPRequestedDelivery: String, Encodable, Sendable { case prepared, auto, direct }
public enum RecordedHTTPActualDelivery: String, Codable, Sendable { case prepared, originalFile = "original_file" }
public enum RecordedHTTPVideoCodec: String, Codable, Sendable { case h264, hevc }
public enum RecordedHTTPAudioCodec: String, Codable, Sendable { case aac, mp3, opus }

public struct RecordedHTTPDecoderCapabilities: Equatable, Sendable {
    public let video: [RecordedHTTPVideoCodec]
    public let audio: [RecordedHTTPAudioCodec]
    public init(video: [RecordedHTTPVideoCodec], audio: [RecordedHTTPAudioCodec]) {
        self.video = video; self.audio = audio
    }
    public static let baseline = Self(video: [.h264], audio: [.aac, .mp3])
    public func validate() throws {
        guard (1...2).contains(video.count), audio.count <= 3,
              Set(video).count == video.count, Set(audio).count == audio.count else { throw RecordedHTTPError.unsupportedSource }
    }
}

public enum RecordedHTTPDeliveryContract: Equatable, Sendable {
    case preparedLegacy, automaticOriginal, metadataUnavailable(Int)
    public var supportsDirectOriginal: Bool { self == .automaticOriginal }
    public var notice: String? {
        switch self {
        case .preparedLegacy: return nil
        case .automaticOriginal: return nil
        case .metadataUnavailable:
            return String(localized: "review.deliveryDiscoveryUnavailable", defaultValue: "Direct-original contract discovery is unavailable. Prepared-only compatibility is active; no new delivery fields will be sent.")
        }
    }
    public static func inspect(openAPI: Data) throws -> Self {
        guard openAPI.count <= 8 * 1024 * 1024,
              let spec = try JSONSerialization.jsonObject(with: openAPI) as? [String: Any],
              let paths = spec["paths"] as? [String: Any],
              let path = paths["/{camera_name}/recordings/http/sessions"] as? [String: Any],
              let post = path["post"] as? [String: Any],
              let body = post["requestBody"] as? [String: Any],
              let content = body["content"] as? [String: Any],
              let json = content["application/json"] as? [String: Any],
              let reference = (json["schema"] as? [String: Any])?["$ref"] as? String,
              reference.hasPrefix("#/components/schemas/"),
              let components = spec["components"] as? [String: Any],
              let schemas = components["schemas"] as? [String: Any],
              let request = schemas[String(reference.dropFirst("#/components/schemas/".count))] as? [String: Any],
              let fields = request["properties"] as? [String: Any],
              Set(["version","after","before","start_timestamp","quality","start_policy"]).isSubset(of: Set(fields.keys)) else {
            throw RecordedHTTPError.invalidContract
        }
        guard let delivery = fields["delivery"] as? [String: Any] else { return .preparedLegacy }
        guard let choices = delivery["enum"] as? [String], Set(["prepared","auto","direct"]).isSubset(of: Set(choices)),
              let video = ((fields["video_codecs"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String],
              video.contains("h264"),
              let audio = ((fields["audio_codecs"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String],
              Set(["aac","mp3"]).isSubset(of: Set(audio)),
              let responses = post["responses"] as? [String: Any],
              let accepted = responses["202"] as? [String: Any],
              let responseContent = accepted["content"] as? [String: Any],
              let responseJSON = responseContent["application/json"] as? [String: Any],
              let responseReference = (responseJSON["schema"] as? [String: Any])?["$ref"] as? String,
              responseReference.hasPrefix("#/components/schemas/"),
              let responseSchema = schemas[String(responseReference.dropFirst("#/components/schemas/".count))] as? [String: Any],
              let responseFields = responseSchema["properties"] as? [String: Any],
              let actual = (responseFields["delivery"] as? [String: Any])?["enum"] as? [String],
              Set(["prepared","original_file"]).isSubset(of: Set(actual)),
              responseFields["preparation_reason"] != nil else { throw RecordedHTTPError.invalidContract }
        return .automaticOriginal
    }
}

public struct RecordedHTTPDeliveryRequest: Equatable, Sendable {
    let delivery: RecordedHTTPRequestedDelivery
    let decoders: RecordedHTTPDecoderCapabilities
    public init(delivery: RecordedHTTPRequestedDelivery, decoders: RecordedHTTPDecoderCapabilities) throws {
        try decoders.validate()
        self.delivery = delivery; self.decoders = decoders
    }
}
