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
        UNUserNotificationCenter.current().delegate = self
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
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let id = Self.conversationID(in: notification.request.content.userInfo)
        let active = await MainActor.run { PushManager.shared.activeConversation }
        // Already reading that thread — the message just appears.
        return id != nil && id == active ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = Self.conversationID(in: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushManager.shared.pendingConversation = id }
    }

    private nonisolated static func conversationID(in userInfo: [AnyHashable: Any]) -> Conversation.ID? {
        (userInfo["conversation_id"] as? String).flatMap(UUID.init)
    }
}

/// UIKit's entry points for remote-notification registration.
final class AppDelegate: NSObject, UIApplicationDelegate {
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
