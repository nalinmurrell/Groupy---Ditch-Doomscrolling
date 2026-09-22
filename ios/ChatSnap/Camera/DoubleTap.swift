import SwiftUI

/// A double-tap that doesn't make UIKit wait. `onTapGesture(count: 2)`
/// installs a recognizer that holds *every* touch in the window until it's
/// sure it isn't a double-tap — for a held finger that's ~0.75s, which is
/// exactly the shutter's hold-to-record latency. This counts taps itself
/// from a zero-distance drag, which claims nothing from anyone else.
private struct DoubleTap: ViewModifier {
    let action: () -> Void
    @State private var lastTap: (time: Date, at: CGPoint)?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let moved = hypot(value.translation.width, value.translation.height)
                    guard moved < 20 else { lastTap = nil; return }
                    let now = Date()
                    if let last = lastTap,
                       now.timeIntervalSince(last.time) < 0.35,
                       hypot(value.startLocation.x - last.at.x, value.startLocation.y - last.at.y) < 60 {
                        lastTap = nil
                        action()
                    } else {
                        lastTap = (now, value.startLocation)
                    }
                }
        )
    }
}

extension View {
    func doubleTap(_ action: @escaping () -> Void) -> some View {
        modifier(DoubleTap(action: action))
    }
}
