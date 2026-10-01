import OSLog
import Supabase
import SwiftUI

/// Who has a chat open right now, via Realtime presence on a private
/// channel "chat:<conversation id>" (RLS lets only members join it). Each
/// open thread tracks itself there, keyed by user id.
@MainActor
final class ChatPresence: ObservableObject {
    @Published private(set) var here: Set<UUID> = []

    private var channel: RealtimeChannelV2?
    private var listener: Task<Void, Never>?
    private let log = Logger(subsystem: "com.groupy.app", category: "presence")

    func join(_ conversationID: UUID, as me: UUID) async {
        await leave()
        here = [me]
        let channel = Backend.client.channel("chat:\(conversationID.uuidString.lowercased())") {
            $0.isPrivate = true
            $0.presence.key = me.uuidString.lowercased()
        }
        self.channel = channel
        let changes = channel.presenceChange()
        listener = Task { [weak self] in
            for await change in changes {
                self?.apply(change, me: me)
            }
        }
        do {
            try await channel.subscribeWithError()
            struct State: Codable { let user_id: UUID }
            try await channel.track(State(user_id: me))
        } catch {
            log.error("presence join failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func leave() async {
        listener?.cancel()
        listener = nil
        if let channel {
            self.channel = nil
            await Backend.client.removeChannel(channel)
        }
        here = []
    }

    private func apply(_ change: any PresenceAction, me: UUID) {
        var next = here
        for key in change.leaves.keys {
            if let id = UUID(uuidString: key), id != me { next.remove(id) }
        }
        for key in change.joins.keys {
            if let id = UUID(uuidString: key) { next.insert(id) }
        }
        here = next
    }
}

/// Snapchat's row of member pills above the composer: everyone in the
/// group, scrollable, and whoever has the chat open lit up in their colour.
struct ChatMembersBar: View {
    let members: [Profile]
    let here: Set<UUID>
    let color: (UUID) -> Color

    /// Who's here first, then everyone else; by name within each.
    private var ordered: [Profile] {
        members.sorted {
            let a = here.contains($0.id), b = here.contains($1.id)
            if a != b { return a }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ordered) { member in
                    let active = here.contains(member.id)
                    Text(firstName(member))
                        .textCase(.uppercase)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.6)
                        .lineLimit(1)
                        .foregroundStyle(active ? color(member.id) : .white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(minWidth: 64)
                        .background(
                            Capsule().strokeBorder(
                                active ? color(member.id) : .white.opacity(0.3),
                                lineWidth: 1.5
                            )
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .animation(.easeInOut(duration: 0.2), value: here)
        }
    }

    private func firstName(_ member: Profile) -> String {
        member.displayName.split(separator: " ").first.map(String.init) ?? member.username
    }
}
