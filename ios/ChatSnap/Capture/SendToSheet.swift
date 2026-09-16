import SwiftUI

/// Pick who gets the snap. Multi-select, because sending one shot to a few
/// people at once is the whole point.
struct SendToSheet: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    let onSend: ([Conversation.ID]) -> Void

    @State private var selected: Set<Conversation.ID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sortedConversations) { conversation in
                        Button {
                            toggle(conversation.id)
                        } label: {
                            row(conversation)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 90)
            }
            .background(Color.black)
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSend(Array(selected))
                } label: {
                    Text(selected.isEmpty ? "Select someone" : "Send to \(selected.count)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected.isEmpty ? .white.opacity(0.4) : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            selected.isEmpty ? Color.white.opacity(0.12) : Color.white,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 14) {
            if let who = conversation.counterpart(for: session.userID) {
                Avatar(subject: who)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title(for: session.userID))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                if let who = conversation.counterpart(for: session.userID), !conversation.isGroup {
                    Text("@\(who.username)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            Image(systemName: selected.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected.contains(conversation.id) ? .white : .white.opacity(0.25))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func toggle(_ id: Conversation.ID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}
