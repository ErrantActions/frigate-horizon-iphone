@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

public final class RecordedMP4Asset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public let asset: AVURLAsset
    private let reader: AuthenticatedRecordedMP4Reader
    private let queue = DispatchQueue(label: "Horizon.recordedMP4")
    private let lock = NSLock()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false
    private let onFailure: @Sendable (Error) -> Void
    public init(reader: AuthenticatedRecordedMP4Reader, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.reader = reader
        self.onFailure = onFailure
        guard var components = URLComponents(url: reader.mediaURL, resolvingAgainstBaseURL: false) else {
            throw RecordedHTTPError.invalidWindow
        }
        components.scheme = "horizon-review"
        guard let url = components.url else { throw RecordedHTTPError.invalidWindow }
        asset = AVURLAsset(url: url)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        lock.lock()
        guard !stopped else { lock.unlock(); request.finishLoading(with: CancellationError()); return true }
        guard requests.count < 8 else { lock.unlock(); request.finishLoading(with: RecordedHTTPError.preparationFailed); return true }
        if let information = request.contentInformationRequest {
            information.contentType = UTType.mpeg4Movie.identifier
            information.contentLength = reader.length
            information.isByteRangeAccessSupported = true
        }
        let job = Task {
            do {
                if let data = request.dataRequest {
                    guard data.requestedOffset >= 0, data.requestedLength >= 0,
                          data.requestedOffset <= Int64.max - Int64(data.requestedLength) else {
                        throw RecordedHTTPError.invalidRange
                    }
                    var offset = max(data.requestedOffset, data.currentOffset)
                    let end = data.requestsAllDataToEndOfResource ? reader.length
                        : min(reader.length, data.requestedOffset + Int64(data.requestedLength))
                    guard offset <= reader.length else { throw RecordedHTTPError.invalidRange }
                    while offset < end {
                        try Task.checkCancellation()
                        let count = Int(min(Int64(RecordedMP4Range.maximumRead), end - offset))
                        let bytes = try await reader.read(RecordedMP4Range(offset: offset, count: count))
                        try Task.checkCancellation()
                        guard !bytes.isEmpty else { throw RecordedHTTPError.invalidRange }
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            queue.async {
                                if request.isCancelled { continuation.resume(throwing: CancellationError()) }
                                else { data.respond(with: bytes); continuation.resume() }
                            }
                        }
                        offset += Int64(bytes.count)
                    }
                }
                try Task.checkCancellation()
                queue.async { if !request.isCancelled { request.finishLoading() } }
            } catch {
                if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled { onFailure(error) }
                queue.async { if !request.isCancelled { request.finishLoading(with: error) } }
            }
            self.remove(key)
        }
        requests[key] = job
        lock.unlock()
        return true
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.lock(); let job = requests.removeValue(forKey: ObjectIdentifier(request)); lock.unlock()
        job?.cancel()
    }
    private func remove(_ key: ObjectIdentifier) {
        lock.lock(); requests.removeValue(forKey: key); lock.unlock()
    }
    public func cancel() {
        lock.lock(); stopped = true; let jobs = Array(requests.values); requests.removeAll(); lock.unlock()
        for job in jobs { job.cancel() }
        asset.cancelLoading()
        reader.close()
    }
    deinit { cancel() }
}
