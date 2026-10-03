import SwiftUI

/// What you just shot, with the one decision that matters: send it, or don't.
struct SnapReviewScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore
    let snap: Snap

    /// Chosen with the picker; empty until then.
    @State private var recipients: [Conversation.ID] = []
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

                        SnapSendBar(
                            snap: snap,
                            recipients: $recipients,
                            isSending: isSending
                        ) {
                            isSending = true
                            Task {
                                await store.send(snap, to: recipients)
                                // Back to the camera, the way Snapchat does
                                // it — the snap is already in the thread.
                                camera.discardSnap()
                            }
                        }
                    }
                }
            }
        }
        // fullScreenCover presents outside RootView, so the status bar has to
        // be hidden again here or it collides with the close button.
        .statusBarHidden()
    }
}
