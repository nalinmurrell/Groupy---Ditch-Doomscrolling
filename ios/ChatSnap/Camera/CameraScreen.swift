import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if camera.usesSimulatorFeed {
                    SimulatorFeed()
                } else {
                    CameraPreview(layer: camera.previewLayer, isActive: camera.captureTarget == nil)
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
                controls
            }
        }
        // While the in-thread camera is up, its snap isn't ours to show.
        .fullScreenCover(item: Binding(
            get: { camera.captureTarget == nil ? camera.snap : nil },
            set: { camera.snap = $0 }
        )) { snap in
            SnapReviewScreen(snap: snap)
                .environmentObject(camera)
                .environmentObject(store)
                .environmentObject(session)
        }
    }

    private var controls: some View {
        VStack {
            // Controls stack down the right edge, Snapchat-style.
            HStack {
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
                isEnabled: camera.status == .running && session.me != nil,
                onPressBegan: camera.pressBegan,
                onHold: camera.holdConfirmed,
                onPressEnded: camera.pressEnded
            )
            .padding(.bottom, AppTabBar.height + 24)
        }
    }
}

// MARK: - Pieces

struct ShutterButton: View {
    let isCapturing: Bool
    let isRecording: Bool
    /// Off while the camera warms up or the session is still being restored.
    let isEnabled: Bool
    let onPressBegan: () -> Void
    let onHold: () -> Void
    let onPressEnded: () -> Void

    /// Held longer than this and it's a video, not a photo. Recording is
    /// already rolling by then, so this only decides which one you get.
    private let holdThreshold: TimeInterval = 0.2

    @State private var pressStart: Date?
    @State private var isHolding = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(isEnabled ? 1 : 0.3), lineWidth: 5)
                .frame(width: 78, height: 78)
            // Fills over the clip's max length while recording.
            if isRecording {
                RecordingRing(seconds: CameraController.maxVideoSeconds)
                    .frame(width: 78, height: 78)
            }
            Circle()
                .fill(isRecording ? Color.red : .white.opacity(isCapturing ? 0.9 : (isEnabled ? 0.15 : 0.05)))
                .frame(width: isRecording ? 40 : 62, height: isRecording ? 40 : 62)
        }
        .contentShape(Circle())
        .scaleEffect(isCapturing ? 0.92 : (isRecording ? 1.12 : 1))
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isCapturing)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isRecording)
        .animation(.easeInOut(duration: 0.25), value: isEnabled)
        .opacity(isEnabled ? 1 : 0.8)
        .overlay {
            PressDetector(onBegan: began, onEnded: ended)
                .clipShape(Circle())
        }
        .allowsHitTesting(isEnabled && !isCapturing)
    }

    /// Touch-down starts things, the threshold makes it a hold, release
    /// ends it; the controller sorts out photo vs video.
    private func began() {
        guard pressStart == nil else { return }
        pressStart = Date()
        onPressBegan()
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold) {
            guard pressStart != nil, !isHolding else { return }
            isHolding = true
            onHold()
        }
    }

    private func ended() {
        guard pressStart != nil else { return }
        pressStart = nil
        isHolding = false
        onPressEnded()
    }
}

/// A red arc that sweeps the full circle over `seconds`.
private struct RecordingRing: View {
    let seconds: Double
    @State private var progress: CGFloat = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .onAppear { withAnimation(.linear(duration: seconds)) { progress = 1 } }
    }
}

struct CircleButton: View {
    let systemName: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.28), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct PermissionPrompt: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
            Text("ChatSnap needs the camera")
                .font(.title3.weight(.semibold))
            Text("It's the whole app. Turn it on in Settings and come back.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

struct MessagePlate: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(32)
    }
}
