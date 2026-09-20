import SwiftUI

/// Pick friends who aren't in the group yet. Same picker as New Group,
/// minus the name field.
struct AddMembersSheet: View {
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation

    @State private var selected: Set<Profile.ID> = []
    @State private var isAdding = false
    @State private var error: String?

    private var candidates: [Profile] {
        let already = Set(conversation.members.map(\.id))
        return friends.friends.filter { !already.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if candidates.isEmpty {
                        Text(friends.friends.isEmpty
                             ? "Add some friends first — groups are made of them."
                             : "All your friends are already in this group.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(20)
                    } else {
                        ForEach(candidates) { friend in
                            Button { toggle(friend.id) } label: { row(friend) }
                                .buttonStyle(.plain)
                        }
                        .padding(.top, 8)
                    }

                    if let error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .padding(20)
                    }
                }
                .padding(.bottom, 90)
            }
            .background(Color.black)
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(
                    isAdding ? "Adding…" : (selected.count > 1 ? "Add \(selected.count) People" : "Add"),
                    enabled: !selected.isEmpty && !isAdding,
                    action: add
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(Color.black)
            }
        }
    }

    private func row(_ friend: Profile) -> some View {
        HStack(spacing: 14) {
            Avatar(subject: friend, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("@\(friend.username)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected.contains(friend.id) ? .white : .white.opacity(0.25))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func toggle(_ id: Profile.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func add() {
        isAdding = true
        error = nil
        let members = candidates.filter { selected.contains($0.id) }
        Task {
            defer { isAdding = false }
            if await chats.addMembers(members, to: conversation.id) {
                dismiss()
            } else {
                error = "Couldn't add them. Check your connection and try again."
            }
        }
    }
}
