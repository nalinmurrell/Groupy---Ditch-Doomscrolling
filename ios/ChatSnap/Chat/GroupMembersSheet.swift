import SwiftUI

/// Who's in the group. Leaving lives here too, since it's the one place
/// that's unmistakably "about the group" rather than the conversation.
struct GroupMembersSheet: View {
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    /// Called after leaving so the thread behind can pop itself.
    let onLeft: () -> Void

    @State private var isConfirmingLeave = false

    private var members: [Profile] {
        // You first, then everyone else alphabetically.
        conversation.members.sorted {
            if $0.id == session.userID { return true }
            if $1.id == session.userID { return false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 10) {
                        Avatar(subject: conversation.avatarSubject(for: session.userID), size: 72)
                        Text(conversation.name ?? "Group")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("\(conversation.members.count) members")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 22)

                    Text("MEMBERS")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                    ForEach(members) { member in
                        HStack(spacing: 14) {
                            Avatar(subject: member, size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("@\(member.username)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer()
                            if member.id == session.userID {
                                Text("You")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.bottom, 90)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) { isConfirmingLeave = true } label: {
                    Text("Leave Group")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(Color.black)
            }
            .confirmationDialog("Leave \(conversation.name ?? "this group")?", isPresented: $isConfirmingLeave, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    Task {
                        await chats.leaveGroup(conversation.id)
                        dismiss()
                        onLeft()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll stop getting messages from it. Someone can add you back.")
            }
        }
    }
}
