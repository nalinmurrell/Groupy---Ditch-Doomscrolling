import SwiftUI

/// Like `.plain`, but never greys out when disabled. The pager disables the
/// tabs for a moment during a swipe (so letting go can't also tap a row),
/// and `.plain` made every row flash grey each time.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// No press feedback and never greyed out. For rows inside a chat thread:
/// the swipe lock disables them mid-swipe, and a press it cancels must not
/// leave the row stuck dimmed (Snapchat's rows don't dim when pressed anyway).
struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == FlatButtonStyle {
    static var flat: FlatButtonStyle { FlatButtonStyle() }
}
