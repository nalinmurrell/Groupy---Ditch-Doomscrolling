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

            // A real photo is 4:3, the screen isn't. Fill from a screen-sized
            // base and clip, otherwise the image widens the whole ZStack and
            // pushes the corner buttons off the edges.
            Color.clear
                .overlay {
                    Image(uiImage: snap.image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()

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

                HStack {
                    Spacer()
                    Button {
                        isPickingRecipients = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(isSending ? "Sending…" : "Send To")
                                .font(.system(size: 16, weight: .semibold))
                            if isSending {
                                ProgressView().tint(.black).controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
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
