import Foundation

public enum HLSPlaybackTuning {
    public static let liveDelay: TimeInterval = 6
    public static func forwardBuffer(grid: Bool) -> TimeInterval { grid ? 3 : 6 }
}

public enum HLSPlaybackFailure: LocalizedError, Sendable {
    case startupTimedOut, stalled
    public var errorDescription: String? {
        switch self {
        case .startupTimedOut: return "HLS did not display a frame before its startup deadline."
        case .stalled: return "HLS playback stopped making progress."
        }
    }
}

public struct HLSRecoveryPolicy: Sendable {
    public private(set) var attempts = 0
    public init() {}
    public mutating func nextDelay(for error: Error, jitter: Double) -> TimeInterval? {
        guard attempts < 2, Self.isTransient(error) else { return nil }
        let delay = attempts == 0 ? 1.0 : 3.0
        attempts += 1
        return delay + (jitter.isFinite ? min(1, max(0, jitter)) : 0)
    }
    public static func isTransient(_ error: Error) -> Bool {
        if error is HLSPlaybackFailure { return true }
        if let status = (error as? HorizonError)?.httpStatusCode {
            return [404, 408, 429, 500, 502, 503, 504].contains(status)
        }
        if error is CancellationError { return false }
        var current = error as NSError
        for _ in 0..<6 {
            if current.domain == NSURLErrorDomain {
                return [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet,
                        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                    .contains(URLError.Code(rawValue: current.code))
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}

public struct HLSRecoverySchedule: Sendable {
    private var nextSlot: TimeInterval = 0
    public init() {}
    public mutating func reserve(now: TimeInterval, backoff: TimeInterval) -> TimeInterval {
        let slot = max(now + backoff, nextSlot)
        nextSlot = slot + 0.75
        return max(0, slot - now)
    }
}

public struct HLSRequestMeasurement: Sendable {
    public enum Kind: String, Hashable, Sendable { case master, childPlaylist, initialization, media }
    public let kind: Kind
    public let elapsed: TimeInterval
    public let firstByte: TimeInterval?
    public let status: Int?
    public let bytes: Int
    public init(kind: Kind, elapsed: TimeInterval, firstByte: TimeInterval?, status: Int?, bytes: Int) {
        self.kind = kind
        self.elapsed = elapsed
        self.firstByte = firstByte
        self.status = status
        self.bytes = bytes
    }
}

public enum HLSMeasurement: Sendable {
    case request(HLSRequestMeasurement)
    case partTarget(Double)
}

public struct HLSStartupMeasurements: Sendable {
    public enum Stage: String, CaseIterable, Hashable, Sendable {
        case statusFetch, masterFetch, childPlaylistFetch, initFetch, playerReady, firstDisplayedFrame
    }
    public private(set) var stages: [Stage: TimeInterval] = [:]
    public private(set) var firstBytes: [Stage: TimeInterval] = [:]
    public private(set) var requestCount = 0
    public private(set) var partTargets: [Double] = []
    public private(set) var httpFailures: [Int] = []
    public init() {}
    public mutating func record(_ stage: Stage, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0, stages[stage] == nil else { return }
        stages[stage] = seconds
    }
    public mutating func record(_ measurement: HLSMeasurement) {
        switch measurement {
        case .partTarget(let value):
            if value.isFinite, value > 0, !partTargets.contains(value), partTargets.count < 8 {
                partTargets.append(value)
            }
        case .request(let request):
            requestCount += 1
            if let status = request.status, status >= 400, httpFailures.count < 8 { httpFailures.append(status) }
            let stage: Stage?
            switch request.kind {
            case .master: stage = .masterFetch
            case .childPlaylist: stage = .childPlaylistFetch
            case .initialization: stage = .initFetch
            case .media: stage = nil
            }
            if let stage, request.status == 200 {
                record(stage, seconds: request.elapsed)
                if firstBytes[stage] == nil, let firstByte = request.firstByte,
                   firstByte.isFinite, firstByte >= 0 { firstBytes[stage] = firstByte }
            }
        }
    }
    public var report: String {
        let times = Stage.allCases.map { stage in
            let text = stages[stage].map { String(format: "%.3f s", $0) } ?? "not observed"
            let firstByte = firstBytes[stage].map { String(format: " (first body %.3f s)", $0) } ?? ""
            return "\(stage.rawValue): \(text)\(firstByte)"
        }
        return (times + ["HTTP requests: \(requestCount)", "HTTP failures: \(httpFailures)",
            "PART-TARGET values: \(partTargets)",
            "Fetch times are request durations; playerReady/firstDisplayedFrame are elapsed since this attempt began."])
            .joined(separator: "\n")
    }
}
