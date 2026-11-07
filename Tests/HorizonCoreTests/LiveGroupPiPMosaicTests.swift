import XCTest
import CoreVideo
@testable import HorizonCore

final class LiveGroupPiPMosaicTests: XCTestCase {
    func testCPUConversionSupportsNativeNV12RangesAndBT709() throws {
        for (full, bt709) in [(true,false),(false,false),(false,true)] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let value = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(value, [])
            let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(value, 0)?.assumingMemoryBound(to: UInt8.self))
            let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(value, 1)?.assumingMemoryBound(to: UInt8.self))
            for row in 0..<64 {
                for col in 0..<64 { y[row * CVPixelBufferGetBytesPerRowOfPlane(value, 0) + col] = full ? 76 : (bt709 ? 63 : 81) }
            }
            for row in 0..<32 {
                for col in 0..<32 {
                    let at = row * CVPixelBufferGetBytesPerRowOfPlane(value, 1) + col * 2
                    uv[at] = full ? 85 : (bt709 ? 102 : 90); uv[at + 1] = full ? 255 : 240
                }
            }
            CVPixelBufferUnlockBaseAddress(value, [])
            if bt709 {
                CVBufferSetAttachment(value, kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
            let rendered = try LiveGroupPiPMosaic().render(pixels: [value], names: ["Front"], unavailable: "Unavailable")
            let color = pixel(rendered, x: 480, y: 270)
            XCTAssertGreaterThan(color.red, 220)
            XCTAssertLessThan(color.green, 40)
        }
    }
    func testCPUCompositionKeepsTopBottomOrientationAndRotation() throws {
        let value = try buffer(red: 255, green: 0)
        CVPixelBufferLockBaseAddress(value, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(value)?.assumingMemoryBound(to: UInt8.self))
        for y in 45..<90 {
            for x in 0..<160 {
                let at = y * CVPixelBufferGetBytesPerRow(value) + x * 4
                base[at + 1] = 255; base[at + 2] = 0
            }
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        let composer = LiveGroupPiPMosaic()
        let normal = try composer.render(images: [LiveGroupPiPImage(buffer: value)], names: ["Front"], unavailable: "Unavailable")
        XCTAssertGreaterThan(pixel(normal, x: 480, y: 135).red, 220)
        XCTAssertGreaterThan(pixel(normal, x: 480, y: 405).green, 220)
        let rotated = try composer.render(images: [LiveGroupPiPImage(buffer: value, rotation: 180)], names: ["Front"], unavailable: "Unavailable")
        XCTAssertGreaterThan(pixel(rotated, x: 480, y: 135).green, 220)
        XCTAssertGreaterThan(pixel(rotated, x: 480, y: 405).red, 220)
        for rotation in [90,270] {
            let sideways = try composer.render(images: [LiveGroupPiPImage(buffer: value, rotation: rotation)], names: ["Front"], unavailable: "Unavailable")
            let red = pixel(sideways, x: rotation == 90 ? 560 : 400, y: 270)
            let green = pixel(sideways, x: rotation == 90 ? 400 : 560, y: 270)
            XCTAssertGreaterThan(red.red, 220); XCTAssertGreaterThan(green.green, 220)
        }
        let crop = try LiveGroupPiPImage(buffer: value, crop: CGRect(x: 0, y: 0, width: 160, height: 45))
        let cropped = try composer.render(images: [crop], names: ["Front"], unavailable: "Unavailable")
        XCTAssertGreaterThan(pixel(cropped, x: 480, y: 270).red, 220)
    }
    func testCPUImageCroppingAndUnsupportedRotationAreExplicit() throws {
        let value = try buffer(red: 255, green: 0)
        let image = try LiveGroupPiPImage(buffer: value, crop: CGRect(x: 10, y: 10, width: 80, height: 40))
        XCTAssertEqual(image.image.width, 80); XCTAssertEqual(image.image.height, 40)
        XCTAssertThrowsError(try LiveGroupPiPImage(buffer: value, rotation: 45))
        XCTAssertThrowsError(try LiveGroupPiPImage(buffer: value, crop: CGRect(x: -1, y: 0, width: 160, height: 90)))
    }
    func testEveryGroupMemberGetsANonoverlappingTileWithoutDroppingExtraCameras() {
        for count in [1,2,3,4,9,10,16,25,32] {
            let grid = LiveGroupPiPGeometry(count: count)
            XCTAssertGreaterThanOrEqual(grid.columns * grid.rows, count)
            var previous: [CGRect] = []
            for index in 0..<count {
                let tile = grid.tile(at: index)
                XCTAssertGreaterThan(tile.width, 0)
                XCTAssertGreaterThan(tile.height, 0)
                XCTAssertGreaterThanOrEqual(tile.minX, 0)
                XCTAssertGreaterThanOrEqual(tile.minY, 0)
                XCTAssertLessThanOrEqual(tile.maxX, 960.000001)
                XCTAssertLessThanOrEqual(tile.maxY, 540.000001)
                for other in previous {
                    let intersection = tile.intersection(other)
                    XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.000001)
                }
                previous.append(tile)
            }
        }
    }
    func testGridUsesDashboardOrderFromTopLeftToBottomRight() {
        let grid = LiveGroupPiPGeometry(count: 4)
        XCTAssertEqual(grid.tile(at: 0), CGRect(x: 0, y: 270, width: 480, height: 270))
        XCTAssertEqual(grid.tile(at: 1), CGRect(x: 480, y: 270, width: 480, height: 270))
        XCTAssertEqual(grid.tile(at: 2), CGRect(x: 0, y: 0, width: 480, height: 270))
    }
    func testStaleAndFutureFramesAreNotPassedOffAsLive() {
        XCTAssertTrue(LiveGroupPiPGeometry.isFresh(received: 100, now: 101.999))
        for received in [nil, 99.0, 100, 103, Double.nan] {
            XCTAssertFalse(LiveGroupPiPGeometry.isFresh(received: received, now: 102))
        }
    }
    func testOnlyNonemptyUniqueAuthorizedMembershipIsAllowed() {
        XCTAssertTrue(LiveGroupPiPGeometry.accepts(cameraIDs: ["front","side"], allowed: ["front","side","rear"]))
        XCTAssertFalse(LiveGroupPiPGeometry.accepts(cameraIDs: [], allowed: ["front"]))
        XCTAssertFalse(LiveGroupPiPGeometry.accepts(cameraIDs: ["front","front"], allowed: ["front"]))
        XCTAssertFalse(LiveGroupPiPGeometry.accepts(cameraIDs: ["front","revoked"], allowed: ["front"]))
    }
    func testNativeCompositorPlacesDecodedPixelsAndLeavesUnavailableTileBlack() throws {
        let red = try buffer(red: 255, green: 0)
        let green = try buffer(red: 0, green: 255)
        let mosaic = LiveGroupPiPMosaic()
        let result = try mosaic.render(pixels: [red,green,nil,nil],
            names: ["Front","Side","Rear","Gate"], unavailable: "Unavailable")
        XCTAssertEqual(CVPixelBufferGetWidth(result), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(result), 540)
        let colors = sampleCenters(result)
        XCTAssertGreaterThan(colors[0].red, 220); XCTAssertLessThan(colors[0].green, 30)
        XCTAssertGreaterThan(colors[1].green, 220); XCTAssertLessThan(colors[1].red, 30)
        XCTAssertLessThan(colors[2].red + colors[2].green, 10)
        XCTAssertLessThan(colors[3].red + colors[3].green, 10)
    }
    func testCompositorRejectsInvalidMembershipAndDoesNotKeepFramesAfterClear() throws {
        let mosaic = LiveGroupPiPMosaic()
        XCTAssertThrowsError(try mosaic.render(pixels: [], names: [], unavailable: "Unavailable"))
        XCTAssertThrowsError(try mosaic.render(pixels: [nil], names: [], unavailable: "Unavailable"))
        _ = try mosaic.render(pixels: [try buffer(red: 255, green: 0)], names: ["Front"], unavailable: "Unavailable")
        let cleared = try mosaic.render(pixels: [nil], names: ["Front"], unavailable: "Unavailable")
        CVPixelBufferLockBaseAddress(cleared, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(cleared, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(cleared)?.assumingMemoryBound(to: UInt8.self))
        let at = 270 * CVPixelBufferGetBytesPerRow(cleared) + 480 * 4
        XCTAssertEqual(bytes[at + 2], 0)
    }
    private func buffer(red: UInt8, green: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let value = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(value, [])
        defer { CVPixelBufferUnlockBaseAddress(value, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(value)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<90 {
            for x in 0..<160 {
                let offset = y * CVPixelBufferGetBytesPerRow(value) + x * 4
                base[offset]=0; base[offset+1]=green; base[offset+2]=red; base[offset+3]=255
            }
        }
        return value
    }
    private func sampleCenters(_ value: CVPixelBuffer) -> [(red: Int, green: Int)] {
        CVPixelBufferLockBaseAddress(value, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(value, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(value)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return [(240,135),(720,135),(240,405),(720,405)].map { x,y in
            let offset = y * CVPixelBufferGetBytesPerRow(value) + x * 4
            return (Int(base[offset+2]), Int(base[offset+1]))
        }
    }
    private func pixel(_ value: CVPixelBuffer, x: Int, y: Int) -> (red: Int, green: Int) {
        CVPixelBufferLockBaseAddress(value, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(value, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(value)?.assumingMemoryBound(to: UInt8.self) else { return (0,0) }
        let at = y * CVPixelBufferGetBytesPerRow(value) + x * 4
        return (Int(base[at + 2]), Int(base[at + 1]))
    }
}
