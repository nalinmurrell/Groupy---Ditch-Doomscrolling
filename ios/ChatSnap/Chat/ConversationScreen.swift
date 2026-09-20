import SwiftUI

struct ConversationScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    let conversationID: Conversation.ID

    @State private var draft = ""
    @State private var viewing: Message?
    @State private var isShowingMembers = false
    @Environment(\.dismiss) private var dismiss

    private var conversation: Conversation? { store.conversation(conversationID) }
    private var thread: [Message] { store.messages[conversationID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            messages
            composer
        }
        .background(Color.black)
        .navigationTitle(conversation?.title(for: session.userID) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In a group the title is a button: tap for members.
            if let conversation, conversation.isGroup {
                ToolbarItem(placement: .principal) {
                    Button { isShowingMembers = true } label: {
                        HStack(spacing: 4) {
                            Text(conversation.title(for: session.userID))
                                .font(.system(size: 17, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $isShowingMembers) {
            if let conversation {
                GroupMembersSheet(conversation: conversation) { dismiss() }
                    .presentationDetents([.medium, .large])
                    .preferredColorScheme(.dark)
            }
        }
        .task { await store.loadMessages(for: conversationID) }
        .fullScreenCover(item: $viewing) { message in
            PhotoViewer(message: message)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                        let mine = message.isFromMe(session.userID)
                        // In a group, label the first message of each run from
                        // someone else — not every bubble, that's noise.
                        let startsRun = index == 0 || thread[index - 1].senderID != message.senderID
                        MessageRow(
                            message: message,
                            isFromMe: mine,
                            senderName: (conversation?.isGroup == true && !mine && startsRun) ? conversation?.senderName(of: message) : nil
                        ) {
                            viewing = message
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: thread.count) { _, _ in
                guard let last = thread.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            // The keyboard shrinks the scroll view from the bottom. Reacting to
            // the size itself (not the keyboard notification, which fires before
            // layout) keeps the latest message pinned above the composer.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                guard let last = thread.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Send a message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1), in: Capsule())
                .foregroundStyle(.white)

            Button {
                let text = draft
                draft = ""
                Task { await store.send(text: text, to: conversationID) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? .black : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.white : Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(Color.black)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MessageRow: View {
    let message: Message
    let isFromMe: Bool
    var senderName: String? = nil
    let onOpenPhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let senderName {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 6)
            }
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if isFromMe { Spacer(minLength: 60) }

            switch message.kind {
            case .text:
                Text(message.body ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(isFromMe ? .black : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isFromMe ? Color.white : Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

            case .photo:
                Button(action: onOpenPhoto) {
                    SnapImage(message: message)
                        .frame(width: 160, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
    }
}

/// Loads a photo message's image from storage, via the store's cache.
struct SnapImage: View {
    @EnvironmentObject private var store: ChatStore
    let message: Message
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.white.opacity(0.08)
                    .overlay { ProgressView().tint(.white.opacity(0.5)) }
            }
        }
        .task(id: message.id) { image = await store.image(for: message) }
    }
}

private struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SnapImage(message: message, contentMode: .fit)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }
        }
        .statusBarHidden()
    }
}
