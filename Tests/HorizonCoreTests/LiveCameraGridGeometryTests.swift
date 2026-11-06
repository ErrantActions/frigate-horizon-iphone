import XCTest
@testable import HorizonCore

final class LiveCameraGridGeometryTests: XCTestCase {
    func testEveryCameraGetsARowIncludingThoseBelowTheScreen() {
        let grid = LiveCameraGridGeometry(width: 390, cameraCount: 20, density: .comfortable, accessibility: false)
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 20)
        XCTAssertEqual(grid.tileHeight, 219.375)
        XCTAssertEqual(grid.origin(at: 19).y, 19 * (219.375 + 18))
        XCTAssertEqual(grid.height, 20 * 219.375 + 19 * 18)
    }

    func testAdaptiveColumnsMatchExistingDensityThresholds() {
        for (density, minimum) in [(CameraDashboardPreferences.Density.comfortable, 280.0), (.compact, 170.0)] {
            let threshold = minimum * 2 + 18
            let narrow = LiveCameraGridGeometry(width: threshold - 1, cameraCount: 6, density: density, accessibility: false)
            let wide = LiveCameraGridGeometry(width: threshold, cameraCount: 6, density: density, accessibility: false)
            XCTAssertEqual(narrow.columns, 1)
            XCTAssertEqual(wide.columns, 2)
            XCTAssertEqual(wide.rows, 3)
            XCTAssertEqual(wide.tileWidth, minimum)
            XCTAssertEqual(wide.origin(at: 1).x, minimum + 18)
            XCTAssertEqual(wide.origin(at: 2).x, 0)
        }
    }

    func testAccessibilityAndOneColumnPreserveFullWidthTiles() {
        let accessible = LiveCameraGridGeometry(width: 1000, cameraCount: 9, density: .compact, accessibility: true)
        let oneColumn = LiveCameraGridGeometry(width: 1000, cameraCount: 9, density: .oneColumn, accessibility: false)
        XCTAssertEqual(accessible, oneColumn)
        XCTAssertEqual(accessible.tileWidth, 1000)
        XCTAssertEqual(accessible.rows, 9)
    }

    func testPartialLastRowKeepsTileSizeAndEmptyGridTakesNoHeight() {
        let grid = LiveCameraGridGeometry(width: 900, cameraCount: 7, density: .comfortable, accessibility: false)
        XCTAssertEqual(grid.columns, 3)
        XCTAssertEqual(grid.rows, 3)
        XCTAssertEqual(grid.tileWidth, 288)
        XCTAssertEqual(grid.origin(at: 6).x, 0)
        XCTAssertEqual(grid.origin(at: 6).y, 2 * (162 + 18))
        let empty = LiveCameraGridGeometry(width: 900, cameraCount: 0, density: .comfortable, accessibility: false)
        XCTAssertEqual(empty.rows, 0)
        XCTAssertEqual(empty.height, 0)
    }

    func testAllTileFramesFitWithoutOverlapAcrossWidthsAndCameraCounts() {
        for density in CameraDashboardPreferences.Density.allCases {
            for width in [0.0, 100, 358, 578, 900, 1366] {
                for count in [1, 2, 7, 32] {
                    let grid = LiveCameraGridGeometry(width: width, cameraCount: count, density: density, accessibility: false)
                    for index in 0..<count {
                        let point = grid.origin(at: index)
                        XCTAssertGreaterThanOrEqual(point.x, 0)
                        XCTAssertLessThanOrEqual(point.x + grid.tileWidth, width + 0.000001)
                        XCTAssertLessThanOrEqual(point.y + grid.tileHeight, grid.height + 0.000001)
                        if index >= grid.columns {
                            XCTAssertGreaterThanOrEqual(point.y, grid.origin(at: index - grid.columns).y + grid.tileHeight)
                        }
                    }
                }
            }
        }
    }
}
