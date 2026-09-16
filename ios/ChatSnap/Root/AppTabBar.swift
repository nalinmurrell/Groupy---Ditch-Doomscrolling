import SwiftUI

struct AppTabBar: View {
    @Binding var selection: AppTab

    /// Camera controls pad themselves above this.
    static let height: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            item(.chat, systemName: "bubble.left.and.bubble.right.fill", label: "Chat")
            item(.camera, systemName: "camera.fill", label: "Camera")
            item(.friends, systemName: "person.2.fill", label: "Friends")
        }
        .frame(height: Self.height)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    private func item(_ tab: AppTab, systemName: String, label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selection == tab ? .white : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
