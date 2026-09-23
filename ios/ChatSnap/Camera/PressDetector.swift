import SwiftUI
import UIKit

/// Reports touch-down and lift the instant UIKit sees them. SwiftUI's own
/// gestures arbitrate with every recognizer up the hierarchy first, which
/// held the shutter's touch-down back by ~0.75s — the whole hold-to-record
/// latency. A UIKit recognizer gets the touch straight from the window.
struct PressDetector: UIViewRepresentable {
    let onBegan: () -> Void
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

        @objc func changed(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onBegan()
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

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
