import AVFoundation
import SwiftUI
import UIKit

/// Hold the mic, talk, let go: Snapchat's voice notes. Recording starts on
/// touch-down; sliding left far enough throws it away.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Loudness right now, 0…1, for the pulsing dot.
    @Published private(set) var level: Float = 0
    /// A tap rather than a hold: tell them how it works.
    @Published private(set) var showsHint = false
    @Published var micDenied = false

    static let maxDuration: TimeInterval = 60
    /// Anything shorter was a tap.
    static let minDuration: TimeInterval = 0.5

    /// Hit the length limit with the finger still down: send what's there.
    var onLimitReached: (URL) -> Void = { _ in }

    private var recorder: AVAudioRecorder?
    private var ticker: Timer?
    private var hintReset: DispatchWorkItem?

    /// Touch-down on the mic. The first ever press only asks permission;
    /// `onGranted` lets the camera pick up the mic for videos too.
    func begin(onGranted: @escaping () -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                if granted { DispatchQueue.main.async(execute: onGranted) }
            }
            return
        case .denied:
            micDenied = true
            return
        default:
            break
        }
        VoicePlayer.shared.stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return }
        self.recorder = recorder
        elapsed = 0
        level = 0
        showsHint = false
        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let ticker = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so it keeps ticking while the finger's down.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Lift: the finished file, or nil if it was too short to count.
    func finish() -> URL? {
        guard let recorder, isRecording else { return nil }
        let length = recorder.currentTime
        stop()
        guard length >= Self.minDuration else {
            try? FileManager.default.removeItem(at: recorder.url)
            flashHint()
            return nil
        }
        return recorder.url
    }

    /// Slid away, left the chat, or the app went to the background.
    func cancel() {
        guard let recorder, isRecording else { return }
        stop()
        recorder.deleteRecording()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        recorder?.stop()
        isRecording = false
        level = 0
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -50 dB and below is silence; 0 dB is as loud as it gets.
        level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        if elapsed >= Self.maxDuration, let url = finish() {
            onLimitReached(url)
        }
    }

    private func flashHint() {
        hintReset?.cancel()
        showsHint = true
        let reset = DispatchWorkItem { [weak self] in self?.showsHint = false }
        hintReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }
}

/// One voice note playing at a time, app-wide. Starting another stops this.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    @Published private(set) var playingID: Message.ID?
    /// 1×, 1.5× or 2×, like Snapchat. Sticks for the next note, and the
    /// next launch.
    @Published private(set) var rate: Float
    private var player: AVAudioPlayer?

    static let rates: [Float] = [1, 1.5, 2]
    private static let rateKey = "voiceNoteRate"

    override init() {
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(saved) ? saved : 1
        super.init()
    }

    /// 1× → 1.5× → 2× → 1×, applied to whatever's playing.
    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
    }

    /// How far through the current note, 0…1.
    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    /// Real time left, so at 2× it counts down twice as fast.
    var remaining: TimeInterval {
        guard let player else { return 0 }
        return (player.duration - player.currentTime) / Double(rate)
    }

    func toggle(_ id: Message.ID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        // Out loud through the speaker, like Snapchat, even on silent.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        // Must be on before play for rate to take.
        player.enableRate = true
        player.rate = rate
        guard player.play() else { return }
        self.player = player
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }
}

/// A voice note's length and waveform, read from the file.
struct VoiceNoteInfo: Sendable {
    static let bars = 28

    let duration: TimeInterval
    /// One per bar, 0…1, scaled so the loudest bar is full height.
    let levels: [Float]

    init?(analysing url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0]
        else { return nil }

        duration = Double(file.length) / file.processingFormat.sampleRate
        let count = Int(buffer.frameLength)
        let chunk = max(1, count / Self.bars)
        let loudness: [Float] = (0..<Self.bars).map { bar in
            let start = bar * chunk
            let end = min(count, start + chunk)
            guard start < end else { return 0 }
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
        let peak = max(loudness.max() ?? 0, 0.0001)
        levels = loudness.map { max(0.12, min(1, $0 / peak)) }
    }
}

/// A voice note in the thread: play button, waveform, length. The bars
/// fill in the sender's colour as it plays.
struct VoiceNoteView: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var player = VoicePlayer.shared
    let message: Message
    let color: Color
    /// Held for the actions sheet; the lift isn't a play.
    var isPicked = false

    @State private var info: VoiceNoteInfo?
    @State private var url: URL?

    private var isPlaying: Bool { player.playingID == message.id }

    var body: some View {
        HStack(spacing: 10) {
            playButton
            if isPlaying {
                speedButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPlaying)
        .task(id: message.id) {
            url = await store.file(for: message)
            info = await store.voiceNote(for: message)
        }
    }

    /// Snapchat's speed chip: shows while playing, tap to step through.
    private var speedButton: some View {
        Button { player.cycleRate() } label: {
            Text(Self.rateLabel(player.rate))
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                // Swap the label outright; a crossfade ghosts the old one.
                .contentTransition(.identity)
                .frame(minWidth: 38)
                .padding(.vertical, 5)
                .background(.white.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed \(Self.rateLabel(player.rate))")
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == 1.5 ? "1.5x" : "\(Int(rate))x"
    }

    private var playButton: some View {
        Button {
            guard let url, !isPicked else { return }
            player.toggle(message.id, url: url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color, in: Circle())
                    .opacity(url == nil ? 0.5 : 1)

                TimelineView(.animation(paused: !isPlaying)) { _ in
                    let progress = isPlaying ? player.progress : 0
                    HStack(spacing: 10) {
                        waveform(progress: progress)
                        Text(Self.clock(isPlaying ? player.remaining : info?.duration))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func waveform(progress: Double) -> some View {
        let levels = info?.levels ?? Array(repeating: 0.12, count: VoiceNoteInfo.bars)
        return HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                let played = Double(index) / Double(levels.count) < progress
                Capsule()
                    .fill(played ? color : .white.opacity(0.4))
                    .frame(width: 3, height: 4 + 22 * CGFloat(levels[index]))
            }
        }
        .frame(height: 26)
    }

    /// 0:07, 1:00. Dashes until the file's been read. A running timer
    /// counts whole seconds done, so it rounds down.
    static func clock(_ seconds: TimeInterval?, roundingDown: Bool = false) -> String {
        guard let seconds else { return "-:--" }
        let whole = max(0, Int(roundingDown ? seconds.rounded(.down) : seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// What the message field turns into while you hold the mic.
struct RecordingStrip: View {
    let elapsed: TimeInterval
    let level: Float
    /// How far the finger has slid left (negative), for the cancel cue.
    let slide: CGFloat
    let cancelDistance: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SnapColors.me)
                .frame(width: 9, height: 9)
                .scaleEffect(1 + CGFloat(level) * 0.7)
                .animation(.linear(duration: 0.05), value: level)
            Text(VoiceNoteView.clock(elapsed, roundingDown: true))
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                Text("Slide to cancel")
                    .font(.system(size: 14))
            }
            .foregroundStyle(.white.opacity(0.55))
            .opacity(1 + Double(slide / cancelDistance))
            .offset(x: slide / 3)
        }
    }
}
