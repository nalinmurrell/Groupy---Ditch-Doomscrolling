import AVFoundation
import SwiftUI
import UIKit

/// Owns the AVCaptureSession. All session mutation happens on `sessionQueue`;
/// everything published to SwiftUI is hopped back to main.
final class CameraController: NSObject, ObservableObject {

    enum Status: Equatable {
        case starting
        case running
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var isCapturing = false
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published var flashMode: AVCaptureDevice.FlashMode = .off

    /// The photo the user just took. Non-nil means we're on the review screen.
    @Published var snap: Snap?

    /// Set while the in-thread camera is up: snaps then belong to that
    /// conversation and the main camera pane must not present them.
    @Published var captureTarget: UUID?

    /// True only in the Simulator, where there is no camera to preview.
    @Published private(set) var usesSimulatorFeed = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.chatsnap.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureThenRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureThenRun()
                } else {
                    self.publish { $0.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func resume() {
        guard status != .denied else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func suspend() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Configuration

    private func configureThenRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isConfigured else {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let device = Self.device(at: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                #if targetEnvironment(simulator)
                self.publish {
                    $0.usesSimulatorFeed = true
                    $0.status = .running
                }
                #else
                self.publish { $0.status = .failed("No camera available on this device.") }
                #endif
                return
            }
            self.session.addInput(input)
            self.videoInput = input

            guard self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                self.publish { $0.status = .failed("Couldn't attach the photo output.") }
                return
            }
            self.session.addOutput(self.photoOutput)
            self.photoOutput.maxPhotoQualityPrioritization = .balanced

            self.session.commitConfiguration()
            self.isConfigured = true
            self.session.startRunning()
            self.publish { $0.status = .running }
        }
    }

    private static func device(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: position
        ).devices.first
    }

    // MARK: - Controls

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let current = self.videoInput else { return }
            let next: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = Self.device(at: next),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()

            let settled = self.videoInput?.device.position ?? .back
            self.publish { $0.position = settled }
        }
    }

    func toggleFlash() {
        flashMode = flashMode == .off ? .on : .off
    }

    // MARK: - Capture

    func capture() {
        guard status == .running, !isCapturing else { return }
        isCapturing = true

        if usesSimulatorFeed {
            captureSimulatorFrame()
            return
        }

        let flash = flashMode
        let mirrored = position == .front

        sessionQueue.async { [weak self] in
            guard let self else { return }

            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }

            if let connection = self.photoOutput.connection(with: .video) {
                // Snaps are always portrait — the UI is locked to portrait too.
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                // Match what the user saw in the mirrored selfie preview.
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
            }

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func discardSnap() {
        snap = nil
    }

    private func captureSimulatorFrame() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A beat of delay so the shutter animation reads the same here as
            // it will with a real capture round-trip.
            try? await Task.sleep(for: .milliseconds(120))
            let size = UIScreen.main.bounds.size
            self.isCapturing = false
            if let image = SimulatorFeed.still(size: size) {
                self.snap = Snap(image: image)
            }
        }
    }

    // MARK: - Helpers

    private func publish(_ mutate: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        publish {
            $0.isCapturing = false
            if let image { $0.snap = Snap(image: image) }
        }
    }
}
