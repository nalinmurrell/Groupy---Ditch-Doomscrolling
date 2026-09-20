import AVFoundation
import SwiftUI
import UIKit

/// Full-bleed live preview. Hosts the controller's single preview layer;
/// whichever active preview asked for it most recently has it.
struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    /// False while another preview (the in-thread camera) owns the layer.
    var isActive = true

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        if isActive { view.adopt(layer) }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if isActive { uiView.adopt(layer) }
    }
}

final class PreviewView: UIView {
    private var preview: AVCaptureVideoPreviewLayer?

    func adopt(_ layer: AVCaptureVideoPreviewLayer) {
        guard layer.superlayer !== self.layer else { return }
        layer.removeFromSuperlayer()
        preview = layer
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation, or the feed visibly lags a rotation/resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        CATransaction.commit()
    }
}
