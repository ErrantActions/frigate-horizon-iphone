import Foundation

public struct LiveCameraGridGeometry: Equatable, Sendable {
    public static let spacing = 18.0
    public let columns: Int
    public let rows: Int
    public let tileWidth: Double
    public let tileHeight: Double
    public let height: Double

    public init(width: Double, cameraCount: Int, density: CameraDashboardPreferences.Density,
                accessibility: Bool) {
        precondition(width.isFinite && width >= 0 && cameraCount >= 0)
        let minimum = density == .compact ? 170.0 : 280.0
        columns = accessibility || density == .oneColumn ? 1
            : max(1, Int(floor((width + Self.spacing) / (minimum + Self.spacing))))
        rows = cameraCount / columns + (cameraCount % columns == 0 ? 0 : 1)
        tileWidth = max(0, (width - Double(columns - 1) * Self.spacing) / Double(columns))
        tileHeight = tileWidth * 9 / 16
        height = Double(rows) * tileHeight + Double(max(0, rows - 1)) * Self.spacing
    }

    public func origin(at index: Int) -> (x: Double, y: Double) {
        precondition(index >= 0)
        return (Double(index % columns) * (tileWidth + Self.spacing),
            Double(index / columns) * (tileHeight + Self.spacing))
    }
}
