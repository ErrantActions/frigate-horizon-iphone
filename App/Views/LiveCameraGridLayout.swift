import SwiftUI
import HorizonCore

// Eager, flat children keep camera/player identity when scrolling or changing column count.
struct LiveCameraGridLayout: Layout {
    let density: CameraDashboardPreferences.Density
    let accessibility: Bool
    let layoutDirection: LayoutDirection

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? (density == .compact ? 170 : 280)
        let width = proposed.isFinite ? max(0, proposed) : 280
        let geometry = geometry(width: width, count: subviews.count)
        return CGSize(width: width, height: geometry.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = geometry(width: bounds.width, count: subviews.count)
        let size = ProposedViewSize(width: geometry.tileWidth, height: geometry.tileHeight)
        for (index, subview) in subviews.enumerated() {
            let origin = geometry.origin(at: index)
            let x = layoutDirection == .rightToLeft ? bounds.width - origin.x - geometry.tileWidth : origin.x
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + origin.y),
                anchor: .topLeading, proposal: size)
        }
    }

    private func geometry(width: Double, count: Int) -> LiveCameraGridGeometry {
        LiveCameraGridGeometry(width: width, cameraCount: count, density: density, accessibility: accessibility)
    }
}
