import XCTest
import CoreVideo
@testable import HorizonCore

final class LiveGroupPiPMosaicTests: XCTestCase {
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
}
