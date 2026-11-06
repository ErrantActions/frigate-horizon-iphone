import AVFoundation
import CoreImage
import SwiftUI
@preconcurrency import WebRTC

final class RTCViewerFrameObserver: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var lastCallback = -Double.infinity
    private var pixels: CVPixelBuffer?
    private var receivedAt: TimeInterval?
    var onDecoded: (@Sendable (CGSize, TimeInterval) -> Void)?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        receivedAt = now
        if let buffer = frame.buffer as? RTCCVPixelBuffer, frame.rotation.rawValue == 0,
           buffer.cropX == 0, buffer.cropY == 0,
           Int(buffer.cropWidth) == CVPixelBufferGetWidth(buffer.pixelBuffer),
           Int(buffer.cropHeight) == CVPixelBufferGetHeight(buffer.pixelBuffer) { pixels = buffer.pixelBuffer }
        else { pixels = nil }
        let notify = now - lastCallback >= 0.25
        if notify { lastCallback = now }
        lock.unlock()
        if notify {
            let rotated = frame.rotation.rawValue == 90 || frame.rotation.rawValue == 270
            onDecoded?(CGSize(width: Int(rotated ? frame.height : frame.width),
                height: Int(rotated ? frame.width : frame.height)), now)
        }
    }
    func pixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let receivedAt, ProcessInfo.processInfo.systemUptime - receivedAt < 1 else { return nil }
        return pixels
    }
    func reset() { lock.lock(); pixels = nil; receivedAt = nil; lastCallback = -.infinity; lock.unlock() }
}

@MainActor
struct NativeRTCViewerSurface: UIViewRepresentable {
    let track: RTCVideoTrack?
    var fillVideo = false
    var pipLayer: AVSampleBufferDisplayLayer? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RTCViewerHost { RTCViewerHost(pipLayer: pipLayer) }
    func updateUIView(_ view: RTCViewerHost, context: Context) {
        view.video.videoContentMode = fillVideo ? .scaleAspectFill : .scaleAspectFit
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view.video)
            context.coordinator.track = track
            if let track { track.add(view.video) } else { view.video.renderFrame(nil) }
        }
    }
    static func dismantleUIView(_ view: RTCViewerHost, coordinator: Coordinator) {
        coordinator.track?.remove(view.video); coordinator.track = nil
        view.video.renderFrame(nil)
        if view.pipLayer?.superlayer === view.layer { view.pipLayer?.removeFromSuperlayer() }
    }
    final class Coordinator { var track: RTCVideoTrack? }
}

final class RTCViewerHost: UIView {
    let video = RTCMTLVideoView(frame: .zero)
    let pipLayer: AVSampleBufferDisplayLayer?
    init(pipLayer: AVSampleBufferDisplayLayer?) {
        self.pipLayer = pipLayer
        super.init(frame: .zero)
        backgroundColor = .black
        if let pipLayer { layer.addSublayer(pipLayer) }
        addSubview(video)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        video.frame = bounds
        if pipLayer?.superlayer === layer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pipLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

final class RTCViewerPiPRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Horizon.rtc-pip", qos: .userInitiated)
    private let converter = RTCViewerPixelConverter()
    private var running = false
    private var busy = false
    private var generation = UUID()
    @MainActor private var track: RTCVideoTrack?
    @MainActor var onFailure: (() -> Void)?
    private struct Sample: @unchecked Sendable { let value: CMSampleBuffer }

    @MainActor func follow(_ value: RTCVideoTrack) {
        guard track !== value else { return }
        stop()
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase else {
            onFailure?(); return
        }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(timebase, rate: 1)
        displayLayer.controlTimebase = timebase
        displayLayer.videoGravity = .resizeAspect
        track = value
        lock.lock(); running = true; lock.unlock()
        value.add(self)
    }
    @MainActor func stop() {
        lock.lock(); running = false; generation = UUID(); lock.unlock()
        track?.remove(self); track = nil
        displayLayer.flushAndRemoveImage(); displayLayer.controlTimebase = nil
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard running, !busy else { lock.unlock(); return }
        busy = true
        let token = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { Sample(value: try self.sample(frame)) }
            Task { @MainActor in
                self.lock.lock(); self.busy = false
                let current = self.running && self.generation == token
                self.lock.unlock()
                guard current else { return }
                switch result {
                case .success(let sample):
                    if self.displayLayer.status == .failed { self.onFailure?(); return }
                    if self.displayLayer.isReadyForMoreMediaData { self.displayLayer.enqueue(sample.value) }
                case .failure: self.onFailure?()
                }
            }
        }
    }
    private func sample(_ frame: RTCVideoFrame) throws -> CMSampleBuffer {
        let buffer = try converter.pixels(frame)
        var format: CMVideoFormatDescription?
        var result: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { throw RenderFailure.invalid }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result else { throw RenderFailure.invalid }
        if let array = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return result
    }
    private enum RenderFailure: Error { case invalid }
}

final class RTCViewerPixelConverter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func pixels(_ frame: RTCVideoFrame) throws -> CVPixelBuffer {
        let image: CIImage
        if let source = frame.buffer as? RTCCVPixelBuffer {
            let raw = source.pixelBuffer
            let crop = CGRect(x: Int(source.cropX),
                y: CVPixelBufferGetHeight(raw) - Int(source.cropY) - Int(source.cropHeight),
                width: Int(source.cropWidth), height: Int(source.cropHeight))
            guard CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(raw), height: CVPixelBufferGetHeight(raw)).contains(crop),
                  crop.width > 0, crop.height > 0 else { throw RenderFailure.invalid }
            if frame.rotation.rawValue == 0, crop.origin == .zero,
               Int(crop.width) == CVPixelBufferGetWidth(raw), Int(crop.height) == CVPixelBufferGetHeight(raw) { return raw }
            image = CIImage(cvPixelBuffer: raw).cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        } else {
            let source = frame.buffer.toI420()
            guard source.width > 0, source.height > 0, source.chromaWidth > 0, source.chromaHeight > 0,
                  source.strideY >= source.width, source.strideU >= source.chromaWidth,
                  source.strideV >= source.chromaWidth else { throw RenderFailure.invalid }
            let raw = try allocate(width: Int(source.width), height: Int(source.height),
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            guard CVPixelBufferLockBaseAddress(raw, []) == kCVReturnSuccess else { throw RenderFailure.invalid }
            defer { CVPixelBufferUnlockBaseAddress(raw, []) }
            guard let y = CVPixelBufferGetBaseAddressOfPlane(raw, 0)?.assumingMemoryBound(to: UInt8.self),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(raw, 1)?.assumingMemoryBound(to: UInt8.self) else { throw RenderFailure.invalid }
            for row in 0..<Int(source.height) {
                for column in 0..<Int(source.width) {
                    y[row * CVPixelBufferGetBytesPerRowOfPlane(raw, 0) + column] = source.dataY[row * Int(source.strideY) + column]
                }
            }
            for row in 0..<Int(source.chromaHeight) {
                for column in 0..<Int(source.chromaWidth) {
                    let at = row * CVPixelBufferGetBytesPerRowOfPlane(raw, 1) + column * 2
                    uv[at] = source.dataU[row * Int(source.strideU) + column]
                    uv[at + 1] = source.dataV[row * Int(source.strideV) + column]
                }
            }
            image = CIImage(cvPixelBuffer: raw)
        }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(frame.rotation.rawValue) * .pi / 180))
        let output = try allocate(width: Int(rotated.extent.width.rounded()), height: Int(rotated.extent.height.rounded()),
            format: kCVPixelFormatType_32BGRA)
        context.render(rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX,
            y: -rotated.extent.minY)), to: output)
        return output
    }
    private func allocate(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw RenderFailure.invalid }
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw RenderFailure.invalid }
        return result
    }
    private enum RenderFailure: Error { case invalid }
}
