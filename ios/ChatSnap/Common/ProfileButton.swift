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
        .sheet(isPresented: $isShowingProfile) {
            ProfileSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(white: 0.09))
                .preferredColorScheme(.dark)
        }
    }
}

/// Who you are, and the way out.
private struct ProfileSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            if let me = session.me {
                Avatar(subject: me, size: 96)
                    .padding(.top, 36)
                Text(me.displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("@\(me.username)")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button {
                dismiss()
                Task { await session.signOut() }
            } label: {
                Text("Sign Out")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
