import Supabase
import SwiftUI
import UIKit

/// Conversations and messages, backed by Supabase. Sends go straight to the
/// database; new messages from anyone — including you, on another device —
/// arrive over a realtime subscription.
@MainActor
final class ChatStore: ObservableObject {

    @Published private(set) var conversations: [Conversation] = []
    /// Full history, loaded per conversation on first open.
    @Published private(set) var messages: [Conversation.ID: [Message]] = [:]

    private let client = Backend.client
    private let imageCache = NSCache<NSString, UIImage>()
    private var realtime: Task<Void, Never>?
    private var deletions: Task<Void, Never>?
    private var membership: Task<Void, Never>?

    /// Pinned first (in the order they were pinned), then most recent activity.
    var sortedConversations: [Conversation] {
        conversations.sorted {
            switch ($0.pinnedAt, $1.pinnedAt) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                return ($0.lastMessage?.createdAt ?? .distantPast) > ($1.lastMessage?.createdAt ?? .distantPast)
            }
        }
    }

    var pinnedCount: Int { conversations.filter(\.isPinned).count }
    nonisolated static let maxPins = 3

    func conversation(_ id: Conversation.ID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    // MARK: - Loading

    /// Every conversation I'm in, with members and the latest message.
    func refresh() async {
        do {
            let rows: [ConversationRow] = try await client
                .from("conversations")
                .select("""
                    id, is_group, name,
                    conversation_members ( user_id, pinned_at, profiles ( id, username, display_name ) ),
                    messages ( id, conversation_id, sender_id, kind, body, photo_path, created_at )
                    """)
                .order("created_at", ascending: false, referencedTable: "messages")
                .limit(1, referencedTable: "messages")
                .execute()
                .value
            let me = client.auth.currentUser?.id
            conversations = rows.map { $0.conversation(for: me) }

            // Realtime sleeps while the app is in the background, so a loaded
            // thread can be missing messages the list already knows about.
            // Re-pull just those threads.
            for conversation in conversations {
                guard let last = conversation.lastMessage,
                      let thread = messages[conversation.id],
                      !thread.contains(where: { $0.id == last.id })
                else { continue }
                await loadMessages(for: conversation.id)
            }
        } catch {
            // Keep whatever we had; the list just goes stale until next pull.
        }
    }

    func loadMessages(for id: Conversation.ID) async {
        do {
            let rows: [Message] = try await client
                .from("messages")
                .select()
                .eq("conversation_id", value: id.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            messages[id] = rows
        } catch {
            // Leave the thread as-is; the realtime feed still appends.
        }
    }

    // MARK: - Sending

    /// One upload per conversation: the storage path is keyed by conversation
    /// so membership gates the file, which means the same snap sent to three
    /// people is three objects. Fine at this scale.
    func send(_ snap: Snap, to conversationIDs: [Conversation.ID]) async {
        guard let data = snap.image.jpegData(compressionQuality: 0.85) else { return }

        for id in conversationIDs {
            let path = "\(id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            do {
                try await client.storage
                    .from("snaps")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
                imageCache.setObject(snap.image, forKey: path as NSString)

                let sent: Message = try await client
                    .from("messages")
                    .insert(NewMessage(conversationID: id, kind: .photo, body: nil, photoPath: path))
                    .select()
                    .single()
                    .execute()
                    .value
                receive(sent)
            } catch {
                continue
            }
        }
    }

    func send(text: String, to conversationID: Conversation.ID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Show it from the server's own row, not a guess: realtime echoes it
        // back too, but the echo can't be relied on after a stint in the
        // background. `receive` dedupes.
        guard let sent: Message = try? await client
            .from("messages")
            .insert(NewMessage(conversationID: conversationID, kind: .text, body: trimmed, photoPath: nil))
            .select()
            .single()
            .execute()
            .value
        else { return }
        receive(sent)
    }

    /// Insert payload. `sender_id` comes from the signed-in user; RLS rejects
    /// anything else anyway.
    private struct NewMessage: Encodable {
        let conversationID: UUID
        let senderID: UUID?
        let kind: Message.Kind
        let body: String?
        let photoPath: String?

        init(conversationID: UUID, kind: Message.Kind, body: String?, photoPath: String?) {
            self.conversationID = conversationID
            self.senderID = Backend.client.auth.currentUser?.id
            self.kind = kind
            self.body = body
            self.photoPath = photoPath
        }

        enum CodingKeys: String, CodingKey {
            case kind, body
            case conversationID = "conversation_id"
            case senderID = "sender_id"
            case photoPath = "photo_path"
        }
    }

    // MARK: - DMs

    /// The DM with this person, created server-side if it doesn't exist.
    @discardableResult
    func openDM(with profile: Profile) async -> Conversation.ID? {
        struct Params: Encodable { let other_user: UUID }
        guard let id: UUID = try? await client
            .rpc("get_or_create_dm", params: Params(other_user: profile.id))
            .execute()
            .value else { return nil }
        if conversation(id) == nil { await refresh() }
        return id
    }

    // MARK: - Groups

    /// Server validates everything (name length, members are friends) and
    /// creates the room + memberships in one transaction.
    func createGroup(named name: String, with members: [Profile]) async -> Conversation.ID? {
        struct Params: Encodable {
            let group_name: String
            let member_ids: [UUID]
        }
        do {
            let id: UUID = try await client
                .rpc("create_group", params: Params(group_name: name, member_ids: members.map(\.id)))
                .execute()
                .value
            await refresh()
            return id
        } catch {
            return nil
        }
    }

    /// Add friends to a group. Returns false if the server said no.
    func addMembers(_ members: [Profile], to id: Conversation.ID) async -> Bool {
        struct Params: Encodable {
            let cid: UUID
            let member_ids: [UUID]
        }
        do {
            try await client
                .rpc("add_group_members", params: Params(cid: id, member_ids: members.map(\.id)))
                .execute()
            await refresh()
            return true
        } catch {
            return false
        }
    }

    func leaveGroup(_ id: Conversation.ID) async {
        struct Params: Encodable { let cid: UUID }
        _ = try? await client.rpc("leave_group", params: Params(cid: id)).execute()
        messages[id] = nil
        conversations.removeAll { $0.id == id }
        await refresh()
    }

    // MARK: - Pins

    enum PinError: LocalizedError {
        case limit
        var errorDescription: String? { "You can pin up to \(ChatStore.maxPins) chats." }
    }

    func setPinned(_ id: Conversation.ID, _ pinned: Bool) async throws {
        if pinned && pinnedCount >= Self.maxPins { throw PinError.limit }
        struct Params: Encodable {
            let cid: UUID
            let pinned: Bool
        }
        try await client.rpc("set_pinned", params: Params(cid: id, pinned: pinned)).execute()
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].pinnedAt = pinned ? Date() : nil
        }
    }

    // MARK: - Photos

    func image(for message: Message) async -> UIImage? {
        guard let path = message.photoPath else { return nil }
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let data = try? await client.storage.from("snaps").download(path: path),
              let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    // MARK: - Deleting

    /// Delete one of your own messages for everyone. The photo file goes
    /// first (its storage policy needs the message row to still exist),
    /// then the row. Returns false if the server refused.
    func delete(_ message: Message) async -> Bool {
        do {
            if let path = message.photoPath {
                _ = try await client.storage.from("snaps").remove(paths: [path])
                imageCache.removeObject(forKey: path as NSString)
            }
            try await client
                .from("messages")
                .delete()
                .eq("id", value: message.id.uuidString)
                .execute()
            remove(messageID: message.id)
            return true
        } catch {
            return false
        }
    }

    /// Drop a message from wherever it's held; if it was a chat's preview,
    /// re-pull the list so the preview falls back to the one before it.
    private func remove(messageID: Message.ID) {
        for (cid, thread) in messages where thread.contains(where: { $0.id == messageID }) {
            messages[cid] = thread.filter { $0.id != messageID }
        }
        if conversations.contains(where: { $0.lastMessage?.id == messageID }) {
            Task { await refresh() }
        }
    }

    // MARK: - Realtime

    func startRealtime() {
        stopRealtime()
        realtime = Task { [weak self] in
            let channel = Backend.client.channel("messages")
            let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
            let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "messages")
            guard (try? await channel.subscribeWithError()) != nil else { return }

            // A delete only carries the old row's primary key.
            deletions = Task { [weak self] in
                struct Key: Decodable { let id: UUID }
                for await delete in deletes {
                    guard let self,
                          let key = try? delete.decodeOldRecord(as: Key.self, decoder: Backend.decoder)
                    else { continue }
                    self.remove(messageID: key.id)
                }
            }

            for await insert in inserts {
                guard let self,
                      let message = try? insert.decodeRecord(as: Message.self, decoder: Backend.decoder)
                else { continue }
                self.receive(message)
            }
        }
        // Being added to (or removed from) a group changes the list itself.
        membership = Task { [weak self] in
            let channel = Backend.client.channel("membership")
            let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "conversation_members")
            guard (try? await channel.subscribeWithError()) != nil else { return }

            for await _ in changes {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func stopRealtime() {
        realtime?.cancel()
        realtime = nil
        deletions?.cancel()
        deletions = nil
        membership?.cancel()
        membership = nil
    }

    private func receive(_ message: Message) {
        // Dedupe: our own sends echo back through the subscription too.
        if var thread = messages[message.conversationID] {
            if !thread.contains(where: { $0.id == message.id }) {
                thread.append(message)
                messages[message.conversationID] = thread
            }
        }

        if let index = conversations.firstIndex(where: { $0.id == message.conversationID }) {
            if (conversations[index].lastMessage?.createdAt ?? .distantPast) < message.createdAt {
                conversations[index].lastMessage = message
            }
        } else {
            // Someone opened a new DM with us — pull the list to pick it up.
            Task { await refresh() }
        }
    }
}
