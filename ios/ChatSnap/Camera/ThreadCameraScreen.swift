import SwiftUI

/// The camera, opened from inside a thread: shoot, glance, send — the
/// recipient is already decided, so there's no Send To step.
struct ThreadCameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var store: ChatStore
    let conversationID: Conversation.ID
    let onClose: () -> Void

    @State private var isSending = false
    @State private var isShown = false
    /// The viewfinder follows a downward drag; far enough and it's dismissed.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            if let snap = camera.snap {
                review(snap)
            } else {
                live
                    .offset(y: dragOffset)
                    .gesture(swipeDown)
            }
        }
        .statusBarHidden()
        // Presented without the system slide; a short fade instead.
        .opacity(isShown ? 1 : 0)
        .onAppear {
            camera.captureTarget = conversationID
            withAnimation(.easeOut(duration: 0.15)) { isShown = true }
        }
        .onDisappear {
            camera.captureTarget = nil
            camera.discardSnap()
        }
    }

    private var live: some View {
        ZStack {
            // Own backdrop, so the whole card slides and the thread shows
            // through underneath (the cover's background is clear).
            Color.black.ignoresSafeArea()

            Group {
                if camera.usesSimulatorFeed {
                    SimulatorFeed()
                } else {
                    CameraPreview(layer: camera.previewLayer)
                }
            }
            .ignoresSafeArea()
            .opacity(camera.status == .running ? 1 : 0)
            // Snapchat muscle memory: double-tap the viewfinder to flip.
            .doubleTap { camera.flipCamera() }

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
                    CircleButton(systemName: "xmark", action: close)
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
                    isRecording: camera.isRecording,
                    isEnabled: camera.status == .running,
                    onPressBegan: camera.pressBegan,
                    onHold: camera.holdConfirmed,
                    onPressEnded: camera.pressEnded
                )
                .padding(.bottom, 36)
            }
        }
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let flung = value.predictedEndTranslation.height > 260
                if value.translation.height > 120 || flung {
                    withAnimation(.easeIn(duration: 0.18)) {
                        dragOffset = UIScreen.main.bounds.height
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: onClose)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.12)) { isShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onClose)
    }

    private func review(_ snap: Snap) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SnapPreview(snap: snap)

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
                            close()
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
