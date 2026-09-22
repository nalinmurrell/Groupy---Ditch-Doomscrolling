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
    @Published private(set) var isRecording = false
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

    /// The one preview layer for the whole app. Attaching a layer to a running
    /// session takes the session's configuration lock and can stall the main
    /// thread for seconds, so this is created once, before the session runs,
    /// and views move it between themselves (see `CameraPreview`).
    let previewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "com.chatsnap.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

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
            // 1080p 16:9: what video needs, and it fills the screen. Stills
            // still come out at the format's full photo size (see below).
            self.session.sessionPreset = .high

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
            self.photoOutput.maxPhotoDimensions = Self.maxPhotoDimensions(for: device)

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
                self.movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxVideoSeconds, preferredTimescale: 600)
                if let connection = self.movieOutput.connection(with: .video),
                   self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                    self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                }
            }
            // Mic only if already allowed; otherwise it's asked for on the
            // first hold-to-record, not on launch.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                self.attachMicrophone()
            }

            self.session.commitConfiguration()
            if let connection = self.previewLayer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.orientMovieConnection(mirrored: false)
            self.isConfigured = true
            self.session.startRunning()
            self.publish { $0.status = .running }
        }
    }

    /// The biggest still the active (video) format can deliver.
    private static func maxPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions {
        device.activeFormat.supportedMaxPhotoDimensions.max { $0.width * $0.height < $1.width * $1.height }
            ?? CMVideoDimensions(width: 1920, height: 1080)
    }

    /// Portrait, and mirrored for selfies so the clip matches the preview.
    /// Done once per camera rather than at each record start, which would
    /// add a reconfigure to the hold-to-record latency.
    private func orientMovieConnection(mirrored: Bool) {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// Must be called inside begin/commitConfiguration on the session queue.
    private func attachMicrophone() {
        guard audioInput == nil,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
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
                self.photoOutput.maxPhotoDimensions = Self.maxPhotoDimensions(for: device)
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()

            let settled = self.videoInput?.device.position ?? .back
            self.orientMovieConnection(mirrored: settled == .front)
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
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
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

    // MARK: - Shutter press

    // Snapchat's trick: the recorder starts the moment the finger lands, so
    // a hold loses nothing to spin-up. Lift before the threshold and the
    // clip is binned and a photo taken instead. File state below lives on
    // the session queue.
    private var isPressed = false
    private var fileCancelled = false
    private var fileDiscard = false
    /// Snapchat-ish cap; keeps a clip well under the upload limit.
    nonisolated static let maxVideoSeconds: Double = 15

    func pressBegan() {
        guard status == .running, !isCapturing, !isRecording, !isPressed else { return }
        isPressed = true
        guard !usesSimulatorFeed else { return }
        // Only if the mic question is already settled; a first-ever tap
        // shouldn't pop a permission prompt.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined {
            beginFile()
        }
    }

    /// The press crossed the threshold: it's a video now.
    func holdConfirmed() {
        guard isPressed else { return }
        isRecording = true
        guard !usesSimulatorFeed else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.async {
                    if granted {
                        self.session.beginConfiguration()
                        self.attachMicrophone()
                        self.session.commitConfiguration()
                        self.orientMovieConnection(mirrored: self.videoInput?.device.position == .front)
                    }
                    // Still held after the prompt? Then record.
                    DispatchQueue.main.async { if self.isPressed { self.beginFile() } }
                }
            }
        }
    }

    func pressEnded() {
        guard isPressed else { return }
        isPressed = false
        if isRecording {
            if usesSimulatorFeed {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRecording = false
                    if let url = SimulatorFeed.clip() { self.snap = Snap(videoURL: url) }
                }
            } else {
                endFile(discard: false)
            }
        } else {
            if !usesSimulatorFeed { endFile(discard: true) }
            capture()
        }
    }

    private func beginFile() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.fileCancelled = false
            self.fileDiscard = false
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func endFile(discard: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.fileDiscard = discard
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                // Asked to start but not rolling yet; stop it as soon as it is.
                self.fileCancelled = true
            }
        }
    }

    func discardSnap() {
        if let url = snap?.videoURL { try? FileManager.default.removeItem(at: url) }
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

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        sessionQueue.async { [weak self] in
            guard let self, self.fileCancelled else { return }
            self.fileCancelled = false
            self.movieOutput.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Hitting the duration cap reports as an error but the file is fine.
        let usable = error == nil
            || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let discard = fileDiscard
        if discard || !usable { try? FileManager.default.removeItem(at: outputFileURL) }
        publish {
            $0.isRecording = false
            if usable && !discard { $0.snap = Snap(videoURL: outputFileURL) }
        }
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
