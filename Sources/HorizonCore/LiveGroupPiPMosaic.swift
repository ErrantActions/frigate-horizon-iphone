import AVFoundation
import CoreText

public struct LiveGroupPiPGeometry: Equatable, Sendable {
    public static let width = 960
    public static let height = 540
    public let columns: Int
    public let rows: Int
    public let count: Int
    public init(count: Int) {
        precondition(count > 0)
        self.count = count
        columns = Int(ceil(sqrt(Double(count))))
        rows = (count + columns - 1) / columns
    }
    public func tile(at index: Int) -> CGRect {
        precondition((0..<count).contains(index))
        let width = Double(Self.width) / Double(columns)
        let height = Double(Self.height) / Double(rows)
        return CGRect(x: Double(index % columns) * width,
            y: Double(rows - 1 - index / columns) * height, width: width, height: height)
    }
    public static func isFresh(received: Double?, now: Double) -> Bool {
        guard let received, received.isFinite, now.isFinite else { return false }
        return now >= received && now - received < 2
    }
    public static func accepts(cameraIDs: [String], allowed: Set<String>) -> Bool {
        !cameraIDs.isEmpty && Set(cameraIDs).count == cameraIDs.count && Set(cameraIDs).isSubset(of: allowed)
    }
}

public final class LiveGroupPiPMosaic {
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    public init() {}
    public func render(pixels: [CVPixelBuffer?], names: [String], unavailable: String) throws -> CVPixelBuffer {
        try render(images: pixels.map { try $0.map { try LiveGroupPiPImage(buffer: $0) } },
            names: names, unavailable: unavailable)
    }
    public func render(images: [LiveGroupPiPImage?], names: [String], unavailable: String) throws -> CVPixelBuffer {
        guard !images.isEmpty, images.count == names.count else { throw RecordedHTTPError.invalidWindow }
        let geometry = LiveGroupPiPGeometry(count: names.count)
        let bounds = CGRect(x: 0, y: 0, width: LiveGroupPiPGeometry.width, height: LiveGroupPiPGeometry.height)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, LiveGroupPiPGeometry.width, LiveGroupPiPGeometry.height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecordedHTTPError.preparationFailed }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw RecordedHTTPError.preparationFailed }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: LiveGroupPiPGeometry.width,
            height: LiveGroupPiPGeometry.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw RecordedHTTPError.preparationFailed
        }
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(bounds)
        cg.interpolationQuality = .medium
        for (index, frame) in images.enumerated() {
            guard let frame else { continue }
            let tile = geometry.tile(at: index).insetBy(dx: 2, dy: 2)
            let rotated = frame.rotation == 90 || frame.rotation == 270
            let width = CGFloat(rotated ? frame.image.height : frame.image.width)
            let height = CGFloat(rotated ? frame.image.width : frame.image.height)
            let scale = min(tile.width / width, tile.height / height)
            cg.saveGState()
            cg.translateBy(x: tile.midX, y: tile.midY)
            cg.scaleBy(x: scale, y: scale)
            cg.rotate(by: -CGFloat(frame.rotation) * .pi / 180)
            cg.draw(frame.image, in: CGRect(x: -CGFloat(frame.image.width) / 2,
                y: -CGFloat(frame.image.height) / 2,
                width: CGFloat(frame.image.width), height: CGFloat(frame.image.height)))
            cg.restoreGState()
        }
        for index in names.indices {
            let tile = geometry.tile(at: index)
            let label = images[index] == nil ? names[index] + " - " + unavailable : names[index]
            cg.saveGState()
            let strip = CGRect(x: tile.minX + 2, y: tile.minY + 2,
                width: max(0, tile.width - 4), height: min(28, tile.height))
            cg.clip(to: strip)
            cg.setFillColor(CGColor(gray: 0, alpha: 0.8)); cg.fill(strip)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            cg.textPosition = CGPoint(x: strip.minX + 6, y: strip.minY + 7)
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
        return buffer
    }
}
