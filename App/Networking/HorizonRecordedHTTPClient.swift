import Foundation
import VideoToolbox
import AudioToolbox
import HorizonCore

final class HorizonRecordedHTTPClient: RecordedHTTPControlClient, @unchecked Sendable {
    private let api: HorizonAPI
    private let account: String
    let decoderCapabilities: RecordedHTTPDecoderCapabilities
    var address: ServerAddress { api.address }
    var cookies: [HTTPCookie] { api.cookies }
    init(api: HorizonAPI) throws {
        guard let account = api.viewingAccountKey else { throw HorizonError.unauthorized }
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else {
            throw HorizonError.message(String(localized: "review.codecDiscoveryFailed", defaultValue: "Native H264 decoder support could not be confirmed. No direct-original codec claim was sent."))
        }
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr,
              size > 0 else { throw RecordedHTTPError.unsupportedSource }
        var formats = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = formats.withUnsafeMutableBytes {
            AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, $0.baseAddress)
        }
        guard status == noErr else { throw RecordedHTTPError.unsupportedSource }
        var audio: [RecordedHTTPAudioCodec] = []
        if formats.contains(kAudioFormatMPEG4AAC) { audio.append(.aac) }
        if formats.contains(kAudioFormatMPEGLayer3) { audio.append(.mp3) }
        // Codec-only discovery cannot certify an original's HEVC profile; do not advertise it.
        decoderCapabilities = .init(video: [.h264], audio: audio)
        self.api=api; self.account=account
    }
    func request(_ url: URL, method: String, body: Data?, success: Set<Int>) async throws -> RecordedHTTPControlResponse {
        guard api.viewingAccountKey == account else { throw HorizonError.unauthorized }
        let result = try await api.viewerResponse(url, method: method, body: body, success: success)
        let headers = result.response.allHeaderFields.reduce(into: [String: String]()) { fields, item in
            if let key = item.key as? String, let value = item.value as? String { fields[key]=value }
        }
        return RecordedHTTPControlResponse(data: result.data, status: result.response.statusCode, headers: headers)
    }
}
