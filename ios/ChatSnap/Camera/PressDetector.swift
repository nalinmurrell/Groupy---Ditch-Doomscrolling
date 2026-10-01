import SwiftUI
import UIKit

/// Reports touch-down and lift the instant UIKit sees them. SwiftUI's own
/// gestures arbitrate with every recognizer up the hierarchy first, which
/// held the shutter's touch-down back by ~0.75s — the whole hold-to-record
/// latency. A UIKit recognizer gets the touch straight from the window.
struct PressDetector: UIViewRepresentable {
    let onBegan: () -> Void
    /// Finger's offset from where it went down (up is negative y).
    var onMoved: (CGSize) -> Void = { _ in }
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = ImmediatePress(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PressDetector
        init(parent: PressDetector) { self.parent = parent }

        private var start: CGPoint = .zero

        @objc func changed(_ recognizer: UIGestureRecognizer) {
            // Window coordinates, so a view that moves or grows under the
            // finger (the voice-note mic slides with it) can't skew the offset.
            let point = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                start = point
                parent.onBegan()
            case .changed:
                parent.onMoved(CGSize(width: point.x - start.x, height: point.y - start.y))
            case .ended, .cancelled, .failed: parent.onEnded()
            default: break
            }
        }

        // Never block or wait on anything else (the pager's swipe, etc.).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// Begins on the first touch, ends on lift. No movement or time threshold.
private final class ImmediatePress: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
