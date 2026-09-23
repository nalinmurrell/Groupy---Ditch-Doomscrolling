import Foundation

/// A row in `profiles` — you, or anyone else.
struct Profile: Identifiable, Codable, Hashable, AvatarRepresentable {
    let id: UUID
    var username: String
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
    }
}

enum UsernameRule {
    static let minLength = 3
    static let maxLength = 15

    /// Nil when usable, otherwise why not. Mirrors the database check
    /// constraint so people get told before the round trip.
    static func problem(with raw: String) -> String? {
        let name = raw.lowercased()
        if name.count < minLength { return "At least \(minLength) characters." }
        if name.count > maxLength { return "At most \(maxLength) characters." }
        if !name.allSatisfy({ ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "_" }) {
            return "Letters, numbers and underscores only."
        }
        return nil
    }
}

/// A row in `messages`.
struct Message: Identifiable, Decodable, Hashable {
    enum Kind: String, Codable {
        case text, photo, video
    }

    let id: UUID
    let conversationID: UUID
    let senderID: UUID
    let kind: Kind
    let body: String?
    let photoPath: String?
    let createdAt: Date
    /// Saved in chat: viewable by everyone, any number of times.
    var savedBy: UUID?
    var savedAt: Date?
    /// Recipients who've opened it (from `snap_views`).
    var openedBy: [UUID]
    /// One per person, oldest first (from `message_reactions`).
    var reactions: [Reaction]

    struct Reaction: Hashable, Decodable {
        let userID: UUID
        var emoji: String
        enum CodingKeys: String, CodingKey { case emoji, userID = "user_id" }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, body
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case photoPath = "photo_path"
        case createdAt = "created_at"
        case savedBy = "saved_by"
        case savedAt = "saved_at"
        case snapViews = "snap_views"
        case reactions = "message_reactions"
    }

    private struct View: Decodable {
        let userID: UUID
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        senderID = try c.decode(UUID.self, forKey: .senderID)
        kind = try c.decode(Kind.self, forKey: .kind)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        savedBy = try c.decodeIfPresent(UUID.self, forKey: .savedBy)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt)
        // Absent on realtime payloads and fresh inserts: nobody's opened it.
        openedBy = (try c.decodeIfPresent([View].self, forKey: .snapViews) ?? []).map(\.userID)
        reactions = try c.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
    }

    func reaction(by user: UUID?) -> String? {
        reactions.first { $0.userID == user }?.emoji
    }

    func isFromMe(_ me: UUID?) -> Bool { senderID == me }

    var isSnap: Bool { kind != .text }
    var isSaved: Bool { savedAt != nil }

    /// A snap you can still open: someone else's, unsaved, not yet opened.
    func isUnopenedSnap(for me: UUID?) -> Bool {
        guard isSnap, !isSaved, let me, senderID != me else { return false }
        return !openedBy.contains(me)
    }
}

/// A conversation with its members and, once opened, its messages.
struct Conversation: Identifiable, Hashable {
    let id: UUID
    let isGroup: Bool
    let name: String?
    var members: [Profile]
    var lastMessage: Message?
    /// When I pinned it, or nil. Mine only — everyone has their own pins.
    var pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    /// Group name, or the other person's name in a DM.
    func title(for me: UUID?) -> String {
        if isGroup { return name ?? "Group" }
        return members.first { $0.id != me }?.displayName ?? "Chat"
    }

    /// Who to show as the avatar. For a DM, the other person.
    func counterpart(for me: UUID?) -> Profile? {
        members.first { $0.id != me } ?? members.first
    }

    /// What to draw in the avatar circle: the other person, or the group.
    func avatarSubject(for me: UUID?) -> any AvatarRepresentable {
        if isGroup { return GroupIdentity(displayName: name ?? "Group", username: id.uuidString) }
        return counterpart(for: me) ?? GroupIdentity(displayName: "?", username: id.uuidString)
    }

    func member(_ id: UUID) -> Profile? {
        members.first { $0.id == id }
    }

    /// First name of whoever sent this, for labelling group messages.
    func senderName(of message: Message) -> String {
        member(message.senderID)?.displayName.split(separator: " ").first.map(String.init) ?? "Someone"
    }

    /// The one line under the name in the chat list.
    func statusLine(for me: UUID?) -> String {
        guard let last = lastMessage else { return isGroup ? "\(members.count) members" : "Tap to chat" }
        let mine = last.isFromMe(me)
        let who = isGroup && !mine ? senderName(of: last) : nil
        switch last.kind {
        case .photo, .video:
            let noun = last.kind == .video ? "Video" : "Snap"
            if mine {
                if last.isSaved { return "Saved" }
                return last.openedBy.isEmpty ? "Delivered" : "Opened"
            }
            if !last.isUnopenedSnap(for: me) { return "Opened" }
            return who.map { "New \(noun) from \($0)" } ?? "New \(noun)"
        case .text:
            let body = last.body ?? ""
            if mine { return "You: \(body)" }
            return who.map { "\($0): \(body)" } ?? body
        }
    }
}

/// Lets a group wear an avatar like a person does: initials of its name,
/// colour keyed to its id.
struct GroupIdentity: AvatarRepresentable {
    let displayName: String
    let username: String
}

// MARK: - Wire shapes

/// What PostgREST returns for the conversation list query; flattened into
/// `Conversation` by the store.
struct ConversationRow: Decodable {
    struct Member: Decodable {
        let userID: UUID
        let pinnedAt: Date?
        let profiles: Profile

        enum CodingKeys: String, CodingKey {
            case profiles
            case userID = "user_id"
            case pinnedAt = "pinned_at"
        }
    }

    let id: UUID
    let isGroup: Bool
    let name: String?
    let conversationMembers: [Member]
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case id, name, messages
        case isGroup = "is_group"
        case conversationMembers = "conversation_members"
    }

    func conversation(for me: UUID?) -> Conversation {
        Conversation(
            id: id,
            isGroup: isGroup,
            name: name,
            members: conversationMembers.map(\.profiles),
            lastMessage: messages.first,
            pinnedAt: conversationMembers.first { $0.userID == me }?.pinnedAt
        )
    }
}
