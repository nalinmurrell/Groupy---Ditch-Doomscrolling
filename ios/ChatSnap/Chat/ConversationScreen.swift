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
    @StateObject private var recorder = VoiceRecorder()
    /// The finger's slide left while recording, for slide-to-cancel.
    @State private var micSlide: CGFloat = 0
    @State private var voiceFailed = false
    private let cancelDistance: CGFloat = 110
    @FocusState private var isComposing: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
            recorder.cancel()
            VoicePlayer.shared.stop()
            // Leaving is what makes seen texts disappear, like Snapchat.
            store.leaveChat(conversationID)
        }
        // Backgrounding the app with the chat open counts as leaving too.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                recorder.cancel()
                VoicePlayer.shared.stop()
                store.leaveChat(conversationID)
            }
        }
        .onAppear {
            recorder.onLimitReached = { url in sendVoiceNote(url) }
        }
        .alert("Couldn't send voice note", isPresented: $voiceFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .alert("Microphone is off for Groupy", isPresented: $recorder.micDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn it on in Settings to send voice notes.")
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
            MessageActionsSheet(
                actions: actions(for: message),
                currentReaction: message.reaction(by: session.userID)
            ) { emoji in
                Task { await store.react(to: message, with: emoji) }
            }
        }
        .confirmationDialog(
            "Delete this \(deleting.map(Self.noun) ?? "message")?",
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
                // No spacing: a run's bars join into one line, like Snapchat.
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Snapchat's rule, said once where it applies.
                    Text("Chats disappear once everyone's seen them.\nPress and hold a message to save it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                    ForEach(Array(thread.enumerated()), id: \.element.id) { index, message in
                        let mine = message.isFromMe(session.userID)
                        let previous = index > 0 ? thread[index - 1] : nil
                        let newDay = previous.map {
                            !Calendar.current.isDate($0.createdAt, inSameDayAs: message.createdAt)
                        } ?? true
                        // Snapchat's day markers: TODAY, YESTERDAY, SUNDAY…
                        if newDay {
                            Text(message.createdAt.threadDayLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.top, index == 0 ? 0 : 14)
                                .padding(.bottom, 2)
                        }
                        // A name header opens each run: a new sender, a new
                        // day, or a lull of twenty minutes or more.
                        let lull = previous.map { message.createdAt.timeIntervalSince($0.createdAt) > 20 * 60 } ?? true
                        let startsRun = newDay || lull || previous?.senderID != message.senderID
                        MessageRow(
                            message: message,
                            me: session.userID,
                            isGroup: conversation?.isGroup == true,
                            color: senderColor(of: message),
                            header: startsRun ? (mine ? "Me" : conversation?.senderName(of: message) ?? "") : nil,
                            saverName: saverName(of: message),
                            isPicked: actionTarget?.id == message.id
                        ) {
                            guard actionTarget == nil else { return }
                            viewing = message
                        }
                        .padding(.top, startsRun && !newDay ? 10 : 0)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                // Snapchat's: a white disc, black camera.
                Image(systemName: "camera.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)

            // The field, with the mic on its right like Snapchat's. While
            // the mic's held the field becomes the recording strip; the mic
            // itself stays put so its touch isn't torn down mid-hold.
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    // Single line so Return means send. (A multiline field
                    // turns Return into a newline and never submits.)
                    TextField("Send a chat", text: $draft)
                        .textFieldStyle(.plain)
                        .submitLabel(.send)
                        .focused($isComposing)
                        .onSubmit(send)
                        .foregroundStyle(.white)
                        .opacity(recorder.isRecording || recorder.showsHint ? 0 : 1)
                    if recorder.isRecording {
                        RecordingStrip(
                            elapsed: recorder.elapsed,
                            level: recorder.level,
                            slide: micSlide,
                            cancelDistance: cancelDistance
                        )
                    } else if recorder.showsHint {
                        Text("Hold to record a voice note")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                micButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            // Outlined, not filled, like Snapchat's field.
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1.5))

            // Camera roll. The picker runs out of process, so no photo
            // library permission is needed — the user only hands over the
            // one image they choose.
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Group {
                    if isSendingPhoto {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
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

    private var micButton: some View {
        Image(systemName: "waveform")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(recorder.isRecording ? 1 : 0.85))
            .frame(width: 32, height: 32)
            .background(recorder.isRecording ? SnapColors.me : .clear, in: Circle())
            .scaleEffect(recorder.isRecording ? 1.25 : 1)
            .offset(x: micSlide)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: recorder.isRecording)
            .contentShape(Circle())
            .overlay {
                PressDetector(
                    onBegan: {
                        micSlide = 0
                        recorder.begin { camera.microphoneAllowed() }
                    },
                    onMoved: { offset in
                        guard recorder.isRecording else { return }
                        micSlide = min(0, offset.width)
                        if offset.width < -cancelDistance {
                            recorder.cancel()
                            withAnimation(.spring(response: 0.25)) { micSlide = 0 }
                        }
                    },
                    onEnded: {
                        withAnimation(.spring(response: 0.25)) { micSlide = 0 }
                        if let url = recorder.finish() { sendVoiceNote(url) }
                    }
                )
            }
            .accessibilityLabel("Hold to record a voice note")
    }

    private func sendVoiceNote(_ url: URL) {
        Task {
            if !(await store.send(voiceNote: url, to: conversationID)) { voiceFailed = true }
        }
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

extension ConversationScreen {
    /// What a long-press offers, Snapchat order: keep it, answer it, copy it,
    /// then the destructive one last.
    fileprivate func actions(for message: Message) -> [MessageAction] {
        let me = session.userID
        let mine = message.isFromMe(me)
        var list: [MessageAction] = []

        let canSave = message.isSnap
            ? (mine || message.isUnopenedSnap(for: me))
            : message.isDisappearingChat
        if message.isSnap || message.ephemeral {
            if message.isSaved {
                // Only whoever saved it can take that back.
                if message.savedBy == me {
                    list.append(.init(title: "Unsave", icon: "square.and.arrow.down.fill") {
                        Task { await store.setSaved(message, false) }
                    })
                }
            } else if canSave {
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

    /// Snapchat's colours: you in red; the other person in blue; in a group,
    /// each member keeps their own colour.
    fileprivate func senderColor(of message: Message) -> Color {
        if message.isFromMe(session.userID) { return SnapColors.me }
        guard conversation?.isGroup == true else { return SnapColors.them }
        let seed = message.senderID.uuidString.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return SnapColors.group[seed % SnapColors.group.count]
    }

    /// "you" or the saver's first name, for the caption under a saved snap.
    fileprivate func saverName(of message: Message) -> String? {
        guard let saver = message.savedBy else { return nil }
        if saver == session.userID { return "you" }
        let name = conversation?.members.first { $0.id == saver }?.displayName
        return name?.split(separator: " ").first.map(String.init) ?? name
    }

    /// What to call a message in a sentence.
    fileprivate static func noun(_ message: Message) -> String {
        switch message.kind {
        case .photo: "photo"
        case .video: "video"
        case .audio: "voice note"
        case .text, .unsupported: "message"
        }
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

/// Snapchat's long-press sheet: a reaction bar on top, then big rows —
/// icon then label, hairlines between.
fileprivate struct MessageActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let actions: [MessageAction]
    let currentReaction: String?
    /// The new reaction, or nil to take yours back.
    let onReact: (String?) -> Void

    @State private var showsAllEmoji = false
    @State private var detent: PresentationDetent = .height(0)

    static let quick = ["❤️", "😂", "😮", "😢", "🔥", "👍"]
    static let more = ["😍", "🥰", "😘", "😭", "🤣", "😅",
                       "😊", "😎", "🤔", "🙄", "😬", "😳",
                       "🥺", "😡", "🤯", "💀", "👀", "😴",
                       "👏", "🙌", "🙏", "💪", "🤝", "🫶",
                       "💯", "✨", "🎉", "👎", "🤮", "🫡"]

    private let rowHeight: CGFloat = 66
    private let barHeight: CGFloat = 96

    private var compact: PresentationDetent {
        .height(barHeight + CGFloat(actions.count) * (rowHeight + 0.5) + 28 + 34)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsAllEmoji {
                emojiGrid
            } else {
                reactionBar
            }
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
        .presentationDetents([compact, .large], selection: $detent)
        .onAppear { detent = compact }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .presentationBackground(Color(white: 0.09))
        .preferredColorScheme(.dark)
    }

    private var reactionBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.quick, id: \.self) { emoji in
                emojiButton(emoji, size: 30)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsAllEmoji = true
                    detent = .large
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.05, green: 0.6, blue: 1), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.1), in: Capsule())
        .frame(height: barHeight - 16)
        .padding(.bottom, 16)
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(Self.quick + Self.more, id: \.self) { emoji in
                emojiButton(emoji, size: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    /// Tapping your current reaction again takes it back.
    private func emojiButton(_ emoji: String, size: CGFloat) -> some View {
        Button {
            dismiss()
            onReact(emoji == currentReaction ? nil : emoji)
        } label: {
            Text(emoji)
                .font(.system(size: size))
                .frame(width: 48, height: 48)
                .background(.white.opacity(emoji == currentReaction ? 0.22 : 0), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Rows darken while pressed, no system highlight.
private struct MessageActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
    }
}

enum SnapColors {
    static let me = Color(red: 0.95, green: 0.24, blue: 0.34)
    static let them = Color(red: 0.05, green: 0.68, blue: 1.0)
    static let group: [Color] = [
        them,
        Color(red: 0.64, green: 0.40, blue: 0.96),
        Color(red: 0.18, green: 0.78, blue: 0.46),
        Color(red: 1.0, green: 0.62, blue: 0.16),
        Color(red: 1.0, green: 0.40, blue: 0.72),
        Color(red: 0.12, green: 0.78, blue: 0.80),
    ]
    static let savedBand = Color(red: 0x2B / 255, green: 0x2B / 255, blue: 0x2B / 255)
}

/// One message, Snapchat-style: no bubble — left-aligned, a thin bar in the
/// sender's colour down its edge, and a name header when a run begins.
private struct MessageRow: View {
    let message: Message
    let me: UUID?
    let isGroup: Bool
    let color: Color
    /// "Me" or the sender's first name, when this message opens a run.
    var header: String? = nil
    /// Who saved it in chat, if anyone ("you" or a first name).
    var saverName: String? = nil
    /// Long-pressed for the actions sheet: lifting the finger mustn't
    /// also count as a tap.
    var isPicked = false
    let onOpenPhoto: () -> Void

    private var showsSavedBand: Bool {
        message.isSaved && (message.isSnap || message.ephemeral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header {
                HStack(alignment: .firstTextBaseline) {
                    Text(header)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(color)
                    Spacer()
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            content
                .padding(.leading, 12)
                .padding(.vertical, showsSavedBand ? 8 : 3)
                .padding(.trailing, showsSavedBand ? 8 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Saved: Snapchat's grey band, the width of the chat.
                .background(showsSavedBand ? SnapColors.savedBand : .clear)
                // The sender's bar, exactly as tall as the message.
                .overlay(alignment: .leading) {
                    Rectangle().fill(color).frame(width: 2.5)
                }

            if !message.reactions.isEmpty {
                ReactionPill(reactions: message.reactions, me: me)
                    .padding(.leading, 12)
            }
            if message.isSnap && message.isSaved {
                // Snapchat's wording and look: a centred, spaced-out caps line.
                Text(saverName.map { "\($0) saved a Snap in Chat!" } ?? "Saved in Chat")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(message.body ?? "")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        case .photo, .video:
            if message.isSaved {
                savedSnap
            } else {
                SnapStatus(message: message, me: me, isGroup: isGroup, onOpen: onOpenPhoto)
            }
        case .audio:
            VoiceNoteView(message: message, color: color, isPicked: isPicked)
        case .unsupported:
            Text("Update Groupy to see this message.")
                .font(.system(size: 15))
                .italic()
                .foregroundStyle(.white.opacity(0.5))
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Reactions under a message: each emoji once, with a count when shared.
private struct ReactionPill: View {
    let reactions: [Message.Reaction]
    let me: UUID?

    private var grouped: [(emoji: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reaction in reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { group in
                HStack(spacing: 2) {
                    Text(group.emoji).font(.system(size: 15))
                    if group.count > 1 {
                        Text("\(group.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.17), in: Capsule())
        // A ring the colour of the background separates it from the bubble.
        .overlay(Capsule().strokeBorder(.black, lineWidth: 2))
        .overlay(
            Capsule().strokeBorder(Color(red: 0.05, green: 0.6, blue: 1).opacity(reactions.contains { $0.userID == me } ? 0.8 : 0), lineWidth: 1)
                .padding(2)
        )
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
            HStack(spacing: 14) {
                icon
                    .frame(width: 22, height: 22)
                Text(label)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(canOpen ? 1 : 0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .chatCard()
            .contentShape(Rectangle())
        }
        // Quiet: disabled (nothing to open) mustn't grey the card out.
        .buttonStyle(.quiet)
        .disabled(!canOpen)
    }

    /// Yours: Snapchat's notched send arrow. Theirs: a square. Filled
    /// while there's something to see.
    @ViewBuilder
    private var icon: some View {
        if message.isFromMe(me) {
            if filled {
                SentArrow().fill(tint)
            } else {
                SentArrow().stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                    .padding(1.1)
            }
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(filled ? tint : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(tint, lineWidth: 2.2)
                )
                .padding(2)
        }
    }
}

/// Snapchat's sent-snap arrow: a right-pointing triangle with a notch cut
/// into its back.
private struct SentArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// The dark rounded card Snapchat puts snaps and voice notes in.
    func chatCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                )
        )
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
        .task(id: message.id) { url = await store.file(for: message) }
    }
}
