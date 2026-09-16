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
struct Message: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case text, photo
    }

    let id: UUID
    let conversationID: UUID
    let senderID: UUID
    let kind: Kind
    let body: String?
    let photoPath: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, body
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case photoPath = "photo_path"
        case createdAt = "created_at"
    }

    func isFromMe(_ me: UUID?) -> Bool { senderID == me }
}

/// A conversation with its members and, once opened, its messages.
struct Conversation: Identifiable, Hashable {
    let id: UUID
    let isGroup: Bool
    let name: String?
    var members: [Profile]
    var lastMessage: Message?

    /// Group name, or the other person's name in a DM.
    func title(for me: UUID?) -> String {
        if isGroup { return name ?? "Group" }
        return members.first { $0.id != me }?.displayName ?? "Chat"
    }

    /// Who to show as the avatar. For a DM, the other person.
    func counterpart(for me: UUID?) -> Profile? {
        members.first { $0.id != me } ?? members.first
    }

    /// The one line under the name in the chat list.
    func statusLine(for me: UUID?) -> String {
        guard let last = lastMessage else { return "Tap to chat" }
        let mine = last.isFromMe(me)
        switch last.kind {
        case .photo: return mine ? "Sent" : "New Snap"
        case .text:  return mine ? "You: \(last.body ?? "")" : (last.body ?? "")
        }
    }
}

// MARK: - Wire shapes

/// What PostgREST returns for the conversation list query; flattened into
/// `Conversation` by the store.
struct ConversationRow: Decodable {
    struct Member: Decodable {
        let profiles: Profile
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

    var conversation: Conversation {
        Conversation(
            id: id,
            isGroup: isGroup,
            name: name,
            members: conversationMembers.map(\.profiles),
            lastMessage: messages.first
        )
    }
}
