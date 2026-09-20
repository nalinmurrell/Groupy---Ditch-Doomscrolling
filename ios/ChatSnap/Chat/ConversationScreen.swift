import SwiftUI
import PhotosUI

struct ConversationScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var camera: CameraController
    let conversationID: Conversation.ID

    @State private var draft = ""
    @State private var viewing: Message?
    @State private var isShowingMembers = false
    @State private var isShootingSnap = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isSendingPhoto = false
    @FocusState private var isComposing: Bool
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
        .fullScreenCover(isPresented: $isShootingSnap) {
            ThreadCameraScreen(conversationID: conversationID)
                .environmentObject(camera)
                .environmentObject(store)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                        let mine = message.isFromMe(session.userID)
                        let previous = index > 0 ? thread[index - 1] : nil
                        // A timestamp opens the thread and marks any lull of
                        // twenty minutes or more — the iMessage rhythm, not a
                        // time on every bubble.
                        if previous.map({ message.createdAt.timeIntervalSince($0.createdAt) > 20 * 60 }) ?? true {
                            Text(message.createdAt.threadTimestamp)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(maxWidth: .infinity)
                                .padding(.top, index == 0 ? 0 : 10)
                                .padding(.bottom, 2)
                        }
                        // In a group, label the first message of each run from
                        // someone else — not every bubble, that's noise.
                        let startsRun = previous?.senderID != message.senderID
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
            // Shoot a snap straight into this thread.
            Button { isShootingSnap = true } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)

            // Single line so Return means send. (A multiline field turns
            // Return into a newline and never submits.)
            TextField("Send a message", text: $draft)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .focused($isComposing)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1), in: Capsule())
                .foregroundStyle(.white)

            // Camera roll. The picker runs out of process, so no photo
            // library permission is needed — the user only hands over the
            // one image they choose.
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Group {
                    if isSendingPhoto {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSendingPhoto)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await sendPicked(item) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(Color.black)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // Return would otherwise drop the keyboard; keep the conversation going.
        isComposing = true
        Task { await store.send(text: text, to: conversationID) }
    }

    /// A library photo goes straight into this thread — no review step, you
    /// already know what it looks like. Downscaled so a 48 MP shot doesn't
    /// become a 20 MB upload.
    private func sendPicked(_ item: PhotosPickerItem) async {
        isSendingPhoto = true
        defer { isSendingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)?.downscaled(longestEdge: 2048)
        else { return }
        await store.send(Snap(image: image), to: [conversationID])
    }
}

private extension UIImage {
    func downscaled(longestEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return self }
        let scale = longestEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
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
