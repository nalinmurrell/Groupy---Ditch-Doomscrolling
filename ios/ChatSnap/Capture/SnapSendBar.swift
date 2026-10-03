import SwiftUI

/// The bottom of a snap you've just taken, Snapchat's layout: save-to-Photos
/// on its own above, then "+ More Friends", a pill naming who it's going to,
/// and the white send arrow. With nobody chosen yet (the main camera), the
/// pill is "Send To" and opens the picker.
struct SnapSendBar: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    let snap: Snap
    @Binding var recipients: [Conversation.ID]
    let isSending: Bool
    let onSend: () -> Void

    @State private var isPicking = false

    private var titles: [String] {
        recipients.compactMap { store.conversation($0)?.title(for: session.userID) }
    }

    private var isGroupish: Bool {
        recipients.count > 1 || recipients.first.flatMap { store.conversation($0)?.isGroup } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SaveSnapButton(snap: snap)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(.leading, 22)

            HStack(spacing: 10) {
                if !recipients.isEmpty {
                    Button { isPicking = true } label: {
                        Text("+ More Friends")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }

                Button { isPicking = true } label: {
                    HStack(spacing: 8) {
                        if !recipients.isEmpty {
                            Image(systemName: isGroupish ? "person.3.fill" : "person.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        // "Gregory", or "Gregory +2" — the count never gets
                        // cut off; the name shrinks or truncates first.
                        Text(titles.first ?? "Send To")
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if titles.count > 1 {
                            Text("+\(titles.count - 1)")
                                .font(.system(size: 18, weight: .bold))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(.white.opacity(0.22), in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onSend) {
                    Group {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white.opacity(recipients.isEmpty ? 0.35 : 1))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(recipients.isEmpty || isSending)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(.black.opacity(0.35))
        }
        .sheet(isPresented: $isPicking) {
            SendToSheet(preselected: Set(recipients), isChoosingOnly: true) { chosen in
                isPicking = false
                // Keep the order: the original chat first, additions after.
                recipients = recipients.filter(chosen.contains) + chosen.filter { !recipients.contains($0) }
            }
            .environmentObject(store)
            .environmentObject(session)
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }
}

/// Saves the snap you've just taken to Photos; shows a tick once it has.
/// `inPill`: the grey rounded button of the main camera's bottom bar.
struct SaveSnapButton: View {
    let snap: Snap
    var inPill = false

    @State private var state: SaveState = .idle
    private enum SaveState { case idle, saving, saved, failed }

    var body: some View {
        Button {
            state = .saving
            Task {
                let ok = await PhotoLibrarySaver.save(snap)
                state = ok ? .saved : .failed
                UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
                if !ok {
                    try? await Task.sleep(for: .seconds(1.5))
                    state = .idle
                }
            }
        } label: {
            Group {
                switch state {
                case .idle: Image(systemName: "arrow.down.to.line")
                case .saving: ProgressView().tint(.white)
                case .saved: Image(systemName: "checkmark")
                case .failed: Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .font(.system(size: inPill ? 22 : 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: inPill ? 76 : 44, height: inPill ? 52 : 44)
            .background(inPill ? Color.white.opacity(0.16) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state == .saving || state == .saved)
        .accessibilityLabel("Save to Photos")
    }
}
