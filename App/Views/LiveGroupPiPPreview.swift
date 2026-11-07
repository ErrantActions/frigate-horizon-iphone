import SwiftUI
import AVFoundation

struct LiveGroupPiPPreview: UIViewRepresentable {
    let controller: LiveGroupPictureInPictureController
    private var wasAttached = false
    func makeUIView(context: Context) -> Host { Host(controller: controller) }
    func updateUIView(_ view: Host, context: Context) {}
    static func dismantleUIView(_ view: Host, coordinator: ()) {
        view.controller.detachPreview()
        if view.controller.renderer.displayLayer.superlayer === view.layer {
            view.controller.renderer.displayLayer.removeFromSuperlayer()
        }
    }
    final class Host: UIView {
        let controller: LiveGroupPictureInPictureController
        init(controller: LiveGroupPictureInPictureController) {
            self.controller = controller
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(controller.renderer.displayLayer)
        }
        required init?(coder: NSCoder) { return nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            controller.renderer.displayLayer.frame = bounds
            CATransaction.commit()
            if window != nil { controller.attachPreview(size: bounds.size) }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                wasAttached = true
                controller.attachPreview(size: bounds.size)
            } else if wasAttached { controller.detachPreview() }
        }
    }
}
