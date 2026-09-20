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

                    // One person must never appear in two sections at once: the
                    // lazy list keys rows by ID, and a duplicate makes SwiftUI
                    // keep whichever row it saw first (usually the "Add" one).
                    // Search results are filtered here, synchronously, rather
                    // than trusting the async search to have caught up.
                    let requests = filtered(friends.incoming)
                    if !requests.isEmpty {
                        SectionHeader("Requests · \(friends.incoming.count)")
                        ForEach(requests.keyed("request")) { row in
                            FriendRow(profile: row.profile, state: .incoming, isBusy: busy.contains(row.profile.id),
                                      primary: { accept(row.profile) }, secondary: { remove(row.profile) })
                        }
                    }

                    let mine = filtered(friends.friends)
                    if !mine.isEmpty {
                        SectionHeader("My Friends · \(friends.friends.count)")
                        ForEach(mine.keyed("friend")) { row in
                            FriendRow(profile: row.profile, state: .friend, isBusy: busy.contains(row.profile.id),
                                      primary: { pendingRemoval = row.profile })
                        }
                    }

                    let others = results.filter {
                        let r = friends.relationship(with: $0)
                        return r == .none || r == .outgoing
                    }
                    if !others.isEmpty {
                        SectionHeader(query.isEmpty ? "People on ChatSnap" : "Add Friends")
                        ForEach(others.keyed("other")) { row in
                            let outgoing = friends.relationship(with: row.profile) == .outgoing
                            FriendRow(profile: row.profile, state: outgoing ? .requested : .add, isBusy: busy.contains(row.profile.id),
                                      primary: { outgoing ? remove(row.profile) : request(row.profile) })
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
            // iOS 26 would otherwise drop the field to the bottom, under our tab bar.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name or @username")
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

/// A profile with a section-scoped identity, so the same person can't collide
/// with themselves across sections of one lazy list.
private struct KeyedProfile: Identifiable {
    let id: String
    let profile: Profile
}

private extension Array where Element == Profile {
    func keyed(_ section: String) -> [KeyedProfile] {
        map { KeyedProfile(id: "\(section)-\($0.id.uuidString)", profile: $0) }
    }
}

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

private struct FriendRow: View {
    enum State {
        /// Not connected — "Add".
        case add
        /// I asked them — "Requested", tap to cancel.
        case requested
        /// They asked me — "Accept" / decline.
        case incoming
        /// Friends — remove.
        case friend
    }

    let profile: Profile
    let state: State
    let isBusy: Bool
    let primary: () -> Void
    var secondary: () -> Void = {}

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

            actions
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .add:
            Pill("Add", filled: true, action: primary)
        case .requested:
            Pill("Requested", filled: false, action: primary)
        case .incoming:
            HStack(spacing: 8) {
                Pill("Accept", filled: true, action: primary)
                Round("xmark", action: secondary)
            }
        case .friend:
            Round("minus", action: primary)
        }
    }
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
