import AVFoundation
import Accelerate

public struct LiveGroupPiPImage {
    public let image: CGImage
    public let rotation: Int
    public init(buffer: CVPixelBuffer, crop: CGRect? = nil, rotation: Int = 0) throws {
        guard [0,90,180,270].contains(rotation) else { throw RecordedHTTPError.invalidWindow }
        let full = try Self.rgbImage(buffer)
        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let crop = crop ?? bounds
        guard crop.width > 0, crop.height > 0, bounds.contains(crop),
              let image = full.cropping(to: crop) else { throw RecordedHTTPError.invalidWindow }
        self.image = image; self.rotation = rotation
    }
    private static func rgbImage(_ buffer: CVPixelBuffer) throws -> CGImage {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw RecordedHTTPError.invalidWindow
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var data: Data
        let rowBytes: Int
        if format == kCVPixelFormatType_32BGRA {
            rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer), rowBytes >= width * 4 else {
                throw RecordedHTTPError.invalidWindow
            }
            data = Data(bytes: base, count: rowBytes * height)
        } else {
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  CVPixelBufferGetPlaneCount(buffer) == 2,
                  let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { throw RecordedHTTPError.invalidWindow }
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var range = vImage_YpCbCrPixelRange(Yp_bias: fullRange ? 0 : 16, CbCr_bias: 128,
                YpRangeMax: fullRange ? 255 : 235, CbCrRangeMax: fullRange ? 255 : 240,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            let matrix: UnsafePointer<vImage_YpCbCrToARGBMatrix>
            if attachment == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
                matrix = kvImage_YpCbCrToARGBMatrix_ITU_R_709_2
            } else if attachment == nil || attachment == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
                matrix = kvImage_YpCbCrToARGBMatrix_ITU_R_601_4
            } else { throw RecordedHTTPError.invalidWindow }
            var conversion = vImage_YpCbCrToARGB()
            guard vImageConvert_YpCbCrToARGB_GenerateConversion(matrix, &range, &conversion,
                kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                throw RecordedHTTPError.invalidWindow
            }
            var sourceY = vImage_Buffer(data: y, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
            var sourceUV = vImage_Buffer(data: uv, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, 1)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, 1)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
            rowBytes = width * 4; data = Data(count: rowBytes * height)
            let status = data.withUnsafeMutableBytes { bytes -> vImage_Error in
                var destination = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: rowBytes)
                return [UInt8(3),2,1,0].withUnsafeBufferPointer {
                    vImageConvert_420Yp8_CbCr8ToARGB8888(&sourceY, &sourceUV, &destination,
                        &conversion, $0.baseAddress, 255, vImage_Flags(kvImageNoFlags))
                }
            }
            guard status == kvImageNoError else { throw RecordedHTTPError.invalidWindow }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedFirst.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RecordedHTTPError.invalidWindow
        }
        return image
    }
}
