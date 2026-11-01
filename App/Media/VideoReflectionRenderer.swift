import AVFoundation
import CoreImage
import HorizonCore

struct ReflectionFrame: @unchecked Sendable {
    enum Content { case pixelBuffer(CVPixelBuffer, CGAffineTransform) }
    let content: Content
}

actor VideoReflectionRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ frame: ReflectionFrame, blurRadius: Double = 8) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let source: CIImage
        switch frame.content {
        case .pixelBuffer(let buffer, let transform): source = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        }
        let bounds = source.extent
        guard let size = VideoReflectionPolicy.downsampledSize(bounds.size) else { return nil }
        var image = source.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        image = image.transformed(by: CGAffineTransform(a: size.width / bounds.width, b: 0,
            c: 0, d: -size.height / bounds.height, tx: 0, ty: size.height))
        let output = CGRect(origin: .zero, size: size)
        if blurRadius > 0 {
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blurRadius]).cropped(to: output)
        }
        guard !Task.isCancelled else { return nil }
        return context.createCGImage(image, from: output)
    }
}
