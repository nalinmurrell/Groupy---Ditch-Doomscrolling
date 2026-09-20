import OSLog
import Supabase
import SwiftUI

/// Friend requests and friends, backed by `friendships`. Every write goes
/// through a database function so the rules (one row per pair, mutual intent
/// auto-accepts, accepting opens the DM) live in one place — the server.
@MainActor
final class FriendsStore: ObservableObject {

    enum Relationship {
        case none
        case friend
        /// They asked me.
        case incoming
        /// I asked them.
        case outgoing
    }

    @Published private(set) var friends: [Profile] = []
    @Published private(set) var incoming: [Profile] = []
    @Published private(set) var outgoing: [Profile] = []

    private let client = Backend.client
    private let log = Logger(subsystem: "com.groupy.app", category: "friends")
    private var realtime: Task<Void, Never>?

    /// Fired after a change arrives over realtime; accepting creates a DM,
    /// so the chat list wants to know.
    var onRemoteChange: (() async -> Void)?

    func relationship(with profile: Profile) -> Relationship {
        if friends.contains(where: { $0.id == profile.id }) { return .friend }
        if incoming.contains(where: { $0.id == profile.id }) { return .incoming }
        if outgoing.contains(where: { $0.id == profile.id }) { return .outgoing }
        return .none
    }

    // MARK: - Loading

    private struct Row: Decodable {
        enum Status: String, Decodable { case pending, accepted }
        let status: Status
        let requester: Profile
        let addressee: Profile
    }

    func refresh() async {
        guard let me = client.auth.currentUser?.id else { return }
        do {
            let rows: [Row] = try await client
                .from("friendships")
                .select("""
                    status,
                    requester:profiles!friendships_user_id_fkey ( id, username, display_name ),
                    addressee:profiles!friendships_friend_id_fkey ( id, username, display_name )
                    """)
                .order("created_at", ascending: false)
                .execute()
                .value

            var friends: [Profile] = [], incoming: [Profile] = [], outgoing: [Profile] = []
            for row in rows {
                let other = row.requester.id == me ? row.addressee : row.requester
                switch row.status {
                case .accepted: friends.append(other)
                case .pending:  row.requester.id == me ? outgoing.append(other) : incoming.append(other)
                }
            }
            self.friends = friends
            self.incoming = incoming
            self.outgoing = outgoing
        } catch {
            log.error("refresh failed: \(String(describing: error))")
        }
    }

    /// People matching the query, minus you and your accepted friends. Pending
    /// people stay in so their row can show "Requested" / "Accept".
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

    private struct Params: Encodable { let other_user: UUID }

    func request(_ profile: Profile) async {
        do {
            _ = try await client.rpc("send_friend_request", params: Params(other_user: profile.id)).execute()
        } catch {
            log.error("send_friend_request failed: \(String(describing: error))")
        }
        await refresh()
    }

    func accept(_ profile: Profile) async {
        do {
            _ = try await client.rpc("accept_friend_request", params: Params(other_user: profile.id)).execute()
        } catch {
            log.error("accept_friend_request failed: \(String(describing: error))")
        }
        await refresh()
    }

    /// Decline an incoming request, cancel an outgoing one, or unfriend.
    func remove(_ profile: Profile) async {
        do {
            _ = try await client.rpc("remove_friendship", params: Params(other_user: profile.id)).execute()
        } catch {
            log.error("remove_friendship failed: \(String(describing: error))")
        }
        await refresh()
    }

    // MARK: - Realtime

    func startRealtime() {
        realtime?.cancel()
        realtime = Task { [weak self] in
            let channel = Backend.client.channel("friendships")
            let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "friendships")
            guard (try? await channel.subscribeWithError()) != nil else { return }

            for await _ in changes {
                guard let self else { return }
                await self.refresh()
                await self.onRemoteChange?()
            }
        }
    }

    func stopRealtime() {
        realtime?.cancel()
        realtime = nil
    }
}
