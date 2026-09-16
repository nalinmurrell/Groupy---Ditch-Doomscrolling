import SwiftUI

enum AppTab: Hashable {
    case chat
    case camera
    case friends
}

struct RootView: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(\.scenePhase) private var scenePhase

    /// Set on the last onboarding step. Survives sign-out so a returning
    /// user goes straight from sign-in to the camera.
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false

    @State private var tab: AppTab = .camera
    /// Lifted out of the chat pane so the tab bar can get out of the way when
    /// a conversation is pushed.
    @State private var openConversations: [Conversation.ID] = []

    private var isTabBarVisible: Bool {
        !(tab == .chat && !openConversations.isEmpty)
    }

    private var isReady: Bool {
        session.me != nil && didFinishOnboarding
    }

    var body: some View {
        Group {
            if !Backend.isConfigured {
                SetupNeededScreen()
            } else if isReady {
                shell
            } else {
                OnboardingFlow()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isReady)
        .task { session.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.resume()
                if isReady { Task { await chats.refresh() } }
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
            TabView(selection: $tab) {
                ChatListScreen(path: $openConversations)
                    .tag(AppTab.chat)

                CameraScreen()
                    .tag(AppTab.camera)

                FriendsScreen()
                    .tag(AppTab.friends)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if isTabBarVisible {
                AppTabBar(selection: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isTabBarVisible)
        .task {
            camera.start()
            chats.startRealtime()
            async let a: () = chats.refresh()
            async let b: () = friends.refresh()
            _ = await (a, b)
        }
        .onDisappear { chats.stopRealtime() }
    }
}
