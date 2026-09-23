import SwiftUI

struct ChatListScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Binding var path: [Conversation.ID]

    @State private var isCreatingGroup = false
    @State private var pinError: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.conversations.isEmpty {
                        Text("Add a friend, or start a group, and it shows up here.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .padding(.top, 80)
                    }

                    ForEach(store.sortedConversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ChatRow(conversation: conversation, me: session.userID)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                togglePin(conversation)
                            } label: {
                                Label(conversation.isPinned ? "Unpin" : "Pin",
                                      systemImage: conversation.isPinned ? "pin.slash" : "pin")
                            }
                        }
                        Divider().padding(.leading, 84).opacity(0.25)
                    }
                }
                // Clear the floating tab bar.
                .padding(.bottom, AppTabBar.height + 16)
            }
            .refreshable { await store.refresh() }
            .background(Color.black)
            .alert("Can't pin", isPresented: .init(get: { pinError != nil }, set: { if !$0 { pinError = nil } })) {
                Button("OK", role: .cancel) { pinError = nil }
            } message: {
                Text(pinError ?? "")
            }
            .navigationTitle("Chats")
            // Title centred in the top bar, beside your avatar — Snapchat's header.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ProfileButton(size: 34) }
                ToolbarItem(placement: .principal) {
                    Text("Chats")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            // Floating, bottom-right, clear of the tab bar — thumb territory.
            .overlay(alignment: .bottomTrailing) {
                Button { isCreatingGroup = true } label: {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Group")
                .padding(.trailing, 20)
                .padding(.bottom, AppTabBar.height + 16)
            }
            .sheet(isPresented: $isCreatingGroup) {
                NewGroupSheet { id in path = [id] }
                    .preferredColorScheme(.dark)
            }
            .navigationDestination(for: Conversation.ID.self) { id in
                ConversationScreen(conversationID: id)
            }
        }
    }

    private func togglePin(_ conversation: Conversation) {
        Task {
            do {
                try await store.setPinned(conversation.id, !conversation.isPinned)
            } catch {
                pinError = error.localizedDescription
            }
        }
    }
}

private struct ChatRow: View {
    let conversation: Conversation
    let me: UUID?

    var body: some View {
        HStack(spacing: 14) {
            Avatar(subject: conversation.avatarSubject(for: me))

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title(for: me))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(conversation.statusLine(for: me))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let sentAt = conversation.lastMessage?.createdAt {
                    Text(sentAt.chatTimestamp)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(45))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

extension Date {
    /// Inside a thread: "3:15 PM", "Yesterday 3:15 PM", "Mon 3:15 PM", "Sep 12, 3:15 PM".
    var threadTimestamp: String {
        let cal = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(self) { return time }
        if cal.isDateInYesterday(self) { return "Yesterday \(time)" }
        if Date().timeIntervalSince(self) < 60 * 60 * 24 * 7 {
            return "\(formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// In the chat list: just enough to place it.
    var chatTimestamp: String {
        let now = Date()
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if now.timeIntervalSince(self) < 60 * 60 * 24 * 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
