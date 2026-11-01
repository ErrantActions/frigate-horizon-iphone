import XCTest
import AVFoundation
import CoreImage
@testable import FrigateHorizon

final class VideoReflectionTests: XCTestCase {
    func testDecodedPixelsAreVerticallyMirrored() async throws {
        let buffer = try pixels()
        let reference = try XCTUnwrap(CIContext().createCGImage(
            CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: 64, height: 32)
        ))
        let rendered = await VideoReflectionRenderer().render(
            ReflectionFrame(content: .pixelBuffer(buffer, .identity)), blurRadius: 0
        )
        let result = try XCTUnwrap(rendered)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 32)
        for (x, y) in [(8, 4), (48, 4), (8, 24), (48, 24)] {
            XCTAssertEqual(try color(result, x: x, y: y), try color(reference, x: x, y: 31 - y))
        }
    }

    func testPlayerPreferredTransformPrecedesVerticalReflection() async throws {
        let buffer = try pixels()
        let reference = try XCTUnwrap(CIContext().createCGImage(
            CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: 64, height: 32)
        ))
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 64, ty: 32)
        let rendered = await VideoReflectionRenderer().render(
            ReflectionFrame(content: .pixelBuffer(buffer, transform)), blurRadius: 0
        )
        let result = try XCTUnwrap(rendered)
        for (x, y) in [(8, 4), (48, 4), (8, 24), (48, 24)] {
            XCTAssertEqual(try color(result, x: x, y: y), try color(reference, x: 63 - x, y: y))
        }
    }

    func testReflectionIsDownsampledAndBlurred() async throws {
        let renderer = VideoReflectionRenderer()
        let large = await renderer.render(
            ReflectionFrame(content: .pixelBuffer(try pixels(width: 1280, height: 720), .identity))
        )
        XCTAssertEqual(try XCTUnwrap(large).width, 320)
        XCTAssertEqual(try XCTUnwrap(large).height, 180)
        let frame = ReflectionFrame(content: .pixelBuffer(try pixels(), .identity))
        let sharpImage = await renderer.render(frame, blurRadius: 0)
        let blurredImage = await renderer.render(frame)
        let sharp = try color(XCTUnwrap(sharpImage), x: 8, y: 15)
        let blurred = try color(XCTUnwrap(blurredImage), x: 8, y: 15)
        XCTAssertNotEqual(sharp, blurred)
        XCTAssertGreaterThan(blurred[0], 10)
        XCTAssertGreaterThan(blurred[2], 10)
    }

    @MainActor
    func testDisablingAndDisappearanceClearAndRejectInFlightFrames() async throws {
        let rendered = await VideoReflectionRenderer().render(
            ReflectionFrame(content: .pixelBuffer(try pixels(), .identity))
        )
        let image = try XCTUnwrap(rendered)
        let reflection = VideoReflection()
        reflection.setEnabled(true)
        let first = reflection.generation
        reflection.publish(image, generation: first)
        XCTAssertNotNil(reflection.image)
        reflection.setEnabled(false)
        XCTAssertNil(reflection.image)
        reflection.publish(image, generation: first)
        XCTAssertNil(reflection.image)
        reflection.setEnabled(true)
        let second = reflection.generation
        reflection.publish(image, generation: second)
        XCTAssertNotNil(reflection.image)
        reflection.clearSource()
        reflection.publish(image, generation: second)
        XCTAssertNil(reflection.image)
        reflection.setEnabled(false)
    }

    @MainActor
    func testPlayerTapDetachesWithoutReplacingOrStoppingThePlayer() {
        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        let first = AVPlayer(playerItem: firstItem)
        let second = AVPlayer(playerItem: secondItem)
        let reflection = VideoReflection()
        reflection.follow(player: first)
        XCTAssertTrue(firstItem.outputs.isEmpty)
        reflection.setEnabled(true)
        XCTAssertEqual(firstItem.outputs.count, 1)
        reflection.follow(player: second)
        XCTAssertTrue(firstItem.outputs.isEmpty)
        XCTAssertEqual(secondItem.outputs.count, 1)
        XCTAssertTrue(first.currentItem === firstItem)
        reflection.setEnabled(false)
        XCTAssertTrue(secondItem.outputs.isEmpty)
        XCTAssertTrue(second.currentItem === secondItem)
        reflection.clearSource()
    }

    @MainActor
    func testItemReplacementRejectsAnOldFrameBeforeKVOOrNextPoll() async throws {
        let rendered = await VideoReflectionRenderer().render(
            ReflectionFrame(content: .pixelBuffer(try pixels(), .identity))
        )
        let image = try XCTUnwrap(rendered)
        let first = AVPlayerItem(asset: AVMutableComposition())
        let second = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: first)
        let reflection = VideoReflection()
        reflection.follow(player: player)
        reflection.setEnabled(true)
        let token = reflection.generation
        reflection.publish(image, generation: token)
        XCTAssertNotNil(reflection.image)
        player.replaceCurrentItem(with: second)
        reflection.publish(image, generation: token)
        XCTAssertNil(reflection.image)
        XCTAssertTrue(first.outputs.isEmpty)
        reflection.clearSource()
        reflection.setEnabled(false)
        XCTAssertTrue(second.outputs.isEmpty)
    }

    private func pixels(width: Int = 64, height: Int = 32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(result, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        let quadrants: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255],
                                    [255, 0, 0, 255], [0, 255, 255, 255]]
        for y in 0..<height {
            for x in 0..<width {
                let value = quadrants[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                for channel in 0..<4 { bytes[y * stride + x * 4 + channel] = value[channel] }
            }
        }
        return result
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
