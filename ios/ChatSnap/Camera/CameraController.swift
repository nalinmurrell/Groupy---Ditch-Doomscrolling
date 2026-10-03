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
    /// Zoom as a multiple of the lens's widest view. Main thread.
    @Published private(set) var zoomFactor: CGFloat = 1
    /// True while two fingers are pinching the viewfinder; the tab pager
    /// stands down so a sideways pinch doesn't page away.
    @Published var isPinching = false
    /// Zoom when the current pinch or shutter-drag began.
    private var zoomAtGestureStart: CGFloat = 1
    /// Snapchat stops around here; past it the image is mush anyway.
    nonisolated static let maxZoom: CGFloat = 10
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
    /// Snapchat's shutter: the live feed's newest frame *is* the photo, so a
    /// tap has nothing to wait for. (The photo output is kept for flash.)
    private let frameOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "com.chatsnap.camera.frames")
    private let frameLock = NSLock()
    private var latestFrame: (buffer: CVPixelBuffer, at: CFTimeInterval)?
    private lazy var frameContext = CIContext(options: [.cacheIntermediates: false])
    private var audioInput: AVCaptureDeviceInput?
    /// Asks iOS which way is up for the active camera. Its angle replaces a
    /// hard-coded 90°, which was right for every older iPhone's sensors but
    /// turned the square front camera on iPhone 17/18 photos sideways.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Width/height of the on-screen viewfinder (see CameraCard). Main thread.
    var viewfinderAspect: CGFloat = 9.0 / 16.0
    /// Width/height of the viewfinder at capture time. Read off-main by the
    /// photo delegate, set on main just before each capture.
    private nonisolated(unsafe) var snapAspect: CGFloat = 9.0 / 16.0
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

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
                self.movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxVideoSeconds, preferredTimescale: 600)
                if let connection = self.movieOutput.connection(with: .video),
                   self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                    self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                }
            }
            if self.session.canAddOutput(self.frameOutput) {
                self.frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.frameOutput.alwaysDiscardsLateVideoFrames = true
                self.frameOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
                self.session.addOutput(self.frameOutput)
            }
            // Mic only if already allowed; otherwise it's asked for on the
            // first hold-to-record, not on launch.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                self.attachMicrophone()
            }

            self.session.commitConfiguration()
            self.tunePhotoOutput(for: device)
            self.trackRotation(of: device)
            self.orientMovieConnection(mirrored: false)
            self.isConfigured = true
            self.session.startRunning()
            self.publish { $0.status = .running }
        }
    }

    /// Set up for a fast shutter, Snapchat-style: speed over extra processing,
    /// no bigger than 12 MP (the 24/48 MP options are slow to capture and to
    /// crop, and a snap is viewed on a phone), and Apple's zero-shutter-lag /
    /// responsive capture where the camera supports them. Session queue.
    private func tunePhotoOutput(for device: AVCaptureDevice) {
        photoOutput.maxPhotoQualityPrioritization = .speed
        photoOutput.maxPhotoDimensions = Self.photoDimensions(for: device)
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
    }

    /// The biggest still the active format offers, up to about 12 MP.
    private static func photoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions {
        let options = device.activeFormat.supportedMaxPhotoDimensions
        let cap: Int32 = 12_300_000
        return options.filter { $0.width * $0.height <= cap }.max { $0.width * $0.height < $1.width * $1.height }
            ?? options.min { $0.width * $0.height < $1.width * $1.height }
            ?? CMVideoDimensions(width: 1920, height: 1080)
    }

    /// Upright for a portrait screen, from the active camera's rotation
    /// coordinator (90° on most iPhones, but not every sensor is mounted the
    /// same way). The UI is portrait-only, so the preview angle is the one we
    /// want for captures too, whichever way the phone is physically held.
    private var portraitAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
    }

    /// New coordinator for a new camera; re-orient everything whenever its
    /// answer changes (e.g. once the preview layer lands in a window).
    private func trackRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.orientMovieConnection(mirrored: self.videoInput?.device.position == .front)
                self.orientPreview()
            }
        }
        orientPreview()
    }

    private func orientPreview() {
        let angle = portraitAngle
        DispatchQueue.main.async { [previewLayer] in
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    /// Portrait, and mirrored for selfies so the clip matches the preview.
    /// Done once per camera rather than at each record start, which would
    /// add a reconfigure to the hold-to-record latency.
    /// Upright and (for selfies) mirrored like the preview: the movie file,
    /// and the live frames the shutter grabs.
    private func orientMovieConnection(mirrored: Bool) {
        let angle = portraitAngle
        for connection in [movieOutput.connection(with: .video), frameOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
        // A frame from the old camera or angle mustn't become the next snap.
        frameLock.withLock { latestFrame = nil }
    }

    /// The mic was allowed somewhere else (a voice note): give videos sound
    /// from now on, not just after the next launch.
    func microphoneAllowed() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.audioInput == nil, !self.movieOutput.isRecording else { return }
            self.session.beginConfiguration()
            self.attachMicrophone()
            self.session.commitConfiguration()
            self.orientMovieConnection(mirrored: self.videoInput?.device.position == .front)
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
                self.tunePhotoOutput(for: device)
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()

            let settled = self.videoInput?.device.position ?? .back
            if let device = self.videoInput?.device { self.trackRotation(of: device) }
            self.orientMovieConnection(mirrored: settled == .front)
            self.publish {
                $0.position = settled
                // A different lens starts wide; say so.
                $0.zoomFactor = 1
            }
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
        // What the viewfinder card shows; the photo gets cut to match.
        snapAspect = viewfinderAspect

        // No flash: take the frame that's on screen right now, like Snapchat.
        if flash == .off, let image = grabLiveFrame() {
            publishInstantly {
                $0.isCapturing = false
                $0.snap = Snap(image: image)
            }
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .speed
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }

            if let connection = self.photoOutput.connection(with: .video) {
                // Snaps are always portrait — the UI is locked to portrait too.
                let angle = self.portraitAngle
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
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

    /// The newest live frame as an upright photo cut to the viewfinder's
    /// shape, or nil if there isn't a fresh one (the feed paused, the camera
    /// just flipped) — the caller then takes a real photo instead.
    private func grabLiveFrame() -> UIImage? {
        guard let frame = frameLock.withLock({ latestFrame }),
              CACurrentMediaTime() - frame.at < 0.25 else { return nil }
        let image = CIImage(cvPixelBuffer: frame.buffer)
        guard let cg = frameContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg).centerCropped(toAspect: snapAspect)
    }

    // MARK: - Zoom

    func beginZoomGesture() {
        zoomAtGestureStart = zoomFactor
    }

    /// Pinch: scale relative to where the pinch started.
    func zoom(pinchScale: CGFloat) {
        setZoom(zoomAtGestureStart * pinchScale)
    }

    /// Recording: slide up from the shutter to zoom in, back down to undo.
    /// Every 80pt of travel is roughly another 1x.
    func zoom(slideUp points: CGFloat) {
        setZoom(zoomAtGestureStart + points / 80)
    }

    private func setZoom(_ factor: CGFloat) {
        let clamped = min(max(factor, 1), Self.maxZoom)
        guard abs(clamped - zoomFactor) > 0.001 else { return }
        zoomFactor = clamped
        guard !usesSimulatorFeed else { return }
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            let upper = min(Self.maxZoom, device.maxAvailableVideoZoomFactor)
            let z = min(max(clamped, device.minAvailableVideoZoomFactor), upper)
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = z
            device.unlockForConfiguration()
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
        zoomAtGestureStart = zoomFactor
        guard !usesSimulatorFeed else { return }
        // Only if the mic question is already settled; a first-ever tap
        // shouldn't pop a permission prompt.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined {
            beginFile()
        }
    }

    /// Finger moved while pressing the shutter. Only zooms once it's a video.
    func pressMoved(_ offset: CGSize) {
        guard isRecording else { return }
        zoom(slideUp: -offset.height)
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
                    if let url = SimulatorFeed.clip() { withoutAnimation { self.snap = Snap(videoURL: url) } }
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
        // Gone at once, like Snapchat, not slid away.
        withoutAnimation { snap = nil }
        // Like Snapchat: each new snap starts wide.
        setZoom(1)
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
                withoutAnimation { self.snap = Snap(image: image) }
            }
        }
    }

    // MARK: - Helpers

    private func publish(_ mutate: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }

    /// For changes that put a snap up for review: no animation, so the review
    /// appears the instant the photo's ready instead of sliding up as a sheet
    /// (that slide was most of the shutter's felt delay — measured ~60ms to
    /// the photo, then half a second of animation).
    private func publishInstantly(_ mutate: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { withoutAnimation { mutate(self) } }
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
        publishInstantly {
            $0.isRecording = false
            if usable && !discard { $0.snap = Snap(videoURL: outputFileURL) }
        }
    }
}

// MARK: - Live frames

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.withLock { latestFrame = (buffer, CACurrentMediaTime()) }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Cropped to the viewfinder's shape: the preview fills its card, but a
        // sensor can hand back a wider frame than it showed — the square
        // front cameras on newer iPhones do — which then arrived cropped
        // sideways. Now what you saw is what's sent, on every model.
        let image = photo.fileDataRepresentation()
            .flatMap(UIImage.init(data:))
            .map { $0.centerCropped(toAspect: snapAspect) }
        publishInstantly {
            $0.isCapturing = false
            if let image { $0.snap = Snap(image: image) }
        }
    }
}


extension UIImage {
    /// The centred slice of this image with the given width/height ratio,
    /// upright (orientation baked in), at the original resolution.
    func centerCropped(toAspect aspect: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        guard w > 0, h > 0, aspect > 0 else { return self }
        let target = w / h > aspect
            ? CGSize(width: (h * aspect).rounded(), height: h)
            : CGSize(width: w, height: (w / aspect).rounded())
        // Already that shape (within a pixel or two): leave it alone.
        if abs(target.width - w) < 2 && abs(target.height - h) < 2 { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // draw(in:) applies imageOrientation, so the result is upright.
            draw(in: CGRect(
                x: (target.width - w) / 2,
                y: (target.height - h) / 2,
                width: w, height: h
            ))
        }
    }
}
