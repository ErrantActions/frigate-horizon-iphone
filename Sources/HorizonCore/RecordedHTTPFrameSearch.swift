import Foundation

public enum RecordedHTTPFrameSearch {
    public static let maximumRequests = 26

    public static func nextFrame(camera: String, at timestamp: Double, before: Double,
                                 transport: any RecordedHTTPTransport) async throws -> Double {
        guard timestamp.isFinite, before.isFinite, timestamp >= 0, timestamp < before else {
            throw RecordedHTTPError.invalidWindow
        }
        var cursor = timestamp
        for _ in 0..<maximumRequests {
            try Task.checkCancellation()
            let request = try RecordedHTTPResolveRequest(after: cursor, before: min(before, cursor + 3600),
                startTimestamp: cursor)
            let result = try await transport.resolve(camera: camera, request: request)
            try Task.checkCancellation()
            try result.validate(request: request)
            if let effective = result.effectiveStartTimestamp { return effective }
            guard result.exhausted, result.searchedBefore == request.before else {
                throw RecordedHTTPError.searchLimit
            }
            cursor = request.before
            if cursor >= before { throw RecordedHTTPError.gap }
        }
        throw RecordedHTTPError.searchLimit
    }
}
