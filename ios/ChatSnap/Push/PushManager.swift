import OSLog
import Supabase
import SwiftUI
import UserNotifications

/// Registers this device for pushes, keeps its token on the server, and
/// routes a tapped notification to its thread. UIKit talks to it through
/// `AppDelegate`; SwiftUI reads it as an environment object.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    /// The thread the user is looking at, so its own pushes stay silent.
    var activeConversation: Conversation.ID?
    /// Set when a notification is tapped; RootView opens it and clears this.
    @Published var pendingConversation: Conversation.ID?

    private let log = Logger(subsystem: "com.groupy.app", category: "push")
    private var token: String?

    /// Ask once we know who the user is. Silent if already decided.
    func enable() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: - Token

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await upload() }
    }

    func didFailToRegister(_ error: Error) {
        log.error("push registration failed: \(error.localizedDescription)")
    }

    /// Store the token against the signed-in user. Debug builds get
    /// sandbox pushes; TestFlight and the App Store get production.
    private func upload() async {
        guard let token, let userID = Backend.client.auth.currentUser?.id else { return }
        struct Row: Encodable {
            let token: String
            let user_id: UUID
            let environment: String
            let updated_at: Date
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            try await Backend.client
                .from("device_tokens")
                .upsert(Row(token: token, user_id: userID, environment: environment, updated_at: Date()))
                .execute()
        } catch {
            log.error("token upload failed: \(error.localizedDescription)")
        }
    }

    /// On sign-out, so the next person on this phone doesn't get your pings.
    func forgetToken() async {
        guard let token else { return }
        _ = try? await Backend.client.from("device_tokens").delete().eq("token", value: token).execute()
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    // The completion-handler forms, not the async ones: UIKit asserts if the
    // completion arrives off the main thread, and Swift concurrency resumes
    // the async variants wherever it likes. These are delivered on main.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let id = Self.conversationID(in: notification.request.content.userInfo)
        let active = MainActor.assumeIsolated { PushManager.shared.activeConversation }
        // Already reading that thread — the message just appears.
        completionHandler(id != nil && id == active ? [] : [.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = Self.conversationID(in: response.notification.request.content.userInfo) {
            MainActor.assumeIsolated { PushManager.shared.pendingConversation = id }
        }
        completionHandler()
    }

    private nonisolated static func conversationID(in userInfo: [AnyHashable: Any]) -> Conversation.ID? {
        (userInfo["conversation_id"] as? String).flatMap(UUID.init)
    }
}

/// UIKit's entry points for remote-notification registration.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes, or a tap that cold-starts the app is lost.
        UNUserNotificationCenter.current().delegate = PushManager.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFailToRegister(error) }
    }
}
