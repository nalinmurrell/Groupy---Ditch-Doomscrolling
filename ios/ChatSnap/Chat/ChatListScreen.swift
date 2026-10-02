import SwiftUI

struct ChatListScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Binding var path: [Conversation.ID]

    @State private var isCreatingGroup = false
    /// The open thread's swipe-to-close drag (negative = left).
    @State private var threadOffset: CGFloat = 0
    @State private var pinError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.conversations.isEmpty {
                        emptyState
                            .padding(.horizontal, 40)
                            .padding(.top, 80)
                    }

                    ForEach(store.sortedConversations) { conversation in
                        Button { open(conversation.id) } label: {
                            ChatRow(conversation: conversation, me: session.userID)
                        }
                        .buttonStyle(.quiet)
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
            // Still names the back button inside a thread.
            .navigationTitle("Chat")
            // Our own header, so the avatar sits exactly where the camera's does.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { TabHeader(title: "Chat") }
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
                .buttonStyle(.quiet)
                .accessibilityLabel("New Group")
                .padding(.trailing, 20)
                .padding(.bottom, AppTabBar.height + 16)
            }
            .sheet(isPresented: $isCreatingGroup) {
                NewGroupSheet { id in path = [id] }
                    .preferredColorScheme(.dark)
            }
        }
        // A thread sits over the list rather than being pushed, so it can
        // come in from, and go back out to, the left — and a swipe can drag
        // it aside to show the list underneath, like Snapchat.
        .overlay {
            if let id = path.last {
                NavigationStack {
                    ConversationScreen(
                        conversationID: id,
                        swipeOffset: $threadOffset,
                        onClose: close
                    )
                }
                .background(Color.black.ignoresSafeArea())
                .offset(x: threadOffset)
                .transition(.move(edge: .leading))
                .id(id)
            }
        }
    }

    private func open(_ id: Conversation.ID) {
        threadOffset = 0
        withAnimation(.easeOut(duration: 0.25)) { path = [id] }
    }

    /// Slides the open thread out to the left, then drops it.
    private func close() {
        let width = UIScreen.main.bounds.width
        withAnimation(.easeOut(duration: 0.2)) { threadOffset = -width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withoutAnimation {
                path = []
                threadOffset = 0
            }
        }
    }

    /// Three different empties: still loading, failed, or genuinely none.
    @ViewBuilder
    private var emptyState: some View {
        if store.loadFailed {
            // The list is .refreshable, so a pull-down is the retry.
            VStack(spacing: 6) {
                Text("Couldn't load your chats.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Pull down to try again.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.45))
            }
        } else if !store.hasLoaded {
            ProgressView().tint(.white.opacity(0.5))
        } else {
            Text("Add a friend, or start a group, and it shows up here.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
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
    /// Snapchat's day markers in a thread: TODAY, YESTERDAY, SUNDAY, SEP 20.
    var threadDayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "TODAY" }
        if cal.isDateInYesterday(self) { return "YESTERDAY" }
        if Date().timeIntervalSince(self) < 60 * 60 * 24 * 7 {
            return formatted(.dateTime.weekday(.wide)).uppercased()
        }
        return formatted(.dateTime.month(.abbreviated).day()).uppercased()
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
