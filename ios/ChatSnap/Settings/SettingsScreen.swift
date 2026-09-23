import SwiftUI

private enum Palette {
    static let background = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
    static let field = Color(white: 0.13)
    static let secondary = Color.white.opacity(0.55)
}

/// Snapchat's settings layout: a Groupy+ banner, then My Account — each
/// row its value underneath and a chevron to an edit page.
struct SettingsScreen: View {
    @EnvironmentObject private var session: SessionStore
    /// Closes the whole profile, so sign-out doesn't leave it up.
    let onSignOut: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink { GroupyPlusScreen() } label: { plusBanner }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("My Account")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 6)

                row("Name", session.me?.displayName) { NameEditScreen() }
                row("Username", session.me?.username) { UsernameEditScreen() }
                row("Birthday", session.details.birthday?.formatted(date: .long, time: .omitted)) { BirthdayEditScreen() }
                row("Mobile Number", session.details.phone.map(AccountDetails.display(phone:))) { PhoneEditScreen() }
                row("Email", session.email) { EmailEditScreen() }

                Button {
                    onSignOut()
                    Task { await session.signOut() }
                } label: {
                    Text("Log Out")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(height: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            }
            .padding(.bottom, 40)
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .task { await session.loadDetails() }
    }

    private var plusBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .semibold))
            Text("Manage Groupy+")
                .font(.system(size: 19, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(red: 0.55, green: 0.38, blue: 0.1))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 20)
        .frame(height: 70)
        .background(
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.88, blue: 0.58), Color(red: 0.93, green: 0.74, blue: 0.40)],
                startPoint: .leading, endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func row<Destination: View>(
        _ title: String, _ value: String?, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                    if let value, !value.isEmpty {
                        Text(value)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 20)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit pages

/// Snapchat's edit page: a line of explanation, full-width fields, Save.
private struct EditPage<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let explanation: String
    let canSave: Bool
    let save: () async throws -> String?
    @ViewBuilder let fields: () -> Fields

    @State private var isSaving = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(explanation)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 16)
                .padding(.bottom, 22)
            VStack(spacing: 0) { fields() }
            if let error {
                Text(error).font(.system(size: 14)).foregroundStyle(.orange).padding(20)
            }
            if let notice {
                Text(notice).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).padding(20)
            }
            Spacer()
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    isSaving = true
                    error = nil
                    Task {
                        defer { isSaving = false }
                        do {
                            // A returned notice means "done, but read this" — stay put.
                            if let message = try await save() { notice = message } else { dismiss() }
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .disabled(!canSave || isSaving)
                .foregroundStyle(canSave && !isSaving ? .white : .white.opacity(0.3))
            }
        }
        .toolbarBackground(Palette.background, for: .navigationBar)
    }
}

/// One full-width input row, hairlines above and below.
private struct FieldRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(.system(size: 18))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.field)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
    }
}

private func prompt(_ text: String) -> Text {
    Text(text).foregroundColor(.white.opacity(0.3))
}

private struct NameEditScreen: View {
    @EnvironmentObject private var session: SessionStore
    @State private var first = ""
    @State private var last = ""

    private var full: String {
        [first, last].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        EditPage(
            title: "Name",
            explanation: "This is how you appear on Groupy, so pick a name your friends know you by.",
            canSave: (1...40).contains(full.count) && full != session.me?.displayName,
            save: { try await session.updateDisplayName(full); return nil }
        ) {
            FieldRow { TextField("", text: $first, prompt: prompt("First Name")).textContentType(.givenName) }
            FieldRow { TextField("", text: $last, prompt: prompt("Last Name")).textContentType(.familyName) }
        }
        .onAppear {
            let parts = (session.me?.displayName ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            first = parts.first ?? ""
            last = parts.count > 1 ? parts[1] : ""
        }
    }
}

private struct UsernameEditScreen: View {
    @EnvironmentObject private var session: SessionStore
    @State private var username = ""

    private var cleaned: String { username.trimmingCharacters(in: .whitespaces).lowercased() }
    private var problem: String? { UsernameRule.problem(with: cleaned) }

    var body: some View {
        EditPage(
            title: "Username",
            explanation: "Friends find you by your username. Letters, numbers and underscores, 3–15 characters.",
            canSave: problem == nil && cleaned != session.me?.username,
            save: { try await session.updateUsername(cleaned); return nil }
        ) {
            FieldRow {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.white.opacity(0.4))
                    TextField("", text: $username, prompt: prompt("username"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            if let problem, !cleaned.isEmpty, cleaned != session.me?.username {
                Text(problem).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).padding(.top, 10)
            }
        }
        .onAppear { username = session.me?.username ?? "" }
    }
}

private struct BirthdayEditScreen: View {
    @EnvironmentObject private var session: SessionStore
    @State private var date = Calendar.current.date(byAdding: .year, value: -20, to: .now) ?? .now

    private var range: ClosedRange<Date> {
        (Calendar.current.date(from: DateComponents(year: 1901, month: 1, day: 1)) ?? .distantPast)...Date.now
    }

    var body: some View {
        EditPage(
            title: "Birthday",
            explanation: "Only you can see your birthday.",
            canSave: session.details.birthday.map { !Calendar.current.isDate($0, inSameDayAs: date) } ?? true,
            save: { try await session.updateBirthday(date); return nil }
        ) {
            DatePicker("", selection: $date, in: range, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
        }
        .onAppear { if let saved = session.details.birthday { date = saved } }
    }
}

private struct PhoneEditScreen: View {
    @EnvironmentObject private var session: SessionStore
    @State private var phone = ""

    /// Digits, keeping a leading +. Empty means "remove it".
    private var normalized: String? {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return (trimmed.hasPrefix("+") ? "+" : "") + digits
    }

    private var valid: Bool {
        guard let normalized else { return true }
        return (7...15).contains(normalized.filter(\.isNumber).count)
    }

    var body: some View {
        EditPage(
            title: "Mobile Number",
            explanation: "Only you can see your mobile number. Leave it blank to remove it.",
            canSave: valid && normalized != session.details.phone,
            save: { try await session.updatePhone(normalized); return nil }
        ) {
            FieldRow {
                TextField("", text: $phone, prompt: prompt("Mobile Number"))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }
        }
        .onAppear { phone = session.details.phone.map(AccountDetails.display(phone:)) ?? "" }
    }
}

private struct EmailEditScreen: View {
    @EnvironmentObject private var session: SessionStore
    @State private var email = ""

    private var cleaned: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    private var looksValid: Bool {
        let parts = cleaned.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !cleaned.contains(" ")
    }

    var body: some View {
        EditPage(
            title: "Email",
            explanation: "You sign in with this email. Only you can see it.",
            canSave: looksValid && cleaned != session.email?.lowercased(),
            save: {
                let pending = try await session.updateEmail(cleaned)
                return pending ? "Check \(cleaned) for a link to confirm the change. Until then you still sign in with your old email." : nil
            }
        ) {
            FieldRow {
                TextField("", text: $email, prompt: prompt("Email"))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .onAppear { email = session.email ?? "" }
    }
}

// MARK: - Groupy+

/// Where a subscription would be managed. There isn't one yet, and this
/// says so rather than pretending.
private struct GroupyPlusScreen: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 0.98, green: 0.88, blue: 0.58), Color(red: 0.93, green: 0.74, blue: 0.40)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .padding(.top, 80)
            Text("Groupy+")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("Coming soon. You're not subscribed to anything and nothing will be charged.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
    }
}
