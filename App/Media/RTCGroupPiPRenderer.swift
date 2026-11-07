import AVFoundation
import HorizonCore
@preconcurrency import WebRTC

private final class GroupPiPFrameSlot: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: RTCVideoFrame?
    private var received: Double?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock(); defer { lock.unlock() }
        self.frame = frame
        received = frame == nil ? nil : ProcessInfo.processInfo.systemUptime
    }
    func latest(now: Double) -> RTCVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return LiveGroupPiPGeometry.isFresh(received: received, now: now) ? frame : nil
    }
    func clear() { lock.lock(); frame = nil; received = nil; lock.unlock() }
}

@MainActor
final class RTCGroupPiPRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onFailure: ((Error) -> Void)?
    var onFirstFrame: (() -> Void)?
    private(set) var hasRenderedFrame = false
    private let queue = DispatchQueue(label: "Horizon.group-pip", qos: .userInitiated)
    private let composer = LiveGroupPiPMosaic()
    private let converter = RTCViewerPixelConverter()
    private var slots: [GroupPiPFrameSlot] = []
    private var names: [String] = []
    private var tracks: [RTCVideoTrack?] = []
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var busy = false
    private struct Output: @unchecked Sendable { let sample: CMSampleBuffer; let allFresh: Bool }

    func start(names: [String]) {
        stop()
        self.names = names
        slots = names.map { _ in GroupPiPFrameSlot() }
        tracks = names.map { _ in nil }
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase else {
            onFailure?(RecordedHTTPError.preparationFailed); return
        }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(timebase, rate: 1)
        displayLayer.controlTimebase = timebase; displayLayer.videoGravity = .resizeAspect
        let token = generation
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                self.tick(token)
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    func follow(_ track: RTCVideoTrack?, at index: Int) {
        guard tracks.indices.contains(index), tracks[index] !== track else { return }
        tracks[index]?.remove(slots[index])
        slots[index].clear()
        tracks[index] = track
        track?.add(slots[index])
    }
    func blank(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].clear()
    }
    private func tick(_ token: UUID) {
        guard !busy, !slots.isEmpty else { return }
        busy = true
        let frames = slots.map { $0.latest(now: ProcessInfo.processInfo.systemUptime) }
        let names = names
        let converter = converter, composer = composer
        let unavailable = String(localized: "groupPip.unavailable", defaultValue: "Unavailable")
        queue.async { [weak self] in
            let result = Result {
                let images = try frames.map { try $0.map { try converter.groupImage($0) } }
                let buffer = try composer.render(images: images, names: names, unavailable: unavailable)
                var format: CMVideoFormatDescription?
                var sample: CMSampleBuffer?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { throw ViewerTransportFailure.connectionLost }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                    presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                      let sample else { throw ViewerTransportFailure.connectionLost }
                return Output(sample: sample, allFresh: frames.allSatisfy { $0 != nil })
            }
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                guard self.generation == token else { return }
                switch result {
                case .success(let output):
                    guard self.displayLayer.status != .failed else {
                        self.onFailure?(self.displayLayer.error ?? ViewerTransportFailure.connectionLost); return
                    }
                    if self.displayLayer.isReadyForMoreMediaData {
                        self.displayLayer.enqueue(output.sample)
                        if output.allFresh, !self.hasRenderedFrame {
                            self.hasRenderedFrame = true
                            self.onFirstFrame?()
                        }
                    }
                case .failure(let error): self.onFailure?(error)
                }
            }
        }
    }
    func stop() {
        generation = UUID(); timer?.cancel(); timer = nil
        for index in tracks.indices { tracks[index]?.remove(slots[index]); slots[index].clear() }
        tracks = []; slots = []; names = []
        hasRenderedFrame = false
        displayLayer.flushAndRemoveImage(); displayLayer.controlTimebase = nil
    }
}
