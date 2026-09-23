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
    /// Your sign-in email.
    @Published private(set) var email: String?
    /// Birthday and phone — private to you (`account_details`).
    @Published private(set) var details = AccountDetails()

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
        email = session?.user.email
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

    // MARK: - Account settings

    /// Your display name, as your friends see it.
    func updateDisplayName(_ name: String) async throws {
        guard let userID else { return }
        try await client.from("profiles")
            .update(["display_name": name])
            .eq("id", value: userID.uuidString)
            .execute()
        await loadProfile()
    }

    func updateUsername(_ username: String) async throws {
        guard let userID else { return }
        do {
            try await client.from("profiles")
                .update(["username": username])
                .eq("id", value: userID.uuidString)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            throw SessionError.usernameTaken
        }
        await loadProfile()
    }

    /// Returns true when the change waits on a confirmation email.
    func updateEmail(_ newEmail: String) async throws -> Bool {
        let user = try await client.auth.update(user: UserAttributes(email: newEmail))
        email = user.email
        return user.newEmail != nil
    }

    func loadDetails() async {
        guard let userID else { return }
        let rows: [AccountDetails.Row]? = try? await client.from("account_details")
            .select("birthday, phone")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        details = rows?.first.map(AccountDetails.init) ?? AccountDetails()
    }

    func updateBirthday(_ date: Date) async throws {
        guard let userID else { return }
        struct Row: Encodable { let user_id: UUID; let birthday: String; let updated_at = Date() }
        try await client.from("account_details")
            .upsert(Row(user_id: userID, birthday: AccountDetails.dayFormatter.string(from: date)))
            .execute()
        details.birthday = date
    }

    /// nil clears it.
    func updatePhone(_ phone: String?) async throws {
        guard let userID else { return }
        struct Row: Encodable {
            let user_id: UUID
            let phone: String?
            let updated_at = Date()
            // Encode nil as null so clearing actually clears.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(user_id, forKey: .user_id)
                try c.encode(phone, forKey: .phone)
                try c.encode(updated_at, forKey: .updated_at)
            }
            enum CodingKeys: String, CodingKey { case user_id, phone, updated_at }
        }
        try await client.from("account_details")
            .upsert(Row(user_id: userID, phone: phone))
            .execute()
        details.phone = phone
    }

    func signOut() async {
        await PushManager.shared.forgetToken()
        try? await client.auth.signOut()
    }
}

/// The private half of your account.
struct AccountDetails: Equatable {
    var birthday: Date?
    /// Digits, optionally with a leading +.
    var phone: String?

    struct Row: Decodable {
        let birthday: String?
        let phone: String?
    }

    init() {}
    init(_ row: Row) {
        birthday = row.birthday.flatMap(Self.dayFormatter.date(from:))
        phone = row.phone
    }

    /// Postgres `date` <-> Date, in the phone's own calendar day.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// (206) 334-9862 for US numbers, as typed otherwise.
    static func display(phone: String) -> String {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11, digits.first == "1" { digits.removeFirst() }
        guard digits.count == 10, !phone.hasPrefix("+") || phone.hasPrefix("+1") else { return phone }
        let d = Array(digits)
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}
