import Foundation
import OSLog
import Supabase

enum SessionError: LocalizedError {
    case usernameTaken

    var errorDescription: String? {
        switch self {
        case .usernameTaken: return "That username is taken."
        }
    }
}

/// Who's signed in, and their profile row.
@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var userID: UUID?
    @Published private(set) var me: Profile?
    /// True from launch until the stored session has been checked and, if
    /// there is one, the profile fetched. The UI shows the camera (disabled)
    /// rather than onboarding during this window.
    @Published private(set) var isRestoring = true
    /// Why the last profile load failed, for the onboarding screen to show.
    @Published private(set) var profileError: String?

    private let log = Logger(subsystem: "com.groupy.app", category: "session")

    private let client = Backend.client
    private var observer: Task<Void, Never>?

    var isSignedIn: Bool { userID != nil }

    func start() {
        observer?.cancel()
        let client = client
        observer = Task { [weak self] in
            for await (_, session) in client.auth.authStateChanges {
                guard let self else { return }
                self.apply(session)
            }
        }
    }

    private func apply(_ session: Session?) {
        let id = session?.user.id
        guard id != userID || (id != nil && me == nil) else {
            isRestoring = false
            return
        }
        userID = id
        me = nil
        if id != nil {
            Task {
                await loadProfile()
                isRestoring = false
            }
        } else {
            isRestoring = false
        }
    }

    func loadProfile() async {
        guard let userID else { return }
        do {
            me = try await client
                .from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value
            profileError = nil
        } catch {
            log.error("profile load failed for \(userID.uuidString): \(String(describing: error))")
            profileError = error.localizedDescription
        }
    }

    /// Returns true when Supabase wants the address confirmed before it will
    /// hand out a session (its default). The profile row is created by a DB
    /// trigger from the metadata, so it exists either way.
    func signUp(email: String, password: String, displayName: String, username: String) async throws -> Bool {
        struct IDRow: Decodable { let id: UUID }
        let taken: [IDRow] = try await client
            .from("profiles")
            .select("id")
            .eq("username", value: username)
            .limit(1)
            .execute()
            .value
        guard taken.isEmpty else { throw SessionError.usernameTaken }

        let result = try await client.auth.signUp(
            email: email,
            password: password,
            data: [
                "username": .string(username),
                "display_name": .string(displayName),
            ]
        )
        return result.session == nil
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signOut() async {
        try? await client.auth.signOut()
    }
}
