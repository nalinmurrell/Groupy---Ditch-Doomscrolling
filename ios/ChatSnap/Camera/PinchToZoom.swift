import SwiftUI

/// Pinch the viewfinder to zoom. The pinching flag lives in @GestureState so
/// it resets even if the system cancels the gesture — otherwise a cancelled
/// pinch would leave tab swiping switched off.
private struct PinchToZoom: ViewModifier {
    @ObservedObject var camera: CameraController
    @GestureState private var isPinching = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($isPinching) { _, state, _ in state = true }
                    .onChanged { value in camera.zoom(pinchScale: value.magnification) }
            )
            .onChange(of: isPinching) { _, pinching in
                if pinching { camera.beginZoomGesture() }
                camera.isPinching = pinching
            }
    }
}

extension View {
    func pinchToZoom(_ camera: CameraController) -> some View {
        modifier(PinchToZoom(camera: camera))
    }
}
