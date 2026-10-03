import SwiftUI
import PhotosUI

struct ConversationScreen: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var camera: CameraController
    let conversationID: Conversation.ID
    /// How far the swipe-to-close has dragged the thread (either way).
    /// The chat list owns it so the whole layer, nav bar included, moves.
    var swipeOffset: Binding<CGFloat> = .constant(0)
    /// Closes the thread, sliding it out to the left (-1) or right (+1).
    var onClose: (_ direction: CGFloat) -> Void = { _ in }
    /// The current drag is sideways (decided on its first movement).
    @State private var isSwipingSideways: Bool?
    /// The thread's rows don't take taps from the moment a sideways swipe
    /// starts until just after it ends — Snapchat's rule: a touch that
    /// became a swipe can't also open the snap it lifts off over.
    /// `.disabled` (not allowsHitTesting) is what cancels a tap in flight.
    @State private var isSwipeLocked = false

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
    @StateObject private var presence = ChatPresence()
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
            if let conversation, conversation.isGroup {
                // Everyone but you: you know you're here.
                ChatMembersBar(
                    members: conversation.members.filter { $0.id != session.userID },
                    here: presence.here,
                    color: memberColor
                )
            }
            composer
        }
        .background(Color.black)
        .navigationTitle(conversation?.title(for: session.userID) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 26+ puts toolbar buttons in a glass bubble; just the
            // chevron, like Snapchat.
            if #available(iOS 26, *) {
                backButton.sharedBackgroundVisibility(.hidden)
            } else {
                backButton
            }
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
                GroupMembersSheet(conversation: conversation) { onClose(-1) }
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
            // Records what you've seen. (Chats no longer disappear.)
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
        // In the group while it's open and the app's up; out otherwise.
        .task(id: scenePhase != .background) {
            guard conversation?.isGroup == true, let me = session.userID else { return }
            if scenePhase != .background {
                await presence.join(conversationID, as: me)
            } else {
                await presence.leave()
            }
        }
        .onDisappear {
            Task { await presence.leave() }
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
            PhotoViewer(
                message: message,
                canDelete: message.isFromMe(session.userID),
                onDelete: {
                    viewing = nil
                    deleting = message
                },
                onSnapReply: {
                    viewing = nil
                    afterSheet {
                        camera.captureTarget = conversationID
                        withoutAnimation { isShootingSnap = true }
                    }
                }
            )
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
                        // A reply to a snap always gets its own header, and
                        // whatever follows one starts afresh, like Snapchat.
                        let repliedTo = message.replyTo.flatMap { id in thread.first { $0.id == id && $0.isSnap } }
                        let startsRun = newDay || lull || previous?.senderID != message.senderID
                            || repliedTo != nil || previous?.replyTo != nil
                        MessageRow(
                            message: message,
                            me: session.userID,
                            isGroup: conversation?.isGroup == true,
                            color: senderColor(of: message),
                            header: startsRun ? (mine ? "Me" : conversation?.senderName(of: message) ?? "") : nil,
                            repliedTo: repliedTo,
                            replyLabel: repliedTo.map(replyLabel(for:)),
                            saverName: saverName(of: message),
                            isPicked: actionTarget?.id == message.id,
                            onTapText: { toggleSaved(message) }
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
                .disabled(isSwipeLocked)
            }
            .defaultScrollAnchor(.bottom)
            // Global coordinates: the thread moves under the finger, and a
            // local measurement would chase itself (the page jittered).
            // Swipe left or right anywhere in the thread to close it: the
            // thread follows the finger off that way, revealing the list.
            // Only a drag that starts out sideways counts, so scrolling never
            // trips it; the composer is outside this view, so the voice-note
            // slide-to-cancel can't either.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if isSwipingSideways == nil {
                            isSwipingSideways = actionTarget == nil && abs(dx) > abs(dy) * 1.5
                        }
                        guard isSwipingSideways == true else { return }
                        isSwipeLocked = true
                        swipeOffset.wrappedValue = dx
                    }
                    .onEnded { value in
                        defer {
                            isSwipingSideways = nil
                            // Outlast the lift-off tap, then take taps again.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isSwipeLocked = false }
                        }
                        guard isSwipingSideways == true else { return }
                        // Same rule as the tabs: a quick flick closes it,
                        // a slow drag has to get past halfway.
                        let dx = value.translation.width, speed = value.velocity.width
                        let half = UIScreen.main.bounds.width / 2
                        // A flick only counts the way the drag went: a
                        // finger lifting off often twitches back, and that
                        // mustn't throw the thread out the other side.
                        if dx < 0 && (speed < -SwipeRule.flickSpeed || dx < -half) {
                            close(-1)
                        } else if dx > 0 && (speed > SwipeRule.flickSpeed || dx > half) {
                            close(1)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                swipeOffset.wrappedValue = 0
                            }
                        }
                    }
            )
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

    private var backButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { close(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
        }
    }

    private func close(_ direction: CGFloat) {
        isComposing = false
        onClose(direction)
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
        memberColor(message.senderID)
    }

    /// One colour per person, the same in their messages and their pill.
    fileprivate func memberColor(_ id: UUID) -> Color {
        if id == session.userID { return SnapColors.me }
        guard conversation?.isGroup == true else { return SnapColors.them }
        let seed = id.uuidString.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return SnapColors.group[seed % SnapColors.group.count]
    }

    /// "Replied to Nalin's Snap" / "Replied to your Snap".
    fileprivate func replyLabel(for snap: Message) -> String {
        let whose = snap.senderID == session.userID
            ? "your"
            : "\(conversation?.senderName(of: snap) ?? "their")'s"
        return "Replied to \(whose) Snap"
    }

    /// "you" or the saver's first name, for the caption under a saved snap.
    fileprivate func saverName(of message: Message) -> String? {
        guard let saver = message.savedBy else { return nil }
        if saver == session.userID { return "you" }
        let name = conversation?.members.first { $0.id == saver }?.displayName
        return name?.split(separator: " ").first.map(String.init) ?? name
    }

    /// Tap a text to save it in chat; tap again to unsave (only whoever
    /// saved it can). Permanent texts and long-press lifts do nothing.
    fileprivate func toggleSaved(_ message: Message) {
        guard actionTarget == nil else { return }
        let me = session.userID
        if message.isSaved {
            guard message.savedBy == me else { return }
        } else {
            guard message.isDisappearingChat else { return }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await store.setSaved(message, !message.isSaved) }
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
    /// The snap this text answers, drawn above it as a thumbnail.
    var repliedTo: Message? = nil
    /// "Replied to Nalin's Snap", beside the header.
    var replyLabel: String? = nil
    /// Who saved it in chat, if anyone ("you" or a first name).
    var saverName: String? = nil
    /// Long-pressed for the actions sheet: lifting the finger mustn't
    /// also count as a tap.
    var isPicked = false
    /// A tap on a text: Snapchat's tap-to-save.
    var onTapText: () -> Void = {}
    let onOpenPhoto: () -> Void

    private var showsSavedBand: Bool {
        message.isSaved && (message.isSnap || message.ephemeral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header {
                HStack(alignment: .firstTextBaseline) {
                    Text(header)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                    if let replyLabel {
                        Label(replyLabel, systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
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
                // The whole line is the target, not just the words. Snaps
                // and voice notes keep their own buttons (a child's tap
                // wins), so this only ever acts for texts.
                .contentShape(Rectangle())
                .onTapGesture {
                    if message.kind == .text { onTapText() }
                }
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
        case .text where repliedTo != nil:
            snapReply
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

    /// Snapchat's reply to a snap: a small thumbnail of it, the text in a
    /// dark bubble overlapping its bottom edge.
    private var snapReply: some View {
        VStack(alignment: .leading, spacing: -28) {
            if let repliedTo {
                SnapImage(message: repliedTo)
                    .frame(width: 84, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(message.body ?? "")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(white: 0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .padding(.leading, 14)
        }
        .padding(.vertical, 2)
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
        // Flat: the swipe lock disables rows; .plain would grey them and
        // a pressed look could stick.
        .buttonStyle(.flat)
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
        // Flat: disabled (nothing to open) mustn't grey the card out.
        .buttonStyle(.flat)
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

/// A snap, Snapchat's way: the picture in a rounded card with who sent it
/// and when, and underneath a camera button (snap back), a "Reply..." field
/// and a download button (save to Photos). Tap the snap or swipe it down to
/// close; the ⋯ menu has Save in Chat and Delete.
private struct PhotoViewer: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let message: Message
    var canDelete = false
    var onDelete: () -> Void = {}
    /// The camera button: close and shoot a snap back into this chat.
    var onSnapReply: () -> Void = {}

    /// Follows a downward drag; far enough (or flung) and the snap closes.
    @State private var dragOffset: CGFloat = 0
    @State private var reply = ""
    @FocusState private var isReplying: Bool
    @State private var saveState: SaveState = .idle

    private enum SaveState { case idle, saving, saved, failed }

    /// The store's copy, so a save made here shows immediately.
    private var current: Message {
        store.messages[message.conversationID]?.first { $0.id == message.id } ?? message
    }

    private var sender: Profile? {
        store.conversation(message.conversationID)?.member(message.senderID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                card
                bottomBar
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        // Shrinks a little as it's pulled down, like Snapchat.
        .scaleEffect(1 - min(dragOffset, 400) / 400 * 0.15)
        .offset(y: dragOffset)
        .gesture(swipeDown)
        // Looking at it is opening it. Unless it's saved, this is the only look.
        .onAppear { store.markOpened(message) }
    }

    // MARK: - The snap

    private var card: some View {
        ZStack {
            Color(white: 0.06)
            if message.kind == .video {
                VideoMessagePlayer(message: message)
            } else {
                ViewerImage(message: message)
            }
        }
        .overlay(alignment: .top) { header }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        // Tap the snap to close it; with the keyboard up, tap just puts it away.
        .onTapGesture {
            if isReplying { isReplying = false } else { dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let sender {
                Avatar(subject: sender, size: 38)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(sender?.displayName ?? "Snap")
                    .font(.system(size: 16, weight: .semibold))
                Text(message.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            Spacer()
            moreMenu
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    /// Save in Chat (anyone; only the saver can undo) and Delete (yours).
    private var moreMenu: some View {
        Menu {
            let saved = current.isSaved
            if !saved || current.savedBy == session.userID {
                Button {
                    Task { await store.setSaved(current, !saved) }
                } label: {
                    Label(saved ? "Unsave in Chat" : "Save in Chat",
                          systemImage: saved ? "bookmark.slash" : "bookmark")
                }
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: onSnapReply) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 52)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            TextField("", text: $reply, prompt: Text("Reply...").foregroundStyle(.white))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .submitLabel(.send)
                .focused($isReplying)
                .onSubmit(sendReply)
                .padding(.horizontal, 20)
                .frame(height: 52)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))

            Button(action: saveToPhotos) {
                Group {
                    switch saveState {
                    case .idle: Image(systemName: "arrow.down.square.fill")
                    case .saving: ProgressView().tint(.white)
                    case .saved: Image(systemName: "checkmark")
                    case .failed: Image(systemName: "exclamationmark.triangle.fill")
                    }
                }
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 52)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(saveState == .saving || saveState == .saved)
            .accessibilityLabel("Save to Photos")
        }
    }

    /// A text back into the chat, then out to the thread to see it land.
    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        Task { await store.send(text: text, to: message.conversationID, replyTo: message.id) }
        dismiss()
    }

    private func saveToPhotos() {
        saveState = .saving
        Task {
            let ok = await PhotoLibrarySaver.save(message, from: store)
            saveState = ok ? .saved : .failed
            UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
            if !ok {
                try? await Task.sleep(for: .seconds(1.5))
                saveState = .idle
            }
        }
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
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
}

/// A photo in the viewer's card, Snapchat's way. A Groupy camera snap is the
/// card's shape near enough, so it fills edge to edge. Anything else (a
/// screenshot, a landscape camera-roll pick) is shown whole, over a blurred,
/// zoomed-in copy of itself so the card never has bare bars.
private struct ViewerImage: View {
    @EnvironmentObject private var store: ChatStore
    let message: Message
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            if let image {
                let card = geo.size.width / max(geo.size.height, 1)
                let photo = image.size.width / max(image.size.height, 1)
                if abs(photo - card) / card < 0.06 {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 30, opaque: true)
                            .overlay(Color.black.opacity(0.15))
                            .clipped()
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            } else {
                ProgressView().tint(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: message.id) { image = await store.image(for: message) }
    }
}

/// Saves a snap to the photo library. Add-only access: Groupy can put
/// things in, never read them out.
enum PhotoLibrarySaver {
    /// A snap you've just taken, before it's sent.
    @MainActor
    static func save(_ snap: Snap) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            switch snap.media {
            case .photo(let image):
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
            case .video(let url):
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func save(_ message: Message, from store: ChatStore) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            if message.kind == .video {
                guard let url = await store.file(for: message) else { return false }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } else {
                guard let image = await store.image(for: message) else { return false }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
            }
            return true
        } catch {
            return false
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
