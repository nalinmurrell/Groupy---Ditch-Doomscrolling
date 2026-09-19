import SwiftUI

struct FriendsScreen: View {
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var session: SessionStore

    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var pendingRemoval: Profile?
    @State private var busy: Set<Profile.ID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    profileCard

                    let requests = filtered(friends.incoming)
                    if !requests.isEmpty {
                        SectionHeader("Requests · \(friends.incoming.count)")
                        ForEach(requests) { profile in
                            FriendRow(profile: profile, isBusy: busy.contains(profile.id)) {
                                RowActions.accept { accept(profile) } decline: { remove(profile) }
                            }
                        }
                    }

                    let mine = filtered(friends.friends)
                    if !mine.isEmpty {
                        SectionHeader("My Friends · \(friends.friends.count)")
                        ForEach(mine) { profile in
                            FriendRow(profile: profile, isBusy: busy.contains(profile.id)) {
                                RowActions.remove { pendingRemoval = profile }
                            }
                        }
                    }

                    // Search results carry their own relationship state, so a
                    // pending request reads "Requested" rather than "Add".
                    let others = results.filter { friends.relationship(with: $0) != .incoming }
                    if !others.isEmpty {
                        SectionHeader(query.isEmpty ? "People on ChatSnap" : "Add Friends")
                        ForEach(others) { profile in
                            FriendRow(profile: profile, isBusy: busy.contains(profile.id)) {
                                switch friends.relationship(with: profile) {
                                case .outgoing:
                                    RowActions.requested { remove(profile) }
                                default:
                                    RowActions.add { request(profile) }
                                }
                            }
                        }
                    }

                    if requests.isEmpty && mine.isEmpty && others.isEmpty {
                        Text(query.isEmpty ? "Nobody else here yet." : "Nobody matches “\(query)”.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, AppTabBar.height + 16)
            }
            .background(Color.black)
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Search by name or @username")
            // Re-query on typing (debounced by the task cancelling itself) and
            // whenever the friend list changes, so accepted people drop out.
            .task(id: "\(query)|\(friends.friends.count)") {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = await friends.search(query, excluding: session.userID)
            }
            .refreshable { await friends.refresh() }
            .confirmationDialog(
                "Remove \(pendingRemoval?.displayName ?? "")?",
                isPresented: .init(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Friend", role: .destructive) {
                    if let profile = pendingRemoval { remove(profile) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Your chat with them stays; they just leave your friend list.")
            }
        }
    }

    private func filtered(_ people: [Profile]) -> [Profile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return people }
        return people.filter {
            $0.username.contains(trimmed) || $0.displayName.lowercased().contains(trimmed)
        }
    }

    private var profileCard: some View {
        Group {
            if let me = session.me {
                HStack(spacing: 14) {
                    Avatar(subject: me, size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(me.displayName)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                        Text("@\(me.username)")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button {
                        Task { await session.signOut() }
                    } label: {
                        Text("Sign out")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private func request(_ profile: Profile) { run(profile) { await friends.request(profile) } }
    private func accept(_ profile: Profile)  { run(profile) { await friends.accept(profile) } }
    private func remove(_ profile: Profile)  { run(profile) { await friends.remove(profile) } }

    private func run(_ profile: Profile, _ work: @escaping () async -> Void) {
        busy.insert(profile.id)
        Task {
            await work()
            busy.remove(profile.id)
        }
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }
}

private struct FriendRow<Actions: View>: View {
    let profile: Profile
    let isBusy: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            Avatar(subject: profile, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("@\(profile.username)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            actions()
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}

/// The right-hand side of a friend row, one per relationship state.
private enum RowActions {
    static func add(_ action: @escaping () -> Void) -> some View {
        Pill("Add", filled: true, action: action)
    }

    static func requested(_ cancel: @escaping () -> Void) -> some View {
        Pill("Requested", filled: false, action: cancel)
    }

    static func accept(_ accept: @escaping () -> Void, decline: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Pill("Accept", filled: true, action: accept)
            Round("xmark", action: decline)
        }
    }

    static func remove(_ action: @escaping () -> Void) -> some View {
        Round("minus", action: action)
    }

    private struct Pill: View {
        let title: String
        let filled: Bool
        let action: () -> Void

        init(_ title: String, filled: Bool, action: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(filled ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(filled ? Color.white : Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private struct Round: View {
        let systemName: String
        let action: () -> Void

        init(_ systemName: String, action: @escaping () -> Void) {
            self.systemName = systemName
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}
