import SwiftUI

@main
struct ChatSnapApp: App {
    /// Owned at app level rather than by a view, so the capture session starts
    /// warming up on launch instead of when some view appears. The camera
    /// should already be live on the first frame the user sees.
    @StateObject private var camera = CameraController()
    @StateObject private var session = SessionStore()
    @StateObject private var chats = ChatStore()
    @StateObject private var friends = FriendsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(session)
                .environmentObject(chats)
                .environmentObject(friends)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
