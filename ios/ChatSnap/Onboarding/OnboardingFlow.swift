import SwiftUI

/// Welcome → account → camera. A returning user who's already signed in
/// lands straight on the camera step.
struct OnboardingFlow: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var camera: CameraController
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false

    private enum Step: Int, CaseIterable {
        case welcome, account, camera
    }

    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                progress
                    .padding(.top, 20)
                    .padding(.horizontal, 32)

                Group {
                    switch step {
                    case .welcome: welcome
                    case .account: AccountStep { advance(to: .camera) }
                    case .camera:  cameraStep
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            if session.isSignedIn { step = .camera }
        }
        .onChange(of: session.isSignedIn) { _, signedIn in
            // Signing in mid-flow (or signing out) moves the step to match.
            step = signedIn ? .camera : .welcome
        }
    }

    // MARK: - Steps

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.white : Color.white.opacity(0.18))
                    .frame(height: 3)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
            Text("ChatSnap")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Text("Opens to the camera. Shoot something, send it to the people you actually talk to. That's the app.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            PrimaryButton("Get Started") { advance(to: .account) }
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 32)
    }

    private var cameraStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text("Turn on the camera")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text("ChatSnap opens straight to the viewfinder, so it needs camera access to do anything at all.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()

            // RootView also needs the profile row before it opens the app, so
            // surface that load here rather than leaving a dead button.
            if session.isSignedIn && session.me == nil {
                VStack(spacing: 8) {
                    if let error = session.profileError {
                        Text("Couldn't load your profile: \(error)")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await session.loadProfile() } }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white.opacity(0.6))
                            Text("Loading your profile…")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 12)
            }

            PrimaryButton("Allow Camera", enabled: session.me != nil) {
                // Triggers the system prompt, then hands off — this flag is
                // what flips RootView into the app proper.
                camera.start()
                didFinishOnboarding = true
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 32)
        .task {
            if session.isSignedIn && session.me == nil { await session.loadProfile() }
        }
    }

    private func advance(to next: Step) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}

// MARK: - Account

private struct AccountStep: View {
    @EnvironmentObject private var session: SessionStore
    let onSignedIn: () -> Void

    private enum Mode { case signUp, signIn }

    @State private var mode: Mode = .signUp
    @State private var displayName = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var awaitingConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer().frame(height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text(mode == .signUp ? "Who are you?" : "Welcome back")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(mode == .signUp ? "Your friends will see this." : "Sign in to your account.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if mode == .signUp {
                    if !displayName.isEmpty {
                        HStack(spacing: 12) {
                            Avatar(subject: Profile(id: UUID(), username: username, displayName: displayName), size: 44)
                            Text(username.isEmpty ? displayName : "@\(username.lowercased())")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Field(title: "Display name", text: $displayName, prompt: "Nalin M")
                    Field(title: "Username", text: $username, prompt: "nalinm", autocapitalize: false)
                    if let problem = UsernameRule.problem(with: username), !username.isEmpty {
                        Text(problem)
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                    }
                }

                Field(title: "Email", text: $email, prompt: "you@example.com", autocapitalize: false, keyboard: .emailAddress)
                Field(title: "Password", text: $password, prompt: "At least 6 characters", autocapitalize: false, secure: true)

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                if awaitingConfirmation {
                    Text("Check your email for a confirmation link, then sign in.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(14)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer().frame(height: 8)

                PrimaryButton(
                    isBusy ? "…" : (mode == .signUp ? "Create Account" : "Sign In"),
                    enabled: canSubmit && !isBusy,
                    action: submit
                )

                Button {
                    withAnimation { mode = mode == .signUp ? .signIn : .signUp }
                    error = nil
                    awaitingConfirmation = false
                } label: {
                    Text(mode == .signUp ? "Already have an account? Sign in" : "New here? Create an account")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var canSubmit: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        let passwordOK = password.count >= 6
        switch mode {
        case .signIn:
            return emailOK && passwordOK
        case .signUp:
            return emailOK && passwordOK
                && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
                && UsernameRule.problem(with: username) == nil
        }
    }

    private func submit() {
        isBusy = true
        error = nil
        awaitingConfirmation = false
        Task {
            defer { isBusy = false }
            do {
                switch mode {
                case .signUp:
                    let needsConfirmation = try await session.signUp(
                        email: email.trimmingCharacters(in: .whitespaces),
                        password: password,
                        displayName: displayName.trimmingCharacters(in: .whitespaces),
                        username: username.lowercased().trimmingCharacters(in: .whitespaces)
                    )
                    if needsConfirmation {
                        awaitingConfirmation = true
                        mode = .signIn
                    } else {
                        onSignedIn()
                    }
                case .signIn:
                    try await session.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                    onSignedIn()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Pieces

private struct Field: View {
    let title: String
    @Binding var text: String
    let prompt: String
    var autocapitalize: Bool = true
    var keyboard: UIKeyboardType = .default
    var secure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.4))
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.25)))
                } else {
                    TextField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.25)))
                        .keyboardType(keyboard)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(autocapitalize ? .words : .never)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? .black : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(enabled ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
