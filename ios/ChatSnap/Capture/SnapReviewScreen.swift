import SwiftUI

/// What you just shot, with the one decision that matters: send it, or don't.
struct SnapReviewScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    let snap: Snap

    @State private var isPickingRecipients = false
    @State private var isSending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraCard {
                ZStack {
                    SnapPreview(snap: snap)

                    VStack {
                        HStack {
                            Button(action: camera.discardSnap) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.28), in: Circle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        Spacer()
                    }
                }
            }
        }
        // Snapchat's bar in the strip under the snap: save, then a big
        // white Send To. (Their Story button left out — no stories here.)
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                SaveSnapButton(snap: snap, inPill: true)
                Button { isPickingRecipients = true } label: {
                    HStack(spacing: 10) {
                        Text(isSending ? "Sending…" : "Send To")
                            .font(.system(size: 20, weight: .bold))
                        if isSending {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 20, weight: .bold))
                        }
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        // fullScreenCover presents outside RootView, so the status bar has to
        // be hidden again here or it collides with the close button.
        .statusBarHidden()
        .sheet(isPresented: $isPickingRecipients) {
            SendToSheet { conversationIDs in
                isPickingRecipients = false
                isSending = true
                Task {
                    await store.send(snap, to: conversationIDs)
                    // Back to the camera, the way Snapchat does it — the snap
                    // is already in the thread.
                    camera.discardSnap()
                }
            }
            .environmentObject(store)
            .environmentObject(session)
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }
}
