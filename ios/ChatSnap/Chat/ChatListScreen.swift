import SwiftUI

struct ChatListScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Binding var path: [Conversation.ID]

    @State private var isCreatingGroup = false

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
                        Divider().padding(.leading, 84).opacity(0.25)
                    }
                }
                // Clear the floating tab bar.
                .padding(.bottom, AppTabBar.height + 16)
            }
            .refreshable { await store.refresh() }
            .background(Color.black)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isCreatingGroup = true } label: {
                        Image(systemName: "person.2.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("New Group")
                }
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

            if let sentAt = conversation.lastMessage?.createdAt {
                Text(sentAt.chatTimestamp)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

extension Date {
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
