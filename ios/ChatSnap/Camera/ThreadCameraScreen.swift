import SwiftUI

/// The camera, opened from inside a thread: shoot, glance, send — the
/// recipient is already decided, so there's no Send To step.
struct ThreadCameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let conversationID: Conversation.ID

    @State private var isSending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let snap = camera.snap {
                review(snap)
            } else {
                live
            }
        }
        .statusBarHidden()
        .onAppear { camera.captureTarget = conversationID }
        .onDisappear {
            camera.captureTarget = nil
            camera.discardSnap()
        }
    }

    private var live: some View {
        ZStack {
            Group {
                if camera.usesSimulatorFeed {
                    SimulatorFeed()
                } else {
                    CameraPreview(session: camera.session)
                }
            }
            .ignoresSafeArea()
            .opacity(camera.status == .running ? 1 : 0)

            switch camera.status {
            case .denied:
                PermissionPrompt()
            case .failed(let message):
                MessagePlate(text: message)
            case .starting, .running:
                EmptyView()
            }

            VStack {
                HStack {
                    CircleButton(systemName: "xmark") { dismiss() }
                    Spacer()
                    VStack(spacing: 14) {
                        CircleButton(
                            systemName: "arrow.triangle.2.circlepath.camera.fill",
                            action: camera.flipCamera
                        )
                        CircleButton(
                            systemName: camera.flashMode == .on ? "bolt.fill" : "bolt.slash.fill",
                            isActive: camera.flashMode == .on,
                            action: camera.toggleFlash
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                ShutterButton(
                    isCapturing: camera.isCapturing,
                    isEnabled: camera.status == .running,
                    action: camera.capture
                )
                .padding(.bottom, 36)
            }
        }
    }

    private func review(_ snap: Snap) -> some View {
        ZStack {
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
                    CircleButton(systemName: "xmark", action: camera.discardSnap)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                HStack {
                    Spacer()
                    Button {
                        isSending = true
                        Task {
                            await store.send(snap, to: [conversationID])
                            camera.discardSnap()
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isSending ? "Sending…" : "Send")
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
    }
}
