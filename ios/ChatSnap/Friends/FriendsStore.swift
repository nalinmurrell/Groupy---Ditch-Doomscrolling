import Supabase
import SwiftUI

/// Your friend list, backed by `friendships` + `profiles`.
@MainActor
final class FriendsStore: ObservableObject {

    @Published private(set) var friends: [Profile] = []

    private let client = Backend.client

    func isFriend(_ profile: Profile) -> Bool {
        friends.contains { $0.id == profile.id }
    }

    // MARK: - Loading

    func refresh() async {
        struct Row: Decodable {
            let profiles: Profile
        }
        do {
            let rows: [Row] = try await client
                .from("friendships")
                .select("profiles!friendships_friend_id_fkey ( id, username, display_name )")
                .order("created_at", ascending: false)
                .execute()
                .value
            friends = rows.map(\.profiles)
        } catch {
            // Keep the last good list.
        }
    }

    /// People matching the query, minus you and anyone already added. An
    /// empty query returns the newest sign-ups so there's something to
    /// browse before there's a real discovery feature.
    func search(_ query: String, excluding me: UUID?) async -> [Profile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let excluded = Set(friends.map(\.id) + [me].compactMap { $0 })

        var request = client.from("profiles").select("id, username, display_name")
        if !trimmed.isEmpty {
            request = request.or("username.ilike.%\(trimmed)%,display_name.ilike.%\(trimmed)%")
        }
        guard let rows: [Profile] = try? await request
            .order("created_at", ascending: false)
            .limit(25)
            .execute()
            .value else { return [] }

        return rows.filter { !excluded.contains($0.id) }
    }

    // MARK: - Mutations

    func add(_ profile: Profile) async {
        struct Row: Encodable {
            let user_id: UUID
            let friend_id: UUID
        }
        guard let me = client.auth.currentUser?.id else { return }
        do {
            try await client
                .from("friendships")
                .insert(Row(user_id: me, friend_id: profile.id))
                .execute()
            friends.insert(profile, at: 0)
        } catch {
            // Likely already friends; leave the list alone.
        }
    }

    func remove(_ profile: Profile) async {
        guard let me = client.auth.currentUser?.id else { return }
        do {
            try await client
                .from("friendships")
                .delete()
                .eq("user_id", value: me.uuidString)
                .eq("friend_id", value: profile.id.uuidString)
                .execute()
            friends.removeAll { $0.id == profile.id }
        } catch {
            // Leave it; they'll see it's still there.
        }
    }
}
