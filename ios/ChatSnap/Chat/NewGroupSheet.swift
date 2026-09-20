import SwiftUI

/// Name it, pick friends, go. Only accepted friends are offered — the server
/// enforces that too, so this is a convenience, not the rule.
struct NewGroupSheet: View {
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(\.dismiss) private var dismiss

    /// Called with the new conversation so the caller can open it.
    let onCreated: (Conversation.ID) -> Void

    @State private var name = ""
    @State private var selected: Set<Profile.ID> = []
    @State private var isCreating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $name, prompt: Text("Group name").foregroundColor(.white.opacity(0.3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)

                    Divider().opacity(0.25)

                    if friends.friends.isEmpty {
                        Text("Add some friends first — groups are made of them.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(20)
                    } else {
                        Text("MEMBERS")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 6)

                        ForEach(friends.friends) { friend in
                            Button { toggle(friend.id) } label: { row(friend) }
                                .buttonStyle(.plain)
                        }
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
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(isCreating ? "Creating…" : "Create Group", enabled: canCreate && !isCreating, action: create)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .background(Color.black)
            }
            .onAppear { nameFocused = true }
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

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty
    }

    private func toggle(_ id: Profile.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func create() {
        isCreating = true
        error = nil
        let members = friends.friends.filter { selected.contains($0.id) }
        Task {
            defer { isCreating = false }
            if let id = await chats.createGroup(named: name, with: members) {
                dismiss()
                onCreated(id)
            } else {
                error = "Couldn't create the group. Check your connection and try again."
            }
        }
    }
}
