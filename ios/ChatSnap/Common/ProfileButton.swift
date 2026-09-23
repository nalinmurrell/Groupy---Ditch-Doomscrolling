import SwiftUI

extension EnvironmentValues {
    /// Opens the profile layer RootView draws over the tabs.
    @Entry var openProfile: () -> Void = {}
}

/// Your avatar, top-left on every tab, Snapchat-style. Opens your profile.
struct ProfileButton: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.openProfile) private var openProfile
    var size: CGFloat = 40

    var body: some View {
        Button { openProfile() } label: {
            Group {
                if let me = session.me {
                    Avatar(subject: me, size: size)
                } else {
                    Circle().fill(.white.opacity(0.15)).frame(width: size, height: size)
                }
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }
}

/// Your profile: a page of its own, with settings behind the gear.
///
/// Drawn by RootView as a layer over the tabs rather than presented with
/// fullScreenCover: closing a cover mid-gesture left UIKit's presentation
/// container behind, and the pager stopped receiving swipes.
struct ProfileScreen: View {
    @EnvironmentObject private var session: SessionStore
    /// Animated close (the back button, sign-out).
    let onClose: () -> Void
    /// Immediate close, for when the page has already been swiped off screen.
    let onSwipedAway: () -> Void
    @State private var isShowingSettings = false
    /// Follows a rightward swipe; far enough (or flung) and the page closes.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                header
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) { topBar }
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsScreen { onSwipedAway() }
            }
        }
        // White back chevrons, like Snapchat, rather than iOS blue.
        .tint(.white)
        .background(Color.black.ignoresSafeArea())
        .offset(x: dragOffset)
        .simultaneousGesture(swipeRight)
        .preferredColorScheme(.dark)
    }

    /// Only on the profile itself — in Settings a right swipe means "back".
    private var swipeRight: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isShowingSettings,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                guard !isShowingSettings, dragOffset > 0 else { return }
                if value.translation.width > 110 || value.predictedEndTranslation.width > 240 {
                    withAnimation(.easeIn(duration: 0.18)) {
                        dragOffset = UIScreen.main.bounds.width
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: onSwipedAway)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("Back")
            Spacer()
            Button { isShowingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// A banner in your avatar's colour, you in the middle of it.
    private var header: some View {
        let hue = session.me?.hue ?? 0.7
        return VStack(spacing: 8) {
            if let me = session.me {
                Avatar(subject: me, size: 132)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                    .padding(.top, 130)
                Text(me.displayName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text(me.username)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.55),
                    Color(hue: hue, saturation: 0.45, brightness: 0.25),
                    .black,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
