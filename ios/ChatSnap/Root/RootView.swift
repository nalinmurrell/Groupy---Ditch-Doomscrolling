import SwiftUI

enum AppTab: Int, Hashable, CaseIterable {
    case chat
    case camera
    case friends
}

struct RootView: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var push: PushManager
    @Environment(\.scenePhase) private var scenePhase

    /// Set on the last onboarding step. Survives sign-out so a returning
    /// user goes straight from sign-in to the camera.
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false

    @State private var tab: AppTab = .camera
    /// Lifted out of the chat pane so the tab bar can get out of the way when
    /// a conversation is pushed.
    @State private var openConversations: [Conversation.ID] = []
    @State private var isProfileOpen = false

    private var isTabBarVisible: Bool {
        !(tab == .chat && !openConversations.isEmpty)
    }

    private var isReady: Bool {
        session.me != nil && didFinishOnboarding
    }

    /// A returning user sees the camera straight away — dark, shutter greyed
    /// — while the session is checked, instead of a flash of onboarding.
    private var showsShell: Bool {
        isReady || (session.isRestoring && didFinishOnboarding)
    }

    var body: some View {
        Group {
            if !Backend.isConfigured {
                SetupNeededScreen()
            } else if showsShell {
                shell
            } else {
                OnboardingFlow()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showsShell)
        .task { session.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.resume()
                if isReady {
                    // Sockets don't survive the background reliably; re-subscribe
                    // rather than trust the reconnect, then fill the gap.
                    chats.startRealtime()
                    friends.startRealtime()
                    Task { await chats.refresh() }
                }
            case .background:
                camera.suspend()
            default:
                break
            }
        }
    }

    private var shell: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            // Chat sits to the LEFT of the camera, so a rightward swipe from
            // the camera reveals it — same direction as Snapchat. Friends is
            // the mirror of that on the right.
            Pager(
                index: Binding(
                    get: { tab.rawValue },
                    set: { tab = AppTab(rawValue: $0) ?? .camera }
                ),
                count: AppTab.allCases.count,
                isSwipeEnabled: openConversations.isEmpty
            ) {
                ChatListScreen(path: $openConversations)
                CameraScreen()
                FriendsScreen()
            }

            if isTabBarVisible {
                AppTabBar(selection: $tab, friendsBadge: friends.incoming.count)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTabBarVisible)
        // Your profile: a layer over everything, sliding in from the right.
        .overlay {
            if isProfileOpen {
                ProfileScreen(
                    onClose: { withAnimation(.easeInOut(duration: 0.28)) { isProfileOpen = false } },
                    onSwipedAway: { withoutAnimation { isProfileOpen = false } }
                )
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .environment(\.openProfile) {
            withAnimation(.easeInOut(duration: 0.28)) { isProfileOpen = true }
        }
        .task { camera.start() }
        // Data needs a session; it arrives once restore finishes.
        .task(id: isReady) {
            guard isReady else { return }
            push.enable()
            // A tap that cold-started the app was recorded before we appeared.
            if let id = push.pendingConversation { open(id) }
            chats.startRealtime()
            // Accepting a request opens a DM, so friend changes ripple to chats.
            friends.onRemoteChange = { [weak chats] in await chats?.refresh() }
            friends.startRealtime()
            async let a: () = chats.refresh()
            async let b: () = friends.refresh()
            _ = await (a, b)
        }
        .onDisappear {
            chats.stopRealtime()
            friends.stopRealtime()
        }
        // A tapped notification lands in its thread.
        .onChange(of: push.pendingConversation) { _, id in
            if let id { open(id) }
        }
    }

    private func open(_ id: Conversation.ID) {
        push.pendingConversation = nil
        withoutAnimation {
            tab = .chat
            openConversations = [id]
        }
        // The thread may already be on screen with a stale cache; the push
        // itself is proof there's something new.
        Task { await chats.loadMessages(for: id) }
    }
}
