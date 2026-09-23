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
    @State private var deleting: Message?
    /// Long-pressed message whose action sheet is up.
    @State private var actionTarget: Message?
    @State private var deleteFailed = false
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
        // Pushes for the thread on screen stay quiet.
        .onAppear { PushManager.shared.activeConversation = conversationID }
        .onDisappear {
            if PushManager.shared.activeConversation == conversationID {
                PushManager.shared.activeConversation = nil
            }
        }
        .fullScreenCover(item: $viewing) { message in
            PhotoViewer(message: message, canDelete: message.isFromMe(session.userID)) {
                viewing = nil
                deleting = message
            }
            // The thread shows through as the snap is swiped away.
            .presentationBackground(.clear)
        }
        .sheet(item: $actionTarget) { message in
            MessageActionsSheet(actions: actions(for: message))
        }
        .confirmationDialog(
            "Delete this \(deleting?.kind == .text ? "message" : deleting?.kind == .video ? "video" : "photo")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete for Everyone", role: .destructive) {
                guard let message = deleting else { return }
                deleting = nil
                Task { deleteFailed = !(await store.delete(message)) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It disappears from the chat for everyone in it.")
        }
        .alert("Couldn't delete", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .fullScreenCover(isPresented: $isShootingSnap) {
            ThreadCameraScreen(conversationID: conversationID) {
                withoutAnimation { isShootingSnap = false }
            }
            .environmentObject(camera)
            .environmentObject(store)
            // Keep the thread visible under the camera so a swipe-down
            // reveals it rather than a black void.
            .presentationBackground(.clear)
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
                            me: session.userID,
                            isGroup: conversation?.isGroup == true,
                            senderName: (conversation?.isGroup == true && !mine && startsRun) ? conversation?.senderName(of: message) : nil
                        ) {
                            guard actionTarget == nil else { return }
                            viewing = message
                        }
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.white.opacity(actionTarget?.id == message.id ? 0.1 : 0))
                        )
                        .padding(-4)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                actionTarget = message
                            }
                        )
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
            // Shoot a snap straight into this thread. The cover's slide-up
            // is a fixed system animation, so skip it; the camera fades in.
            Button {
                // Claim the preview layer before the cover builds its view.
                camera.captureTarget = conversationID
                withoutAnimation { isShootingSnap = true }
            } label: {
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

/// Runs a state change with SwiftUI's implicit animations off.
func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
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

extension ConversationScreen {
    /// What a long-press offers, Snapchat order: keep it, answer it, copy it,
    /// then the destructive one last.
    fileprivate func actions(for message: Message) -> [MessageAction] {
        let me = session.userID
        let mine = message.isFromMe(me)
        var list: [MessageAction] = []

        if message.isSnap {
            if message.isSaved {
                // Only whoever saved it can take that back.
                if message.savedBy == me {
                    list.append(.init(title: "Unsave", icon: "square.and.arrow.down.fill") {
                        Task { await store.setSaved(message, false) }
                    })
                }
            } else if mine || message.isUnopenedSnap(for: me) {
                list.append(.init(title: "Save in Chat", icon: "square.and.arrow.down") {
                    Task { await store.setSaved(message, true) }
                })
            }
        }

        list.append(.init(title: "Snap Reply", icon: "camera") {
            afterSheet {
                camera.captureTarget = conversationID
                withoutAnimation { isShootingSnap = true }
            }
        })

        if message.kind == .text, let body = message.body {
            list.append(.init(title: "Copy", icon: "doc.on.doc") {
                UIPasteboard.general.string = body
            })
        }

        // Only your own. Others' messages aren't yours to remove.
        if mine {
            list.append(.init(title: "Delete", icon: "trash", isDestructive: true) {
                afterSheet { deleting = message }
            })
        }
        return list
    }

    /// Presenting straight from a dismissing sheet gets dropped; wait it out.
    private func afterSheet(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

fileprivate struct MessageAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var isDestructive = false
    let run: () -> Void
}

/// Snapchat's long-press sheet: big rows, icon then label, hairlines between.
fileprivate struct MessageActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let actions: [MessageAction]

    private let rowHeight: CGFloat = 66

    var body: some View {
        VStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    dismiss()
                    action.run()
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: action.icon)
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 30)
                        Text(action.title)
                            .font(.system(size: 19, weight: .regular))
                        Spacer()
                    }
                    .foregroundStyle(action.isDestructive ? Color(red: 1, green: 0.27, blue: 0.35) : .white)
                    .padding(.horizontal, 24)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MessageActionRowStyle())

                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 0.5)
            }
        }
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(CGFloat(actions.count) * (rowHeight + 0.5) + 28 + 34)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .presentationBackground(Color(white: 0.09))
        .preferredColorScheme(.dark)
    }
}

/// Rows darken while pressed, no system highlight.
private struct MessageActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
    }
}

private struct MessageRow: View {
    let message: Message
    let me: UUID?
    let isGroup: Bool
    var senderName: String? = nil
    let onOpenPhoto: () -> Void

    private var isFromMe: Bool { message.isFromMe(me) }

    var body: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 3) {
            if let senderName {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            bubble
            if message.isSnap && message.isSaved {
                Text("Saved")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6)
            }
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

            case .photo, .video:
                if message.isSaved {
                    savedSnap
                } else {
                    SnapStatus(message: message, me: me, isGroup: isGroup, onOpen: onOpenPhoto)
                }
            }

            if !isFromMe { Spacer(minLength: 60) }
        }
    }

    /// Saved in chat: the snap itself, openable any time.
    private var savedSnap: some View {
        Button(action: onOpenPhoto) {
            SnapImage(message: message)
                .frame(width: 160, height: 240)
                .overlay {
                    if message.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// An unsaved snap: never a preview, just where it stands. Red for photos,
/// purple for videos; filled until you've opened it, like Snapchat.
private struct SnapStatus: View {
    let message: Message
    let me: UUID?
    let isGroup: Bool
    let onOpen: () -> Void

    private var tint: Color { message.kind == .video ? Color(red: 0.62, green: 0.35, blue: 0.95) : Color(red: 0.95, green: 0.25, blue: 0.3) }
    private var canOpen: Bool { message.isUnopenedSnap(for: me) }

    private var label: String {
        if message.isFromMe(me) {
            let n = message.openedBy.count
            if n == 0 { return "Delivered" }
            return isGroup ? "Opened by \(n)" : "Opened"
        }
        return canOpen ? "Tap to view" : "Opened"
    }

    /// Filled = there's something to see (yours: nobody's opened it yet).
    private var filled: Bool {
        message.isFromMe(me) ? message.openedBy.isEmpty : canOpen
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: message.isFromMe(me)
                      ? (filled ? "arrowtriangle.right.fill" : "arrowtriangle.right")
                      : (filled ? "square.fill" : "square"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                Text(message.kind == .video ? "Video" : "Snap")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 14, weight: canOpen ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(canOpen ? 0.9 : 0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(canOpen ? 0.9 : 0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
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
        .task(id: message.id) {
            image = message.kind == .video ? await store.thumbnail(for: message) : await store.image(for: message)
        }
    }
}

private struct PhotoViewer: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let message: Message
    var canDelete = false
    var onDelete: () -> Void = {}

    /// Follows a downward drag; far enough (or flung) and the snap closes.
    @State private var dragOffset: CGFloat = 0

    /// The store's copy, so a save made here shows immediately.
    private var current: Message {
        store.messages[message.conversationID]?.first { $0.id == message.id } ?? message
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if message.kind == .video {
                VideoMessagePlayer(message: message)
                    .ignoresSafeArea()
            } else {
                SnapImage(message: message, contentMode: .fit)
                    .ignoresSafeArea()
            }

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
                    if canDelete {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                saveButton
                    .padding(.bottom, 24)
            }
        }
        // Shrinks a little as it's pulled down, like Snapchat.
        .scaleEffect(1 - min(dragOffset, 400) / 400 * 0.15)
        .offset(y: dragOffset)
        .gesture(swipeDown)
        .statusBarHidden()
        // Looking at it is opening it. Unless it's saved, this is the only look.
        .onAppear { store.markOpened(message) }
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 260 {
                    withAnimation(.easeIn(duration: 0.18)) {
                        dragOffset = UIScreen.main.bounds.height
                    }
                    // Already off screen; skip the cover's own slide.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withoutAnimation { dismiss() }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    @ViewBuilder
    private var saveButton: some View {
        let saved = current.isSaved
        // Anyone can save; only whoever saved it can unsave.
        if !saved || current.savedBy == session.userID {
            Button { Task { await store.setSaved(current, !saved) } } label: {
                Label(saved ? "Saved in Chat" : "Save in Chat", systemImage: saved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(saved ? .black : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(saved ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.45)), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Label("Saved in Chat", systemImage: "bookmark.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Fetches a video message's clip, then loops it full-screen with sound.
private struct VideoMessagePlayer: View {
    @EnvironmentObject private var store: ChatStore
    let message: Message
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                LoopingVideo(url: url, gravity: .resizeAspect)
            } else {
                ProgressView().tint(.white.opacity(0.5))
            }
        }
        .task(id: message.id) { url = await store.video(for: message) }
    }
}
