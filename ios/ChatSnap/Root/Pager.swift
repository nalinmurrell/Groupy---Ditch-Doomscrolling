import SwiftUI

/// Three panes side by side, one screen wide each, swiped or jumped between.
///
/// Pure SwiftUI on purpose. `TabView(.page)` hosts each page in its own UIKit
/// view controller, and those miscount safe areas: nav titles slid under the
/// Dynamic Island and the chat composer floated a home-indicator's height
/// above the keyboard. One SwiftUI hierarchy has none of that.
/// Shared by the tab pager and the thread's swipe-to-close.
enum SwipeRule {
    /// Points per second that count as a flick.
    static let flickSpeed: CGFloat = 300
}

struct Pager<Content: View>: View {
    @Binding var index: Int
    let count: Int
    /// Off while a conversation is pushed, so a sideways drag in a thread
    /// doesn't peel the whole pane away.
    var isSwipeEnabled = true
    @ViewBuilder let content: () -> Content

    @State private var drag: CGFloat = 0
    @State private var axis: Axis?
    /// True only while a drag is live. Unlike `onEnded`, this resets when the
    /// system *cancels* a drag too (a full-screen page opening or closing
    /// mid-touch), so the pager can never stay locked mid-swipe.
    @GestureState private var isDragging = false
    /// True from the moment a drag commits to sideways until just after it
    /// settles. The panes are disabled meanwhile, so letting go over a row or
    /// button doesn't also count as a tap on it (that opened a chat mid-swipe,
    /// invisibly, and a pushed chat turns paging off — the pager looked stuck).
    @State private var isPaging = false

    private let snap = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                content()
                    .frame(width: width)
            }
            // On the panes only; the swipe gesture below sits outside it.
            // .disabled, not allowsHitTesting: only disabling stops a tap that
            // began before the swipe from firing on release. Buttons on the
            // panes use `.quiet` so this doesn't grey them out.
            .disabled(isPaging)
            .offset(x: -CGFloat(index) * width + drag)
            .simultaneousGesture(swipe(width: width), including: isSwipeEnabled ? .all : .subviews)
            .onChange(of: isDragging) { _, live in
                guard !live, axis != nil || drag != 0 else { return }
                // Ended without onEnded: cancelled. Put everything back.
                axis = nil
                withAnimation(snap) { drag = 0 }
                settle()
            }
        }
    }

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                // Lock to whichever axis the finger commits to first, so a
                // vertical scroll in a list never drifts the pane sideways.
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                // Turned off mid-drag (a pinch began): don't move the panes.
                guard axis == .horizontal, isSwipeEnabled else {
                    if drag != 0 { withAnimation(snap) { drag = 0 } }
                    return
                }
                if !isPaging { isPaging = true }

                var dx = value.translation.width
                // Rubber-band past the ends instead of showing empty space.
                if (index == 0 && dx > 0) || (index == count - 1 && dx < 0) { dx /= 3 }
                drag = dx
            }
            .onEnded { value in
                defer { axis = nil }
                guard axis == .horizontal, isSwipeEnabled else {
                    withAnimation(snap) { drag = 0 }
                    settle()
                    return
                }

                // A quick flick changes tab however short it is; a slow drag
                // has to get past halfway. Slow, short drags snap back.
                let dx = value.translation.width
                let speed = value.velocity.width
                var next = index
                // Only a flick the same way as the drag counts (lift-off
                // twitches back the other way).
                if dx < 0 && (speed < -SwipeRule.flickSpeed || dx < -width / 2) { next += 1 }
                if dx > 0 && (speed >  SwipeRule.flickSpeed || dx >  width / 2) { next -= 1 }
                next = max(0, min(count - 1, next))

                withAnimation(snap) {
                    index = next
                    drag = 0
                }
                settle()
            }
    }

    /// Re-enable the panes once the finger's release has been and gone.
    private func settle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isPaging = false }
    }
}
