import SwiftUI

/// Three panes side by side, one screen wide each, swiped or jumped between.
///
/// Pure SwiftUI on purpose. `TabView(.page)` hosts each page in its own UIKit
/// view controller, and those miscount safe areas: nav titles slid under the
/// Dynamic Island and the chat composer floated a home-indicator's height
/// above the keyboard. One SwiftUI hierarchy has none of that.
struct Pager<Content: View>: View {
    @Binding var index: Int
    let count: Int
    /// Off while a conversation is pushed, so a sideways drag in a thread
    /// doesn't peel the whole pane away.
    var isSwipeEnabled = true
    @ViewBuilder let content: () -> Content

    @State private var drag: CGFloat = 0
    @State private var axis: Axis?

    private let snap = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                content()
                    .frame(width: width)
            }
            .offset(x: -CGFloat(index) * width + drag)
            .simultaneousGesture(swipe(width: width), including: isSwipeEnabled ? .all : .subviews)
        }
    }

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // Lock to whichever axis the finger commits to first, so a
                // vertical scroll in a list never drifts the pane sideways.
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard axis == .horizontal else { return }

                var dx = value.translation.width
                // Rubber-band past the ends instead of showing empty space.
                if (index == 0 && dx > 0) || (index == count - 1 && dx < 0) { dx /= 3 }
                drag = dx
            }
            .onEnded { value in
                defer { axis = nil }
                guard axis == .horizontal else { return }

                let projected = value.predictedEndTranslation.width
                var next = index
                if projected < -width / 3 { next += 1 }
                if projected >  width / 3 { next -= 1 }
                next = max(0, min(count - 1, next))

                withAnimation(snap) {
                    index = next
                    drag = 0
                }
            }
    }
}
