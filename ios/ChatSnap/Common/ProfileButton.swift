import SwiftUI

/// Your avatar, top-left on every tab, Snapchat-style. Opens your profile.
struct ProfileButton: View {
    @EnvironmentObject private var session: SessionStore
    var size: CGFloat = 40

    @State private var isShowingProfile = false

    var body: some View {
        Button { isShowingProfile = true } label: {
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
        .fullScreenCover(isPresented: $isShowingProfile) {
            ProfileScreen()
        }
    }
}

/// Your profile: a page of its own, with settings behind the gear.
private struct ProfileScreen: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingSettings = false

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
                SettingsScreen { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
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

/// Settings. For now, just who you're signed in as and the way out.
private struct SettingsScreen: View {
    @EnvironmentObject private var session: SessionStore
    /// Closes the whole profile, so sign-out doesn't leave it up.
    let onSignOut: () -> Void

    var body: some View {
        List {
            if let me = session.me {
                Section("Account") {
                    LabeledContent("Name", value: me.displayName)
                    LabeledContent("Username", value: "@\(me.username)")
                }
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    onSignOut()
                    Task { await session.signOut() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
